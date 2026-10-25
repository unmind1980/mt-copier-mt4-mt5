#!/usr/bin/env python3
r"""
modify_event_test.py - the SL/TP event path (MODIFY).

WHY THIS EXISTS
---------------
Stops used to reach the receiver only inside a snapshot, so their latency was
`SnapshotSeconds`. That was written down as acceptable at 2 s ("the receiver
follows within ~2 s", PILOT-MT4.md) and stopped being acceptable when
SnapshotSeconds was raised to cut bandwidth - a stop's whole purpose is to act
AT a level, and a stop that arrives late arrives wrong.

MODIFY makes the common case fast while the snapshot stays the convergence
source of truth. Three things about that arrangement are easy to get wrong and
invisible when you do:

  1. THE PAYLOAD. It carries only what the receiver cannot already know: the
     sender's stops and the sender's ENTRY (stops are mirrored as a distance
     from the entry, so both are needed to re-anchor on the receiver's fill).

  2. THE OVERRIDE. Convergence re-derives the target from the snapshot on every
     pass, so an event applied straight to the position would be reverted by the
     very next pass. The event has to sit BESIDE the snapshot and win until the
     snapshot agrees - not be written into it.

  3. THE THROTTLE. A trailing stop moves on nearly every scan, so the floor is
     what keeps one position from becoming ten broker OrderModify calls a
     second. It must DEFER, not DROP: dropping would leave the mirror on a stale
     stop until the next snapshot, which is the delay this path exists to
     remove.

Run:  python modify_event_test.py
"""

import sys

passes = []
fails = []


def check(name, ok, detail=""):
    (passes if ok else fails).append(name)
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   [{detail}]" if detail else ""))


CP_SEP_KV = ";"
CP_DIGITS_PX = 8


def fmt(v):
    return f"{v:.{CP_DIGITS_PX}f}"


def encode_modify(uid, opn, sl, tp):
    """Mirror of CopierPayloadModify()."""
    return (f"UID={uid}{CP_SEP_KV}OPN={fmt(opn)}"
            f"{CP_SEP_KV}SL={fmt(sl)}{CP_SEP_KV}TP={fmt(tp)}")


def parse_modify(payload):
    """Mirror of CopierPayloadModifyParse(). Returns None when refused."""
    kv = {}
    for item in payload.split(CP_SEP_KV):
        if "=" in item:
            k, v = item.split("=", 1)
            kv[k] = v
    if not kv.get("UID"):
        return None
    if "OPN" not in kv or "SL" not in kv or "TP" not in kv:
        return None
    try:
        opn = float(kv["OPN"])
        sl = float(kv["SL"])
        tp = float(kv["TP"])
        if opn < 0.0 or sl < 0.0 or tp < 0.0:
            return None
        return {
            "uid": kv["UID"],
            "opn": opn,
            "sl": sl,
            "tp": tp,
        }
    except ValueError:
        return None


class Stops:
    """The receiver's per-uid stop state, mirroring the MQL arrays."""

    def __init__(self, throttle_s=2):
        self.throttle_s = throttle_s
        self.uid = []
        self.has_ov = []
        self.ov_sl = []
        self.ov_tp = []
        self.ov_opn = []
        self.last_ms = []
        self.pushes = []

    def _idx(self, uid, create):
        if uid in self.uid:
            return self.uid.index(uid)
        if not create:
            return -1
        self.uid.append(uid)
        self.has_ov.append(False)
        self.ov_sl.append(0.0)
        self.ov_tp.append(0.0)
        self.ov_opn.append(0.0)
        self.last_ms.append(-1)
        return len(self.uid) - 1

    def on_event(self, uid, opn, sl, tp):
        """Mirror of HandleModifyEvent()."""
        i = self._idx(uid, True)
        self.has_ov[i] = True
        self.ov_sl[i] = sl
        self.ov_tp[i] = tp
        self.ov_opn[i] = opn

    def converge(self, now, uid, snap_sl, snap_tp, snap_opn, local_entry, local_sl, local_tp):
        """Mirror of QueueModifyIfNeeded(). True when a modify is pushed."""
        d_sl, d_tp, d_opn = snap_sl, snap_tp, snap_opn
        i = self._idx(uid, False)
        if i >= 0 and self.has_ov[i]:
            if abs(snap_sl - self.ov_sl[i]) < 1e-7 and abs(snap_tp - self.ov_tp[i]) < 1e-7:
                self.has_ov[i] = False          # the snapshot caught up
            else:
                d_sl, d_tp, d_opn = self.ov_sl[i], self.ov_tp[i], self.ov_opn[i]

        # the sender's stops as a distance, re-anchored on OUR entry
        want_sl = (d_sl + (local_entry - d_opn)) if d_sl > 0 else 0.0
        want_tp = (d_tp + (local_entry - d_opn)) if d_tp > 0 else 0.0

        if abs(local_sl - want_sl) < 1e-7 and abs(local_tp - want_tp) < 1e-7:
            return False

        if i < 0:
            i = self._idx(uid, True)
        if self.throttle_s > 0 and self.last_ms[i] >= 0 \
           and now - self.last_ms[i] < self.throttle_s * 1000:
            return False                        # deferred, NOT dropped
        self.last_ms[i] = now
        self.pushes.append((now, round(want_sl, 5), round(want_tp, 5)))
        return True


def main():
    print("== 1. the MODIFY payload ==")
    p = encode_modify("ABCD1234", 1.10000000, 1.09500000, 1.11000000)
    check("carries uid, entry, sl and tp",
          p == "UID=ABCD1234;OPN=1.10000000;SL=1.09500000;TP=1.11000000", p)
    check("prices are fixed 8-decimal, so the width never varies",
          encode_modify("X", 1.1, 0.0, 2.0) == "UID=X;OPN=1.10000000;SL=0.00000000;TP=2.00000000")
    r = parse_modify(p)
    check("round-trips", r == {"uid": "ABCD1234", "opn": 1.1, "sl": 1.095, "tp": 1.11}, str(r))
    check("a payload with no uid is refused", parse_modify("OPN=1.0;SL=1.0") is None)
    check("an empty uid is refused too", parse_modify("UID=;SL=1.0") is None)
    check("a cleared stop is representable (sl=0 means 'no stop')",
          parse_modify(encode_modify("X", 1.1, 0.0, 1.2))["sl"] == 0.0)

    print()
    print("== 2. the event wins over a snapshot that has not caught up ==")
    # The snapshot in flight was built BEFORE the change, so it still carries
    # the old stop. The event must win until the snapshot agrees.
    s = Stops()
    s.on_event("U1", 1.10000, 1.09500, 0.0)         # sender moved SL to 1.095
    pushed = s.converge(1000, "U1",
                        snap_sl=1.09000, snap_tp=0.0, snap_opn=1.10000,   # stale snapshot
                        local_entry=1.10050, local_sl=1.09050, local_tp=0.0)
    check("the event's value is used, not the stale snapshot's", pushed)
    check("and the pushed stop is the EVENT's distance, re-anchored",
          s.pushes and s.pushes[0][1] == 1.09550, str(s.pushes))
    check("the override is still held (the snapshot has not agreed yet)",
          s.has_ov[0] is True)

    print()
    print("== 3. the override clears once the snapshot agrees ==")
    s.converge(9000, "U1",
               snap_sl=1.09500, snap_tp=0.0, snap_opn=1.10000,   # snapshot caught up
               local_entry=1.10050, local_sl=1.09550, local_tp=0.0)
    check("override dropped", s.has_ov[0] is False)
    check("no further modify is needed", len(s.pushes) == 1, str(s.pushes))

    print()
    print("== 4. the throttle DEFERS rather than drops ==")
    # A trailing stop moving faster than the throttle window. Every pass sees a
    # difference; only the ones outside the window may reach the broker.
    s = Stops(throttle_s=2)
    t = 0
    for i in range(10):                 # 10 passes, 200 ms apart, 2 s total
        t += 200
        s.on_event("U2", 1.10000, 1.09500 + i * 0.00010, 0.0)
        s.converge(t, "U2",
                   snap_sl=1.09000, snap_tp=0.0, snap_opn=1.10000,
                   local_entry=1.10000, local_sl=s.pushes[-1][1] if s.pushes else 1.09000,
                   local_tp=0.0)
    check("far fewer pushes than passes", len(s.pushes) < 10, f"{len(s.pushes)} pushes / 10 passes")
    check("but at least one", len(s.pushes) >= 1, str(s.pushes))

    # The value must not be LOST: once the window opens, the newest value goes.
    s2 = Stops(throttle_s=2)
    s2.on_event("U3", 1.10000, 1.09500, 0.0)
    s2.converge(0, "U3", 1.09000, 0.0, 1.10000, 1.10000, 1.09000, 0.0)
    check("first push happens immediately", len(s2.pushes) == 1, str(s2.pushes))
    # the stop moves again inside the window
    s2.on_event("U3", 1.10000, 1.09900, 0.0)
    fired_inside = s2.converge(500, "U3", 1.09000, 0.0, 1.10000, 1.10000, 1.09500, 0.0)
    check("a change inside the window is held back", not fired_inside)
    fired_after = s2.converge(2500, "U3", 1.09000, 0.0, 1.10000, 1.10000, 1.09500, 0.0)
    check("and is applied as soon as the window opens", fired_after)
    check("with the NEWEST value, not the one that was skipped",
          s2.pushes[-1][1] == 1.09900, str(s2.pushes))

    print()
    print("== 5. throttle 0 means no throttle ==")
    s = Stops(throttle_s=0)
    for t in (0, 100, 200):
        s.on_event("U4", 1.10000, 1.09500 + t * 0.00001, 0.0)
        s.converge(t, "U4", 1.09000, 0.0, 1.10000, 1.10000, 1.09000, 0.0)
    check("every pass can push when the floor is off", len(s.pushes) == 3, str(s.pushes))

    print()
    print("== 6. an unchanged stop pushes nothing ==")
    s = Stops()
    fired = s.converge(0, "U5", 1.09500, 0.0, 1.10000, 1.10000, 1.09500, 0.0)
    check("no difference -> no modify", not fired)

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
