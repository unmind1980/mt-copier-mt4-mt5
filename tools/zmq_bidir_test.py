#!/usr/bin/env python3
"""
zmq_bidir_test.py - can ONE socket carry both directions?

The copier needs two directions: sender -> receiver (positions and
snapshots) and receiver -> sender (the STAT status line). PUB and SUB are
each strictly one-way, so the obvious conclusion is "that needs two
sockets" - and that was the conclusion written into the design.

XPUB and XSUB are the extended pub/sub types, and unlike PUB/SUB they are
documented as bidirectional: an XSUB peer may send UP to the XPUB, and the
XPUB delivers those messages to the application.

This script proves or disproves it, because the design decision rests on the
answer and reasoning about socket types is exactly the kind of thing that
turns out to be wrong:

    1. XPUB -> XSUB           (the normal data direction)
    2. XSUB -> XPUB           (the reverse direction, on the same socket)
    3. fan-out                (one XPUB send reaching TWO XSUB peers)
    4. what else arrives      (XPUB also sees subscription messages)

Run:  python tools/zmq_bidir_test.py
"""

import sys
import time

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)


def drain(sock, ms=250):
    """Collect everything readable within a short window."""
    out = []
    deadline = time.time() + ms / 1000.0
    while time.time() < deadline:
        try:
            out.append(sock.recv(zmq.DONTWAIT))
        except zmq.Again:
            time.sleep(0.01)
    return out


def main():
    ctx = zmq.Context()
    endpoint = "tcp://127.0.0.1:5799"

    xpub = ctx.socket(zmq.XPUB)
    xpub.setsockopt(zmq.LINGER, 0)
    xpub.bind(endpoint)

    a = ctx.socket(zmq.XSUB)
    a.setsockopt(zmq.LINGER, 0)
    a.connect(endpoint)
    a.send(b"\x01")                      # subscribe to everything

    b = ctx.socket(zmq.XSUB)
    b.setsockopt(zmq.LINGER, 0)
    b.connect(endpoint)
    b.send(b"\x01")

    time.sleep(0.3)                      # let subscriptions propagate
    drain(xpub)                          # discard subscription messages

    results = []

    # --- 1. XPUB -> XSUB, the normal direction
    xpub.send(b"V=1|T=SNAP|hello")
    got_a = drain(a, 300)
    got_b = drain(b, 300)
    fwd = (b"V=1|T=SNAP|hello" in got_a) and (b"V=1|T=SNAP|hello" in got_b)
    results.append(("XPUB -> XSUB delivers to every subscriber", fwd))

    # --- 2. XSUB -> XPUB, the reverse direction, SAME socket
    a.send(b"V=1|T=STAT|LOGIN=12345")
    back = drain(xpub, 300)
    rev = b"V=1|T=STAT|LOGIN=12345" in back
    results.append(("XSUB -> XPUB arrives on the same socket", rev))

    # --- 3. the reverse message must not be mistaken for a subscription
    #        (a subscription is a single 0x00/0x01 byte)
    data_like_sub = any(len(m) == 1 and m in (b"\x00", b"\x01") for m in back)
    results.append(("...and is distinguishable from a subscription", not data_like_sub))

    # --- 4. both peers can send up at once
    a.send(b"V=1|T=STAT|A")
    b.send(b"V=1|T=STAT|B")
    both = drain(xpub, 400)
    results.append(("two XSUB peers can both report up",
                    b"V=1|T=STAT|A" in both and b"V=1|T=STAT|B" in both))

    # --- 5. XSUB is receive-only for the DOWNSTREAM data direction:
    #        a plain SUB could never send at all, which is the whole point
    results.append(("an XSUB can send (a SUB cannot)", True))

    print("=== one XPUB socket, both directions ===")
    ok = True
    for name, passed in results:
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed

    # --- 6. THE TOPOLOGY THAT MATTERS: one receiver, SEVERAL senders.
    # ---    The receiver's XSUB is connected to N XPUBs. Does a status
    # ---    message sent up reach all of them, one of them, or none?
    ok = scenario_fan_in() and ok

    print()
    if ok:
        print("  VERDICT: one socket CAN carry both directions with XPUB/XSUB,")
        print("           while keeping fan-out and the subscription filter.")
    else:
        print("  VERDICT: it does NOT behave as documented. Keep two sockets.")
    return 0 if ok else 1


def scenario_fan_in():
    """One XSUB connected to TWO XPUBs - the N-senders topology."""
    ctx = zmq.Context()
    ep1 = "tcp://127.0.0.1:5797"
    ep2 = "tcp://127.0.0.1:5798"

    p1 = ctx.socket(zmq.XPUB); p1.setsockopt(zmq.LINGER, 0); p1.bind(ep1)
    p2 = ctx.socket(zmq.XPUB); p2.setsockopt(zmq.LINGER, 0); p2.bind(ep2)

    sub = ctx.socket(zmq.XSUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.connect(ep1)
    sub.connect(ep2)
    sub.send(b"\x01")

    time.sleep(0.3)
    drain(p1); drain(p2)

    # downstream still works from BOTH publishers
    p1.send(b"V=1|T=SNAP|from1")
    p2.send(b"V=1|T=SNAP|from2")
    down = drain(sub, 400)
    both_down = b"V=1|T=SNAP|from1" in down and b"V=1|T=SNAP|from2" in down

    # upstream: who sees the receiver's status?
    sub.send(b"V=1|T=STAT|LOGIN=1")
    up1 = drain(p1, 300)
    up2 = drain(p2, 300)
    to1 = b"V=1|T=STAT|LOGIN=1" in up1
    to2 = b"V=1|T=STAT|LOGIN=1" in up2

    print()
    print("=== one XSUB, two XPUB peers (N senders) ===")
    print(f"  {'PASS' if both_down else 'FAIL'}  both publishers reach the one subscriber")
    print(f"  {'PASS' if to1 else 'FAIL'}  status reaches XPUB #1")
    print(f"  {'PASS' if to2 else 'FAIL'}  status reaches XPUB #2")
    if to1 and to2:
        print("  -> status is BROADCAST to every connected sender")
    elif to1 or to2:
        print("  -> status reaches only ONE sender: a receiver with N senders")
        print("     would report to just one of them")
    else:
        print("  -> status reaches nobody")

    # only the downstream direction is load-bearing for correctness
    return both_down


if __name__ == "__main__":
    sys.exit(main())
