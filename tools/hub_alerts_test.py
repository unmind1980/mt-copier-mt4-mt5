#!/usr/bin/env python3
"""
hub_alerts_test.py - M6 against the REAL hub binary.

The alert engine dedups, silences and re-arms; the rules read the registry,
the node's own clock and the receiver's risk fields. This test pins down:

  * **A node that goes quiet for OFFLINE_AFTER fires `node.offline` once** -
    and does NOT fire again during the silence window (the re-arm is what
    makes a later flap a second incident, which takes 60+ s to test here).
  * **A node whose own clock is far from the hub's fires `node.clock.drift`.**
    Sent as a REG with a TS in the past - the hub compares it to its own
    clock at receipt.
  * **A receiver's BLOCKED/RISK on its STAT fire `risk.blocked` /
    `risk.tripped`.**
  * **`GET /api/v1/alerts` and the snapshot both carry the ring.**
  * **The alert lands in the M7 audit log as `alert.<kind>`** - durable, and
    the ring is the cheap surface.

The command.unknown rule is deliberately NOT exercised here: exhausting the
retry ladder takes the full 2/5/15/60 s (~82 s), which the Rust unit tests
cover for the engine and the ladder unit tests cover for the state change.
"""
import http.client
import json
import os
import subprocess
import sys
import time

import zmq

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HUB = os.path.join(REPO, "hub", "target", "release", "copier-hub.exe")

ZMQ_PORT = 6196
HTTP_PORT = 6197
RECV = "252034803"           # the receiver's account, node key = receiver:<this>
NODE = f"receiver:{RECV}"
OFFLINE_AFTER_SECS = 62      # registry's OFFLINE_AFTER is 60 s; give it margin

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


#--- M9: the API is closed without a session, so every hub suite signs in
#--- first. The hub bootstraps the FIRST admin from MTC_ADMIN_PASSWORD when
#--- the env is set (tests), or prints a random one once (production).
os.environ.setdefault("MTC_ADMIN_PASSWORD", "hub-test-pass")
COOKIE = {"v": None}


def login(password="hub-test-pass", user="admin", port=HTTP_PORT):
    c = http.client.HTTPConnection(f"127.0.0.1:{port}", timeout=5)
    try:
        body = json.dumps({"id": user, "password": password})
        c.request("POST", "/api/v1/login", body=body,
                  headers={"Content-Type": "application/json"})
        r = c.getresponse()
        raw = r.read()
        if r.status != 200:
            return False
        sc = r.getheader("Set-Cookie") or ""
        for part in sc.split(";"):
            part = part.strip()
            if part.startswith("mtc_session="):
                COOKIE["v"] = "mtc_session=" + part[len("mtc_session="):]
        return True
    finally:
        c.close()


def start():
    #--- Isolated data paths, like the other suites. This one MATTERS more:
    #--- the command journal is where ladders that exhausted in an earlier
    #--- session live, and the engine's command.unknown rule would (correctly)
    #--- re-announce them on this hub's first tick - the test would then be
    #--- asserting about somebody else's commands.
    cmds = os.path.join(HERE, "_hub_alert_cmds.jsonl")
    audit = os.path.join(HERE, "_hub_alert_audit.jsonl")
    cfg = os.path.join(HERE, "_hub_alert_revs.jsonl")
    users = os.path.join(HERE, "_hub_alert_users.json")
    for f in (cmds, audit, cfg, users):
        try:
            os.remove(f)
        except OSError:
            pass
    p = subprocess.Popen([HUB, "--http", f"127.0.0.1:{HTTP_PORT}", "--port",
                          str(ZMQ_PORT), "--commands", cmds, "--audit", audit,
                          "--config", cfg, "--users", users,
                          #--- --curve off: this suite tests the alert rules, and
                          #--- its fake nodes speak plaintext. CURVE has its own
                          #--- suite (hub_curve_test.py); since CURVE became the
                          #--- hub's DEFAULT, a suite that does not test it must
                          #--- say so explicitly.
                          "--curve", "off"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    #--- ANY status counts as up, including 401: since M9 the topology
    #--- endpoint answers without a session, which is exactly the signal
    #--- that the API thread is listening.
    for _ in range(50):
        try:
            c = http.client.HTTPConnection(f"127.0.0.1:{HTTP_PORT}", timeout=1)
            c.request("GET", "/api/v1/topology")
            if c.getresponse().status:
                if not login():
                    continue
                return p
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("hub did not come up, or login failed")


def stop(p):
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()
    for f in ("_hub_alert_cmds.jsonl", "_hub_alert_audit.jsonl",
              "_hub_alert_revs.jsonl", "_hub_alert_users.json"):
        try:
            os.remove(os.path.join(HERE, f))
        except OSError:
            pass


def js(method, path, body=None):
    c = http.client.HTTPConnection(f"127.0.0.1:{HTTP_PORT}", timeout=5)
    headers = {"Cookie": COOKIE["v"]} if COOKIE["v"] else {}
    c.request(method, path, body, headers=headers)
    r = c.getresponse()
    raw = r.read().decode()
    try:
        return r.status, json.loads(raw)
    except ValueError:
        return r.status, {}


def announce(sock, seq, ts=None):
    """A REG, optionally with a chosen TS for the drift test."""
    if ts is None:
        ts = int(time.time())
    env = (f"V=1|SID={RECV}|SSID={RECV}|SEQ={seq}|TS={ts}|MS=0|T=REG|"
           f"P=ROLE=receiver;ACC={RECV};VER=2.0;NAME=alert-test;UP=1")
    sock.send_multipart([b"@hub", env.encode()])


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2
    pub = start()
    try:
        ctx = zmq.Context()

        # =================================================================
        print("== 1. the rules that need no waiting: drift and risk ==")
        up = ctx.socket(zmq.XSUB)
        up.setsockopt(zmq.LINGER, 0)
        up.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        up.send(b"\x01@" + RECV.encode())
        time.sleep(0.3)

        # The rule is a JUMP, not an offset: a node's first announcement
        # establishes the baseline and never fires, however far its timezone
        # sits from the hub's. The first live run of an "offset" rule fired
        # for all four nodes at exactly the broker-vs-host offset - right
        # about everything, informative about nothing.
        announce(up, 1, ts=int(time.time()) - 3600)   # baseline, far away
        time.sleep(6.0)
        alerts = js("GET", "/api/v1/alerts")[1].get("alerts", [])
        check("a stable timezone offset does NOT fire",
              not [a for a in alerts if a["kind"] == "node.clock.drift"],
              str([a["kind"] for a in alerts]))

        # Now the clock STEPS by another hour past the hub's - a broken clock.
        announce(up, 2, ts=int(time.time()))
        time.sleep(6.0)

        st, d = js("GET", "/api/v1/alerts")
        check("/api/v1/alerts -> 200", st == 200, f"status {st}")
        alerts = d.get("alerts", [])
        drift = [a for a in alerts if a["kind"] == "node.clock.drift"]
        check("clock drift fired on the JUMP", len(drift) == 1,
              str([(a["kind"], a["node"]) for a in alerts]))
        if drift:
            check("...and reports what the offset moved by",
                  abs(abs(drift[0]["detail"]["changed_by_secs"]) - 3600) < 30,
                  json.dumps(drift[0]["detail"]))

        # The receiver's risk state, from its STAT: BLOCKED/RISK ride the
        # same frame as the delivery receipt.
        stat = (f"V=1|SID=receiver|SSID={RECV}|SEQ=2|TS={int(time.time())}|MS=0|"
                f"T=STAT|P=LOGIN={RECV};SID=53203697;H=abc123;BLOCKED=3;RISK=maxtot")
        up.send_multipart([b"@hub", stat.encode()])
        time.sleep(6.0)

        alerts = js("GET", "/api/v1/alerts")[1].get("alerts", [])
        kinds = sorted(a["kind"] for a in alerts)
        check("risk.blocked fired", "risk.blocked" in kinds, str(kinds))
        check("risk.tripped fired", "risk.tripped" in kinds, str(kinds))
        trip = [a for a in alerts if a["kind"] == "risk.tripped"]
        if trip:
            check("...and names the limit that tripped",
                  trip[0]["detail"].get("trip") == "maxtot"
                  and trip[0]["severity"] == "critical",
                  json.dumps(trip[0]["detail"]))

        # The audit log gets it too - that is the durable record.
        st, d = js("GET", "/api/v1/audit?limit=200")
        actions = {e.get("action") for e in d.get("records", [])}
        check("the audit log has alert.* actions",
              "alert.node.clock.drift" in actions and "alert.risk.tripped" in actions,
              str(sorted(actions)))

        st, d = js("GET", "/api/v1/topology")
        check("the snapshot carries the ring",
              isinstance(d.get("alerts"), list) and len(d["alerts"]) >= 3,
              f"{len(d.get('alerts', []))} alert(s)")

        # =================================================================
        print()
        print(f"== 2. offline: a silent node fires once, and stays firing-free "
              f"for the silence window ({OFFLINE_AFTER_SECS}s wait) ==")
        # Drop the socket so the hub sees the node go quiet. (close + linger 0
        # is enough: nothing more is ever announced.)
        up.close()

        fired = None
        deadline = time.time() + OFFLINE_AFTER_SECS + 20
        while time.time() < deadline:
            alerts = js("GET", "/api/v1/alerts")[1].get("alerts", [])
            hits = [a for a in alerts if a["kind"] == "node.offline"]
            if hits:
                fired = hits
                break
            time.sleep(1.0)
        check("node.offline fired after OFFLINE_AFTER", fired is not None,
              f"in {OFFLINE_AFTER_SECS}s window")
        if fired:
            check("...with the role and the quiet time", 
                  fired[0]["detail"].get("role") == "receiver"
                  and fired[0]["detail"].get("quiet_secs", 0) >= 60,
                  json.dumps(fired[0]["detail"]))

        # The silence window: after the first fire, no repeat even though the
        # node stays offline for another 12 s (well inside the 10-min window).
        time.sleep(12.0)
        alerts = js("GET", "/api/v1/alerts")[1].get("alerts", [])
        offs = [a for a in alerts if a["kind"] == "node.offline"]
        check("...and the silence window stops the repeat", len(offs) == 1,
              f"{len(offs)} offline alert(s)")

    finally:
        stop(pub)

    bad = [c for c in CHECKS if not c[1]]
    print()
    print(f"  pass={len(CHECKS) - len(bad)}  fail={len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
