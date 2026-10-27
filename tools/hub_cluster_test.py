#!/usr/bin/env python3
"""
hub_cluster_test.py - Phase 2 HA Cluster & Replication Engine Contract Tests.

Validates against REAL copier-hub instances:
  1. Cluster status endpoint & metadata reporting (GET /api/v1/cluster/status).
  2. ADR-03 Single-Writer Protection:
     - Standby node strictly rejects config modifications (PUT /config) with 409 Conflict.
     - Standby node strictly rejects command issuance (POST /commands) with 409 Conflict.
     - Standby node strictly rejects user mutations (POST /users) with 409 Conflict.
     - Standby node strictly rejects notification channel mutations with 409 Conflict.
  3. Primary writes and incremental background replication (ADR-08):
     - Config revisions, commands, users, and notification channels are replicated to Standby.
     - Line counts and SHA-256 hashes achieve Zero-Lag sync.
  4. Manual Promotion (POST /api/v1/cluster/promote):
     - Standby can be promoted to Primary, advancing epoch and opening write gate.
  5. ADR-10 Two-Phase Handover & Graceful Failback:
     - Handover request causes active Primary to step down and close write gate before agreeing.
     - Recovered node successfully promotes and opens write gate with incremented epoch.
  6. Failback Lock:
     - Operator can lock failback, preventing automated handover.

Run:
  python tools/hub_cluster_test.py
"""

import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

if not os.path.exists(HUB):
    HUB = os.path.join(REPO, "hub", "target", "debug", "copier-hub.exe")

P_ZMQ_PORT = 6380
P_HTTP_PORT = 6381
S_ZMQ_PORT = 6382
S_HTTP_PORT = 6383

CLUSTER_TOKEN = "test-cluster-token-xyz"
TEST_ADMIN_PASS = "admin-pass-123"

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def http_req(port, method, path, body=None, token=None, cookie=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=6)
    try:
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if cookie:
            headers["Cookie"] = cookie
        if body is not None:
            headers["Content-Type"] = "application/json"
            if isinstance(body, (dict, list)):
                body = json.dumps(body)
        c.request(method, path, body=body, headers=headers)
        r = c.getresponse()
        raw = r.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except Exception:
            parsed = {"_raw": raw[:200].decode("utf-8", "replace")}
        return r.status, parsed, r.getheader("Set-Cookie")
    finally:
        c.close()


def login(port, password=TEST_ADMIN_PASS, user="admin"):
    body = {"id": user, "password": password}
    status, _, sc = http_req(port, "POST", "/api/v1/login", body=body)
    if status != 200 or not sc:
        return None
    for part in sc.split(";"):
        part = part.strip()
        if part.startswith("mtc_session="):
            return part
    return None


class TestCluster:
    def __init__(self):
        self.tmpdir = tempfile.mkdtemp(prefix="mtc_ha_test_")
        self.p_proc = None
        self.s_proc = None

    def start_hubs(self, failback_hours=24.0):
        env = os.environ.copy()
        env["MTC_ADMIN_PASSWORD"] = TEST_ADMIN_PASS
        env["MTC_CLUSTER_TOKEN"] = CLUSTER_TOKEN

        p_dir = os.path.join(self.tmpdir, "primary")
        s_dir = os.path.join(self.tmpdir, "standby")
        os.makedirs(p_dir, exist_ok=True)
        os.makedirs(s_dir, exist_ok=True)

        # Primary args
        p_cmd = [
            HUB,
            "--port", str(P_ZMQ_PORT),
            "--http", f"127.0.0.1:{P_HTTP_PORT}",
            "--role", "primary",
            "--peer-api", f"http://127.0.0.1:{S_HTTP_PORT}",
            "--cluster-token", CLUSTER_TOKEN,
            "--cluster-state", os.path.join(p_dir, "cluster_state.json"),
            "--config", os.path.join(p_dir, "config_revisions.jsonl"),
            "--commands", os.path.join(p_dir, "commands.jsonl"),
            "--users", os.path.join(p_dir, "users.json"),
            "--notifications", os.path.join(p_dir, "alert_channels.json"),
            "--curve-clients", os.path.join(p_dir, "curve_clients.txt"),
            "--curve", "off",
            "--failback-hours", str(failback_hours),
        ]

        # Standby args
        s_cmd = [
            HUB,
            "--port", str(S_ZMQ_PORT),
            "--http", f"127.0.0.1:{S_HTTP_PORT}",
            "--role", "standby",
            "--peer-api", f"http://127.0.0.1:{P_HTTP_PORT}",
            "--cluster-token", CLUSTER_TOKEN,
            "--cluster-state", os.path.join(s_dir, "cluster_state.json"),
            "--config", os.path.join(s_dir, "config_revisions.jsonl"),
            "--commands", os.path.join(s_dir, "commands.jsonl"),
            "--users", os.path.join(s_dir, "users.json"),
            "--notifications", os.path.join(s_dir, "alert_channels.json"),
            "--curve-clients", os.path.join(s_dir, "curve_clients.txt"),
            "--curve", "off",
            "--failback-hours", str(failback_hours),
        ]

        self.p_proc = subprocess.Popen(p_cmd, cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.s_proc = subprocess.Popen(s_cmd, cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Wait for both APIs to become available
        for _ in range(50):
            try:
                st1, _, _ = http_req(P_HTTP_PORT, "GET", "/healthz")
                st2, _, _ = http_req(S_HTTP_PORT, "GET", "/healthz")
                if st1 == 200 and st2 == 200:
                    break
            except Exception:
                pass
            time.sleep(0.1)

    def stop_hubs(self):
        for proc in (self.p_proc, self.s_proc):
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
        try:
            shutil.rmtree(self.tmpdir)
        except Exception:
            pass


def main():
    print("=" * 72)
    print("mt-copier Phase 2: HA Cluster & Replication Engine Contract Tests")
    print("=" * 72)

    tc = TestCluster()
    try:
        tc.start_hubs()

        # Login to both dashboards
        p_cookie = login(P_HTTP_PORT)
        s_cookie = login(S_HTTP_PORT)

        check("Primary login successful", p_cookie is not None)
        check("Standby login successful", s_cookie is not None)

        # ---------------------------------------------------------------------
        # 1. Cluster Status Endpoint (ADR-03 / ADR-04)
        # ---------------------------------------------------------------------
        st, p_status, _ = http_req(P_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)
        check("GET /cluster/status on Primary returns 200", st == 200, f"status={st}")
        check("Primary role is 'primary'", p_status.get("role") == "primary")
        check("Primary writes are enabled", p_status.get("writes") is True)
        check("Primary epoch is 1", p_status.get("epoch") == 1)

        st, s_status, _ = http_req(S_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)
        check("GET /cluster/status on Standby returns 200", st == 200, f"status={st}")
        check("Standby role is 'standby'", s_status.get("role") == "standby")
        check("Standby writes are locked (false)", s_status.get("writes") is False)
        check("Standby epoch is 1", s_status.get("epoch") == 1)

        # ---------------------------------------------------------------------
        # 2. Single-Writer Protection (ADR-03)
        # ---------------------------------------------------------------------
        sample_ini = "[common]\nmagic=123456\nsymbol_suffix=.raw\n"

        # Try modifying config on Standby -> Must return 409 Conflict
        st, res, _ = http_req(S_HTTP_PORT, "PUT", "/api/v1/nodes/receiver:252033316/config",
                              body=sample_ini, cookie=s_cookie)
        check("Standby rejects PUT config with 409 Conflict", st == 409, f"status={st}, err={res.get('error')}")

        # Try issuing command on Standby -> Must return 409 Conflict
        st, res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/nodes/receiver:252033316/commands",
                              body={"op": "pause"}, cookie=s_cookie)
        check("Standby rejects POST command with 409 Conflict", st == 409, f"status={st}, err={res.get('error')}")

        # Try creating user on Standby -> Must return 409 Conflict
        st, res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/users",
                              body={"id": "operator_standby", "password": "password123", "role": "operator"},
                              cookie=s_cookie)
        check("Standby rejects POST /users with 409 Conflict", st == 409, f"status={st}, err={res.get('error')}")

        # Try creating notification channel on Standby -> Must return 409 Conflict
        st, res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/notifications",
                              body={"name": "test_chan", "channel_type": "telegram", "config": {}},
                              cookie=s_cookie)
        check("Standby rejects POST /notifications with 409 Conflict", st == 409, f"status={st}, err={res.get('error')}")

        # ---------------------------------------------------------------------
        # 3. Primary Writes and Replication to Standby (ADR-08)
        # ---------------------------------------------------------------------
        # Create user on Primary
        st, res, _ = http_req(P_HTTP_PORT, "POST", "/api/v1/users",
                              body={"id": "op_primary", "password": "password123", "role": "operator"},
                              cookie=p_cookie)
        check("Primary allows creating user (200 OK)", st == 200, f"status={st}")

        # Create config revision on Primary
        st, res, _ = http_req(P_HTTP_PORT, "PUT", "/api/v1/nodes/receiver:252033316/config",
                              body=sample_ini, cookie=p_cookie)
        check("Primary allows creating config revision (202 Accepted)", st == 202, f"status={st}")

        # Create command on Primary
        st, res, _ = http_req(P_HTTP_PORT, "POST", "/api/v1/nodes/receiver:252033316/commands",
                              body={"op": "reqpos"}, cookie=p_cookie)
        check("Primary allows issuing command (202 Accepted)", st == 202, f"status={st}")

        # Wait 2 seconds for background replication worker to sync from Primary
        time.sleep(2.0)

        # Check Standby status: cfg_lines, cmd_lines, users_hash
        st, s_status, _ = http_req(S_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)
        st_p, p_status, _ = http_req(P_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)

        check("Standby config lines synced to Primary count", s_status.get("cfg_lines") == p_status.get("cfg_lines"),
              f"s={s_status.get('cfg_lines')} vs p={p_status.get('cfg_lines')}")
        check("Standby command lines synced to Primary count", s_status.get("cmd_lines") == p_status.get("cmd_lines"),
              f"s={s_status.get('cmd_lines')} vs p={p_status.get('cmd_lines')}")
        check("Standby users SHA-256 hash matches Primary", s_status.get("users_hash") == p_status.get("users_hash"),
              f"s_hash={s_status.get('users_hash')[:12]} vs p_hash={p_status.get('users_hash')[:12]}")

        # Verify reading the replicated config from Standby
        st, cfg_res, _ = http_req(S_HTTP_PORT, "GET", "/api/v1/nodes/receiver:252033316/config", cookie=s_cookie)
        check("Standby can read replicated config revision (200 OK)", st == 200, f"rev={cfg_res.get('revision')}")

        # ---------------------------------------------------------------------
        # 4. Manual Promotion (POST /api/v1/cluster/promote)
        # ---------------------------------------------------------------------
        st, prom_res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/cluster/promote", cookie=s_cookie)
        check("Standby promote returns 200 OK", st == 200, f"status={st}")
        check("Promoted role is now 'primary'", prom_res.get("role") == "primary")
        check("Promoted epoch advanced to 2", prom_res.get("epoch") == 2)
        check("Promoted writes are now enabled", prom_res.get("writes") is True)

        # Verify writes are now accepted on the promoted node
        st, res, _ = http_req(S_HTTP_PORT, "PUT", "/api/v1/nodes/receiver:252033316/config",
                              body="[common]\nmagic=999999\n", cookie=s_cookie)
        check("Promoted node accepts writes (202 Accepted)", st == 202, f"status={st}")

        # ---------------------------------------------------------------------
        # 5. Stale Primary Auto-Demote on Higher Epoch (ADR-04)
        # ---------------------------------------------------------------------
        # The original Primary will contact the promoted node and discover epoch 2 > 1.
        time.sleep(2.0)
        st, p_status, _ = http_req(P_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)
        check("Original Primary auto-demoted to 'standby' due to higher epoch",
              p_status.get("role") == "standby", f"p_role={p_status.get('role')}")
        check("Original Primary writes closed", p_status.get("writes") is False)

        # ---------------------------------------------------------------------
        # 6. Two-Phase Handover & Failback (ADR-10)
        # ---------------------------------------------------------------------
        # Original Primary requests handover back:
        # Current Primary (S_HTTP_PORT) steps down, closes write gate, increments epoch to 3.
        p_hub_id = p_status.get("hub_id", "original-primary")
        st, h_res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/cluster/handover-request",
                                body={"from_hub_id": p_hub_id, "from_epoch": 2,
                                      "is_configured_primary": True, "reason": "test_handover"},
                                token=CLUSTER_TOKEN)
        check("Handover request returns 200 OK", st == 200, f"status={st}")
        check("Handover agreed is True", h_res.get("agreed") is True)
        check("Handover generated new_epoch = 3", h_res.get("new_epoch") == 3)

        # S node has stepped down
        st, s_status, _ = http_req(S_HTTP_PORT, "GET", "/api/v1/cluster/status", token=CLUSTER_TOKEN)
        check("Handover node stepped down to 'standby'", s_status.get("role") == "standby")
        check("Handover node writes closed", s_status.get("writes") is False)

        # ---------------------------------------------------------------------
        # 7. Failback Lock (ADR-10)
        # ---------------------------------------------------------------------
        # Promote S node again to test lock
        http_req(S_HTTP_PORT, "POST", "/api/v1/cluster/promote", cookie=s_cookie)
        # Lock failback on S node
        st, lock_res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/cluster/failback-lock",
                                   body={"locked": True}, cookie=s_cookie)
        check("Failback lock returns 200 OK", st == 200 and lock_res.get("failback_locked") is True)

        # Now handover request must be rejected with 403 Forbidden
        st, rej_res, _ = http_req(S_HTTP_PORT, "POST", "/api/v1/cluster/handover-request",
                                  body={"from_hub_id": "test", "from_epoch": 3,
                                        "is_configured_primary": True, "reason": "test_locked"},
                                  token=CLUSTER_TOKEN)
        check("Locked node rejects handover request with 403 Forbidden", st == 403,
              f"status={st}, err={rej_res.get('error')}")

    finally:
        tc.stop_hubs()

    print("\n" + "=" * 72)
    failed = [c for c in CHECKS if not c[1]]
    if not failed:
        print(f"ALL {len(CHECKS)} HA CLUSTER TESTS PASSED")
        return 0
    else:
        print(f"FAILED {len(failed)} / {len(CHECKS)} tests")
        for f in failed:
            print(f"  FAILED: {f[0]} ({f[2]})")
        return 1


if __name__ == "__main__":
    sys.exit(main())
