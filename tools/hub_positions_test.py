#!/usr/bin/env python3
r"""
hub_positions_test.py - M3: the hub's read-only position view.

WHY THIS EXISTS
---------------
M3 makes the hub PARSE a payload. Until now it moved bytes and read nothing but
`T=`, and that restraint is the whole reason it cannot corrupt a trade
instruction. So this test has two jobs, and the second one matters more:

  1. the view is correct - the right sender, the right count, the right lots
  2. **the bytes that go out are still the bytes that came in**

If (2) ever fails, the hub has stopped being a transparent proxy and every other
guarantee in the project is void. It is checked first, and with a payload whose
parse would be visibly wrong if it had been used to rebuild the frame.

The trap this also pins: a SNAP is published on the SENDER's nid when it is the
periodic broadcast, but on the RECEIVER's nid when it is a targeted repair. A
view keyed by topic would file that receiver's account as a sender holding
somebody else's positions. The view is keyed by the envelope's SID instead.

Run:  python hub_positions_test.py
"""

import os
import subprocess
import sys
import time

import zmq

HERE = os.path.dirname(os.path.abspath(__file__))
HUB = os.path.join(os.path.dirname(HERE), "hub", "target", "release", "copier-hub.exe")

PORT = 6198                      # NOT 6000 - do not disturb a live hub
SID = "252033316"                # the sender
RECV_NID = "252034803"           # a receiver mirroring it

passes = []
fails = []


def check(name, ok, detail=""):
    (passes if ok else fails).append(name)
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def rec(uid, sym, side, lots):
    return (f"{uid},9918271,{sym},{side},{lots},1.08450000,"
            f"1.08000000,1.09000000,0,1780000000")


def snap(recs, receipt="a1b2c3d4"):
    p = f"N={len(recs)}"
    if recs:
        p += ";R=" + "~".join(recs)
    return p + f";H={receipt}"


def env(sid, ty, payload, seq=1):
    return (f"V=1|SID={sid}|SSID=abc123|SEQ={seq}|TS=1780000000|T={ty}|P={payload}"
            .encode("latin-1"))


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2

    out_path = os.path.join(HERE, "_hub_positions.out")
    out = open(out_path, "wb")
    # --curve off: the suite speaks PLAINTEXT ZMQ to fake nodes, and --curve
    # now defaults ON (the 1380af1 flip) - without the flag the ZAP handler
    # refuses every fake client at the handshake and the whole suite "fails"
    # for a reason that has nothing to do with positions.
    hub = subprocess.Popen([HUB, "--port", str(PORT), "--stats-every", "1",
                            "--curve", "off"],
                           stdout=out, stderr=subprocess.STDOUT)
    time.sleep(1.5)

    ctx = zmq.Context()

    sender = ctx.socket(zmq.XSUB)
    sender.setsockopt(zmq.LINGER, 0)
    sender.connect(f"tcp://127.0.0.1:{PORT}")
    sender.send(b"\x01@" + SID.encode())
    sender.send(b"\x01@all")

    recv = ctx.socket(zmq.XSUB)
    recv.setsockopt(zmq.LINGER, 0)
    recv.connect(f"tcp://127.0.0.1:{PORT}")
    recv.send(b"\x01" + SID.encode())

    time.sleep(1.5)               # let subscriptions propagate

    def drain(sock):
        seen = []
        while True:
            try:
                seen.append(sock.recv_multipart(zmq.NOBLOCK))
            except zmq.Again:
                return seen

    # ------------------------------------------------------------------
    print("== 1. the forward is still byte for byte ==")
    # A payload whose own text is NOT the thing that should come out the other
    # side. If the hub rebuilt the frame from its parse - or reused the parse's
    # buffer - this is where it would show.
    p1 = snap([rec("AAAA", "EURUSD", 1, "0.50000000"),
               rec("BBBB", "EURUSD", -1, "0.10000000"),
               rec("CCCC", "XAUUSD", 1, "0.02000000")])
    raw = env(SID, "SNAP", p1, seq=7)
    drain(recv)
    sender.send_multipart([SID.encode(), raw])
    time.sleep(0.7)
    got = [p for p in drain(recv) if len(p) >= 2 and b"SNAP" in p[1]]
    check("the receiver got the snapshot", bool(got))
    if got:
        check("frame 1 (the topic) is unchanged", got[0][0] == SID.encode(),
              got[0][0].decode("latin-1"))
        check("frame 2 is IDENTICAL, byte for byte", got[0][1] == raw,
              "differs" if got[0][1] != raw else "ok")
        check("...including the payload's own text, unedited",
              p1.encode("latin-1") in got[0][1])

    # ------------------------------------------------------------------
    print()
    print("== 2. the view is keyed by SID, not by the topic ==")
    # The same snapshot, but published on the RECEIVER's nid - the shape a
    # targeted repair has. It must land on the SENDER's row.
    p2 = snap([rec("DDDD", "GBPUSD", 1, "0.25000000")], receipt="beefbeef")
    sender.send_multipart([RECV_NID.encode(), env(SID, "SNAP", p2, seq=8)])
    time.sleep(2.5)               # a stats window must pass

    hub.terminate()
    try:
        hub.wait(timeout=5)
    except subprocess.TimeoutExpired:
        hub.kill()
    out.close()

    text = open(out_path, "rb").read().decode("utf-8", "replace")
    pos = [ln.strip() for ln in text.splitlines() if "[hub] positions" in ln]
    rows = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("[hub]   ") and "pos" in ln]

    check("the hub printed a positions block", bool(pos), "none found")
    # A well-formed snapshot must NOT trip the declared-vs-carried warning. It
    # did once, on every snapshot, because the parser was handed the whole
    # envelope instead of the P= section - so `N=` (the first field, preceded by
    # `|P=` rather than `;`) was never found and the count always read 0.
    check("a well-formed snapshot does not trip the count warning",
          not any("WARNING" in p for p in pos), str(pos[-1:]))
    if pos:
        print("      " + pos[-1])
        check("it counted 1 sender", " 1 sender(s)" in pos[-1], pos[-1])
        check("and 1 position (the last snapshot wins)",
              " 1 position(s)" in pos[-1], pos[-1])
        check("with the right volume", "0.25 lots" in pos[-1], pos[-1])
    check("the sender is the row's key, never the receiver",
          any(SID in r for r in rows) and not any(RECV_NID in r for r in rows),
          str(rows[-3:]))

    # ------------------------------------------------------------------
    print()
    print("== 3. the totals are honest and the receipt is shown ==")
    if rows:
        print("      " + rows[-1])
        check("the symbol breakdown is on the row", "GBPUSD:1:0.25" in rows[-1], rows[-1])
        check("the receipt hash is shown", "h=beefbeef" in rows[-1], rows[-1])

    # ------------------------------------------------------------------
    print()
    print("== 4. hostile input does not take the hub down ==")
    out2 = open(out_path, "wb")
    hub2 = subprocess.Popen([HUB, "--port", str(PORT), "--stats-every", "1",
                             "--curve", "off"],
                            stdout=out2, stderr=subprocess.STDOUT)
    time.sleep(1.5)
    sender2 = ctx.socket(zmq.XSUB)
    sender2.setsockopt(zmq.LINGER, 0)
    sender2.connect(f"tcp://127.0.0.1:{PORT}")
    sender2.send(b"\x01" + SID.encode())
    time.sleep(1.0)
    for bad in (b"N=999999999999999999999;R=x",
                b"N=1;R=" + b"A" * 5000,
                b"N=1;R=~" * 500,
                b"\xff\xfe\x00\x01",
                b""):
        sender2.send_multipart([SID.encode(), env(SID, "SNAP", "")[:-len(b"")] + b"P=" + bad])
        time.sleep(0.15)
    time.sleep(0.5)
    alive = hub2.poll() is None
    check("the hub survived malformed snapshots", alive,
          "the hub exited" if not alive else "ok")
    hub2.terminate()
    try:
        hub2.wait(timeout=5)
    except subprocess.TimeoutExpired:
        hub2.kill()
    out2.close()

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
