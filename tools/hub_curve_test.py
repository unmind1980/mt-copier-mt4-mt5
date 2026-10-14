#!/usr/bin/env python3
"""
hub_curve_test.py - CURVE on the hub link (the plan's §19.1 boundary).

What this proves, against the REAL hub binary and REAL libzmq:

  * **A CURVE client can talk to a CURVE hub.** The handshake completes and
    the hub registers the node. This is the half that is easy to get wrong
    silently - a 40-character key handed to zmq_setsockopt as 41 bytes never
    completes a handshake and says nothing anywhere.
  * **The allow-list is enforced at the handshake.** A client with a valid
    keypair that is NOT on the list is denied by the ZAP handler, so its REG
    never arrives and no node appears. This is the difference between
    "encrypted" and "authorised": CURVE alone accepts any keypair.
  * **A client with the wrong server key cannot connect at all.**
  * **An empty allow-list with --curve on REFUSES TO START** rather than
    accepting every keypair.
  * **Plaintext is refused on a CURVE port**: a client with no CURVE keys
    gets nowhere, which is what stops the boundary being optional in
    practice.
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
CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, ok, detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def read_public_key(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line.startswith("PUBLIC="):
            return line[len("PUBLIC="):].strip()
    return None


def start(clients_text, learn=False):
    """Start the hub with CURVE on. Returns (proc, out, out_path, keys_path...).

    `clients_text=None` means the clients file is left ABSENT - which is the
    real bring-up state for learn mode (an empty list that must not refuse)."""
    keys = os.path.join(HERE, "_hub_curve.keys")
    clients = os.path.join(HERE, "_hub_curve_clients.txt")
    audit = os.path.join(HERE, "_hub_curve_audit.jsonl")
    users = os.path.join(HERE, "_hub_curve_users.json")
    for f in (keys, clients, audit, users):
        try:
            os.remove(f)
        except OSError:
            pass
    if clients_text is not None:
        open(clients, "w", encoding="utf-8").write(clients_text)

    out_path = os.path.join(HERE, "_hub_curve.out")
    out = open(out_path, "wb")
    env = dict(os.environ)
    env["MTC_ADMIN_PASSWORD"] = "hub-test-pass"
    args = [HUB, "--port", str(ZMQ_PORT), "--http", f"127.0.0.1:{HTTP_PORT}",
            "--curve", "on", "--curve-keys", keys, "--curve-clients", clients,
            "--audit", audit, "--users", users,
            "--stats-every", "0", "--duration", "60"]
    if learn:
        args += ["--curve-learn", "on"]
    p = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT, env=env)
    return p, out, out_path, keys, clients, audit, users


def stop(p, out, *paths):
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()
    out.close()
    for f in paths:
        try:
            os.remove(f)
        except OSError:
            pass


def wait_http(seconds=8.0):
    end = time.time() + seconds
    while time.time() < end:
        try:
            c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=1)
            c.request("GET", "/healthz")
            c.getresponse().read()
            c.close()
            return True
        except Exception:
            time.sleep(0.1)
    return False


def api_login():
    c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
    c.request("POST", "/api/v1/login",
              body=json.dumps({"id": "admin", "password": "hub-test-pass"}),
              headers={"Content-Type": "application/json"})
    r = c.getresponse()
    sc = r.getheader("Set-Cookie") or ""
    r.read()
    c.close()
    for part in sc.split(";"):
        part = part.strip()
        if part.startswith("mtc_session="):
            return part[len("mtc_session="):]
    return None


def nodes(tok):
    c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
    c.request("GET", "/api/v1/nodes", headers={"Cookie": "mtc_session=" + tok})
    r = c.getresponse()
    d = json.loads(r.read())
    c.close()
    return {n["key"] for n in d.get("nodes", [])}


def curve_client(ctx, hub_pub, my_pub=None, my_sec=None, use_curve=True):
    s = ctx.socket(zmq.XSUB)
    s.setsockopt(zmq.LINGER, 0)
    if use_curve:
        # pyzmq exposes CURVE through setsockopt with BYTE values (the named
        # curve_* properties are not present on this build); 40-byte Z85 text
        # is accepted by libzmq directly, so no decoding is needed here.
        s.setsockopt(zmq.CURVE_SERVERKEY, hub_pub if isinstance(hub_pub, bytes)
                     else hub_pub.encode())
        if my_pub:
            s.setsockopt(zmq.CURVE_PUBLICKEY, my_pub)
            s.setsockopt(zmq.CURVE_SECRETKEY, my_sec)
    s.connect(f"tcp://127.0.0.1:{ZMQ_PORT}")
    return s


def announce(sock, acc, name):
    reg = (f"V=1|SID=sender|SSID={acc}|SEQ=1|TS={int(time.time())}|MS=0|T=REG|"
           f"P=ROLE=sender;ACC={acc};VER=1;NAME={name};UP=5")
    sock.send_multipart([b"@hub", reg.encode()])


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2
    if not zmq.has("curve"):
        print("this pyzmq has no CURVE support - install a build with libsodium")
        return 2

    # =====================================================================
    print("== 1. --curve on with an EMPTY allow-list must REFUSE to start ==")
    p, out, out_path, keys, clients, audit, users = start("# nothing yet\n")
    try:
        time.sleep(2.0)
        rc = p.poll()
        text = open(out_path, encoding="utf-8", errors="replace").read()
        check("the hub refused to start", rc is not None, f"exit code {rc}")
        check("...and said why (empty allow-list)",
              "contains no keys" in text and "Refusing to start" in text,
              text.strip().splitlines()[-1][:90] if text.strip() else "(no output)")
    finally:
        stop(p, out, keys, clients, audit, users, out_path)

    # =====================================================================
    print()
    print("== 2. a CURVE client is accepted when the list says '*' ==")
    p, out, out_path, keys, clients, audit, users = start("*\n")
    try:
        if not wait_http():
            check("hub came up", False, "no HTTP")
            return 1
        hub_pub = read_public_key(keys)
        check("the hub generated a keypair", hub_pub is not None and len(hub_pub) == 40,
              f"public key len {len(hub_pub) if hub_pub else 0}")
        tok = api_login()
        check("logged in to the API", tok is not None, "")

        ctx = zmq.Context()
        a_pub, a_sec = zmq.curve_keypair()
        s = curve_client(ctx, hub_pub, a_pub, a_sec)
        time.sleep(1.5)
        announce(s, "11111111", "curve-sender")
        time.sleep(2.0)
        got = nodes(tok)
        check("the CURVE client's node was registered",
              "sender:11111111" in got, str(sorted(got)))

        # The dashboard shows the hub's public key from the topology payload -
        # it is PUBLIC by definition, but it still has to actually BE there.
        c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
        c.request("GET", "/api/v1/topology", headers={"Cookie": "mtc_session=" + tok})
        r = c.getresponse()
        top = json.loads(r.read())
        c.close()
        cv = top.get("curve") or {}
        check("topology carries the CURVE state",
              cv.get("on") is True and cv.get("public_key") == hub_pub,
              str(cv)[:90])

        s.close(0)
        ctx.term()

        text = open(out_path, encoding="utf-8", errors="replace").read()
        check("the hub logged ZAP ALLOW", "ZAP ALLOW" in text,
              [l for l in text.splitlines() if "ZAP" in l][:1])
    finally:
        stop(p, out, keys, clients, audit, users, out_path)

    # =====================================================================
    print()
    print("== 3. the allow-list decides who gets in ==")
    # Two clients with valid keypairs; only ONE is listed.
    allowed_pub, allowed_sec = zmq.curve_keypair()
    other_pub, other_sec = zmq.curve_keypair()
    p, out, out_path, keys, clients, audit, users = start(allowed_pub.decode() + "\n")
    try:
        if not wait_http():
            check("hub came up (phase 3)", False, "no HTTP")
            return 1
        hub_pub = read_public_key(keys)
        tok = api_login()

        ctx = zmq.Context()
        s_ok = curve_client(ctx, hub_pub, allowed_pub, allowed_sec)
        s_no = curve_client(ctx, hub_pub, other_pub, other_sec)
        time.sleep(1.5)
        announce(s_ok, "22222222", "allowed")
        announce(s_no, "33333333", "not-allowed")
        time.sleep(2.5)

        got = nodes(tok)
        check("the LISTED client is registered", "sender:22222222" in got, str(sorted(got)))
        check("the UNLISTED client is NOT registered", "sender:33333333" not in got,
              str(sorted(got)))

        text = open(out_path, encoding="utf-8", errors="replace").read()
        check("the hub logged a ZAP DENY", "ZAP DENY" in text,
              [l for l in text.splitlines() if "ZAP DENY" in l][:1])
        s_ok.close(0)
        s_no.close(0)
        ctx.term()
    finally:
        stop(p, out, keys, clients, audit, users, out_path)

    # =====================================================================
    print()
    print("== 4. the wrong server key, and no key at all ==")
    p, out, out_path, keys, clients, audit, users = start("*\n")
    try:
        if not wait_http():
            check("hub came up (phase 4)", False, "no HTTP")
            return 1
        tok = api_login()
        ctx = zmq.Context()

        # (a) CURVE on, but pointed at a DIFFERENT hub's public key.
        bogus = zmq.curve_keypair()[0].decode()
        c_pub, c_sec = zmq.curve_keypair()
        s_wrong = curve_client(ctx, bogus, c_pub, c_sec)
        time.sleep(1.5)
        announce(s_wrong, "44444444", "wrong-server-key")

        # (b) no CURVE at all against a CURVE port.
        s_plain = curve_client(ctx, None, use_curve=False)
        time.sleep(1.5)
        announce(s_plain, "55555555", "plaintext")

        time.sleep(2.5)
        got = nodes(tok)
        check("the wrong-server-key client never arrives", "sender:44444444" not in got,
              str(sorted(got)))
        check("the plaintext client never arrives", "sender:55555555" not in got,
              str(sorted(got)))
        s_wrong.close(0)
        s_plain.close(0)
        ctx.term()
    finally:
        stop(p, out, keys, clients, audit, users, out_path)

    # =====================================================================
    print()
    print("== 5. --curve-learn on: the fleet registers ITSELF ==")
    # The bring-up case: NO clients file at all (an empty list must not
    # refuse), a node that has never been named, and the hub writing the
    # node's key into the file by itself. This is what removes the manual
    # 40-character transcription the operator used to have to do.
    p, out, out_path, keys, clients, audit, users = start(None, learn=True)
    try:
        if not wait_http():
            check("hub came up (learn, empty list)", False, "no HTTP")
            return 1
        hub_pub = read_public_key(keys)
        tok = api_login()

        ctx = zmq.Context()
        l_pub, l_sec = zmq.curve_keypair()
        s = curve_client(ctx, hub_pub, l_pub, l_sec)
        time.sleep(1.5)
        announce(s, "66666666", "learning")
        time.sleep(2.5)

        got = nodes(tok)
        check("an UNLISTED client is accepted in learn mode",
              "sender:66666666" in got, str(sorted(got)))
        listed = open(clients, encoding="utf-8", errors="replace").read()
        check("...and its key was auto-appended to curve_clients.txt",
              l_pub.decode() in listed, listed.strip()[:80])
        check("...marked '# learned' so it can be pruned", "# learned" in listed, "")
        s.close(0)
        ctx.term()

        text = open(out_path, encoding="utf-8", errors="replace").read()
        check("the hub logged ZAP LEARNED", "ZAP LEARNED" in text,
              [l for l in text.splitlines() if "LEARNED" in l][:1])
    finally:
        stop(p, out, keys, clients, audit, users, out_path)

    bad = [c for c in CHECKS if not c[1]]
    print()
    print(f"  pass={len(CHECKS) - len(bad)}  fail={len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
