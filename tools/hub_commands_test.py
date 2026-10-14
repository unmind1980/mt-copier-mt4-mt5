#!/usr/bin/env python3
"""
hub_commands_test.py - M5 against the REAL hub binary.

The command engine that M5 reuses is the SAME one M4 built for config pushes:
one issue/retry/ack machine, with the same content-vs-sequence id and the same
2/5/15/60 ladder. What M5 adds is the operational command and the `CMD` wire
frame. This test pins down:

  * **The write gate refuses on an explicit --writes off, and the default is
    asserted.** Same as M4's PUT gate, because the argument is identical: the
    plan's §19 wants role checks that M9 (users and roles) has not built yet.
    Since 2026-10-14 the DEFAULT is ON (owner's test-period call, see main.rs)
    - so this test asserts the default AND the refusal, and flipping the
    default back means flipping the assertion here with it.
  * **With writes on, POST /nodes/{id}/commands -> 202 + command_id**, and a
    `CMD` frame arrives on the node's own `@<nid>` topic carrying that id and
    the op. The node-side half (M5b) is not built, so here the test plays the
    role of the receiver: it reads the `CMD`, then sends the `ACK`.
  * **The id is per-intent.** Two POSTs of the same op mint two different
    command ids - "pause, resume, pause" must not collapse.
  * **The node dedupes by id.** A repeated ACK for a known id answers again
    without re-applying - but that is M5b's job; here we only confirm the hub
    records it once.
  * **The audit has the operator actions**: command.issued / command.acked /
    command.rejected / command.unknown_ack / command.timeout.
  * **The journal survives a restart.** A command issued, then dropped, then the
    hub restarted, is still `pending` in the journal - §15's "in-flight commands
    are stored" requirement.

The LONG-running property - the finite ladder - is pinned by the Rust unit
tests in commands.rs (82 s is too long for this suite). Here we only assert the
state transitions that arrive quickly.
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

ZMQ_PORT = 6192
HTTP_PORT = 6193
RECV = "252034803"           # the receiver's account, node key = receiver:<this>
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


def start(writes, audit, cfg, cmds):
    """`writes=None` means DO NOT PASS THE FLAG AT ALL (proves the default)."""
    users = os.path.join(HERE, "_hub_cmd_users.json")
    args = [HUB, "--port", str(ZMQ_PORT), "--http", f"127.0.0.1:{HTTP_PORT}",
            "--audit", audit, "--config", cfg, "--commands", cmds,
            "--users", users, "--stats-every", "0", "--duration", "45"]
    if writes is not None:
        args += ["--writes", "on" if writes else "off"]
    out = open(os.path.join(HERE, "_hub_cmd.out"), "wb")
    p = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT)
    time.sleep(2.0)
    if not login():
        raise RuntimeError("could not log in to the test hub - M9 bootstrap failed?")
    return p, out


def stop(p, out):
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()
    out.close()
    for f in (os.path.join(HERE, "_hub_cmd.out"),
              os.path.join(HERE, "_hub_cmd_users.json")):
        try:
            os.remove(f)
        except OSError:
            pass


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2
    cfg_path = os.path.join(HERE, "_hub_cmd_revs.jsonl")
    audit_path = os.path.join(HERE, "_hub_cmd_audit.jsonl")
    cmds_path = os.path.join(HERE, "_hub_cmd_journal.jsonl")

    # =====================================================================
    print("== 1. the write gate: the DEFAULT is ON, and explicit --writes off refuses ==")
    for f in (cfg_path, audit_path, cmds_path):
        try:
            os.remove(f)
        except OSError:
            pass

    #--- Default flipped to ON on 2026-10-14 (owner's test-period call, see
    #--- main.rs); asserted so it cannot flip back silently.
    hub, out = start(None, audit_path, cfg_path, cmds_path)      # <- no --writes at all
    try:
        st, d = js("GET", "/api/v1/commands")
        check("/api/v1/commands -> 200", st == 200, f"status {st}")
        check("...the DEFAULT says writes are ENABLED",
              d.get("writes_enabled") is True, str(d.get("writes_enabled")))
    finally:
        stop(hub, out)

    #--- The refusal path, spelled out explicitly.
    hub, out = start(False, audit_path, cfg_path, cmds_path)     # <- explicit --writes off
    try:
        st, d = js("GET", "/api/v1/commands")
        check("--writes off says writes are disabled", d.get("writes_enabled") is False,
              str(d.get("writes_enabled")))

        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "pause")
        check("POST command -> 403 with writes off", st == 403, f"status {st}")
        check("...and the refusal says how to fix it",
              "writes" in json.dumps(d).lower() and "--writes" in json.dumps(d),
              json.dumps(d)[:80])

        # G10's global endpoint sits behind the SAME gate.
        st, d = js("POST", "/api/v1/commands", "pause")
        check("global POST -> 403 with writes off", st == 403, f"status {st}")

        st, d = js("GET", "/api/v1/commands")
        check("...and nothing was queued", d.get("commands") == [],
              f"{len(d.get('commands', []))} command(s)")
        check("...and no journal was written", not os.path.exists(cmds_path)
              or os.path.getsize(cmds_path) == 0,
              f"{os.path.getsize(cmds_path) if os.path.exists(cmds_path) else 0} bytes")
    finally:
        stop(hub, out)

    # =====================================================================
    print()
    print("== 2. writes ON: a command is recorded and a CMD goes out ==")
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    try:
        ctx = zmq.Context()
        node = ctx.socket(zmq.XSUB)
        node.setsockopt(zmq.LINGER, 0)
        node.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        node.send(b"\x01@" + RECV.encode())
        time.sleep(1.0)

        # A bare-word body is accepted, not just JSON.
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "pause")
        check("POST pause -> 202 Accepted", st == 202, f"status {st}")
        check("...answers with a command_id", bool(d.get("command_id")),
              str(d.get("command_id")))
        check("...and the op", d.get("op") == "pause", str(d.get("op")))
        check("...and a poll URL", d.get("poll", "").endswith(d.get("command_id", "")),
              str(d.get("poll")))
        cmd_id = d.get("command_id")

        # The CMD must arrive, with the id and the op.
        got = None
        deadline = time.time() + 4
        while time.time() < deadline:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CMD" in parts[1]:
                got = parts
                break
        check("the CMD arrived on @<receiver nid>", got is not None,
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
            check("...carries the op", kv.get("OP") == "pause", kv.get("OP"))

        # Issuing the same op again is a SECOND command (distinct id).
        st, d2 = js("POST", f"/api/v1/nodes/{NODE}/commands",
                    json.dumps({"op": "pause"}))
        check("a second pause -> 202", st == 202, f"status {st}")
        check("...with a DIFFERENT id (no collapse)",
              d2.get("command_id") != cmd_id,
              f"{cmd_id} vs {d2.get('command_id')}")

        # A known node is reported, so the operator sees if the target exists.
        st, d3 = js("POST", f"/api/v1/nodes/{NODE}/commands", "resume")
        check("resume -> 202", st == 202, f"status {st}")

        # /api/v1/commands lists all three, newest first-ish, with kind/op.
        st, d = js("GET", "/api/v1/commands")
        cmds = d.get("commands", [])
        check("three commands are listed", len(cmds) == 3, f"{len(cmds)}")
        check("each has kind=op and its op",
              all(c.get("kind") == "op" and c.get("op") for c in cmds),
              str([(c.get("kind"), c.get("op")) for c in cmds]))
        check("each is pending until ACKed",
              all(c.get("state") == "pending" for c in cmds),
              str([c.get("state") for c in cmds]))

    finally:
        stop(hub, out)

    # =====================================================================
    print()
    print("== 2b. G10: one POST, every receiver - one command per node ==")
    RECV2 = "112233445"          # a second fake receiver, distinct nid
    for f in (cfg_path, audit_path, cmds_path):
        try:
            os.remove(f)
        except OSError:
            pass
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    try:
        ctx = zmq.Context()
        sockets = []
        seq = 0
        for nid in (RECV, RECV2):
            s = ctx.socket(zmq.XSUB)
            s.setsockopt(zmq.LINGER, 0)
            s.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
            s.send(b"\x01@" + nid.encode())
            #--- The hub's node table is built from REG/HBT2 and NOTHING else
            #--- - subscribing alone makes the socket visible but the NODE
            #--- imaginary, and the global endpoint would mint zero commands.
            #--- So announce, exactly the way HubAnnounce does.
            seq += 1
            reg = (f"V=1|SID={nid}|SSID={nid}|SEQ={seq}|TS={int(time.time())}|MS=0|"
                   f"T=REG|P=ROLE=receiver;ACC={nid};VER=2.0;NAME=fake-{nid};UP=0")
            s.send_multipart([b"@hub", reg.encode()])
            sockets.append(s)
        time.sleep(1.0)

        st, d = js("POST", "/api/v1/commands", json.dumps({"op": "pause"}))
        check("global pause -> 202", st == 202, f"status {st}")
        check("...covers every known receiver", d.get("count") == 2, str(d.get("count")))
        issued = d.get("issued", [])
        nodes_issued = sorted(x.get("node", "") for x in issued)
        check("...the nodes are the two receivers",
              nodes_issued == sorted([NODE, f"receiver:{RECV2}"]), str(nodes_issued))
        ids = [x.get("command_id") for x in issued]
        check("...distinct command ids (two nodes are two commands)",
              len(set(ids)) == 2, str(ids))
        check("...each carries its own poll URL",
              all(x.get("poll", "").endswith(x.get("command_id", "?")) for x in issued),
              str([x.get("poll") for x in issued]))

        # The CMD must arrive on EACH node's own topic - per-node delivery,
        # not one shared broadcast frame.
        for s, nid in zip(sockets, (RECV, RECV2)):
            got = None
            deadline = time.time() + 4
            while time.time() < deadline:
                try:
                    parts = s.recv_multipart(zmq.NOBLOCK)
                except zmq.Again:
                    time.sleep(0.1)
                    continue
                if len(parts) >= 2 and b"T=CMD" in parts[1]:
                    got = parts
                    break
            check(f"the CMD arrived on @{nid}", got is not None,
                  "nothing" if got is None else got[0].decode())

        # Same door validation as the per-node endpoint.
        st, d = js("POST", "/api/v1/commands", json.dumps({"op": "nope"}))
        check("global unknown op -> 400 with the known list",
              st == 400 and "known" in d, f"status {st}")
    finally:
        stop(hub, out)

    # =====================================================================
    print()
    print("== 3. validation at the door ==")
    for f in (cfg_path, audit_path, cmds_path):
        try:
            os.remove(f)
        except OSError:
            pass
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    try:
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", json.dumps({"op": "paus"}))
        check("a typo'd op -> 400", st == 400, f"status {st}")
        check("...and lists the known ops",
              st == 400 and "known" in d, json.dumps(d)[:80])
        st, d = js("POST", "/api/v1/nodes/sender:123/commands", "pause")
        check("a command for a SENDER -> 400", st == 400, f"status {st}")
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "")
        check("an empty body -> 400", st == 400, f"status {st}")
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands",
                    json.dumps({"op": "PAUSE"}))
        check("a wrong-cased op -> 400 (set is case-sensitive)", st == 400, f"status {st}")
        st, d = js("GET", "/api/v1/commands")
        check("...and no command was queued", d.get("commands") == [],
              f"{len(d.get('commands', []))} command(s)")
    finally:
        stop(hub, out)

    # =====================================================================
    print()
    print("== 4. ACK: the result of a command comes back as a message ==")
    for f in (cfg_path, audit_path, cmds_path):
        try:
            os.remove(f)
        except OSError:
            pass
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    try:
        ctx = zmq.Context()
        node = ctx.socket(zmq.XSUB)
        node.setsockopt(zmq.LINGER, 0)
        node.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        node.send(b"\x01@" + RECV.encode())
        up = ctx.socket(zmq.XSUB)
        up.setsockopt(zmq.LINGER, 0)
        up.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
        up.send(b"\x01@hub")
        time.sleep(0.8)

        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "pause")
        cid = d["command_id"]
        # wait for the CMD
        deadline = time.time() + 4
        while time.time() < deadline:
            try:
                parts = node.recv_multipart(zmq.NOBLOCK)
            except zmq.Again:
                time.sleep(0.1)
                continue
            if len(parts) >= 2 and b"T=CMD" in parts[1] and cid.encode() in parts[1]:
                break

        up.send_multipart([b"@hub", env("receiver", "ACK", f"ID={cid};OK=1;REV=0")])
        time.sleep(0.8)
        st, d = js("GET", f"/api/v1/commands/{cid}")
        check("the ACK moved it to acked", d.get("state") == "acked", str(d.get("state")))
        check("...and recorded when", d.get("ack_at", 0) > 0, str(d.get("ack_at")))

        # An ACK for an unknown id is reported, not silently accepted. Use an
        # OP-shaped id so the hub can still file it under `command` rather than
        # guessing `config` (see unknown_ack_prefix in main.rs).
        up.send_multipart([b"@hub", env("receiver", "ACK",
            f"ID=receiver-252034803-pause-999;OK=1;REV=0")])
        time.sleep(0.6)
        st, d = js("GET", "/api/v1/commands/receiver-252034803-pause-999")
        check("an ACK for an unknown id does not mint a command",
              d.get("error") == "no such command", json.dumps(d))

        # A rejection carries its reason.
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "closeall")
        rid = d["command_id"]
        up.send_multipart([b"@hub", env("receiver", "ACK", f"ID={rid};OK=0;ERR=refused")])
        time.sleep(0.8)
        st, d = js("GET", f"/api/v1/commands/{rid}")
        check("a rejection is recorded as rejected", d.get("state") == "rejected",
              str(d.get("state")))
        check("...with the node's reason kept", d.get("err") == "refused",
              str(d.get("err")))

        print()
        print("== 5. the audit has the operator actions ==")
        st, d = js("GET", "/api/v1/audit?limit=200")
        acts = [r["action"] for r in d.get("records", [])]
        for want in ("command.issued", "command.acked", "command.rejected",
                     "command.unknown_ack"):
            check(f"audit records {want}", want in acts, str(sorted(set(acts))))
    finally:
        stop(hub, out)
        for f in (cfg_path, audit_path, cmds_path):
            try:
                os.remove(f)
            except OSError:
                pass

    # =====================================================================
    print()
    print("== 6. the journal survives a hub restart (§15) ==")
    cmds_path = os.path.join(HERE, "_hub_cmd_journal.jsonl")
    audit_path = os.path.join(HERE, "_hub_cmd_audit.jsonl")
    cfg_path = os.path.join(HERE, "_hub_cmd_revs.jsonl")
    for f in (cfg_path, audit_path, cmds_path):
        try:
            os.remove(f)
        except OSError:
            pass
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    issued_id = None
    try:
        st, d = js("POST", f"/api/v1/nodes/{NODE}/commands", "reload")
        issued_id = d.get("command_id")
        check("issued a command before restart", bool(issued_id), str(issued_id))
    finally:
        stop(hub, out)

    # Restart with the SAME journal file.
    hub, out = start(True, audit_path, cfg_path, cmds_path)
    try:
        st, d = js("GET", "/api/v1/commands")
        cmds = d.get("commands", [])
        check("the command is still known after restart",
              any(c.get("id") == issued_id for c in cmds),
              f"{len(cmds)} command(s)")
        match = next((c for c in cmds if c.get("id") == issued_id), None)
        check("...and still pending (not lost, not re-applied)",
              match is not None and match.get("state") == "pending",
              str(match.get("state") if match else "missing"))
    finally:
        stop(hub, out)
        for f in (cfg_path, audit_path, cmds_path):
            try:
                os.remove(f)
            except OSError:
                pass

    print()
    p = sum(1 for _, ok, _ in CHECKS if ok)
    f = len(CHECKS) - p
    print(f"  pass={p}  fail={f}")
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
