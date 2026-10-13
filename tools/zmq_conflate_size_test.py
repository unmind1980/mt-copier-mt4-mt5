#!/usr/bin/env python3
"""
zmq_conflate_size_test.py - does CONFLATE on a PUB socket corrupt or drop
                            messages once the payload is not tiny?

The copier's snapshot socket is PUB + SNDHWM=10 + CONFLATE=1, and a sniffer
showed its messages arriving at the subscriber completely EMPTY while the
events socket (PUB + SNDHWM=100, no CONFLATE) delivered normally.

An earlier fan-out test with 4-byte payloads showed no problem at all, which
is exactly the kind of false negative a too-simple reproduction gives you.
A real snapshot is ~1.2 KB, so size is the variable to test.

    PUB: SNDHWM=10, IMMEDIATE=1, CONFLATE=<0|1>
    SUB: plain
    payload sizes: small (16 B), realistic (1.2 KB), large (8 KB)
"""

import multiprocessing as mp
import sys
import time

import zmq

PORT = 5801


def make_payload(n):
    """A payload shaped like a real SNAP: long, with the copier's separators."""
    rec = ("ABCD1234,385171084,EURUSD,1,0.01000000,1.11795000,0.00000000,"
           "0.00000000,0,1791186615")
    recs = "~".join(rec for _ in range(max(1, n // len(rec) + 1)))
    p = f"V=1|SID=sender01|SSID=TEST01|SEQ=1|TS=0|T=SNAP|P=N=1;R={recs}"
    return p[:n].encode()


def subscriber(port, ready_q, result_q):
    ctx = zmq.Context()
    s = ctx.socket(zmq.SUB)
    s.setsockopt(zmq.LINGER, 0)
    s.setsockopt(zmq.RCVHWM, 100)
    s.setsockopt(zmq.SUBSCRIBE, b"")
    s.connect(f"tcp://127.0.0.1:{port}")
    ready_q.put(1)
    got = []
    deadline = time.time() + 12
    while time.time() < deadline:
        if s.poll(200, zmq.POLLIN):
            got.append(s.recv())
    s.close(0)
    ctx.term()
    result_q.put(got)


def run(conflate, size, label):
    ctx = zmq.Context()
    pub = ctx.socket(zmq.PUB)
    pub.setsockopt(zmq.LINGER, 0)
    pub.setsockopt(zmq.SNDHWM, 10)
    pub.setsockopt(zmq.IMMEDIATE, 1)
    if conflate:
        pub.setsockopt(zmq.CONFLATE, 1)
    pub.bind(f"tcp://127.0.0.1:{PORT}")

    ready_q, result_q = mp.Queue(), mp.Queue()
    p = mp.Process(target=subscriber, args=(PORT, ready_q, result_q))
    p.start()
    ready_q.get(timeout=5)
    time.sleep(1.0)

    payload = make_payload(size)
    N = 5
    for _ in range(N):
        pub.send(payload)
        time.sleep(0.3)

    got = result_q.get(timeout=20)
    p.join(timeout=5)
    pub.close(0)
    ctx.term()

    empty = sum(1 for m in got if len(m) == 0)
    whole = sum(1 for m in got if len(m) == len(payload))
    print(f"  {label:<34} sent {N} x {len(payload):>5}B -> "
          f"received {len(got):>2}, empty {empty:>2}, correct-size {whole:>2}")
    return empty == 0 and whole == len(got)


def main():
    print("\n=== CONFLATE on PUB, payload size sweep ===")
    results = {}
    for size in (16, 1200, 8000):
        results[("conflate", size)] = run(True, size, f"CONFLATE=1  size={size}")
        results[("plain", size)] = run(False, size, f"CONFLATE=0  size={size}")

    print("\n=== verdict ===")
    bad = [k for k, ok in results.items() if not ok and k[0] == "conflate"]
    good_plain = all(ok for k, ok in results.items() if k[0] == "plain")
    if bad and good_plain:
        print("  CONFLATE on PUB CORRUPTS/DROPS messages at: "
              + ", ".join(f"{s}B" for _, s in bad))
        print("  while the same payloads are fine without CONFLATE.")
        print("  -> remove ZMQ_CONFLATE from the snapshot PUB socket.")
    elif bad:
        print("  CONFLATE is broken, but so is the control - inconclusive")
    else:
        print("  no corruption at any tested size - CONFLATE is not the cause")
    return 0


if __name__ == "__main__":
    sys.exit(main())
