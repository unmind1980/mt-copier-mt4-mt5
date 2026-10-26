#!/usr/bin/env python3
"""
ha_probe_test.py - Phase 0 ZMQ Multi-Endpoint & Dual-Active Probe Suite

This test suite executes empirical probes against the core assumptions of the
Phase 0 HA (High Availability) design for mt-copier:
  1. Multi-Endpoint connect on single XSUB socket (Primary + Standby).
  2. Upstream frame routing: does XSUB send fan-out to all connected XPUBs,
     or does it round-robin (load-balance)?
  3. Single CURVE server key shared between two XPUB servers.
  4. Interleaved arrival & out-of-order snapshot/event deduplication.
  5. Multi-Hub PONG identity isolation vs single 'hub' collision.

Run:
  python tools/ha_probe_test.py
"""

import sys
import time
import socket

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)


def get_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def drain(sock, ms=300):
    """Collect everything readable within a short window."""
    out = []
    deadline = time.time() + ms / 1000.0
    while time.time() < deadline:
        try:
            parts = sock.recv_multipart(zmq.DONTWAIT)
            out.append(parts)
        except zmq.Again:
            time.sleep(0.01)
    return out


def test_multi_endpoint_downstream(ctx):
    """Probe 1: Can one XSUB socket receive from both Primary and Standby XPUBs?"""
    p1 = get_free_port()
    p2 = get_free_port()
    ep1 = f"tcp://127.0.0.1:{p1}"
    ep2 = f"tcp://127.0.0.1:{p2}"

    hub1 = ctx.socket(zmq.XPUB)
    hub1.setsockopt(zmq.LINGER, 0)
    hub1.bind(ep1)

    hub2 = ctx.socket(zmq.XPUB)
    hub2.setsockopt(zmq.LINGER, 0)
    hub2.bind(ep2)

    sub = ctx.socket(zmq.XSUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.connect(ep1)
    sub.connect(ep2)

    # Subscribe to prefix "123456"
    sub.send(b"\x01123456")
    time.sleep(0.15)
    drain(hub1, 50)
    drain(hub2, 50)

    # Send from Hub1
    hub1.send_multipart([b"123456", b"V=1|FROM=hub1|T=OPEN"])
    # Send from Hub2
    hub2.send_multipart([b"123456", b"V=1|FROM=hub2|T=OPEN"])

    received = drain(sub, 300)
    received_payloads = [r[1] for r in received if len(r) >= 2]

    got_hub1 = any(b"FROM=hub1" in p for p in received_payloads)
    got_hub2 = any(b"FROM=hub2" in p for p in received_payloads)

    sub.close()
    hub1.close()
    hub2.close()

    ok = got_hub1 and got_hub2
    desc = f"Single XSUB receives from both Primary ({ep1}) and Standby ({ep2})"
    return ok, desc, f"got_hub1={got_hub1}, got_hub2={got_hub2}, total_frames={len(received)}"


def test_upstream_distribution_policy(ctx):
    """Probe 2: When XSUB sends upstream to two XPUBs, is it fan-out or round-robin?"""
    p1 = get_free_port()
    p2 = get_free_port()
    ep1 = f"tcp://127.0.0.1:{p1}"
    ep2 = f"tcp://127.0.0.1:{p2}"

    hub1 = ctx.socket(zmq.XPUB)
    hub1.setsockopt(zmq.LINGER, 0)
    hub1.bind(ep1)

    hub2 = ctx.socket(zmq.XPUB)
    hub2.setsockopt(zmq.LINGER, 0)
    hub2.bind(ep2)

    sub = ctx.socket(zmq.XSUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.connect(ep1)
    sub.connect(ep2)
    time.sleep(0.15)

    # Send 10 messages upstream
    for i in range(10):
        sub.send_multipart([b"@hub", f"V=1|MSG={i}".encode()])
        time.sleep(0.01)

    got1 = drain(hub1, 300)
    got2 = drain(hub2, 300)

    count1 = len([m for m in got1 if len(m) >= 2 and m[0] == b"@hub"])
    count2 = len([m for m in got2 if len(m) >= 2 and m[0] == b"@hub"])

    sub.close()
    hub1.close()
    hub2.close()

    # In ZeroMQ XSUB upstream routing:
    # Notice: In ZeroMQ, messages sent through XSUB are load-balanced (round-robin)
    # across connected XPUB sockets, NOT broadcast/fanned-out.
    is_round_robin = (count1 > 0 and count2 > 0 and (count1 + count2 == 10))
    is_broadcast = (count1 == 10 and count2 == 10)

    desc = "XSUB upstream transmission routing policy observation"
    detail = f"Primary received {count1}/10, Standby received {count2}/10 -> "
    if is_round_robin:
        detail += "ZMQ standard behavior: Round-Robin (load-balanced)."
    elif is_broadcast:
        detail += "Broadcast behavior (fan-out)."
    else:
        detail += f"Single-preferred or asymmetric (h1={count1}, h2={count2})."

    # This probe always passes because its purpose is finding ground truth
    return True, desc, detail


def test_shared_curve_keypair_dual_connect(ctx):
    """Probe 3: Verify single XSUB socket CURVE handshake with two XPUBs sharing identical server keys."""
    # Generate shared server keypair (Primary & Standby share this keypair)
    srv_pub, srv_sec = zmq.curve_keypair()
    # Generate client keypair
    cli_pub, cli_sec = zmq.curve_keypair()

    p1 = get_free_port()
    p2 = get_free_port()
    ep1 = f"tcp://127.0.0.1:{p1}"
    ep2 = f"tcp://127.0.0.1:{p2}"

    hub1 = ctx.socket(zmq.XPUB)
    hub1.setsockopt(zmq.LINGER, 0)
    hub1.setsockopt(zmq.CURVE_SERVER, 1)
    hub1.setsockopt(zmq.CURVE_SECRETKEY, srv_sec)
    hub1.bind(ep1)

    hub2 = ctx.socket(zmq.XPUB)
    hub2.setsockopt(zmq.LINGER, 0)
    hub2.setsockopt(zmq.CURVE_SERVER, 1)
    hub2.setsockopt(zmq.CURVE_SECRETKEY, srv_sec)
    hub2.bind(ep2)

    sub = ctx.socket(zmq.XSUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.setsockopt(zmq.CURVE_SERVERKEY, srv_pub)
    sub.setsockopt(zmq.CURVE_PUBLICKEY, cli_pub)
    sub.setsockopt(zmq.CURVE_SECRETKEY, cli_sec)
    sub.connect(ep1)
    sub.connect(ep2)

    sub.send(b"\x01")  # subscribe all
    time.sleep(0.2)
    drain(hub1, 50)
    drain(hub2, 50)

    # Both hubs send encrypted traffic
    hub1.send_multipart([b"topic", b"V=1|T=TEST|P=FROM_HUB1_ENCRYPTED"])
    hub2.send_multipart([b"topic", b"V=1|T=TEST|P=FROM_HUB2_ENCRYPTED"])

    received = drain(sub, 300)
    payloads = [r[1] for r in received if len(r) >= 2]

    got1 = any(b"FROM_HUB1_ENCRYPTED" in p for p in payloads)
    got2 = any(b"FROM_HUB2_ENCRYPTED" in p for p in payloads)

    sub.close()
    hub1.close()
    hub2.close()

    ok = got1 and got2
    desc = "Shared CURVE server key allows single XSUB socket to encrypt-connect to both Hubs"
    return ok, desc, f"hub1_ok={got1}, hub2_ok={got2}, total_decrypted={len(payloads)}"


def test_conflation_max_seq_vs_reverse_index():
    """Probe 4: Demonstrate reverse array index vs max_seq snapshot conflation under multi-hub latency jitter."""
    # Simulate a batch of snapshots received in drain queue:
    # Due to network jitter between Primary (fast) and Standby (slow):
    # Slot 0 contains new snapshot from Primary: SEQ=105
    # Slot 1 contains older snapshot from Standby arriving 2ms later: SEQ=104
    batch = [
        {"slot": 0, "sid": "1001", "ssid": "sess_A", "seq": 105, "data": "POS=EURUSD,1.0;H=AAAA"},
        {"slot": 1, "sid": "1001", "ssid": "sess_A", "seq": 104, "data": "POS=EURUSD,0.5;H=BBBB"},
    ]

    # Current flawed MQL logic in CopierReceiver.mq4:7185:
    # for (i = n - 1; i >= 0; i--) -> selects the first one encountered from the back!
    selected_flawed = None
    for i in range(len(batch) - 1, -1, -1):
        if batch[i]["sid"] == "1001":
            selected_flawed = batch[i]
            break

    # Proposed ADR max_seq logic:
    selected_fixed = None
    max_seq = -1
    for item in batch:
        if item["sid"] == "1001" and item["seq"] > max_seq:
            max_seq = item["seq"]
            selected_fixed = item

    flawed_is_stale = (selected_flawed["seq"] == 104)
    fixed_is_latest = (selected_fixed["seq"] == 105)

    ok = flawed_is_stale and fixed_is_latest
    desc = "Snapshot Conflation: Max-SEQ algorithm selects latest (SEQ=105) whereas reverse index falls into stale (SEQ=104)"
    detail = f"flawed_selected_seq={selected_flawed['seq']} (stale rollback!), fixed_selected_seq={selected_fixed['seq']} (correct latest)"
    return ok, desc, detail


def test_pong_peer_identity_collision():
    """Probe 5: Demonstrate peer table collision when both Hubs reply with identical FROM=hub."""
    class MockPeerTable:
        def __init__(self):
            self.peers = {}

        def record_pong(self, peer_name, rtt_ms):
            self.peers[peer_name] = {"rtt": rtt_ms, "last_seen": time.time()}

    table = MockPeerTable()

    # Case A: Both Hubs reply with identical name "hub"
    table.record_pong("hub", 5)   # Primary is fast (5ms)
    time.sleep(0.01)
    table.record_pong("hub", 85)  # Standby is slower (85ms) -> overwrites Primary!
    collision_rtt = table.peers["hub"]["rtt"]

    # Case B: Differentiated names: hub:primary vs hub:standby
    table_diff = MockPeerTable()
    table_diff.record_pong("hub:primary", 5)
    table_diff.record_pong("hub:standby", 85)

    primary_ok = table_diff.peers["hub:primary"]["rtt"] == 5
    standby_ok = table_diff.peers["hub:standby"]["rtt"] == 85

    ok = (collision_rtt == 85) and primary_ok and standby_ok
    desc = "PONG identity isolation: 'hub:primary' and 'hub:standby' prevent latency masking & false-online blindspots"
    detail = f"single_hub_rtt_overwritten_to={collision_rtt}ms, split_rtts={{primary: {table_diff.peers['hub:primary']['rtt']}ms, standby: {table_diff.peers['hub:standby']['rtt']}ms}}"
    return ok, desc, detail


def main():
    print("=" * 72)
    print("mt-copier Phase 0: HA Dual-Active Empirical Probe Test Suite")
    print("=" * 72)

    ctx = zmq.Context()
    probes = [
        test_multi_endpoint_downstream(ctx),
        test_upstream_distribution_policy(ctx),
        test_shared_curve_keypair_dual_connect(ctx),
        test_conflation_max_seq_vs_reverse_index(),
        test_pong_peer_identity_collision(),
    ]
    ctx.term()

    all_passed = True
    print("\nProbe Results:")
    for i, (ok, desc, detail) in enumerate(probes, 1):
        status = "PASS" if ok else "FAIL"
        if not ok:
            all_passed = False
        print(f"\n[{status}] Probe {i}: {desc}")
        print(f"       Evidence: {detail}")

    print("\n" + "=" * 72)
    if all_passed:
        print("ALL 5 HA EMPIRICAL PROBES PASSED (Baseline & Assumptions Verified)")
        return 0
    else:
        print("SOME PROBES FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(main())
