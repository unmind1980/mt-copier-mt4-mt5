#!/usr/bin/env python3
"""
zmq_topic_test.py - can the hub ADDRESS one node, or only broadcast?

THE QUESTION THIS SETTLES
=========================

The central hub needs to send a config update to ONE receiver, not to all of
them. The plan says "use XPUB/XSUB, address the recipient by its account
number" - but that only works if the routing key is the FIRST thing in the
message, because ZMQ's pub/sub filter is a PREFIX match on the message bytes.

The copier's envelope is:

    V=1|SID=888888|SSID=...|SEQ=...|...

Every message starts with "V=1|". So subscribing to "888888" matches NOTHING.
That is not a ZMQ limitation - it is a consequence of the envelope's layout,
which was chosen for easy MQL parsing in v1.

The fix is a TOPIC FRAME: publish a two-frame message [topic, envelope]. ZMQ
matches the subscription against frame 0 only, so `\\x01` + topic becomes an
exact, network-level filter - and frame 1 stays byte-identical to what the
direct (mesh) channel already sends, so one parser serves both.

This script proves or disproves each part of that, because the whole central
channel format rests on the answers:

    1. a two-frame message survives XPUB -> XSUB, frames in order
    2. the subscription filters on FRAME 0, not on the payload
    3. the CURRENT envelope cannot be subscribed to at all (the problem)
    4. one XSUB can hold SEVERAL prefixes at once
    5. prefix matching is NOT exact: 888888 also matches 8888881
    6. the '@' namespace keeps control and data apart
    7. fan-out: one publish still reaches every matching subscriber
    8. a node can send a two-frame message UP to the hub
    9. a subscription can be REMOVED again (a node changes its sender list)

What this script CANNOT answer is whether mql-zmq can RECEIVE two frames -
`ZmqMsg` has no `getPart()`, only `more()`. That needs the MQL probe
(CopierZmqProbe.mq4/mq5), which must be run inside a terminal.

Run:  python tools/zmq_topic_test.py
"""

import sys
import time

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)

BASE = "tcp://127.0.0.1:5791"


def drain(sock, ms=250):
    """Collect every multipart message readable within a short window.

    Returns a list of frame-lists, so a caller can assert on BOTH frames.
    """
    out = []
    deadline = time.time() + ms / 1000.0
    while time.time() < deadline:
        try:
            out.append(sock.recv_multipart(zmq.DONTWAIT))
        except zmq.Again:
            time.sleep(0.01)
    return out


def topics(msgs):
    """Frame 0 of each message - the routing key."""
    return [m[0] for m in msgs if m]


def payloads(msgs):
    """Frame 1 of each message, when there is one."""
    return [m[1] for m in msgs if len(m) > 1]


def main():
    ctx = zmq.Context()

    xpub = ctx.socket(zmq.XPUB)
    xpub.setsockopt(zmq.LINGER, 0)
    xpub.bind(BASE)

    results = []

    # ---------------------------------------------------------------
    # A subscriber that wants everything, used for the framing tests.
    # ---------------------------------------------------------------
    allsub = ctx.socket(zmq.XSUB)
    allsub.setsockopt(zmq.LINGER, 0)
    allsub.connect(BASE)
    allsub.send(b"\x01")
    time.sleep(0.3)
    drain(xpub)                       # discard subscription notifications

    # --- 1. a two-frame message survives, in order
    xpub.send_multipart([b"888888", b"V=1|SID=888888|SSID=a1|SEQ=1|T=SNAP|P=x"])
    got = drain(allsub, 300)
    ok1 = any(m[0] == b"888888" and m[1].startswith(b"V=1|") for m in got)
    results.append(("a two-frame message survives XPUB -> XSUB, frames in order", ok1))

    # --- 2. frame 1 is byte-identical to the v1 envelope (nothing re-encoded)
    ok2 = any(m[1] == b"V=1|SID=888888|SSID=a1|SEQ=1|T=SNAP|P=x" for m in got)
    results.append(("frame 1 arrives byte-identical to the v1 envelope", ok2))

    # ---------------------------------------------------------------
    # The problem: the CURRENT envelope cannot be subscribed to.
    # ---------------------------------------------------------------
    sid_sub = ctx.socket(zmq.XSUB)
    sid_sub.setsockopt(zmq.LINGER, 0)
    sid_sub.connect(BASE)
    sid_sub.send(b"\x01888888")       # "I want account 888888"
    time.sleep(0.3)
    drain(xpub)

    # single-frame, the way v1 actually sends it
    xpub.send(b"V=1|SID=888888|SSID=a1|SEQ=2|T=SNAP|P=x")
    got = drain(sid_sub, 300)
    ok3 = len(got) == 0
    results.append(("...the CURRENT envelope cannot be subscribed to at all", ok3))

    # --- 3b. and the same message WITH a topic frame DOES arrive
    xpub.send_multipart([b"888888", b"V=1|SID=888888|SSID=a1|SEQ=3|T=SNAP|P=x"])
    got = drain(sid_sub, 300)
    ok3b = any(m[0] == b"888888" for m in got)
    results.append(("...but the SAME message with a topic frame arrives", ok3b))

    # --- 4. the filter is on FRAME 0: a different topic is NOT delivered
    xpub.send_multipart([b"999999", b"V=1|SID=999999|SSID=b1|SEQ=4|T=SNAP|P=y"])
    got = drain(sid_sub, 300)
    ok4 = len(got) == 0
    results.append(("the filter is on frame 0: another topic is not delivered", ok4))

    # ---------------------------------------------------------------
    # One node, several prefixes: a receiver mirrors N senders AND
    # wants control addressed to itself.
    # ---------------------------------------------------------------
    multi = ctx.socket(zmq.XSUB)
    multi.setsockopt(zmq.LINGER, 0)
    multi.connect(BASE)
    for pfx in (b"@222222", b"888888", b"999999"):
        multi.send(b"\x01" + pfx)
    time.sleep(0.3)
    drain(xpub)

    xpub.send_multipart([b"@222222", b"V=1|T=CFG|P=ID=AA2026"])
    xpub.send_multipart([b"888888",  b"V=1|T=SNAP|P=a"])
    xpub.send_multipart([b"999999",  b"V=1|T=SNAP|P=b"])
    xpub.send_multipart([b"777777",  b"V=1|T=SNAP|P=c"])   # not subscribed
    got = drain(multi, 400)
    seen = set(topics(got))
    ok5 = seen == {b"@222222", b"888888", b"999999"}
    results.append(("one XSUB holds several prefixes; unsubscribed ones are absent", ok5))

    # ---------------------------------------------------------------
    # Prefix matching is NOT exact - this is why '@' exists.
    # ---------------------------------------------------------------
    xpub.send_multipart([b"8888881", b"V=1|T=SNAP|P=other-account"])
    got = drain(multi, 300)
    collided = any(m[0] == b"8888881" for m in got)
    results.append(("prefix match is NOT exact: 888888 also catches 8888881", collided))

    # --- the '@' namespace keeps control and data apart
    ctl = ctx.socket(zmq.XSUB)
    ctl.setsockopt(zmq.LINGER, 0)
    ctl.connect(BASE)
    ctl.send(b"\x01@888888")
    time.sleep(0.3)
    drain(xpub)
    xpub.send_multipart([b"888888", b"V=1|T=SNAP|P=data"])       # must NOT arrive
    xpub.send_multipart([b"@888888", b"V=1|T=CFG|P=ctl"])        # must arrive
    got = drain(ctl, 400)
    seen = set(topics(got))
    ok6 = seen == {b"@888888"}
    results.append(("the '@' namespace separates control from data", ok6))

    # ---------------------------------------------------------------
    # Fan-out still works: one publish, every matching subscriber.
    # ---------------------------------------------------------------
    fan1 = ctx.socket(zmq.XSUB); fan1.setsockopt(zmq.LINGER, 0)
    fan2 = ctx.socket(zmq.XSUB); fan2.setsockopt(zmq.LINGER, 0)
    fan1.connect(BASE); fan2.connect(BASE)
    fan1.send(b"\x01@555555"); fan2.send(b"\x01@555555")
    time.sleep(0.3)
    drain(xpub)
    xpub.send_multipart([b"@555555", b"V=1|T=CFG|P=broadcast"])
    g1 = drain(fan1, 300); g2 = drain(fan2, 300)
    ok7 = any(m[0] == b"@555555" for m in g1) and any(m[0] == b"@555555" for m in g2)
    results.append(("fan-out: one publish reaches every matching subscriber", ok7))

    # ---------------------------------------------------------------
    # Upstream: a node ACKs the hub with a topic frame of its own.
    # ---------------------------------------------------------------
    multi.send_multipart([b"@hub", b"V=1|T=ACK|P=ID=AA2026;OK=1"])
    up = drain(xpub, 400)
    ok8 = any(m[0] == b"@hub" and b"OK=1" in m[1] for m in up)
    results.append(("a node can send a two-frame message UP to the hub", ok8))

    # ---------------------------------------------------------------
    # Unsubscribe: a receiver whose sender list CHANGED must drop the old
    # sender, or it keeps receiving a stream it no longer mirrors.
    # ---------------------------------------------------------------
    multi.send(b"\x00" + b"999999")            # unsubscribe from 999999
    time.sleep(0.3)
    drain(xpub)
    xpub.send_multipart([b"999999", b"V=1|T=SNAP|P=gone"])
    xpub.send_multipart([b"888888", b"V=1|T=SNAP|P=still"])
    got = drain(multi, 400)
    seen = set(topics(got))
    ok9 = b"888888" in seen and b"999999" not in seen
    results.append(("a prefix can be REMOVED again (sender list changed)", ok9))

    # ---------------------------------------------------------------
    print()
    print("=== topic frame + prefix subscription (the hub's addressing) ===")
    ok = True
    for name, passed in results:
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed

    print()
    if ok:
        print("  VERDICT: a topic frame gives the hub real per-node addressing.")
        print("           Frame 1 stays byte-identical to v1, so one parser")
        print("           serves both the direct and the central channel.")
        print("           NOTE: '@' in the namespace is NOT optional - 888888")
        print("           also matches 8888881 under plain prefix matching.")
    else:
        print("  VERDICT: the addressing scheme does NOT behave as designed.")
        print("           Fall back to plan A (in-payload TO= filtering):")
        print("           it costs bandwidth and leaks every control message")
        print("           to every receiver, but needs no format change.")

    print()
    print("  STILL UNVERIFIED (needs a terminal, not this script):")
    print("    can mql-zmq RECEIVE two frames?  ZmqMsg has no getPart(),")
    print("    only more() - run the CopierZmqProbe script in MetaTrader.")

    ctx.destroy(linger=0)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
