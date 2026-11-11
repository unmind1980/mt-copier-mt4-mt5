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
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB_BIN = "copier-hub.exe" if sys.platform == "win32" else "copier-hub"
HUB = os.path.join(REPO, "hub", "target", "release", HUB_BIN)

ZMQ_PORT = 6200
HTTP_PORT = 6201

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

    test_dir = tempfile.mkdtemp(prefix="mtc_audit_rot_test_")
    os.environ["MTC_ADMIN_PASSWORD"] = "rot-test-pass"
    audit_file = os.path.join(test_dir, "_test_audit.jsonl")
    users_file = os.path.join(test_dir, "_test_audit_users.json")
    cmds_file = os.path.join(test_dir, "_test_audit_cmds.jsonl")
    notif_file = os.path.join(test_dir, "_test_audit_notif.json")
    curve_keys = os.path.join(test_dir, "_test_audit_curve.keys")
    curve_clients = os.path.join(test_dir, "_test_audit_curve_clients.txt")

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
        cwd=test_dir,
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
                "config": {"url": f"https://example.com/webhook/{i}"}
            }, cookie=cookie)

        st, audit_resp2, _ = http_req("GET", "/api/v1/audit", cookie=cookie)
        recs = audit_resp2.get("records", [])
        check("7. Audit recorded actions", len(recs) >= 6)
        check("8. Records have ascending seqs", all(recs[i]["seq"] < recs[i+1]["seq"] for i in range(len(recs)-1)))

        # HUB-03: Test forward pagination with ?since=1&limit=3
        st, audit_page, _ = http_req("GET", "/api/v1/audit?since=1&limit=3", cookie=cookie)
        page_recs = audit_page.get("records", [])
        check("9. Forward pagination ?since=1 returns records > 1 (HUB-03)", len(page_recs) > 0 and all(r["seq"] > 1 for r in page_recs))

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except Exception:
            proc.kill()

    # --- Phase 2: Dynamic threshold rotation with MTC_AUDIT_MAX_BYTES and MTC_AUDIT_MAX_BACKUPS (E#11) ---
    print("\n--- Phase 2: Env-driven rotation thresholds (MTC_AUDIT_MAX_BYTES=600, MTC_AUDIT_MAX_BACKUPS=2) ---")
    p2_dir = tempfile.mkdtemp(prefix="mtc_audit_rot_p2_")
    p2_audit_file = os.path.join(p2_dir, "_p2_audit.jsonl")
    p2_env = os.environ.copy()
    p2_env["MTC_ADMIN_PASSWORD"] = "rot-test-pass"
    p2_env["MTC_AUDIT_MAX_BYTES"] = "600"
    p2_env["MTC_AUDIT_MAX_BACKUPS"] = "2"

    proc2 = subprocess.Popen(
        [
            HUB,
            "--port", str(ZMQ_PORT + 10),
            "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", p2_audit_file,
            "--users", os.path.join(p2_dir, "_users.json"),
            "--commands", os.path.join(p2_dir, "_cmds.jsonl"),
            "--notifications", os.path.join(p2_dir, "_notif.json"),
            "--curve", "off",
            "--stats-every", "0",
            "--duration", "60",
        ],
        cwd=p2_dir,
        env=p2_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )

    try:
        time.sleep(2.0)
        st, _, c_hdr = http_req("POST", "/api/v1/login", {"id": "admin", "password": "rot-test-pass"})
        cookie = c_hdr.split(";")[0] if c_hdr and "mtc_session=" in c_hdr else None
        check("10. Phase 2 login succeeds", st == 200 and bool(cookie))

        st, a_stat, _ = http_req("GET", "/api/v1/audit", cookie=cookie)
        check("11. Phase 2 max_bytes env override (600)", a_stat.get("max_bytes") == 600)
        check("12. Phase 2 max_backups env override (2)", a_stat.get("max_backups") == 2)

        # Send 20 operations to trigger multiple rotations
        for i in range(20):
            http_req("POST", "/api/v1/notifications", {
                "name": f"RotChannel_{i}",
                "channel_type": "webhook",
                "config": {"url": f"https://example.com/hook/{i:04d}"}
            }, cookie=cookie)

        time.sleep(1.0)
        st, a_stat2, _ = http_req("GET", "/api/v1/audit", cookie=cookie)
        rotations = a_stat2.get("rotations", 0)
        check("13. Rotations occurred (>= 2)", rotations >= 2, f"rotations={rotations}")

        gz1 = p2_audit_file + ".1.gz"
        gz2 = p2_audit_file + ".2.gz"
        gz3 = p2_audit_file + ".3.gz"
        check("14. Backup .1.gz exists", os.path.exists(gz1))
        check("15. Backup .2.gz exists", os.path.exists(gz2))
        check("16. Backup .3.gz pruned (max_backups=2)", not os.path.exists(gz3))

        # Check pagination stitches archive records
        st, a_stitched, _ = http_req("GET", "/api/v1/audit?since=1&limit=50", cookie=cookie)
        s_recs = a_stitched.get("records", [])
        check("17. Pagination stitches records across archives", len(s_recs) >= 6, f"len={len(s_recs)}")
        is_ordered = all(s_recs[i]["seq"] < s_recs[i+1]["seq"] for i in range(len(s_recs)-1)) if len(s_recs) > 1 else False
        check("18. Stitched records maintain strictly ascending seqs", is_ordered)

    finally:
        proc2.terminate()
        try:
            proc2.wait(timeout=3)
        except Exception:
            proc2.kill()
        shutil.rmtree(test_dir, ignore_errors=True)
        shutil.rmtree(p2_dir, ignore_errors=True)

    passed = sum(1 for _, ok, _ in CHECKS if ok)
    total = len(CHECKS)
    failed = total - passed
    print(f"\n  pass={passed}  fail={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
