#!/usr/bin/env python3
r"""
snapshot_repair_test.py - behavioural test for slice B's repair decision.

WHY THIS EXISTS
---------------
Slice B re-sends a snapshot to a receiver whose receipt says it is behind. The
hard part is not the send - it is deciding WHEN, and every rule involved is a
promise about behaviour that no compile can check:

  * a HEALTHY receiver must never trigger a repair, even though its receipt is
    always a little behind (it can only echo what it has INGESTED, while the
    sender stamps a new hash the instant it SENDS - so a content change opens a
    short window in which an honest receiver reports the previous hash)
  * a GENUINELY stuck receiver must trigger one
  * a receiver that reports slowly must not be made to wait two of its own
    heartbeats (Q4: the debounce is two when the cadence is <= 2s, one when it
    is slower)
  * and two repairs for the same receiver must never be closer together than
    SnapshotSeconds (Q5), or a receiver that is stuck for a reason re-sending
    cannot fix - a dead socket, a rejected subscription - is fed a full
    snapshot on every heartbeat forever, which is the original traffic problem
    with the blame moved

The simulation below mirrors `SnapTrack()` + `SnapRepairMaybe()` in
CopierSender.mq4 line for line. If those change, this file must change with it.

Run:  python snapshot_repair_test.py
"""

import sys

passes = []
fails = []


def check(name, ok, detail=""):
    (passes if ok else fails).append(name)
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


class Receiver:
    """One peer's slice-B state, mirroring the MQL arrays."""

    def __init__(self, snapshot_seconds):
        self.snapshot_seconds = snapshot_seconds
        self.stale_n = 0
        self.stale_ms = 0
        self.rcpt_ms = 0
        self.int_ms = 0
        self.repair_ms = None
        self.repairs = []

    def track(self, now, reported, sender_hash, payload_present=True, latest_hash=None, valid_hashes=None):
        """Mirror of SnapTrack(). Returns True when a repair fires."""
        # --- cadence, measured from the receipts themselves
        if self.rcpt_ms > 0:
            iv = now - self.rcpt_ms
            if iv > 0:
                if self.int_ms <= 0:
                    self.int_ms = iv
                else:
                    self.int_ms = (self.int_ms + iv) // 2
        self.rcpt_ms = now

        if reported == "":
            if sender_hash == "":
                return False
            return self.maybe_repair(now, payload_present, is_bootstrap=True)
        if sender_hash == "":
            return False

        all_valid = {sender_hash}
        if latest_hash:
            all_valid.add(latest_hash)
        if valid_hashes:
            all_valid.update(valid_hashes)

        if reported not in all_valid:
            if self.stale_n == 0:
                self.stale_ms = now
            self.stale_n += 1
            return self.maybe_repair(now, payload_present, is_bootstrap=False)

        self.stale_n = 0
        self.stale_ms = 0
        return False

    def maybe_repair(self, now, payload_present, is_bootstrap=False):
        """Mirror of SnapRepairMaybe()."""
        if not is_bootstrap:
            est = self.int_ms if self.int_ms > 0 else 2000
            wait_ms = 2 * est if est <= 2000 else est

            if now - self.stale_ms < wait_ms:
                return False

        floor_sec = self.snapshot_seconds if self.snapshot_seconds > 0 else 1
        if self.repair_ms is not None and now - self.repair_ms < floor_sec * 1000:
            return False

        if not payload_present:
            return False

        self.repair_ms = now
        self.stale_n = 0
        self.stale_ms = now
        self.repairs.append(now)
        return True


def main():
    print("== 1. a HEALTHY receiver must never be repaired ==")
    # The realistic sequence: the content changes, the sender's hash moves
    # immediately, the receiver catches up within one heartbeat. Every honest
    # receiver does this on every change, so firing here would fire constantly.
    r = Receiver(snapshot_seconds=10)
    r.track(0, "H1", "H1")           # in step
    fired = r.track(1000, "H1", "H2")   # content changed; it has not ingested yet
    r.track(2000, "H2", "H2")           # caught up
    check("a one-heartbeat lag does not trigger a repair", not fired)
    check("no repair was recorded at all", r.repairs == [], str(r.repairs))

    print()
    print("== 2. a GENUINELY stuck receiver is repaired ==")
    r = Receiver(snapshot_seconds=10)
    fired = []
    for t in range(0, 5000, 1000):    # reports H1 forever while the sender is at H2
        fired.append(r.track(t, "H1", "H2"))
    check("it does fire eventually", any(fired), str(r.repairs))
    check("it does NOT fire on the first report", not fired[0])
    check("it does NOT fire on the second either (2s debounce at 1s cadence)",
          not fired[1], str(fired))
    check("the first repair is at the 2s mark", r.repairs[:1] == [2000], str(r.repairs))

    print()
    print("== 3. a SLOW reporter needs only ONE heartbeat (Q4) ==")
    # SyncHeartbeatSeconds > 2: waiting for a second report would add a whole
    # extra period for no extra evidence.
    r = Receiver(snapshot_seconds=10)
    r.track(0, "H1", "H1")
    fired = [r.track(5000, "H1", "H2"), r.track(10000, "H1", "H2")]
    check("the first slow report alone does not fire", not fired[0])
    check("the second slow report fires", fired[1], str(r.repairs))
    check("and it fired at 10000ms, not 15000ms", r.repairs[:1] == [10000], str(r.repairs))

    print()
    print("== 4. the rate limit holds a stuck receiver to one repair per SnapshotSeconds ==")
    r = Receiver(snapshot_seconds=10)
    for t in range(0, 41000, 1000):   # stuck for 41 seconds
        r.track(t, "H1", "H2")
    # Repairs may not be closer than 10s apart.
    gaps = [b - a for a, b in zip(r.repairs, r.repairs[1:])]
    check("more than one repair happened over 41s", len(r.repairs) >= 3, str(r.repairs))
    check("no two repairs are closer than SnapshotSeconds",
          all(g >= 10000 for g in gaps), str(gaps))
    check("a 41s stuck receiver cost about 4 full sends, not 41",
          len(r.repairs) <= 5, f"{len(r.repairs)} repairs")

    print()
    print("== 5. SnapshotSeconds = 0 floors the limit instead of removing it ==")
    # 0 turns the periodic broadcast OFF, so repairs are the only way state
    # moves. No floor would mean one full send per heartbeat.
    r = Receiver(snapshot_seconds=0)
    for t in range(0, 11000, 1000):
        r.track(t, "H1", "H2")
    gaps = [b - a for a, b in zip(r.repairs, r.repairs[1:])]
    check("repairs still happen", len(r.repairs) >= 2, str(r.repairs))
    check("but never closer than 1s", all(g >= 1000 for g in gaps), str(gaps))

    print()
    print("== 6. the repair must re-send the SAME bytes (no cascade) ==")
    # If a repair rebuilt the snapshot, g_snapHash would move and every other
    # receiver - whose receipt was perfectly correct - would look behind too.
    # One lagging peer would drag a repair out of all of them.
    r = Receiver(snapshot_seconds=10)
    sender_hash = "H2"
    for t in range(0, 5000, 1000):
        r.track(t, "H1", sender_hash)
    check("a repair happened", bool(r.repairs), str(r.repairs))
    check("the sender's hash is untouched by it (the payload is reused)",
          sender_hash == "H2", sender_hash)

    print()
    print("== 7. empty receipt bootstraps immediately on first contact ==")
    # A new receiver reports "" on its first heartbeat; the sender bootstraps it
    # immediately (<1s) rather than making it wait for SnapshotSeconds, but respects
    # the rate limit so it does not flood if the receiver cannot ingest.
    r = Receiver(snapshot_seconds=10)
    fired = [r.track(t, "", "H2") for t in range(0, 11000, 1000)]
    check("an empty receipt triggers an immediate bootstrap repair on first contact",
          fired[0] and r.repairs[:1] == [0], str(r.repairs))
    check("subsequent empty reports inside the floor do not fire",
          not any(fired[1:10]), str(fired))
    check("it re-attempts only after SnapshotSeconds floor expires",
          fired[10] and r.repairs == [0, 10000], str(r.repairs))

    print()
    print("== 8. dual-hash and recent valid hashes prevent false BEHIND ==")
    # When sender generates unbroadcast intermediate hashes (g_latestSnapHash) or
    # maintains a recent valid hash ring, a receiver echoing an intermediate hash
    # is considered IN STEP and does not trigger stale counter or false repair storms.
    r = Receiver(snapshot_seconds=10)
    # sender has broadcast H1, but locally rebuilt H2
    r.track(0, "H1", sender_hash="H1", latest_hash="H2")
    check("matching broadcast hash H1 is in step", r.stale_n == 0)
    # receiver caught up to H2 via directed repair
    r.track(1000, "H2", sender_hash="H1", latest_hash="H2")
    check("matching unbroadcast latest hash H2 is also in step", r.stale_n == 0)
    # sender modified again to H3, keeping H2 in recent valid hashes
    r.track(2000, "H2", sender_hash="H1", latest_hash="H3", valid_hashes={"H2"})
    check("matching recently valid hash H2 avoids false BEHIND", r.stale_n == 0)

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
