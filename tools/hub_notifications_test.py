#!/usr/bin/env python3
"""
hub_notifications_test.py - End-to-end integration test for external notifications.

Verifies:
  1. Access control: 401 without session cookie.
  2. CRUD of channels: Telegram, WeCom, DingTalk, Webhook.
  3. Sensitive credential masking in GET /api/v1/notifications.
  4. Real HTTP webhook dispatch via /api/v1/notifications/test to local HTTP server.
  5. Secret masking preservation on partial updates (stars do not overwrite raw secrets).
  6. Persistence across hub restart from alert_channels.json.
  7. Channel deletion and cleanup.
"""
import http.client
import http.server
import json
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

ZMQ_PORT = 6184
HTTP_PORT = 6185
HOOK_PORT = 6186

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


# Simple local HTTP receiver to capture webhook deliveries
class WebhookHandler(http.server.BaseHTTPRequestHandler):
    received_requests = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        parsed = {}
        try:
            parsed = json.loads(body.decode("utf-8"))
        except Exception:
            pass
        WebhookHandler.received_requests.append({
            "path": self.path,
            "headers": self.headers,
            "body": parsed,
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, format, *args):
        pass


def run_webhook_server(port):
    server = http.server.HTTPServer(("127.0.0.1", port), WebhookHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2

    os.environ["MTC_ADMIN_PASSWORD"] = "hub-test-pass"
    os.environ["MTC_ALLOW_LOCAL_WEBHOOK"] = "1"
    cmds = os.path.join(HERE, "_hub_notif_cmds.jsonl")
    audit = os.path.join(HERE, "_hub_notif_audit.jsonl")
    users = os.path.join(HERE, "_hub_notif_users.json")
    notif = os.path.join(HERE, "_hub_notif_channels.json")

    for f in (cmds, audit, users, notif):
        try:
            os.remove(f)
        except OSError:
            pass

    server = run_webhook_server(HOOK_PORT)

    p = subprocess.Popen(
        [
            HUB,
            "--port", str(ZMQ_PORT),
            "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", audit,
            "--commands", cmds,
            "--users", users,
            "--notifications", notif,
            "--curve", "off",
            "--stats-every", "0",
            "--duration", "60",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )

    try:
        time.sleep(2.0)

        cookie = {"v": None}

        def req(method, path, body=None, c=None):
            conn = http.client.HTTPConnection(f"127.0.0.1:{HTTP_PORT}", timeout=5)
            headers = {}
            if c:
                headers["Cookie"] = f"mtc_session={c}"
            if body is not None:
                headers["Content-Type"] = "application/json"
            try:
                conn.request(method, path, body=body, headers=headers)
                r = conn.getresponse()
                raw = r.read()
                set_cookie = r.getheader("Set-Cookie") or ""
                return r.status, raw, set_cookie
            finally:
                conn.close()

        def js(method, path, body=None, c=None):
            st, raw, _ = req(
                method, path, json.dumps(body) if body is not None else None, c
            )
            try:
                return st, json.loads(raw) if raw else {}
            except ValueError:
                return st, {}

        # 1. Closed without session
        st, _ = js("GET", "/api/v1/notifications")
        check("1. GET /api/v1/notifications requires auth (401)", st == 401)

        # 2. Login
        st, _, set_cookie = req(
            "POST",
            "/api/v1/login",
            json.dumps({"id": "admin", "password": "hub-test-pass"}),
        )
        check("2. Admin login succeeds", st == 200)
        for part in set_cookie.split(";"):
            part = part.strip()
            if part.startswith("mtc_session="):
                cookie["v"] = part[len("mtc_session=") :]

        token = cookie["v"]
        check("3. Acquired session token", bool(token))

        # 3. Initially empty
        st, body = js("GET", "/api/v1/notifications", c=token)
        check("4. Initial channels list is empty", st == 200 and body.get("channels") == [])

        # 4. Create Telegram channel
        raw_tg_token = "123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ"
        st, body = js(
            "POST",
            "/api/v1/notifications",
            {
                "name": "Dev Telegram",
                "channel_type": "telegram",
                "enabled": True,
                "min_severity": "warning",
                "config": {
                    "bot_token": raw_tg_token,
                    "chat_id": "-1001234567890",
                },
            },
            c=token,
        )
        tg_id = body.get("channel", {}).get("id")
        check(
            "5. Create Telegram channel",
            st == 200 and tg_id and body.get("channel", {}).get("name") == "Dev Telegram",
        )

        # 5. Create WeCom channel
        raw_wecom_key = "693a91f6-7xxx-4bc4-97a0-0b5012345678"
        st, body = js(
            "POST",
            "/api/v1/notifications",
            {
                "name": "Ops WeCom",
                "channel_type": "wechat_work",
                "enabled": True,
                "min_severity": "critical",
                "config": {"key": raw_wecom_key},
            },
            c=token,
        )
        wecom_id = body.get("channel", {}).get("id")
        check("6. Create WeCom channel", st == 200 and wecom_id)

        # 6. Create DingTalk channel
        raw_ding_token = "da9e31a02123456789abcdef01234567"
        raw_ding_secret = "SEC999888777666555444"
        st, body = js(
            "POST",
            "/api/v1/notifications",
            {
                "name": "DingTalk Group",
                "channel_type": "dingtalk",
                "enabled": True,
                "min_severity": "warning",
                "config": {"access_token": raw_ding_token, "secret": raw_ding_secret},
            },
            c=token,
        )
        ding_id = body.get("channel", {}).get("id")
        check("7. Create DingTalk channel", st == 200 and ding_id)

        # 7. Create Webhook channel pointing to local test receiver
        st, body = js(
            "POST",
            "/api/v1/notifications",
            {
                "name": "Local Test Hook",
                "channel_type": "webhook",
                "enabled": True,
                "min_severity": "warning",
                "config": {
                    "url": f"http://127.0.0.1:{HOOK_PORT}/webhook",
                    "headers": {"X-Custom-Auth": "secret-token-xyz"},
                },
            },
            c=token,
        )
        hook_id = body.get("channel", {}).get("id")
        check("8. Create Webhook channel", st == 200 and hook_id)

        # 8. List channels and verify masking
        st, body = js("GET", "/api/v1/notifications", c=token)
        channels = {c["id"]: c for c in body.get("channels", [])}
        check("9. All 4 channels listed", len(channels) == 4)

        tg_c = channels.get(tg_id, {}).get("config", {})
        check(
            "10. Telegram bot token is masked in list",
            "***" in tg_c.get("bot_token", "") and tg_c.get("bot_token") != raw_tg_token,
        )

        wecom_c = channels.get(wecom_id, {}).get("config", {})
        check(
            "11. WeCom webhook key is masked in list",
            "***" in wecom_c.get("key", "") and wecom_c.get("key") != raw_wecom_key,
        )

        ding_c = channels.get(ding_id, {}).get("config", {})
        check(
            "12. DingTalk token and secret are masked",
            "***" in ding_c.get("secret", "") and ding_c.get("secret") != raw_ding_secret,
        )

        # 9. Test Webhook dispatch via /api/v1/notifications/test
        WebhookHandler.received_requests.clear()
        st, body = js(
            "POST",
            "/api/v1/notifications/test",
            {"id": hook_id},
            c=token,
        )
        check("13. POST /api/v1/notifications/test returns 200", st == 200 and body.get("ok"))

        # Wait up to 3s for local receiver to handle dispatched test alert
        received = False
        for _ in range(30):
            if WebhookHandler.received_requests:
                received = True
                break
            time.sleep(0.1)

        check("14. Local HTTP server received webhook test dispatch", received)
        if received:
            req_data = WebhookHandler.received_requests[0]
            check(
                "15. Webhook path and headers correct",
                req_data["path"] == "/webhook"
                and req_data["headers"].get("X-Custom-Auth") == "secret-token-xyz",
            )
            body_data = req_data.get("body", {})
            check(
                "16. Webhook payload contains test alert content",
                body_data.get("event") == "alert"
                and body_data.get("kind") == "test"
                and "Manual connection test" in str(body_data.get("detail", {})),
            )

        # 10. Update channel with masked credentials (stars preservation test)
        masked_tg_token = tg_c.get("bot_token")
        st, body = js(
            "POST",
            "/api/v1/notifications",
            {
                "id": tg_id,
                "name": "Renamed Telegram Channel",
                "channel_type": "telegram",
                "enabled": False,
                "min_severity": "critical",
                "config": {
                    "bot_token": masked_tg_token,  # Contains stars
                    "chat_id": "-1001234567890",
                },
            },
            c=token,
        )
        check("17. Update channel with masked stars succeeds", st == 200)

        # Verify on disk that raw secret was preserved and NOT replaced by stars
        with open(notif, "r", encoding="utf-8") as f:
            disk_data = json.load(f)
        disk_tg = next((c for c in disk_data if c["id"] == tg_id), None)
        check(
            "18. Disk persistence preserved raw unmasked Telegram token",
            disk_tg and disk_tg["config"]["bot_token"] == raw_tg_token,
        )

        # 11. Delete a channel
        st, body = js("DELETE", f"/api/v1/notifications/{wecom_id}", c=token)
        check("19. DELETE /api/v1/notifications/:id returns 200", st == 200 and body.get("ok"))

        st, body = js("GET", "/api/v1/notifications", c=token)
        check(
            "20. Channel removed from active list (3 left)",
            len(body.get("channels", [])) == 3
            and not any(c["id"] == wecom_id for c in body["channels"]),
        )

    finally:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()

    # 12. Hub restart persistence test
    time.sleep(1.0)
    p2 = subprocess.Popen(
        [
            HUB,
            "--port", str(ZMQ_PORT),
            "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", audit,
            "--commands", cmds,
            "--users", users,
            "--notifications", notif,
            "--curve", "off",
            "--stats-every", "0",
            "--duration", "30",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    try:
        time.sleep(2.0)
        # Login again to get new session
        st, _, set_cookie = req(
            "POST",
            "/api/v1/login",
            json.dumps({"id": "admin", "password": "hub-test-pass"}),
        )
        new_token = None
        for part in set_cookie.split(";"):
            part = part.strip()
            if part.startswith("mtc_session="):
                new_token = part[len("mtc_session=") :]

        st, body = js("GET", "/api/v1/notifications", c=new_token)
        rem_channels = body.get("channels", [])
        check(
            "21. Persisted channels survive hub restart (3 channels loaded)",
            st == 200 and len(rem_channels) == 3,
        )
        rem_ids = {c["id"] for c in rem_channels}
        check(
            "22. Surviving channel IDs match disk store",
            tg_id in rem_ids and ding_id in rem_ids and hook_id in rem_ids,
        )
    finally:
        p2.terminate()
        try:
            p2.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p2.kill()

    # Cleanup test files
    for f in (cmds, audit, users, notif):
        try:
            os.remove(f)
        except OSError:
            pass

    failed = [name for name, ok, _ in CHECKS if not ok]
    print(f"\n  pass={len(CHECKS) - len(failed)}  fail={len(failed)}")
    if failed:
        print(f"FAILED tests: {failed}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
