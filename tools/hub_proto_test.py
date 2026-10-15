#!/usr/bin/env python3
"""
hub_proto_test.py - does the hub actually route the way the design says?

WHY THIS EXISTS
===============

The hub is the thing the EAs are written against, so its behaviour has to be
trustworthy BEFORE any EA is changed. A hub that "looks right" is worse than no
hub, because the EA work then gets debugged against a moving target.

So this drives it with a FAKE sender and FAKE receivers - real XSUB sockets,
real two-frame messages, real subscriptions - and asserts the six things the
design actually depends on:

    1. a receiver gets the senders it subscribed to, and only those
    2. frame 1 arrives BYTE-IDENTICAL (the hub must not re-encode)
    3. a control message goes up and is CONSUMED, not echoed back down
    4. a non-envelope frame is dropped, not fanned out
    5. the '@' namespace keeps control and data apart
    6. the hub answers a PING with a PONG
    7. REG builds a node, HBT2 does not duplicate it, and a REG with no ACC is
       refused (Phase 2's registry)

It needs no terminal, no broker and no EA.

WHY IT CAN DRIVE EITHER IMPLEMENTATION
======================================

Step 5 of the plan is "port the prototype to Rust", and the whole claim is that
the Rust hub is an ALIGNMENT, not a redesign. The cheapest way to hold that
claim to account is to run the identical suite against both binaries: if the
same 13 checks pass against `hub_proto.py` and against `copier-hub.exe`, then
"the Rust version behaves the same" is a measurement rather than an assertion.

    python tools/hub_proto_test.py                       # the Python prototype
    python tools/hub_proto_test.py --hub "hub/target/release/copier-hub.exe"
    python tools/hub_proto_test.py --hub "hub/target/release/copier-hub.exe" --port 6113

Usage:
    python tools/hub_proto_test.py [--hub CMD] [--port N]
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)

DEFAULT_PORT = 6112


def drain(sock, ms=400):
    out = []
    end = time.time() + ms / 1000.0
    while time.time() < end:
        try:
            out.append(sock.recv_multipart(zmq.DONTWAIT))
        except zmq.Again:
            time.sleep(0.01)
    return out


def main():
    ap = argparse.ArgumentParser(description="routing contract test for the Phase 1 hub")
    ap.add_argument("--hub", default=None,
                    help="command that starts a hub (default: the Python prototype)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help="port to run the hub on (default %d)" % DEFAULT_PORT)
    ap.add_argument("--registry", action="store_true",
                    help="also check the Phase 2 registry (REG/HBT2/WHO). "
                         "OFF by default because the Python prototype is frozen "
                         "at Phase 1 - Phase 2 exists only in the Rust hub")
    args = ap.parse_args()

    port = args.port
    ep = "tcp://127.0.0.1:%d" % port

    if args.hub:
        cmd = shlex.split(args.hub, posix=(os.name != "nt"))
        what = args.hub
    else:
        cmd = [sys.executable,
               os.path.join(os.path.dirname(os.path.abspath(__file__)), "hub_proto.py")]
        what = "hub_proto.py (python prototype)"

    log = tempfile.NamedTemporaryFile(delete=False, suffix=".hub.log", mode="w")
    hub = subprocess.Popen(
        #--- --stats-every 2, not 0: the stats line is the only place some
        #--- diagnostics appear, and a test that never prints it cannot see them.
        #--- (No --curve here: the default target is the Python prototype, which
        #--- has no --curve flag. Point --hub at the Rust exe to test it, and
        #--- pass --curve off in the --hub string yourself - see tests.bat.)
        cmd + ["--bind", "127.0.0.1", "--port", str(port), "--stats-every", "2"],
        stdout=log, stderr=subprocess.STDOUT)

    ctx = zmq.Context()
    failures = []

    #--- Report each check AS IT COMPLETES, not in a batch at the end.
    #--- A suite that only prints once it is finished says nothing at all when
    #--- it hangs - which is exactly the situation where you most need to know
    #--- how far it got. (Same lesson as the hub's own stdout buffering.)
    def check(name, cond):
        print("  %s  %s" % ("PASS" if cond else "FAIL", name), flush=True)
        if not cond:
            failures.append(name)

    try:
        time.sleep(1.5)

        def xsub(subs):
            s = ctx.socket(zmq.XSUB)
            s.setsockopt(zmq.LINGER, 0)
            s.connect(ep)
            for p in subs:
                s.send(b"\x01" + p.encode())
            return s

        sender = xsub([])            # a sender only wants its own control topic
        rA = xsub(["111111"])        # mirrors sender 111111
        rB = xsub(["222222"])        # mirrors sender 222222
        time.sleep(1.0)
        drain(sender); drain(rA); drain(rB)

        print("=== hub routing contract: %s ===" % what)

        # --- 1. routing: the subscribed receiver gets it, the other does not
        sender.send_multipart([b"111111", b"V=1|SID=111111|SSID=a1|SEQ=1|T=SNAP|P=N=1"])
        a = drain(rA); b = drain(rB)
        check("data reaches the receiver subscribed to that sender",
              any(m[1].startswith(b"V=1|SID=111111") for m in a))
        check("...and NOT one subscribed to a different sender", len(b) == 0)

        sender.send_multipart([b"222222", b"V=1|SID=222222|SSID=b1|SEQ=1|T=SNAP|P=N=1"])
        a = drain(rA); b = drain(rB)
        check("the second sender reaches only its own receiver",
              any(m[1].startswith(b"V=1|SID=222222") for m in b) and len(a) == 0)

        # --- 2. the payload must survive untouched
        orig = b"V=1|SID=111111|SSID=a1|SEQ=7|TS=1780000000|MS=123|T=SNAP|P=N=1;R=X"
        sender.send_multipart([b"111111", orig])
        a = drain(rA)
        check("frame 1 arrives byte-identical (the hub does not re-encode)",
              any(m[1] == orig for m in a))
        check("frame 0 is the routing key", any(m[0] == b"111111" for m in a))

        # --- 3. control goes up and STOPS there.
        # ---     The hub consumes every '@' topic on the receive path: that is
        # ---     what stops one node's control traffic being fanned out to all
        # ---     the others. (The DOWN path - the hub publishing '@<acc>' and
        # ---     only that node receiving it - is a ZMQ property, and is
        # ---     covered by tools/zmq_topic_test.py. Phase 1 has no down-path
        # ---     control to test: the hub does not send any.)
        rA.send_multipart([b"@hub", b"V=1|SID=222222|T=REG|P=ROLE=receiver;ACC=222222"])
        time.sleep(0.5)
        check("a control message is consumed, never echoed back down",
              len(drain(rA)) == 0 and len(drain(rB)) == 0)

        sender.send_multipart([b"@333333", b"V=1|SID=1|T=CFG|P=ID=AA1"])
        time.sleep(0.4)
        check("...and an '@' topic is never forwarded, whoever sent it",
              len(drain(rA)) == 0 and len(drain(rB)) == 0)

        # --- 4. garbage is not fanned out
        sender.send_multipart([b"111111", b"not-an-envelope"])
        check("a non-envelope frame is dropped, not forwarded", len(drain(rA)) == 0)

        # --- 5. '@' separates control from data
        rC = xsub(["@333333"])
        time.sleep(0.8)
        drain(rC)
        sender.send_multipart([b"333333", b"V=1|SID=333333|T=SNAP|P=x"])
        check("'@' namespace: a control subscriber receives no data", len(drain(rC)) == 0)

        # --- 6. the hub ANSWERS a ping.
        # ---     The one message it originates, and it has to: ZMQ connect()
        # ---     succeeds against a hub that does not exist, so without an echo
        # ---     a node cannot tell a live link from a dead one - the panel
        # ---     would read "connected" forever.
        rD = xsub(["@444444"])
        time.sleep(0.8)
        drain(rD)
        rD.send_multipart([b"@hub",
                           b"V=1|SID=444444|SSID=x|SEQ=1|TS=1|MS=1|T=PING|P=MS=12345;FROM=444444"])
        got = drain(rD, 600)
        pong = [m for m in got if m[0] == b"@444444"]
        check("the hub answers a PING with a PONG", len(pong) == 1)
        if pong:
            check("...echoing the node's own ms (a true round trip)",
                  b"MS=12345" in pong[0][1])
            check("...naming itself as the responder", b"FROM=hub" in pong[0][1])
            check("...and addressing the node that asked", b"TO=444444" in pong[0][1])

        # --- 7. THE REGISTRY (Phase 2).
        # ---     The hub learns who exists ONLY from REG/HBT2 - it never probes
        # ---     and never guesses - so these two messages are the entire input
        # ---     to its node table. Checked against the hub's own stdout, which
        # ---     is the only view of that table until the API exists.
        # ---
        # ---     Skipped unless --registry: the Python prototype is frozen at
        # ---     Phase 1, so these would fail against it for the right reason
        # ---     and the wrong result.
        if args.registry:
            rE = xsub([])                 # a node needs no data subscription
            time.sleep(0.8)
            drain(rE)

            # --- 7a. A NODE WHOSE REG WAS LOST.
            # ---     This is not a hypothetical: the EAs open their socket with
            # ---     IMMEDIATE, so a send made before the TCP connection
            # ---     completes is DISCARDED - and the first thing a node sends
            # ---     is a REG fired immediately after connect(). The node is
            # ---     still real, and HBT2 is what introduces it. It must be
            # ---     REPORTED, or the hub counts nodes and explains none of
            # ---     them, which is exactly how a working hub was mistaken for
            # ---     a broken one.
            rE.send_multipart([b"@hub",
                               b"V=1|SID=555001|SSID=x|SEQ=1|TS=1|MS=1|T=HBT2|"
                               b"P=ROLE=sender;ACC=555001;VER=2.0;UP=41"])
            time.sleep(0.5)

            # --- 7b. ...and then the REG arrives, which must fill in the name
            # ---     WITHOUT creating a second node.
            rE.send_multipart([b"@hub",
                               b"V=1|SID=555001|SSID=x|SEQ=2|TS=1|MS=2|T=REG|"
                               b"P=ROLE=sender;ACC=555001;VER=2.0;NAME=REG-NODE;UP=42"])
            time.sleep(0.4)
            rE.send_multipart([b"@hub",
                               b"V=1|SID=555001|SSID=x|SEQ=3|TS=1|MS=3|T=HBT2|"
                               b"P=ROLE=sender;ACC=555001;VER=2.0;UP=43"])
            time.sleep(0.4)
            # --- a REG with no ACC is not a node: it cannot be addressed, so it
            # --- must be refused rather than filed under an empty key forever
            rE.send_multipart([b"@hub",
                               b"V=1|SID=555002|SSID=x|SEQ=4|TS=1|MS=4|T=REG|"
                               b"P=ROLE=sender;VER=2.0"])

            # --- 7c. A SINGLE-FRAME MESSAGE, which the hub cannot route.
            # ---     The direct channel is one frame; the central channel is
            # ---     two. A node that sends its uplink the direct way produces
            # ---     something the hub reads, matches against the subscription
            # ---     shape, finds is not one, and drops - with no trace at all,
            # ---     until this counter existed. A silent discard is the worst
            # ---     possible treatment for a protocol mismatch.
            rE.send(b"V=1|SID=555001|SSID=x|SEQ=9|T=STAT|P=EQ=1")

            # --- 7d. A SETTLING NODE. The counter-reset trap, checked because
            # ---     the wrong version looks like a safety net.
            # ---
            # ---     A node's first CP_REG_REPEATS announces are REG; after
            # ---     that it must settle into HBT2 forever. If it re-arms that
            # ---     counter every time it answers a WHO - and the hub sweeps
            # ---     WHO unconditionally every 60s - it never settles. A
            # ---     measured 300s run produced 19 REG from a node whose
            # ---     correct figure is 3, and every extra one carried a NAME.
            # ---
            # ---     The EA's counter is not visible from here, so what is
            # ---     asserted is the shape the fix guarantees: a node that
            # ---     announces repeatedly is ONE node, reported once.
            rF = xsub([])
            time.sleep(0.6)
            drain(rF)
            # --- a first burst of REG, then HBT2 once settled
            for i in range(3):
                rF.send_multipart([b"@hub",
                                   b"V=1|SID=666001|SSID=x|SEQ=%d|TS=1|MS=%d|T=REG|"
                                   b"P=ROLE=sender;ACC=666001;VER=2.0;NAME=SETTLE;UP=1"
                                   % (i + 1, i + 1)])
                time.sleep(0.2)
            rF.send_multipart([b"@hub",
                               b"V=1|SID=666001|SSID=x|SEQ=9|TS=1|MS=9|T=HBT2|"
                               b"P=ROLE=sender;ACC=666001;VER=2.0;UP=2"])
            time.sleep(0.3)
            # --- and an extra REG, as a WHO reply would be
            rF.send_multipart([b"@hub",
                               b"V=1|SID=666001|SSID=x|SEQ=20|TS=1|MS=20|T=REG|"
                               b"P=ROLE=sender;ACC=666001;VER=2.0;NAME=SETTLE;UP=3"])

            # --- long enough for at least one registry tick (2s cadence)
            time.sleep(2.6)

    finally:
        hub.terminate()
        try:
            hub.wait(timeout=5)
        except subprocess.TimeoutExpired:
            hub.kill()
        #--- destroy(), NOT term(). Context.term() blocks until every socket
        #--- opened from the context has been closed, and this test never
        #--- closes them individually - so term() waited forever on four
        #--- sockets that were still alive. Every check had already PASSED by
        #--- then, which made it look like a hang in the hub rather than in the
        #--- teardown of the test itself.
        ctx.destroy(linger=0)

    log.close()
    with open(log.name, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    try:
        os.unlink(log.name)
    except OSError:
        pass

    print()
    print("--- hub stdout ---")
    for ln in lines:
        print("  " + ln)

    #--- PHASE 2 checks. The hub's node table has no other view yet - the API is
    #--- the second half of Phase 2 - so its own stdout IS the assertion
    #--- surface. That is a limitation worth naming rather than hiding.
    if args.registry:
        joined = "\n".join(lines)
        print()
        print("=== registry contract (Phase 2) ===")
        #--- 7a: introduced by a heartbeat, because its REG was lost. It must be
        #--- REPORTED - a hub that counts nodes and explains none of them is
        #--- indistinguishable from a broken one.
        check("a node introduced by its HBT2 is reported, not counted silently",
              "+node sender:555001" in joined)
        check("...and the hub says the REG was lost", "REG was lost" in joined)
        check("...with no name, because HBT2 carries none",
              re.search(r"\+node sender:555001\s+-\s", joined) is not None)
        #--- 7b: the REG finally arrives. It must fill in the name WITHOUT
        #--- creating a second node, and it must say so.
        check("the late REG names the node it did not re-create",
              "named sender:555001" in joined)
        check("...and does not create a SECOND entry", joined.count("+node sender:555001") == 1)
        check("...and the name it reported is the one shown", "REG-NODE" in joined)
        #--- "counts it online" rather than an exact number: check 3 above also
        #--- sends a REG (from receiver:222222), so the total legitimately
        #--- depends on how many ticks landed between the two.
        check("...and the hub counts nodes online",
              re.search(r"nodes online [1-9]", joined) is not None)
        check("a REG with no ACC is refused, not filed under an empty key",
              "no ACC" in joined)
        #--- The hub registers whoever registers, including the receiver that
        #--- check 3's control message came from. Both roles, not just the one
        #--- this section sends.
        check("a receiver registers too, not only senders",
              "+node receiver:222222" in joined)
        #--- 7c: an unroutable single frame must be COUNTED, not swallowed.
        check("an unroutable single-frame message is counted, not silent",
              "single-frame" in joined)
        #--- And control must be broken down by type, for the same reason
        #--- forwarded traffic is. Reporting "control 201" with no way to ask
        #--- "of what" is what let a 2-per-second runaway sit in plain sight:
        #--- the number was visible and the explanation was not, and the first
        #--- thing anyone does with a rate they cannot explain is guess.
        check("the stats break control down by type",
              "control by type" in joined)
        #--- And the routine chatter must NOT be what fills the log. PING fires
        #--- every 2 s per sender; printing it buries everything that is not
        #--- routine, and an operator who cannot see the signal stops reading.
        check("routine PINGs are not logged by default",
              "T=PING" not in joined)
        #--- 7d: the settle case. A node that announces more than once is still
        #--- ONE node - the hub keys on ROLE:ACC, not on the message. This is
        #--- what keeps a re-announcing node from flooding the table, and it is
        #--- the hub-side half of the counter-reset fix (the EA-side half is the
        #--- unchanged g_announceCount, which sends one REG per WHO, not one per
        #--- heartbeat).
        check("a node that announces repeatedly is reported exactly once",
              joined.count("+node sender:666001") == 1)

    print()
    if not failures:
        print("  VERDICT: the hub routes, forwards byte-for-byte, consumes")
        print("           control, keeps '@' separate from data, and builds a")
        print("           node table from what nodes SAY rather than guessing.")
        print("           Safe to point a real sender/receiver at it.")
        return 0

    print("  VERDICT: routing does NOT match the design:")
    for f in failures:
        print("             %s" % f)
    print("           Fix this BEFORE changing any EA - debugging the EAs")
    print("           against a wrong hub is how a protocol gets blamed for a")
    print("           bug that is not in it.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
