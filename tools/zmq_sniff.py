#!/usr/bin/env python3
"""
zmq_sniff.py - watch what a sender is actually publishing.

A passive subscriber: it connects to a sender's endpoint and prints the
message stream, decoded. It changes nothing and the sender does not know it
is there (PUB does not care how many subscribers exist).

This exists because the copier's own logs answer "what did the receiver do",
never "what did the sender put on the wire". When a receiver looks silent,
the first question is whether the messages are there at all.

Events and snapshots share ONE socket, so there is one subscription and the
two streams are separated by the envelope's T= field.

    zmq_sniff.py --host 127.0.0.1 --events 5555 --seconds 10
    zmq_sniff.py --host 127.0.0.1 --events 5555 --raw

Options:
    --seconds N   how long to listen (default 10)
    --raw         print the raw wire line as well as the decode
    --snap N      DEPRECATED and ignored - there is no second port any more.
                  Accepted so older command lines and scripts still run.
"""

import argparse
import sys
import time
from collections import Counter

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)


def decode(line):
    """Turn 'V=1|SID=..|...|P=..' into a short readable summary."""
    if "|P=" in line:
        head, payload = line.split("|P=", 1)
    else:
        head, payload = line, ""
    fields = {}
    for part in head.split("|"):
        if "=" in part:
            k, v = part.split("=", 1)
            fields[k] = v
    t = fields.get("T", "?")
    sid = fields.get("SID", "?")
    seq = fields.get("SEQ", "?")
    extra = ""
    if t == "SNAP":
        n = ""
        for part in payload.split(";"):
            if part.startswith("N="):
                n = part[2:]
        extra = f"positions={n}"
    elif t == "OPEN":
        vals = dict(p.split("=", 1) for p in payload.split(";") if "=" in p)
        extra = (f"uid={vals.get('UID','?')} {vals.get('SYM','?')} "
                 f"side={vals.get('SIDE','?')} lots={vals.get('LOTS','?')}")
    elif t == "CLOSE":
        vals = dict(p.split("=", 1) for p in payload.split(";") if "=" in p)
        extra = f"uid={vals.get('UID','?')}"
    elif t == "HBT":
        vals = dict(p.split("=", 1) for p in payload.split(";") if "=" in p)
        extra = f"eq={vals.get('EQ','?')} npos={vals.get('NPOS','?')}"
    return t, sid, seq, extra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--events", type=int, default=5555,
                    help="the sender's single port (events and snapshots)")
    ap.add_argument("--snap", type=int, default=None,
                    help="DEPRECATED and ignored - no second port any more")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--raw", action="store_true")
    args = ap.parse_args()

    if args.snap is not None:
        print(f"note: --snap {args.snap} is ignored - events and snapshots"
              f" share one socket on :{args.events} now")

    ctx = zmq.Context()
    sub = ctx.socket(zmq.SUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.setsockopt(zmq.RCVHWM, 1000)
    sub.setsockopt(zmq.RECONNECT_IVL, 100)
    sub.setsockopt(zmq.RECONNECT_IVL_MAX, 5000)
    sub.setsockopt(zmq.SUBSCRIBE, b"")
    sub.connect(f"tcp://{args.host}:{args.events}")

    poller = zmq.Poller()
    poller.register(sub, zmq.POLLIN)

    print(f"listening {args.seconds:g}s on tcp://{args.host}:{args.events} "
          f"(both streams)")
    counts = Counter()
    first_seq = {}
    last_seq = {}
    deadline = time.time() + args.seconds

    while time.time() < deadline:
        for sock, ev in poller.poll(200):
            raw = sock.recv().decode("utf-8", "replace")
            t, sid, seq, extra = decode(raw)
            counts[t] += 1
            key = f"{t}/{sid}"
            if key not in first_seq:
                first_seq[key] = seq
            last_seq[key] = seq
            print(f"  [{t:<5}] sid={sid:<10} seq={seq:<6} {extra}")
            if args.raw:
                print(f"             {raw}")

    print()
    print("=== summary ===")
    if not counts:
        print("  NOTHING RECEIVED.")
        print("  The sender is not running, or is bound somewhere else, or")
        print("  is not publishing at all.")
        return 1
    print(f"  {sum(counts.values()):>5} message(s)  {dict(counts)}")
    print()
    print("  sequence ranges (per stream, so the two counters advance")
    print("  independently even though they share one socket):")
    for key in sorted(first_seq):
        print(f"    {key:<24} {first_seq[key]} .. {last_seq[key]}")
    print()
    if counts.get("SNAP", 0) == 0:
        print("  !! no SNAP messages. The receiver never sets ready=true")
        print("     without one, so it will do nothing at all.")
    else:
        print("  snapshots are flowing - a silent receiver is not a")
        print("  publishing problem")
    return 0


if __name__ == "__main__":
    sys.exit(main())
