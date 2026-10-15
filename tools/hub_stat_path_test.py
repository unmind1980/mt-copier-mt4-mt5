#!/usr/bin/env python3
r"""
hub_stat_path_test.py - how a receiver's snapshot receipt reaches the SENDER.

WHY THIS EXISTS
---------------
Slice A of the snapshot-on-demand design rides on the STAT message: the
receiver echoes the sender's snapshot hash back up, and the sender compares it
against what it last sent. On a live central-mode run that produced NO output
at all, which is ambiguous - "perfectly in sync" and "the message never
arrives" look identical from the sender's log.

It turned out to be the second. In central mode the hub CONSUMES every
'@'-prefixed message and D13 (doc/CENTRAL-HUB-PLAN.md) deliberately keeps the
receiver's status at the hub rather than passing it to a sender. So the STAT
never reaches the sender, and the receipt inside it never did either.

The fix (O1) is a REFINEMENT of D13, not an exception to it: the hub keeps the
monitoring figures - equity, lots, risk, everything that is a property of the
receiver - and relays ONLY the delivery receipt, because "did my bytes arrive"
is a signal only the sender can act on.

This test measures all three of those claims against the real hub binary:

  1. the receipt DOES now arrive at the sender, on the '@<nid>' channel that
     already existed for hub -> node traffic
  2. the relayed message carries NO monitoring figures (D13 preserved)
  3. a STAT that cannot be addressed - no SID, i.e. an older receiver - is not
     relayed, and a receipt for a DIFFERENT sender does not land here

plus a control that the ordinary sender -> hub -> receiver data path still
works, since the relay shares the socket with it.

Nodes are modelled by their ACTUAL subscriptions:
  * SENDER   : "@<nid>" + "@all"        (CopierSender.mq4:501,505)
  * RECEIVER : "@<nid>" + "@all" + "<sender nid>"   (CopierReceiver.mq4:3691,3695,3697)
  * receiver sends STAT on "@hub"       (CopierReceiver.mq4:3272)

Run:  python hub_stat_path_test.py
"""

import os
import subprocess
import sys
import time

import zmq

HERE = os.path.dirname(os.path.abspath(__file__))
HUB = os.path.join(os.path.dirname(HERE), "hub", "target", "release", "copier-hub.exe")

PORT = 6199                      # deliberately NOT 6000 - do not disturb a live hub
NID_SENDER = "252033316"
NID_OTHER = "53203697"
NID_RECV = "252034803"
RECV_LOGIN = "9918271"
HASH = "13b2bc5c"

passes = []
fails = []


def check(name, ok, detail=""):
    (passes if ok else fails).append(name)
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


def stat_env(payload: bytes) -> bytes:
    return (b"V=1|SID=receiver|SSID=" + RECV_LOGIN.encode() + b"|SEQ=7|TS=1780000001|T=STAT|P="
            + payload)


def rcv_payload(env: bytes):
    """T= and the P= key/values of a received envelope, for assertions."""
    text = env.decode("latin-1")
    ty = ""
    if "|T=" in text:
        ty = text.split("|T=", 1)[1].split("|", 1)[0]
    kv = {}
    if "|P=" in text:
        for item in text.split("|P=", 1)[1].split(";"):
            if "=" in item:
                k, v = item.split("=", 1)
                kv[k] = v
    return ty, kv


def main():
    if not os.path.exists(HUB):
        print(f"hub binary not found: {HUB}")
        return 2

    print("== start a hub on a spare port, with its output captured ==")
    out_path = os.path.join(HERE, "_hub_stat_path.out")
    out = open(out_path, "wb")
    # --curve off: the suite speaks PLAINTEXT ZMQ to fake nodes (see
    # hub_positions_test) - without it the ZAP handler refuses every client.
    hub = subprocess.Popen([HUB, "--port", str(PORT), "--stats-every", "2",
                            "--curve", "off"],
                           stdout=out, stderr=subprocess.STDOUT)
    time.sleep(1.5)               # let it bind

    ctx = zmq.Context()

    sender = ctx.socket(zmq.XSUB)
    sender.setsockopt(zmq.LINGER, 0)
    sender.connect(f"tcp://127.0.0.1:{PORT}")
    sender.send(b"\x01@" + NID_SENDER.encode())
    sender.send(b"\x01@all")

    recv = ctx.socket(zmq.XSUB)
    recv.setsockopt(zmq.LINGER, 0)
    recv.connect(f"tcp://127.0.0.1:{PORT}")
    recv.send(b"\x01@" + NID_RECV.encode())
    recv.send(b"\x01@all")
    recv.send(b"\x01" + NID_SENDER.encode())

    time.sleep(1.5)               # let subscriptions propagate through the hub

    def drain(sock):
        seen = []
        while True:
            try:
                seen.append(sock.recv_multipart(zmq.NOBLOCK))
            except zmq.Again:
                return seen

    def wait_rcpt(timeout=1.2):
        """The first T=RCPT to arrive, ignoring hub chatter (WHO is on @all)."""
        end = time.time() + timeout
        while time.time() < end:
            for parts in drain(sender):
                if len(parts) >= 2:
                    ty, kv = rcv_payload(parts[1])
                    if ty == "RCPT":
                        return parts, kv
            time.sleep(0.05)
        return None, None

    print()
    print("== 1. the receipt now reaches the sender (O1) ==")
    drain(sender)
    recv.send_multipart([b"@hub", stat_env(
        b"LOGIN=" + RECV_LOGIN.encode() + b";SID=" + NID_SENDER.encode()
        + b";H=" + HASH.encode() + b";EQ=10042.11;BL=10000.00;HELD=2;LOTS=0.60")])
    parts, kv = wait_rcpt()
    check("hub relays the receipt to the sender", parts is not None,
          "nothing arrived" if parts is None else "ok")
    if parts is not None:
        check("it arrives on the '@<sender nid>' control topic",
              parts[0] == b"@" + NID_SENDER.encode(), parts[0].decode("latin-1"))
        check("the hash is relayed unchanged", kv.get("H") == HASH, str(kv.get("H")))
        check("the receiver is named, so senders can be tracked apart",
              kv.get("LOGIN") == RECV_LOGIN, str(kv.get("LOGIN")))
        check("it says which sender it is about", kv.get("SID") == NID_SENDER,
              str(kv.get("SID")))

        print()
        print("== 2. D13 preserved: no monitoring figures travel ==")
        for k in ("EQ", "BL", "HELD", "LOTS", "NSEND", "BLOCKED", "RISK"):
            check(f"the relayed receipt carries no {k}", k not in kv)

    print()
    print("== 3. a STAT that cannot be addressed is not relayed ==")
    drain(sender)
    recv.send_multipart([b"@hub", stat_env(b"LOGIN=" + RECV_LOGIN.encode() + b";H=" + HASH.encode())])
    parts, _ = wait_rcpt(timeout=0.8)
    check("an older receiver's STAT (no SID) is not relayed", parts is None,
          "relayed anyway" if parts is not None else "nothing arrived")

    drain(sender)
    recv.send_multipart([b"@hub", stat_env(
        b"LOGIN=" + RECV_LOGIN.encode() + b";SID=" + NID_OTHER.encode() + b";H=" + HASH.encode())])
    parts, _ = wait_rcpt(timeout=0.8)
    check("a receipt for ANOTHER sender does not land here", parts is None,
          "delivered to the wrong sender" if parts is not None else "nothing arrived")

    print()
    print("== 4. control: the data path still forwards ==")
    drain(recv)
    sender.send_multipart([NID_SENDER.encode(), b"V=1|SID=252033316|T=SNAP|P=N=0;H=x"])
    time.sleep(0.7)
    got = [p for p in drain(recv) if len(p) >= 2 and b"SNAP" in p[1]]
    check("sender -> hub -> receiver data still forwards", bool(got),
          "nothing arrived" if not got else "ok")

    # ------------------------------------------------------------------
    # Slice B: a sender must be able to reach ONE receiver, not all of them.
    #
    # The mechanism is the receiver's OWN NID used as a DATA topic. This is
    # the part the design document originally got wrong - it assumed '@<nid>'
    # could be used for it, which the hub consumes instead. Both are checked
    # here so the difference cannot be quietly lost again.
    # ------------------------------------------------------------------
    print()
    print("== 5. targeted repair addressing (slice B) ==")

    # Two receivers, each subscribing to its own NID as a data topic.
    r_target = ctx.socket(zmq.XSUB)
    r_target.setsockopt(zmq.LINGER, 0)
    r_target.connect(f"tcp://127.0.0.1:{PORT}")
    r_target.send(b"\x01" + NID_RECV.encode())

    r_other = ctx.socket(zmq.XSUB)
    r_other.setsockopt(zmq.LINGER, 0)
    r_other.connect(f"tcp://127.0.0.1:{PORT}")
    r_other.send(b"\x01" + NID_OTHER.encode())

    time.sleep(1.5)               # let the new subscriptions propagate

    def drain_sock(sock):
        seen = []
        while True:
            try:
                seen.append(sock.recv_multipart(zmq.NOBLOCK))
            except zmq.Again:
                return seen

    repair = b"V=1|SID=252033316|T=SNAP|P=N=1;R=ABC,1,EURUSD,1,0.01000000,1.1,0,0,0,1;H=deadbeef"

    # --- the correct mechanism: the receiver's own NID, no '@'
    drain_sock(r_target)
    drain_sock(r_other)
    sender.send_multipart([NID_RECV.encode(), repair])
    time.sleep(0.7)
    hit = any(repair in p for p in drain_sock(r_target))
    missed = not any(repair in p for p in drain_sock(r_other))
    check("a repair on '<receiver nid>' reaches THAT receiver", hit)
    check("...and does NOT reach a different receiver", missed)

    # --- the mechanism the design document first assumed: '@<receiver nid>'
    drain_sock(r_target)
    sender.send_multipart([b"@" + NID_RECV.encode(), repair])
    time.sleep(0.7)
    check("a repair on '@<receiver nid>' reaches nobody (the hub consumes it)",
          not any(repair in p for p in drain_sock(r_target)))

    # --- log volume: a routine uplink must not write a line per message
    #
    # STAT carries a receipt every SyncHeartbeatSeconds PER MIRRORED SENDER, so
    # it is routine in exactly the sense PING and HBT2 are. Before it joined that
    # list the live hub wrote ~4 lines/s of the same content-free string
    # ("[hub] up @hub T=STAT") - 1612 lines in 390 s on two senders and two
    # receivers, scaling with receivers x senders.
    #
    # Asserted with a burst rather than one message, because a single missing
    # line is easy to explain away and the whole point is the aggregate.
    for _ in range(20):
        sender.send_multipart(
            [b"@hub", stat_env(b"LOGIN=53203699;SID=252033316;H=cafebabe")])
    time.sleep(1.0)
    drain(sender)                      # the relayed receipts are not the test

    # A control message that is NOT routine must still print - the suppression
    # list is a list, not a mode, and widening it must not silence the unknown.
    sender.send_multipart(
        [b"@hub", b"V=1|SID=probe|T=CFGZ|P=ID=1"])
    time.sleep(0.7)

    print()
    print("== what the hub itself said ==")
    time.sleep(0.3)
    hub.terminate()
    try:
        hub.wait(timeout=5)
    except subprocess.TimeoutExpired:
        hub.kill()
    out.close()

    with open(out_path, "rb") as fh:
        text = fh.read().decode("utf-8", "replace")
    relay = [ln for ln in text.splitlines() if "receipts" in ln]
    print("  " + (relay[0].strip() if relay else "(hub reported no receipts)"))

    stat_lines = [ln for ln in text.splitlines() if "T=STAT" in ln]
    check("20 routine STAT uplinks wrote ZERO log lines",
          len(stat_lines) == 0,
          f"{len(stat_lines)} line(s): " + (stat_lines[0].strip()[:70] if stat_lines else ""))
    unknown = [ln for ln in text.splitlines() if "T=CFGZ" in ln]
    check("a non-routine control type still prints once",
          len(unknown) >= 1, f"{len(unknown)} line(s)")

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
