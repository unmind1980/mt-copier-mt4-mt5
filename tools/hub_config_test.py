#!/usr/bin/env python3
"""
hub_config_test.py - M4a against the REAL hub binary.

The config store, the write gate, and the CFG wire. Deliberately NOT the EA
half: nothing here writes a file on a node or reloads anything, because that is
M4b and it is the half that can brick a receiver.

WHAT THIS PINS DOWN, in the order it matters:

  * **The write gate refuses, and the default says so.** Since 2026-10-14 the
    DEFAULT is ON (owner's test-period call; see main.rs). The safety property
    is unchanged and still tested both ways: an explicit `--writes off`
    REFUSES - not "silently accepts and does nothing" but a 403 with a reason
    - and the shipped default is ASSERTED, so a future flip of the default
    cannot happen silently. The plan's long-term stance stays "off until M9";
    flipping the default back must flip the assertion here with it.
  * **With writes on, a PUT is recorded and a CFG goes out** - and the ini that
    arrives is BYTE-IDENTICAL to the one sent. An ini contains every character
    the payload uses as a separator, so this is where a truncating escape would
    show up.
  * **A revision is never rewritten.** A rollback appends.
  * **A node that is behind gets pushed; a node that is AHEAD is reported as
    drifted and NOT overwritten** (§7.4).
  * **An ACK moves the command**, and an ACK for an unknown id is reported.
  * **The retry ladder is finite.**
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

ZMQ_PORT = 6190
HTTP_PORT = 6191
RECV = "252034803"          # the receiver's account, so its node key is receiver:<this>
NODE = f"receiver:{RECV}"

CHECKS = []

#--- M9: the API is closed without a session, so every hub suite signs in
#--- first. The hub bootstraps the FIRST admin from MTC_ADMIN_PASSWORD when
#--- the env is set (tests), or prints a random one once (production).
os.environ.setdefault("MTC_ADMIN_PASSWORD", "hub-test-pass")
COOKIE = {"v": None}


def login(password="hub-test-pass", user="admin", port=HTTP_PORT):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
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


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def env(sid, ty, payload):
    return (f"V=1|SID={sid}|SSID={sid}|SEQ=1|TS=1|T={ty}|P={payload}").encode("latin-1")


def req(method, path, body=None, port=HTTP_PORT):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=6)
    try:
        headers = {"Cookie": COOKIE["v"]} if COOKIE["v"] else {}
        c.request(method, path, body=body, headers=headers)
        r = c.getresponse()
        return r.status, r.read()
    finally:
        c.close()


def js(method, path, body=None):
    st, b = req(method, path, body)
    try:
        return st, json.loads(b) if b else {}
    except Exception:                               # noqa: BLE001
        return st, {"_raw": b[:200].decode("utf-8", "replace")}


def start(writes, audit, cfg):
    """`writes=None` means DO NOT PASS THE FLAG AT ALL.

    That distinction is the point of section 1: passing `--writes off`
    explicitly would prove that the flag works, which nobody doubted. Leaving it
    out proves the DEFAULT is off, which is the entire safety argument for
    shipping a write path before M9 exists.

    A fresh command journal is passed explicitly (so the hub does not dump a
    stray `commands.jsonl` into the CWD and so two tests in the same directory
    do not collide), and the caller removes it in stop().
    """
    cmds = os.path.join(HERE, "_hub_cfg_cmds.jsonl")
    users = os.path.join(HERE, "_hub_cfg_users.json")
    for f in (cfg, audit, cmds, users):
        try:
            os.remove(f)
        except OSError:
            pass
    args = [HUB, "--port", str(ZMQ_PORT), "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", audit, "--config", cfg, "--commands", cmds,
            "--users", users,
            #--- --curve off: this suite tests the config store, and its fake
            #--- receivers speak plaintext. CURVE has its own suite
            #--- (hub_curve_test.py); since CURVE became the hub's DEFAULT,
            #--- a suite that does not test it must say so explicitly.
            "--curve", "off",
            "--stats-every", "0", "--duration", "45"]
    if writes is not None:
        args += ["--writes", "on" if writes else "off"]
    out = open(os.path.join(HERE, "_hub_cfg.out"), "wb")
    p = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT)
    time.sleep(2.0)
    if not login():
        raise RuntimeError("could not log in to the test hub - M9 bootstrap failed?")
    return p, out, cmds


def stop(p, out, cmds=None):
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()
    out.close()
    for f in (os.path.join(HERE, "_hub_cfg.out"), cmds,
              os.path.join(HERE, "_hub_cfg_users.json")):
        try:
            os.remove(f)
        except OSError:
            pass


INI = ("[sender1]\n"
       "id=alpari01\n"
       "events=5555\n"
       "; a comment with = and ; in it\n"
       "lotmode=multiplier\n"
       "lotparam=2.0\n"
       "symbol.EURUSD=EURUSD.m\n")


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2
    cfg_path = os.path.join(HERE, "_hub_cfg_revs.jsonl")
    audit_path = os.path.join(HERE, "_hub_cfg_audit.jsonl")

    # =====================================================================
    print("== 1. the write gate: the DEFAULT is ON, and explicit --writes off refuses ==")
    for f in (cfg_path, audit_path):
        try:
            os.remove(f)
        except OSError:
            pass

    #--- The default flipped to ON on 2026-10-14 (owner's test-period call,
    #--- see main.rs). Asserting the default here means a future flip of it
    #--- cannot happen silently - the test goes red and forces the change to
    #--- be a decision.
    hub, out, cmds_path = start(None, audit_path, cfg_path)      # <- no --writes at all
    try:
        st, d = js("GET", "/api/v1/config")
        check("/api/v1/config -> 200", st == 200, f"status {st}")
        check("...the DEFAULT says writes are ENABLED",
              d.get("writes_enabled") is True, str(d.get("writes_enabled")))
    finally:
        stop(hub, out, cmds_path)

    #--- The refusal path is no longer the default, but the switch must still
    #--- exist and still refuse WITH A REASON.
    hub, out, cmds_path = start(False, audit_path, cfg_path)     # <- explicit --writes off
    try:
        st, d = js("GET", "/api/v1/config")
        check("--writes off says writes are disabled", d.get("writes_enabled") is False,
              str(d.get("writes_enabled")))

        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", INI)
        check("PUT -> 403 with writes off", st == 403, f"status {st}")
        check("...and the refusal says how to fix it",
              "writes" in json.dumps(d).lower() and "--writes" in json.dumps(d),
              json.dumps(d)[:80])

        st, d = js("POST", f"/api/v1/nodes/{NODE}/config/rollback/1")
        check("rollback -> 403 too", st == 403, f"status {st}")

        st, d = js("GET", "/api/v1/commands")
        check("...and nothing was queued", d.get("commands") == [],
              f"{len(d.get('commands', []))} command(s)")
        check("...and no revision was stored", not os.path.exists(cfg_path)
              or os.path.getsize(cfg_path) == 0,
              f"{os.path.getsize(cfg_path) if os.path.exists(cfg_path) else 0} bytes")
    finally:
        stop(hub, out, cmds_path)

    # =====================================================================
    print()
    print("== 2. writes ON: a PUT is recorded and a CFG goes out ==")
    hub, out, cmds_path = start(True, audit_path, cfg_path)
    try:
        ctx = zmq.Context()
        # Subscribe as the receiver would: its own control topic.
        node = ctx.socket(zmq.XSUB)
        node.setsockopt(zmq.LINGER, 0)
        node.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        node.send(b"\x01@" + RECV.encode())
        time.sleep(1.0)

        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", INI)
        check("PUT -> 202 Accepted", st == 202, f"status {st}")
        check("...answers with a command_id", bool(d.get("command_id")),
              str(d.get("command_id")))
        check("...and a rev", d.get("rev") == 1, str(d.get("rev")))
        cmd_id = d.get("command_id")

        # The CFG must arrive, with the ini byte-identical after unescaping.
        got = None
        deadline = time.time() + 4
        while time.time() < deadline:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CFG" in parts[1]:
                got = parts
                break
        check("the CFG arrived on @<receiver nid>", got is not None,
              "nothing" if got is None else got[0].decode())
        if got:
            body = got[1].decode("latin-1")
            payload = body.split("|P=", 1)[1]
            kv = {}
            for item in payload.split(";"):
                if "=" in item:
                    k, v = item.split("=", 1)
                    kv[k] = v
            check("...carries the command id", kv.get("ID") == cmd_id, kv.get("ID"))
            check("...carries rev 1", kv.get("REV") == "1", kv.get("REV"))
            # Unescape exactly as the MQL mirror will.
            ini = kv.get("INI", "")
            for a, b in (("%0A", "\n"), ("%0D", "\r"), ("%3D", "="), ("%3B", ";"),
                         ("%7C", "|"), ("%7E", "~"), ("%2C", ","), ("%25", "%")):
                ini = ini.replace(a, b)
            check("...and the ini survives the escape BYTE FOR BYTE",
                  ini == INI,
                  "identical" if ini == INI else f"{len(ini)} vs {len(INI)} bytes")

        print()
        print("== 3. the store: revision, history, and no rewrite ==")
        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("GET config -> 200", st == 200, f"status {st}")
        check("...managed, at rev 1", d.get("hub_rev") == 1, str(d.get("hub_rev")))
        check("...and holds the ini", (d.get("rev") or {}).get("ini") == INI,
              "identical" if (d.get("rev") or {}).get("ini") == INI else "differs")

        before = open(cfg_path, "rb").read()
        st, d2 = js("PUT", f"/api/v1/nodes/{NODE}/config", INI.replace("2.0", "3.0"))
        check("a second PUT -> rev 2", d2.get("rev") == 2, str(d2.get("rev")))
        after = open(cfg_path, "rb").read()
        check("the revisions file only ever grew",
              after.startswith(before) and len(after) > len(before),
              f"{len(before)} -> {len(after)} bytes")

        # --- the rollback ---
        before_rb = open(cfg_path, "rb").read()
        st, d3 = js("POST", f"/api/v1/nodes/{NODE}/config/rollback/1")
        check("rollback to rev 1 -> 202", st == 202, f"status {st}")
        check("...and it is a NEW revision (3), not a rewind",
              d3.get("rev") == 3, str(d3.get("rev")))
        after_rb = open(cfg_path, "rb").read()
        check("...and it APPENDED rather than rewrote",
              after_rb.startswith(before_rb) and len(after_rb) > len(before_rb),
              f"{len(before_rb)} -> {len(after_rb)} bytes")

        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("...the current body is rev 1's again",
              (d.get("rev") or {}).get("ini") == INI,
              (d.get("rev") or {}).get("kind"))
        check("...and the excursion is still in the history",
              len(d.get("history", [])) == 3, f"{len(d.get('history', []))} entries")
        check("...and it is marked as a rollback",
              (d.get("rev") or {}).get("kind") == "rollback",
              str((d.get("rev") or {}).get("kind")))
        check("rollback to a rev that never existed -> 404",
              js("POST", f"/api/v1/nodes/{NODE}/config/rollback/99")[0] == 404)

        print()
        print("== 4. validation: a bad ini is refused at the door ==")
        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", "no section here\nk=v\n")
        check("an ini with no [section] -> 400", st == 400, f"status {st}")
        check("...and says why", "section" in json.dumps(d), json.dumps(d)[:70])
        check("a truncated paste -> 400",
              js("PUT", f"/api/v1/nodes/{NODE}/config", "[sender1\nid=a\n")[0] == 400)
        check("an empty body -> 400",
              js("PUT", f"/api/v1/nodes/{NODE}/config", "")[0] == 400)
        st, d = js("PUT", "/api/v1/nodes/sender:123/config", INI)
        check("a SENDER has no config -> 400", st == 400, f"status {st}")

        print()
        print("== 5. ACK: the result of a push comes back as a message ==")
        up = ctx.socket(zmq.XSUB)
        up.setsockopt(zmq.LINGER, 0)
        up.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        up.send(b"\x01@hub")
        time.sleep(0.8)
        # Acknowledge the rollback command (rev 3).
        st, d = js("GET", "/api/v1/commands")
        pending = [c for c in d.get("commands", []) if c["state"] == "pending"]
        check("there are pending commands to ack", len(pending) > 0,
              f"{len(pending)} pending")
        target = pending[0]
        up.send_multipart([b"@hub", env("receiver", "ACK",
            f"ID={target['id']};OK=1;REV={target['rev']}")])
        time.sleep(0.8)
        st, d = js("GET", f"/api/v1/commands/{target['id']}")
        check("the ACK moved it to acked", d.get("state") == "acked", str(d.get("state")))
        check("...and recorded when", d.get("ack_at", 0) > 0, str(d.get("ack_at")))

        # An ACK for something the hub never sent.
        up.send_multipart([b"@hub", env("receiver", "ACK", "ID=never-sent;OK=1;REV=9")])
        time.sleep(0.6)
        check("an ACK for an unknown id does not create a command",
              js("GET", "/api/v1/commands/never-sent")[1].get("error") == "no such command")

        # A rejection carries its reason.
        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", INI.replace("3.0", "4.0"))
        rid = d["command_id"]
        up.send_multipart([b"@hub", env("receiver", "ACK",
            f"ID={rid};OK=0;ERR=magic overflow")])
        time.sleep(0.8)
        st, d = js("GET", f"/api/v1/commands/{rid}")
        check("a rejection is recorded as rejected", d.get("state") == "rejected",
              str(d.get("state")))
        check("...with the node's reason kept", d.get("err") == "magic overflow",
              str(d.get("err")))

        print()
        print("== 6. the audit has the operator actions ==")
        st, d = js("GET", "/api/v1/audit?limit=200")
        acts = [r["action"] for r in d.get("records", [])]
        for want in ("config.changed", "config.rolled_back", "config.acked",
                     "config.rejected", "config.unknown_ack"):
            check(f"audit records {want}", want in acts, str(sorted(set(acts))))
        chg = next((r for r in d["records"] if r["action"] == "config.changed"), None)
        check("...with the rev in before/after", bool(chg) and "rev" in (chg.get("after") or {}),
              json.dumps(chg.get("after"))[:60] if chg else "none")

        print()
        print("== 7. drift is REPORTED, never overwritten ==")
        # The node claims a rev the hub never issued. §7.4: show it, do not
        # silently erase it.
        up.send_multipart([b"@hub", env(RECV, "REG",
            f"ROLE=receiver;ACC={RECV};VER=2.0;NAME=Pilot;UP=9;REV=99")])
        time.sleep(1.0)
        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("the node's higher rev is visible as drift",
              d.get("drift") is True and d.get("node_rev") == 99,
              f"node_rev={d.get('node_rev')} drift={d.get('drift')}")
        check("...and the hub did NOT overwrite its own rev",
              d.get("hub_rev") == 4, str(d.get("hub_rev")))
        st, d = js("GET", "/api/v1/config")
        row = next((r for r in d["nodes"] if r["node"] == NODE), None)
        check("...and /api/v1/config shows it too",
              bool(row) and row.get("drift") is True, json.dumps(row))
        st, d = js("GET", "/api/v1/audit?limit=50")
        check("...and it is audited",
              any(r["action"] == "config.drift" for r in d.get("records", [])),
              str(sorted({r["action"] for r in d.get("records", [])})))

        print()
        print("== 8. the whole loop, from a receiver's point of view ==")
        #
        # The strongest thing this test can do without MetaTrader: act as the
        # receiver EXACTLY as the EA will - receive CFG, unescape, validate,
        # write the file, ACK - and check that the file on disk is byte-equal
        # to what was PUT, and that the hub marks the command acked.
        #
        # It is not a substitute for running the EA, and it is not meant to be.
        # It is the check that the WIRE CONTRACT is complete: everything the EA
        # needs to do its half is present in the message.
        import tempfile
        ini2 = ("[sender1]\nid=alpari01\nevents=5555\n"
                "; a comment with = and ; in it\nlotmode=multiplier\n"
                "lotparam=7.5\n")
        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", ini2)
        cmd = d["command_id"]
        rev = d["rev"]

        cfg = None
        deadline = time.time() + 4
        while time.time() < deadline and cfg is None:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CFG" in parts[1] and cmd.encode() in parts[1]:
                cfg = parts[1].decode("latin-1")
        # The detail is written so it reads correctly on SUCCESS as well as on
        # failure. The first version said "no CFG for <id>" unconditionally,
        # which appeared next to a PASS and read like a contradiction.
        check("the receiver's half has everything it needs on the wire",
              cfg is not None,
              (f"ID={cmd} arrived" if cfg else f"no CFG for {cmd}"))

        if cfg:
            kv = {}
            for item in cfg.split("|P=", 1)[1].split(";"):
                if "=" in item:
                    k, v = item.split("=", 1)
                    kv[k] = v
            # --- unescape, exactly as CopierIniUnescape does
            ini = kv["INI"]
            for a, b in (("%0A", "\n"), ("%0D", "\r"), ("%3D", "="), ("%3B", ";"),
                         ("%7C", "|"), ("%7E", "~"), ("%2C", ","), ("%25", "%")):
                ini = ini.replace(a, b)
            check("...and it unescapes to the exact ini that was PUT",
                  ini == ini2, "identical" if ini == ini2 else "differs")

            # --- write it the way CopierIniWriteAtomic does: to a temp file,
            # --- read it back, verify it parses
            with tempfile.TemporaryDirectory() as td:
                p = os.path.join(td, "copier.ini")
                with open(p, "w", encoding="ascii", newline="") as fh:
                    fh.write(ini)
                with open(p, encoding="ascii", newline="") as fh:
                    written = fh.read()
                check("...the file written back is byte-identical",
                      written == ini2, f"{len(written)} vs {len(ini2)} bytes")
                sections = [l for l in written.split("\n") if l.startswith("[")]
                check("...and it parses as an ini", len(sections) == 1,
                      f"{len(sections)} section(s)")

            # --- ACK it, and the hub must agree the loop closed
            up.send_multipart([b"@hub", env("receiver", "ACK",
                f"ID={cmd};OK=1;REV={rev};WARN=0")])
            time.sleep(0.8)
            st, d = js("GET", f"/api/v1/commands/{cmd}")
            check("...the ACK closes the command", d.get("state") == "acked",
                  str(d.get("state")))
            st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
            check("...and the hub's current rev is the one acknowledged",
                  d.get("hub_rev") == rev, f"{d.get('hub_rev')} vs {rev}")

        print()
        print("== 9. the retry ladder is finite ==")
        st, d = js("GET", "/api/v1/commands")
        check("every command has a state from the known set",
              all(c["state"] in ("pending", "acked", "rejected", "unknown", "superseded")
                  for c in d.get("commands", [])),
              str(sorted({c["state"] for c in d.get("commands", [])})))

        print()
        print("== 10. receiver current setting reporting (REG & CFGRPT) & full [common] inputs ==")

        def escape_ini(s):
            out = s.replace("%", "%25")
            out = out.replace("\r\n", "%0A").replace("\n", "%0A").replace("\r", "%0A")
            out = out.replace("=", "%3D").replace(";", "%3B").replace("|", "%7C").replace("~", "%7E").replace(",", "%2C")
            return out

        # 10a. Simulate Receiver registering with its live Current Setting (including [common] inputs)
        CURRENT_INI_1 = (
            "[common]\n"
            "deviation_points=30\n"
            "max_slippage_pips=5.0\n"
            "max_daily_loss_currency=1000.0\n"
            "magic_number_offset=200000\n"
            "copy_stop_loss=true\n"
            "invert_trade_direction=false\n"
            "\n"
            "[sender1]\n"
            "id=alpari01\n"
            "events=5555\n"
            "lotmode=multiplier\n"
            "lotparam=1.5\n"
        )
        esc1 = escape_ini(CURRENT_INI_1)
        up.send_multipart([b"@hub", env(RECV, "REG",
            f"ROLE=receiver;ACC={RECV};VER=2.0;NAME=Pilot;UP=10;REV=5;INI={esc1}")])
        time.sleep(1.0)

        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("GET /config includes current_setting reported via REG",
              bool(d.get("current_setting")), f"current_setting length {len(d.get('current_setting') or '')}")
        check("...and current_setting matches what receiver reported",
              d.get("current_setting") == CURRENT_INI_1,
              "identical" if d.get("current_setting") == CURRENT_INI_1 else "differs")
        check("...and current_setting_ts timestamp is recorded",
              d.get("current_setting_ts", 0) > 0, str(d.get("current_setting_ts")))

        # 10b. Simulate Receiver sending CFGRPT (effective config update)
        CURRENT_INI_2 = (
            "[common]\n"
            "deviation_points=50\n"
            "max_slippage_pips=3.0\n"
            "max_daily_loss_currency=2500.0\n"
            "magic_number_offset=200000\n"
            "copy_stop_loss=false\n"
            "invert_trade_direction=true\n"
            "\n"
            "[sender1]\n"
            "id=alpari01\n"
            "events=5555\n"
            "lotmode=fixed\n"
            "lotparam=0.10\n"
        )
        esc2 = escape_ini(CURRENT_INI_2)
        up.send_multipart([b"@hub", env(RECV, "CFGRPT",
            f"ROLE=receiver;ACC={RECV};REV=6;INI={esc2}")])
        time.sleep(1.0)

        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("CFGRPT updates current_setting on hub",
              d.get("current_setting") == CURRENT_INI_2,
              "identical" if d.get("current_setting") == CURRENT_INI_2 else "differs")

        # 10c. Hub pushes a new config with comprehensive [common] receiver inputs
        FULL_INI_PUSH = (
            "[common]\n"
            "deviation_points=40\n"
            "max_slippage_pips=4.0\n"
            "max_spread_pips=12.0\n"
            "max_daily_loss_currency=3000.0\n"
            "max_single_order_risk_currency=500.0\n"
            "poll_interval_ms=100\n"
            "enable_retry_on_requote=true\n"
            "copy_take_profit=true\n"
            "copy_stop_loss=true\n"
            "\n"
            "[sender1]\n"
            "id=alpari01\n"
            "events=5555\n"
            "lotmode=multiplier\n"
            "lotparam=2.5\n"
        )
        st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", FULL_INI_PUSH)
        check("PUT comprehensive [common] config accepted", st == 202, f"status {st}")
        cmd_full = d.get("command_id")

        cfg_received = None
        deadline = time.time() + 4
        while time.time() < deadline and cfg_received is None:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CFG" in parts[1] and cmd_full.encode() in parts[1]:
                cfg_received = parts[1].decode("latin-1")

        check("comprehensive CFG with [common] delivered to receiver wire",
              cfg_received is not None, f"ID={cmd_full}")
        if cfg_received:
            kv_full = {}
            for item in cfg_received.split("|P=", 1)[1].split(";"):
                if "=" in item:
                    k, v = item.split("=", 1)
                    kv_full[k] = v
            ini_un = kv_full.get("INI", "")
            for a, b in (("%0A", "\n"), ("%0D", "\r"), ("%3D", "="), ("%3B", ";"),
                         ("%7C", "|"), ("%7E", "~"), ("%2C", ","), ("%25", "%")):
                ini_un = ini_un.replace(a, b)
            check("...and received INI matches FULL_INI_PUSH byte-for-byte",
                  ini_un == FULL_INI_PUSH,
                  "identical" if ini_un == FULL_INI_PUSH else "differs")
            check("...contains [common] section and risk limits",
                  "[common]" in ini_un and "max_daily_loss_currency=3000.0" in ini_un,
                  "verified")


    finally:
        stop(hub, out, cmds_path)
        for f in (cfg_path, audit_path):
            try:
                os.remove(f)
            except OSError:
                pass


    # =====================================================================
    print()
    print("== 11. IH hash matching and reqcfg on-demand pull ==")
    hub, out, cmds_path = start(True, audit_path, cfg_path)
    try:
        ctx = zmq.Context()
        node = ctx.socket(zmq.XSUB)
        node.setsockopt(zmq.LINGER, 0)
        node.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        node.send(b"\x01@" + RECV.encode())
        time.sleep(1.0)

        # 1. Receiver reports REG with an unknown hash IH=1122334455667788
        # Hub has no record for this receiver -> triggers reqcfg command
        env_reg = (
            f"V=1|SID={RECV}|SSID={RECV}|SEQ=10|TS=1000|MS=1000|T=REG|"
            f"P=ROLE=receiver;ACC={RECV};REV=1;VER=1.0;NAME=rec1;IH=1122334455667788"
        ).encode("latin-1")
        node.send_multipart([b"@hub", env_reg])

        # Expect T=CMD;OP=reqcfg on @RECV
        got_cmd = None
        deadline = time.time() + 4
        while time.time() < deadline:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CMD" in parts[1] and b"OP=reqcfg" in parts[1]:
                got_cmd = parts[1].decode("latin-1")
                break
        check("hub issues reqcfg when receiver reports unseen IH hash", got_cmd is not None, got_cmd or "none")

        # 2. Receiver responds with CFGREPORT containing the full INI
        sample_ini = "[sender0]\nid=acct0\nmagic=7000\n"
        ini_esc = sample_ini.replace("\n", "%0A").replace("=", "%3D")
        env_rpt = (
            f"V=1|SID={RECV}|SSID={RECV}|SEQ=11|TS=1001|MS=1001|T=CFGRPT|"
            f"P=ROLE=receiver;ACC={RECV};REV=1;INI={ini_esc}"
        ).encode("latin-1")
        node.send_multipart([b"@hub", env_rpt])
        time.sleep(0.5)

        # Verify current_setting in GET /api/v1/nodes/receiver:<acc>/config
        st, d = js("GET", f"/api/v1/nodes/{NODE}/config")
        check("GET /config returns updated current_setting", st == 200 and d.get("current_setting") == sample_ini, str(d.get("current_setting")))

        # 3. Receiver reports REG again with the MATCHING hash
        # Reference hash for sample_ini is 5b780b2ceb382f10
        matching_hash = "5b780b2ceb382f10"
        env_reg_match = (
            f"V=1|SID={RECV}|SSID={RECV}|SEQ=12|TS=1002|MS=1002|T=REG|"
            f"P=ROLE=receiver;ACC={RECV};REV=1;VER=1.0;NAME=rec1;IH={matching_hash}"
        ).encode("latin-1")
        node.send_multipart([b"@hub", env_reg_match])

        # Verify NO new command is sent (queue stays clear)
        got_unexpected = None
        deadline = time.time() + 1.5
        while time.time() < deadline:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CMD" in parts[1]:
                got_unexpected = parts[1].decode("latin-1")
                break
        check("hub does NOT issue reqcfg when IH matches stored hash (0 bytes transferred)", got_unexpected is None, str(got_unexpected))

        node.close()
        ctx.term()
    finally:
        stop(hub, out, cmds_path)

    # =====================================================================
    print("== 12. the sender ceiling is REACHABLE, and both ends agree on the byte bound ==")
    #--- The capacity is a promise made to whoever downloads this, so it gets
    #--- asserted rather than typed into a README: a config for every sender
    #--- the EA can take must be accepted by the hub, and the node's own byte
    #--- bound must equal the hub's. A gap in either direction is a config that
    #--- "pushed fine" and silently never applied.
    with open(os.path.join(REPO, "hub", "src", "config.rs"), encoding="utf-8") as fh:
        rs = fh.read()
    with open(os.path.join(REPO, "src", "Include", "Copier", "CopierConfig.mqh"),
              encoding="utf-8") as fh:
        mqh = fh.read()
    with open(os.path.join(REPO, "src", "Include", "Copier", "CopierDefs.mqh"),
              encoding="utf-8") as fh:
        defs = fh.read()

    import re
    re_hub = re.search(r"const MAX_INI_BYTES: usize = (\d+) \* 1024;", rs)
    re_mql_bytes = re.search(r"#define CP_INI_MAX_BYTES (\d+)", mqh)
    re_senders = re.search(r"#define CP_MAX_SENDERS\s+(\d+)", defs)
    re_rows = re.search(r"#define CP_INI_MAX (\d+)", mqh)
    check("all four constants are readable from source",
          bool(re_hub and re_mql_bytes and re_senders and re_rows),
          f"hub={re_hub and re_hub.group(1)}KB "
          f"node={re_mql_bytes and re_mql_bytes.group(1)}B "
          f"senders={re_senders and re_senders.group(1)} "
          f"rows={re_rows and re_rows.group(1)}")

    ceiling = int(re_senders.group(1)) if re_senders else -1
    rows_bound = int(re_rows.group(1)) if re_rows else -1
    bytes_bound = int(re_mql_bytes.group(1)) if re_mql_bytes else -1
    hub_bytes = int(re_hub.group(1)) * 1024 if re_hub else -1

    if re_hub and re_mql_bytes:
        check("the hub's byte bound EQUALS the node's (one bound, two languages)",
              hub_bytes == bytes_bound,
              f"hub {hub_bytes} vs node {bytes_bound}")

    if ceiling > 0 and rows_bound > 0 and bytes_bound > 0:
        #--- The same shape SerializeCurrentConfigToIni() actually writes, key
        #--- for key and long-named-key for long-named-key: a three-key stub
        #--- would fit any row bound and prove nothing. This is the config a
        #--- hub-pushed CFG carries, so this is the size the bound must hold.
        per_sender_keys = [
            "id", "magic", "lotmode", "lotparam", "suffix",
            "deviationpoints", "emergencyslpips", "emergencytppips",
            "reopenclosedmirrors", "dedupduplicates", "ignorenewentrysignals",
            "ignoreallexitsignals", "ignoreuids", "nobuy", "nosell",
            "permittedsymbols", "permittedmagic", "minsenderlotsize",
            "maxsenderlotsize", "checkforexistingposition",
            "requirepositionfillwithinseconds", "requirepositionfillwithinminutes",
            "requirepositionfillwithinhours", "fillwithinminutesbar",
            "pendingfillgraceseconds", "waitforseconds", "waitforminutes",
            "waitforhours", "waitforprofitpips", "waitforminutesbar",
            "includetradingtimes", "daytradingtimes", "inverttrades",
            "mirrorstops", "stoplosstakeprofit", "secondsfrommodify",
            "ignorebasketorder", "maxlotsperposition", "maxtotallots",
            "maxopenpositions", "dailylosspct", "maxdrawdownpct",
            "stopsthrottleseconds", "ordercomment", "custompipsizes",
            "includetradingtimesdays", "daytradingtimesdays", "notes",
        ]
        blocks = ["[common]\nmaxlotsperposition=10.0\nmaxopenpositions=100\n"]
        for i in range(ceiling):
            body = "".join(f"{k}=v{i}\n" for k in per_sender_keys)
            blocks.append(f"[sender{i}]\n{body}symbol.EURUSD=EURUSD.m\n")
        full = "".join(blocks)
        rows = sum(1 for ln in full.splitlines()
                   if ln.strip() and not ln.strip().startswith((";", "#")))
        size = len(full.encode("utf-8"))
        check(f"a FULL {ceiling}-sender config fits the node's row bound",
              rows < rows_bound, f"{rows} rows of {rows_bound}")
        check(f"...and its byte bound", size < bytes_bound,
              f"{size} bytes of {bytes_bound}")
        hub, out, cmds_path = start(True, audit_path, cfg_path)
        try:
            st, d = js("PUT", f"/api/v1/nodes/{NODE}/config", full)
            check(f"the hub ACCEPTS a {ceiling}-sender config", st == 202, f"status {st}")
        finally:
            stop(hub, out, cmds_path)

    print()
    p = sum(1 for _, ok, _ in CHECKS if ok)
    f = len(CHECKS) - p
    print(f"  pass={p}  fail={f}")
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
