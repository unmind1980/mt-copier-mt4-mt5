#!/usr/bin/env python3
"""
hub_proto.py - Phase 1 "transparent proxy" hub, as a throwaway prototype.

WHY A PROTOTYPE AND NOT RUST
============================

Phase 1's hub is PURE FORWARDING: receive a two-frame message, look at frame 0,
send it on. There is no registry, no config store, no routing table - it does
not even need to know which senders or receivers exist. Written as a script
that is about 120 lines of real logic; written as a Rust project it is the same
logic plus a workspace, a build, and a service definition.

So the prototype exists to answer the PROTOCOL questions before any of that is
committed to:

    * do two-frame messages survive a real round trip through the hub?
    * does a receiver really only get the senders it subscribed to?
    * does the receiver converge identically to a direct connection?
    * what happens to the receiver when the hub is stopped and restarted?

Once those are answered against the REAL EAs, the Rust version is "implement a
behaviour that is already known to work" instead of "implement a design".

WHAT IT DOES
============

    bind XPUB on --port (default 6000); every EA connects an XSUB to it.

    loop:
        parts = recv_multipart()
        if len(parts) < 2:  ignore          # subscription byte, not data
        topic, payload = parts[0], parts[1]
        if not payload.startswith(b"V="):   drop + warn   # not a v1 envelope
        if topic.startswith(b"@"):          consume       # control for a node
        else:                               republish     # sender data

That is the whole thing. Frame 1 is forwarded BYTE FOR BYTE - the hub never
re-encodes, never touches SEQ/SSID/TS. That is what makes it structurally
incapable of corrupting a trade instruction, and it is the reason the receiver
needs no changes to its convergence logic.

WHAT IT DELIBERATELY DOES NOT DO
================================

  * no registry, no REG handling beyond logging
  * no config, no ini, no ACK tracking
  * no conflation (it does not parse T= to keep only the newest snapshot)
  * no persistence, no auth - see the plan: the firewall is the trust boundary

The ONE thing it originates is a PONG. That is not scope creep: a node cannot
otherwise tell a working hub link from a dead one, because ZMQ connect()
succeeds immediately whether or not anything is listening at the other end.
It needs no state - the node's own millisecond value is echoed straight back,
so (now - echoed) is a true round trip with no clocks involved.

Usage:
    python tools/hub_proto.py                       # tcp://0.0.0.0:6000
    python tools/hub_proto.py --port 6100
    python tools/hub_proto.py --verbose             # every message
    python tools/hub_proto.py --duration 300        # exit after 5 minutes
"""

import argparse
import collections
import signal
import sys
import time

try:
    import zmq
except ImportError:
    print("pyzmq is required: pip install pyzmq")
    sys.exit(2)

#--- match the EAs' own queue depths (CP_SNDHWM / CP_RCVHWM). A PUB drops when
#--- its queue is full, and that is acceptable here ONLY because a snapshot is
#--- idempotent full state: whatever is dropped is superseded within
#--- SnapshotSeconds. The hub must not be the thing that makes it worse.
HWM = 1000

#--- The largest frame this hub will accept, matching the EAs' CP_MAXMSGSIZE
#--- (1 MB) so a frame the hub forwards can never be one a node would refuse.
#---
#--- This is the DoS control that actually works, and it is not the same thing
#--- as a length check in the app. The hub is the internet-facing end, so a
#--- peer can announce a multi-gigabyte frame: without this libzmq reads and
#--- buffers it before any Python line runs, and the process dies of the
#--- allocation, not of the parsing. ZMQ_MAXMSGSIZE is enforced during the
#--- frame read and the peer is DISCONNECTED instead.
#---
#--- A hub is also a fan-out: one oversized frame it accepted would be copied
#--- to every subscriber, so the cost of being wrong is multiplied by the
#--- number of nodes.
MAXMSGSIZE = 1024 * 1024

#--- A topic emitting faster than this is not traffic, it is a loop: some node
#--- is echoing a data topic back up and the hub is forwarding it again. The
#--- intended design cannot produce that (receivers only ever send UP with a
#--- "@hub" topic), so it can only be a bug - and a silent infinite loop is
#--- worth five lines to catch.
LOOP_WARN_PER_SEC = 200

EXIT = False


def on_sigint(signum, frame):
    global EXIT
    EXIT = True


def envelope_type(payload):
    """The T= field of a v1 envelope, or '' if it is not shaped as expected."""
    i = payload.find(b"|T=")
    if i < 0:
        return ""
    j = payload.find(b"|", i + 3)
    if j < 0:
        return ""
    return payload[i + 3:j].decode("latin-1", "replace")


def envelope_kv(payload, key):
    """First k=v in the payload section. Used only for logging."""
    p = payload.find(b"|P=")
    if p < 0:
        return ""
    want = (key + "=").encode()
    for item in payload[p + 3:].split(b";"):
        if item.startswith(want):
            return item[len(want):].decode("latin-1", "replace")
    return ""


class HubState:
    """The little the hub needs to originate a message of its own.

    ONLY the PONG uses this. It is deliberately not a registry: the hub still
    does not know which nodes exist, which is the line that keeps Phase 1 from
    quietly absorbing Phase 2.
    """

    def __init__(self):
        self.seq = 0
        self.ssid = "hubproto"


def send_pong(sock, nid, ms, state):
    """Echo a node's probe back, on the two-frame channel.

    The PAYLOAD MS is the NODE'S value, echoed untouched - that is what makes
    (now - echoed) a true round trip with no clock synchronisation involved.
    The envelope's own MS is the hub's clock and nothing reads it for a PONG.
    """
    state.seq += 1
    env = ("V=1|SID=hub|SSID=%s|SEQ=%d|TS=%d|MS=%d|T=PONG|P=MS=%s;FROM=hub;TO=%s"
           % (state.ssid, state.seq, int(time.time()),
              int(time.time() * 1000) % 2147483647, ms, nid))
    sock.send_multipart([("@" + nid).encode("ascii"), env.encode("ascii")])


class Stats:
    def __init__(self):
        self.forwarded = 0
        self.control = 0
        self.dropped = 0
        self.by_topic = collections.Counter()
        self.by_type = collections.Counter()
        self.window_start = time.time()
        self.subs = {}                      # prefix -> True (present)

    def window(self):
        return max(0.001, time.time() - self.window_start)

    def reset_window(self):
        self.by_topic.clear()
        self.by_type.clear()
        self.window_start = time.time()


def main():
    ap = argparse.ArgumentParser(description="Phase 1 transparent-proxy hub (prototype)")
    ap.add_argument("--bind", default="0.0.0.0", help="interface to bind (default 0.0.0.0)")
    ap.add_argument("--port", type=int, default=6000, help="port to bind (default 6000)")
    ap.add_argument("--verbose", action="store_true",
                    help="log every message, not just events and stats")
    ap.add_argument("--stats-every", type=float, default=30.0,
                    help="seconds between stats lines (default 30)")
    ap.add_argument("--duration", type=float, default=0.0,
                    help="exit after this many seconds (0 = run until Ctrl-C)")
    args = ap.parse_args()

    signal.signal(signal.SIGINT, on_sigint)

    #--- Line-buffer stdout, explicitly.
    #---
    #--- The hub is normally run with its output redirected to a file or a log
    #--- collector, and Python block-buffers stdout when it is not a terminal.
    #--- The result was a hub that had been running for an hour and whose log
    #--- was EMPTY - every line still sat in a buffer, and a killed process
    #--- discards it. That reads exactly like "it never started", which is the
    #--- most expensive possible way to be wrong about a process that is fine.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass

    ctx = zmq.Context()
    sock = ctx.socket(zmq.XPUB)
    sock.setsockopt(zmq.LINGER, 0)          # or ctx_term blocks forever
    sock.setsockopt(zmq.SNDHWM, HWM)
    sock.setsockopt(zmq.RCVHWM, HWM)
    #--- refuse an oversized frame mid-read rather than buffering it first
    sock.setsockopt(zmq.MAXMSGSIZE, MAXMSGSIZE)

    endpoint = "tcp://%s:%d" % (args.bind, args.port)
    try:
        sock.bind(endpoint)
    except zmq.ZMQError as e:
        print("[hub] cannot bind %s: %s" % (endpoint, e))
        return 1

    print("[hub] listening on %s" % endpoint)
    print("[hub] EAs connect an XSUB here; the hub needs no other configuration")
    if args.duration:
        print("[hub] will exit after %.0fs" % args.duration)
    print()

    stats = Stats()
    state = HubState()
    started = time.time()
    last_stats = time.time()

    while not EXIT:
        #--- poll with a timeout so the stats line still appears on a quiet
        #--- feed. A blocking recv here would mean no output at all while the
        #--- market is shut - exactly when someone is watching it.
        if sock.poll(1000) == 0:
            pass
        else:
            try:
                parts = sock.recv_multipart(zmq.DONTWAIT)
            except zmq.Again:
                parts = []

            if len(parts) == 1:
                #--- a subscription change, NOT data. XPUB delivers these on
                #--- the same socket, so they must be told apart by SHAPE
                #--- (one frame) rather than assumed to be data.
                b = parts[0]
                if b and b[0] in (1, 0):
                    prefix = b[1:].decode("latin-1", "replace")
                    if b[0] == 1:
                        if prefix not in stats.subs:
                            stats.subs[prefix] = True
                            print("[hub] +sub %-24s %s" % (prefix, describe_sub(prefix)))
                    else:
                        stats.subs.pop(prefix, None)
                        print("[hub] -sub %-24s (last subscriber for this prefix left)" % prefix)
            elif len(parts) >= 2:
                topic, payload = parts[0], parts[1]

                if not payload.startswith(b"V="):
                    stats.dropped += 1
                    print("[hub] DROP  topic=%s  %d bytes, does not start with 'V='"
                          % (topic.decode("latin-1", "replace"), len(payload)))
                elif topic.startswith(b"@"):
                    stats.control += 1
                    t = envelope_type(payload)
                    print("[hub] up    %-14s T=%-5s %s" % (topic.decode("latin-1", "replace"),
                                                           t, control_note(payload, t)))
                    #--- ANSWER PINGS. This is the one thing the hub originates,
                    #--- and it is not scope creep: a node cannot otherwise tell
                    #--- a working hub link from a dead one. ZMQ connect()
                    #--- succeeds immediately whether or not anything is
                    #--- listening, so without an echo the sender's panel would
                    #--- show "connected" against a hub that does not exist.
                    #---
                    #--- It needs no state: echo the node's own MS back and the
                    #--- round trip falls out with no clocks involved.
                    if t == "PING":
                        nid = envelope_kv(payload, "FROM")
                        ms = envelope_kv(payload, "MS")
                        if nid and ms:
                            send_pong(sock, nid, ms, state)
                else:
                    #--- THE FORWARD. Two frames, byte for byte. No parsing of
                    #--- frame 1 beyond reading T= for the log, and nothing
                    #--- rebuilt: SEQ, SSID and TS are whatever the sender sent.
                    sock.send_multipart([topic, payload])

                    stats.forwarded += 1
                    ts = topic.decode("latin-1", "replace")
                    t = envelope_type(payload)
                    stats.by_topic[ts] += 1
                    stats.by_type[t] += 1

                    #--- events are rare and worth seeing by default; SNAP and
                    #--- HBT fire continuously and are what the stats line is for
                    if args.verbose or t in ("OPEN", "CLOSE"):
                        print("[hub] fwd   %-14s T=%-5s %s"
                              % (ts, t, envelope_kv(payload, "SYM")))

        now = time.time()
        if args.stats_every > 0 and now - last_stats >= args.stats_every:
            last_stats = now
            print_stats(stats, args.verbose)
            stats.reset_window()

        if args.duration and now - started >= args.duration:
            print("[hub] duration reached, exiting")
            break

    print()
    print("[hub] final stats")
    print_stats(stats, args.verbose)
    sock.close(linger=0)
    ctx.term()
    return 0


def describe_sub(prefix):
    if prefix.startswith("@"):
        return "control for %s" % prefix[1:]
    return "data from sender %s" % prefix


def control_note(payload, t):
    """A short human note for a control message - Phase 1 only logs these."""
    if t == "REG":
        return "role=%s acc=%s" % (envelope_kv(payload, "ROLE"), envelope_kv(payload, "ACC"))
    if t == "ACK":
        return "id=%s ok=%s" % (envelope_kv(payload, "ID"), envelope_kv(payload, "OK"))
    if t == "PING":
        return "probe from %s - answering" % envelope_kv(payload, "FROM")
    return ""


def print_stats(stats, verbose):
    w = stats.window()
    print("[hub] --- last %.0fs ---" % w)
    print("[hub]   forwarded %d   control %d   dropped %d"
          % (stats.forwarded, stats.control, stats.dropped))

    if stats.by_topic:
        parts = ["%s:%d" % (k, v) for k, v in stats.by_topic.most_common(8)]
        print("[hub]   by topic  " + "  ".join(parts))
    if stats.by_type:
        parts = ["%s:%d" % (k, v) for k, v in stats.by_type.most_common(8)]
        print("[hub]   by type   " + "  ".join(parts))

    subs = sorted(stats.subs.keys())
    print("[hub]   subscribers %d %s" % (len(subs), subs if subs else ""))

    #--- the loop detector. The intended design cannot make a data topic echo,
    #--- so this can only fire on a bug - and an infinite forward loop is
    #--- otherwise invisible until the network bill arrives.
    hot = [(k, v / w) for k, v in stats.by_topic.items() if v / w > LOOP_WARN_PER_SEC]
    for k, rate in hot:
        print("[hub]   WARNING topic %s is doing %.0f msg/s - that is not traffic,"
              " it looks like a forwarding LOOP" % (k, rate))

    if not verbose and stats.forwarded and not stats.by_topic:
        print("[hub]   (no topics seen this window)")


if __name__ == "__main__":
    sys.exit(main())
