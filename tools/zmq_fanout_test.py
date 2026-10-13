#!/usr/bin/env python3
"""
zmq_fanout_test.py - does ZMQ_CONFLATE on a PUB socket break fan-out?

The copier's sender publishes on two sockets:
    events   : PUB, SNDHWM=100
    snapshot : PUB, SNDHWM=10, CONFLATE=1

On the MT4 pilot, with TWO receivers subscribed (one MT5, one MT4), the MT4
receiver received the heartbeat stream but no snapshots for ~30 seconds, and
started working the moment the MT5 receiver stopped. That is a mutual
exclusion, and CONFLATE on a PUB socket is the only per-socket option that
differs between the two streams.

This reproduces the exact topology in isolation:

    A: PUB(conflate=1, sndhwm=10) + two SUBs in separate processes
    B: PUB(conflate=0, sndhwm=10) + two SUBs in separate processes   (control)

If A loses one subscriber and B does not, CONFLATE on PUB is the cause.
"""

import multiprocessing as mp
import os
import sys
import time

import zmq

PORT = int(os.environ.get("FANOUT_PORT", "5799"))
NMSG = 40
INTERVAL = 0.05


def subscriber(idx, port, ready_q, result_q, connect_delay):
    ctx = zmq.Context()
    s = ctx.socket(zmq.SUB)
    s.setsockopt(zmq.LINGER, 0)
    s.setsockopt(zmq.RCVHWM, 10)
    s.setsockopt(zmq.RECONNECT_IVL, 100)
    s.setsockopt(zmq.RECONNECT_IVL_MAX, 5000)
    s.setsockopt(zmq.IMMEDIATE, 1)
    time.sleep(connect_delay)
    s.connect(f"tcp://127.0.0.1:{port}")
    s.setsockopt(zmq.SUBSCRIBE, b"")
    ready_q.put(idx)

    got = set()
    deadline = time.time() + 12
    while time.time() < deadline:
        try:
            if s.poll(200, zmq.POLLIN):
                msg = s.recv()
                try:
                    got.add(int(msg.decode().split("=")[1]))
                except Exception:
                    pass
        except zmq.ZMQError:
            break
    s.close(0)
    ctx.term()
    result_q.put((idx, sorted(got)))


def run(conflate, label):
    ctx = zmq.Context()
    pub = ctx.socket(zmq.PUB)
    pub.setsockopt(zmq.LINGER, 0)
    pub.setsockopt(zmq.SNDHWM, 10)
    pub.setsockopt(zmq.IMMEDIATE, 1)
    if conflate:
        pub.setsockopt(zmq.CONFLATE, 1)
    pub.bind(f"tcp://127.0.0.1:{PORT}")

    ready_q = mp.Queue()
    result_q = mp.Queue()
    procs = []
    for i, delay in enumerate((0.0, 0.5)):
        p = mp.Process(target=subscriber,
                       args=(i, PORT, ready_q, result_q, delay))
        p.start()
        procs.append(p)

    for _ in range(2):
        ready_q.get(timeout=5)
    time.sleep(1.0)                      # let subscriptions propagate

    for n in range(NMSG):
        pub.send(f"n={n}".encode())
        time.sleep(INTERVAL)

    results = {}
    for _ in range(2):
        idx, got = result_q.get(timeout=20)
        results[idx] = got
    for p in procs:
        p.join(timeout=5)

    pub.close(0)
    ctx.term()

    print(f"\n=== {label} (CONFLATE={int(conflate)}) ===")
    ok = True
    for idx in sorted(results):
        got = results[idx]
        missing = [n for n in range(NMSG) if n not in got]
        print(f"  SUB{idx}: received {len(got)}/{NMSG}"
              f"{'' if not missing else '  MISSING ' + str(missing[:8])}"
              f"{' ...' if len(missing) > 8 else ''}")
        if len(got) < NMSG * 0.5:
            ok = False
    return ok


def main():
    a = run(True, "A: conflate ON")
    b = run(False, "B: conflate OFF (control)")
    print()
    print("=== verdict ===")
    if a and b:
        print("  both delivered to both subscribers - CONFLATE is NOT the cause")
    elif b and not a:
        print("  CONFLATE on PUB BREAKS fan-out to the second subscriber")
    else:
        print("  inconclusive - the control also lost messages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
