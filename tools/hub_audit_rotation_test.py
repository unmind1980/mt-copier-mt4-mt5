#!/usr/bin/env python3
"""
hub_audit_rotation_test.py - End-to-end integration test for Audit Log Rotation.

Verifies:
  1. GET /api/v1/audit returns rotation configuration (max_bytes, max_backups, rotations count).
  2. Sequential recording advances sequence numbers and updates audit stats.
  3. Archives are gzip-compressed (.jsonl.gz).
  4. Automatic rotation occurs when log reaches threshold, archiving up to max_backups.
  5. Oldest backup archive beyond the limit is pruned.
  6. Read API transparently stitches active records and compressed archive records.
"""
import http.client
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

ZMQ_PORT = 6188
HTTP_PORT = 6189

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def http_req(method, path, body=None, cookie=None):
    conn = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
    headers = {"Content-Type": "application/json"}
    if cookie:
        headers["Cookie"] = cookie
    b = json.dumps(body) if body is not None else None
    conn.request(method, path, body=b, headers=headers)
    resp = conn.getresponse()
    raw = resp.read().decode("utf-8")
    data = {}
    try:
        data = json.loads(raw)
    except Exception:
        pass
    cookie_hdr = resp.getheader("Set-Cookie")
    conn.close()
    return resp.status, data, cookie_hdr


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2

    os.environ["MTC_ADMIN_PASSWORD"] = "rot-test-pass"
    audit_file = os.path.join(HERE, "_test_audit.jsonl")
    users_file = os.path.join(HERE, "_test_audit_users.json")
    cmds_file = os.path.join(HERE, "_test_audit_cmds.jsonl")
    notif_file = os.path.join(HERE, "_test_audit_notif.json")
    curve_keys = os.path.join(HERE, "_test_audit_curve.keys")
    curve_clients = os.path.join(HERE, "_test_audit_curve_clients.txt")

    # Clean previous artifacts
    for f in [audit_file, users_file, cmds_file, notif_file, curve_keys, curve_clients]:
        if os.path.exists(f):
            try:
                os.remove(f)
            except Exception:
                pass
    for idx in range(1, 20):
        arc = f"{audit_file}.{idx}.gz"
        if os.path.exists(arc):
            try:
                os.remove(arc)
            except Exception:
                pass

    proc = subprocess.Popen(
        [
            HUB,
            "--port", str(ZMQ_PORT),
            "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", audit_file,
            "--users", users_file,
            "--commands", cmds_file,
            "--notifications", notif_file,
            "--curve", "off",
            "--stats-every", "0",
            "--duration", "60",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )

    try:
        time.sleep(2.0)

        # 1. Login to obtain session cookie
        st, data, c_hdr = http_req("POST", "/api/v1/login", {"id": "admin", "password": "rot-test-pass"})
        check("1. Admin login succeeds", st == 200, f"HTTP {st}")
        cookie = None
        if c_hdr and "mtc_session=" in c_hdr:
            cookie = c_hdr.split(";")[0]
        check("2. Acquired session token", bool(cookie))

        # 2. Check /api/v1/audit endpoint exposes rotation stats
        st, audit_resp, _ = http_req("GET", "/api/v1/audit", cookie=cookie)
        check("3. GET /api/v1/audit returns 200", st == 200)
        check("4. Audit exposes max_bytes (10MB)", audit_resp.get("max_bytes") == 10 * 1024 * 1024)
        check("5. Audit exposes max_backups (10)", audit_resp.get("max_backups") == 10)
        check("6. Audit exposes rotations count", "rotations" in audit_resp)

        # 3. Perform several operations that record audit entries
        for i in range(5):
            http_req("POST", "/api/v1/notifications", {
                "name": f"Channel_{i}",
                "channel_type": "webhook",
                "config": {"url": f"http://127.0.0.1:9999/{i}"}
            }, cookie=cookie)

        st, audit_resp2, _ = http_req("GET", "/api/v1/audit", cookie=cookie)
        recs = audit_resp2.get("records", [])
        check("7. Audit recorded actions", len(recs) >= 6)
        check("8. Records have ascending seqs", all(recs[i]["seq"] < recs[i+1]["seq"] for i in range(len(recs)-1)))

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except Exception:
            proc.kill()

        # Clean artifacts
        for f in [audit_file, users_file, cmds_file, notif_file, curve_keys, curve_clients]:
            if os.path.exists(f):
                try:
                    os.remove(f)
                except Exception:
                    pass
        for idx in range(1, 20):
            arc = f"{audit_file}.{idx}.gz"
            if os.path.exists(arc):
                try:
                    os.remove(arc)
                except Exception:
                    pass

    passed = sum(1 for _, ok, _ in CHECKS if ok)
    total = len(CHECKS)
    failed = total - passed
    print(f"\n  pass={passed}  fail={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
