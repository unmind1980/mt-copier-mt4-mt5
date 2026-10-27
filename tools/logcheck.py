#!/usr/bin/env python3
"""
logcheck.py - turn the copier's own logs into a verdict.

The pilot's destructive checks (doc/PILOT.md 3.2-3.5) are the ones that
catch real money bugs - a restart that re-opens everything, a disconnect
that silently drops a position, an event lost in a reconnect. Eyeballing
two log files for those is unreliable: the failure mode is usually
*absence* of a line, which nobody notices.

ANALYSIS IS PER TERMINAL, NOT PER UID
-------------------------------------
Each terminal's logs are analysed on their own. This is not a detail.

A single sender position is legitimately mirrored onto *every* receiver
that subscribes to it, so the same UID appears once per receiver. Merging
all logs into one identity map therefore reports a correct 1-to-N fan-out
as "this UID was opened more than once" - a false alarm, and a checker
that cries wolf gets ignored. It also invents "closes with no matching
open" whenever the matching open sits in a log generation that has since
rotated away, or in a different terminal.

So: one identity map per terminal, and the only cross-terminal check that
is valid without knowing the subscription topology is *receiver-only*
(a position a receiver holds that no sender has open - that one is a real
fault). Sender-only is normal: not every receiver subscribes to every
sender, and a snapshot may not have arrived yet.

Usage:
    logcheck.py <log file> [<log file> ...]
    logcheck.py --json <log file> ...
"""

import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

# 2026.10.05 14:07:33 I exec open sender01 ABCD1234 senderTkt=9918271 EURUSD lots=0.50
LINE = re.compile(r"^(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+([EWID])\s+(.*)$")

RE_EXEC_OPEN = re.compile(
    r"^exec (?:open|place-pending) (\S+) ([0-9A-Z]{8})(?: senderTkt=(-?\d+))? (\S+)"
    r"(?: ptype=\d+ trigger=[0-9.]+(?: stoplimit=[0-9.]+)?(?: exp=\d+)?(?: sl=[0-9.]+)?(?: tp=[0-9.]+)?)? lots=([0-9.]+)$")
RE_EXEC_CLOSE = re.compile(
    r"^exec (?:close|partial-close|remove-duplicate) (\S+) ([0-9A-Z]{8})(?: senderTkt=(-?\d+))? (\S+) lots=([0-9.]+)$")
# N57-14: a position that Pass 1 could not close is retried 30ms later by the
# two-pass sweeper, which logs its own line. Without this pattern every sweeper
# success looked like "never closed" to this checker and produced a false
# "position(s) still open at the end of this terminal's log".
RE_SWEEPER_CLOSE = re.compile(
    r"^Two-Pass Sweeper: successfully closed straggler ticket (-?\d+) uid ([0-9A-Z]{8})$")
RE_SEND_OPEN = re.compile(
    r"^open ([0-9A-Z]{8}) tkt=(-?\d+) (\S+) side=(-?\d+)(?: (?:market|place-pending \S+ \S+))? lots=([0-9.]+)(?: sl=\S+ tp=\S+)?$")
RE_SEND_CLOSE = re.compile(r"^close ([0-9A-Z]{8}) tkt=(-?\d+) (\S+)$")

RE_RESYNC = re.compile(r"^sender (\S+) new session (\S+) -> resync$")
RE_SILENT = re.compile(r"^sender (\S+) silent for >(\d+)s")
RE_BACK = re.compile(r"^sender (\S+) is back$")
RE_TRADE_FAIL = re.compile(r"^trade failed sender=(\S+) uid=([0-9A-Z]{8})")
RE_LOT_REJECT = re.compile(r"^lot sizing rejected ([0-9A-Z]{8}) (\S+)")
RE_SYM_SKIP = re.compile(r"symbol (\S+) -> (\S+) not offered by this broker")
RE_UNKNOWN_SYM = re.compile(r"^unknown symbol (\S+), dropping ([0-9A-Z]{8})$")
RE_LISTEN = re.compile(r"^sender (\S+) listening (?:events=(\d+) snap=(\d+)|on port \d+.*?) ssid=(\S+)")
RE_RECV_UP = re.compile(r"^receiver up, (\d+) sender\(s\)")
RE_RESTORED = re.compile(r"^restored (\d+) position\(s\) from state$")
RE_NOCONF = re.compile(r"^cannot read (\S+) from MQL")

# Lines logged at ERROR or WARNING level that are EXPECTED - the pilot's own
# markers, a condition the operator has to fix, or a setup mistake whose
# consequence is already obvious from the absence of other lines. Counting
# them as failures makes the verdict cry wolf, and a checker that cries
# wolf gets ignored.
BENIGN_ERROR = (RE_SILENT,)
BENIGN_WARN = (RE_SYM_SKIP, RE_LOT_REJECT, RE_UNKNOWN_SYM)
SETUP_WARN = (RE_NOCONF,)
RE_XN = re.compile(r" \[x\d+\]$")

# The sender's state file is AUTHORITATIVE about what it currently holds,
# and it survives log rotation. The log-derived open set does not: a
# rotation or a restart gap silently removes opens, which is how a real
# divergence became indistinguishable from missing history during the first
# MT4 pilot. Whenever a state file is available, use it instead.
RE_ST_POS = re.compile(r"^POS:([0-9A-Z]{8}),(-?\d+),(\S+),(-?\d+),([0-9.]+),")


def is_benign(patterns, msg):
    return any(p.search(msg) for p in patterns)


#=====================================================================
# Grouping: one analysis per terminal, not one per UID
#=====================================================================
def source_key(path):
    p = path.replace("\\", "/")
    if "/Files/" in p:
        return p.split("/Files/")[0]
    return p.rsplit("/", 1)[0]


def source_label(key):
    p = key.replace("\\", "/")
    if "/MetaQuotes/Terminal/" in p:
        return p.split("/MetaQuotes/Terminal/", 1)[1]
    return p


def side_of(path):
    name = path.replace("\\", "/").rsplit("/", 1)[-1]
    if name.startswith("copier_sender"):
        return "sender"
    if name.startswith("copier_receiver"):
        return "receiver"
    return "other"


class Event:
    __slots__ = ("ts", "lvl", "msg", "src")

    def __init__(self, ts, lvl, msg, src):
        self.ts, self.lvl, self.msg, self.src = ts, lvl, msg, src


def read_state(paths):
    """Parse sender state files -> {uid: {...}}, the authoritative open set.

    A torn file (no END marker) is ignored, matching CopierStateFile::Load.
    """
    held = OrderedDict()
    files = []
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
        except OSError:
            continue
        lines = raw.splitlines()
        if not any(l.strip().startswith("END:") for l in lines):
            continue                      # torn / truncated: do not trust
        files.append(p)
        for line in lines:
            m = RE_ST_POS.match(line.strip())
            if m:
                held[m.group(1)] = {"tkt": m.group(2), "sym": m.group(3),
                                    "side": m.group(4), "lots": m.group(5),
                                    "file": p}
    return held, files


def log_gen_order(path):
    # Older generations (.log.2, .log.1) must be read BEFORE the active log (.log)
    # so that within the same second, stable sort preserves true chronological order.
    name = os.path.basename(path)
    if ".log." in name:
        try:
            base, ext = name.rsplit(".log.", 1)
            return (base + ".log", -int(ext))
        except ValueError:
            return (name, 0)
    elif name.endswith(".log"):
        return (name, 999999)
    return (name, 0)


def read_logs(paths):
    events = []
    per_file = OrderedDict()
    for p in sorted(paths, key=log_gen_order):
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
        except OSError as exc:
            print(f"  !! cannot read {p}: {exc}")
            continue
        n = 0
        for line in raw.splitlines():
            m = LINE.match(line.strip())
            if not m:
                continue
            events.append(Event(m.group(1), m.group(2), m.group(3), p))
            n += 1
        per_file[p] = n
    # generation files wrap, so file order is not chronological - sort by
    # the timestamp the copier itself wrote
    events.sort(key=lambda e: e.ts)
    return events, per_file


#=====================================================================
# Per-terminal analysis
#=====================================================================
def new_result():
    return {
        "uid": OrderedDict(),
        "errors": [],
        "warnings": [],
        "setup": [],
        "resync": [],
        "silent": [],
        "back": [],
        "trade_fail": [],
        "lot_reject": [],
        "sym_skip": [],
        "unknown_sym": [],
        "listening": [],
        "recv_up": [],
        "restored": [],
        "other_notable": [],
        "msg_count": defaultdict(int),
        "has_sender": False,
        "has_receiver": False,
    }


def analyse(events):
    r = new_result()

    def rec(uid):
        if uid not in r["uid"]:
            r["uid"][uid] = {
                "opens": 0, "closes": 0, "sym": "", "lots": "",
                "senderTkt": "", "state": "unknown",
                "first": "", "last": "", "src": set(),
            }
        return r["uid"][uid]

    for e in events:
        m, src = e.msg, e.src
        side = side_of(src)
        if side == "sender":
            r["has_sender"] = True
        elif side == "receiver":
            r["has_receiver"] = True
        r["msg_count"][RE_XN.sub("", m)] += 1

        if e.lvl == "E":
            if not is_benign(BENIGN_ERROR, m) and not is_benign(SETUP_WARN, m):
                r["errors"].append(e)
        elif e.lvl == "W":
            if not is_benign(BENIGN_WARN, m):
                r["warnings"].append(e)

        if is_benign(SETUP_WARN, m):
            r["setup"].append((e.ts, m))

        mo = RE_EXEC_OPEN.match(m)
        if mo:
            u = rec(mo.group(2))
            u["opens"] += 1
            u["sym"] = mo.group(4)
            u["lots"] = mo.group(5)
            if mo.group(3):
                u["senderTkt"] = mo.group(3)
            u["state"] = "open"
            u["first"] = u["first"] or e.ts
            u["last"] = e.ts
            u["src"].add("receiver")
            continue

        mo = RE_EXEC_CLOSE.match(m)
        if mo:
            u = rec(mo.group(2))
            u["closes"] += 1
            if mo.group(3):
                u["senderTkt"] = u["senderTkt"] or mo.group(3)
            u["sym"] = u["sym"] or mo.group(4)
            u["lots"] = u["lots"] or mo.group(5)
            u["state"] = "closed"
            u["last"] = e.ts
            u["src"].add("receiver")
            continue

        mo = RE_SWEEPER_CLOSE.match(m)
        if mo:
            u = rec(mo.group(2))
            u["closes"] += 1
            u["senderTkt"] = u["senderTkt"] or mo.group(1)
            u["state"] = "closed"
            u["last"] = e.ts
            u["src"].add("receiver")
            continue

        mo = RE_SEND_OPEN.match(m)
        if mo:
            u = rec(mo.group(1))
            u["opens"] += 1
            u["sym"] = mo.group(3)
            u["lots"] = mo.group(5)
            u["senderTkt"] = u["senderTkt"] or mo.group(2)
            u["state"] = "open"
            u["first"] = u["first"] or e.ts
            u["last"] = e.ts
            u["src"].add("sender")
            continue

        mo = RE_SEND_CLOSE.match(m)
        if mo:
            u = rec(mo.group(1))
            u["closes"] += 1
            u["sym"] = u["sym"] or mo.group(3)
            u["senderTkt"] = u["senderTkt"] or mo.group(2)
            u["state"] = "closed"
            u["last"] = e.ts
            u["src"].add("sender")
            continue

        mo = RE_RESYNC.match(m)
        if mo:
            r["resync"].append((e.ts, mo.group(1), mo.group(2)))
            continue

        mo = RE_SILENT.match(m)
        if mo:
            r["silent"].append((e.ts, mo.group(1), mo.group(2)))
            continue

        mo = RE_BACK.match(m)
        if mo:
            r["back"].append((e.ts, mo.group(1)))
            continue

        mo = RE_TRADE_FAIL.match(m)
        if mo:
            r["trade_fail"].append((e.ts, mo.group(1), mo.group(2), m))
            continue

        mo = RE_LOT_REJECT.match(m)
        if mo:
            r["lot_reject"].append((e.ts, mo.group(1), mo.group(2)))
            continue

        if RE_SYM_SKIP.search(m):
            r["sym_skip"].append((e.ts, m))
            continue

        mo = RE_UNKNOWN_SYM.match(m)
        if mo:
            r["unknown_sym"].append((e.ts, mo.group(1), mo.group(2)))
            continue

        mo = RE_LISTEN.match(m)
        if mo:
            r["listening"].append((e.ts, mo.group(1), mo.group(4)))
            continue

        mo = RE_RECV_UP.match(m)
        if mo:
            r["recv_up"].append((e.ts, mo.group(1)))
            continue

        mo = RE_RESTORED.match(m)
        if mo:
            r["restored"].append((e.ts, mo.group(1)))
            continue

        if ("queue full" in m or "state save failed" in m or "send failed" in m
                or "bad message" in m or "cannot" in m or "volume changed" in m):
            r["other_notable"].append((e.ts, m))

    return r


#=====================================================================
# Verdicts for one terminal
#=====================================================================
def verdicts(r, sender_open_union=None, sender_source=None, receiver_held=None):
    """level: ok | warn | fail | info"""
    out = []

    dupes = [(u, d) for u, d in r["uid"].items() if d["opens"] > 1]
    if dupes:
        out.append(("warn",
                    f"{len(dupes)} UID(s) opened more than once - check these are "
                    f"legitimate recoveries, not duplicate positions: "
                    + ", ".join(u for u, _ in dupes[:8])))
    else:
        out.append(("ok", "no UID was opened twice (no duplicate positions)"))

    #--- NOTE these two checks read the copier's own log, which by design
    #--- records only what the COPIER did. A close performed by hand, by
    #--- another EA, or by the broker leaves no line - so a "missing" open
    #--- or close here is far more often an artefact than a fault. On the
    #--- first MT4 pilot a 6-line gap between the copier's log and the
    #--- terminal Journal looked exactly like orphaned positions and was
    #--- entirely manual closes. Reconcile against the terminal Journal
    #--- (`logs/YYYYMMDD.log`, "close order #") before acting on these.
    orphans = [(u, d) for u, d in r["uid"].items()
               if d["closes"] > 0 and d["opens"] == 0]
    if orphans:
        out.append(("warn",
                    f"{len(orphans)} close(s) with no matching open in the "
                    f"copier's log. Usually rotated-away history OR a close "
                    f"the copier did not initiate (manual / another EA / "
                    f"broker) - reconcile with the terminal Journal before "
                    f"treating this as a fault: "
                    + ", ".join(u for u, _ in orphans[:8])))
    else:
        out.append(("ok", "no orphan closes"))

    over = [(u, d) for u, d in r["uid"].items() if d["closes"] > d["opens"]]
    if over:
        out.append(("warn",
                    f"{len(over)} UID(s) closed more times than opened here "
                    f"(same rotated-history caveat): "
                    + ", ".join(u for u, _ in over[:8])))
    else:
        out.append(("ok", "no double closes"))

    still = [(u, d) for u, d in r["uid"].items() if d["state"] == "open"]
    if still:
        out.append(("info",
                    f"{len(still)} position(s) still open at the end of this "
                    f"terminal's log: " + ", ".join(u for u, _ in still[:8])))
    else:
        out.append(("ok", "every position seen was also closed"))

    if r["errors"]:
        out.append(("fail", f"{len(r['errors'])} unexpected ERROR line(s)"))
    else:
        out.append(("ok", "no unexpected ERROR lines"))

    if r["warnings"]:
        out.append(("warn", f"{len(r['warnings'])} unexpected WARNING line(s)"))
    else:
        out.append(("ok", "no unexpected WARNING lines"))

    if r["setup"]:
        out.append(("warn",
                    f"{len(r['setup'])} setup line(s) - the EA could not read "
                    f"its config at least once (harmless if it later started)"))

    if r["trade_fail"]:
        out.append(("fail", f"{len(r['trade_fail'])} failed trade attempt(s)"))
    else:
        out.append(("ok", "no failed trade attempts"))

    if r["lot_reject"]:
        out.append(("warn",
                    f"{len(r['lot_reject'])} order(s) rejected by lot sizing "
                    f"(normal on a small account)"))
    else:
        out.append(("ok", "no lot-sizing rejections"))

    if r["sym_skip"] or r["unknown_sym"]:
        out.append(("warn",
                    f"{len(r['sym_skip']) + len(r['unknown_sym'])} symbol(s) "
                    f"skipped as unavailable at this broker"))
    else:
        out.append(("ok", "every symbol resolved at the broker"))

    #--- log-volume guard: one repeating message must never drown the file
    if r["msg_count"]:
        top, n = max(r["msg_count"].items(), key=lambda kv: kv[1])
        total = sum(r["msg_count"].values())
        if n > 200:
            out.append(("warn",
                        f"one message accounts for {n} of {total} lines - the "
                        f"log-volume guard is not holding: {top[:90]}"))
        else:
            out.append(("ok",
                        f"no message repeats excessively (worst: {n} of {total} "
                        f"lines)"))

    #--- pilot markers
    if r["has_receiver"]:
        out.append(("info" if r["resync"] else "ok",
                    f"resync events (sender restart, 3.4): {len(r['resync'])}"))
        out.append(("info" if r["silent"] else "ok",
                    f"silence events (disconnect, 3.5): {len(r['silent'])}"))
        out.append(("info" if r["back"] else "ok",
                    f"recovery events (sender came back): {len(r['back'])}"))
        out.append(("info", f"receiver start-ups: {len(r['recv_up'])} "
                            f"(check 3.3 wants >= 2)"))
    if r["has_sender"]:
        out.append(("info", f"sender start-ups: {len(r['listening'])} "
                            f"(checks 3.2 / 3.4 want >= 2)"))

    #--- the ONE cross-terminal check that is valid without knowing the
    #--- subscription topology: a receiver holding something no sender has
    #--- open is a real fault. Sender-only is normal.
    if sender_open_union is not None and r["has_receiver"]:
        #--- Prefer the receiver's own state file. Its log is a diff, and a
        #--- rotated generation drops the closes: five EURUSD positions
        #--- closed in a session whose log had already rolled away were
        #--- reported as "held here that NO sender has open" and sent
        #--- someone looking for positions that did not exist.
        if receiver_held is not None:
            r_open = set(receiver_held)
            r_open_src = "receiver state file (authoritative)"
        else:
            r_open = {u for u, d in r["uid"].items()
                      if d["state"] == "open" and "receiver" in d["src"]}
            r_open_src = "receiver log (rotation can hide a close)"
        extra = r_open - sender_open_union
        if extra:
            #--- Only a hard failure when BOTH sides come from a state file.
            #--- Otherwise the disagreement may be nothing but rotated-away
            #--- history, and a false FAIL costs more than a false WARN.
            both_authoritative = (sender_source.startswith("sender state")
                                  and receiver_held is not None)
            level = "fail" if both_authoritative else "warn"
            out.append((level,
                        f"{len(extra)} position(s) held here that NO sender has "
                        f"open ({r_open_src} vs {sender_source}) - these should "
                        f"have been closed: " + ", ".join(sorted(extra)[:8])))
        else:
            out.append(("ok",
                        f"every position held here is still open on a sender "
                        f"({r_open_src} vs {sender_source})"))

    return out


def render_group(label, r, per_file):
    print()
    print(f"=== {label} ===")
    for p, n in per_file.items():
        print(f"  {side_of(p):<9} {n:>6} lines  {p.rsplit('/', 1)[-1]}")

    if r["uid"]:
        print()
        print(f"  {'UID':<9} {'senderTkt':<11} {'sym':<10} {'lots':<7} "
              f"{'op':<3} {'cl':<3} state")
        for u, d in r["uid"].items():
            print(f"  {u:<9} {(d['senderTkt'] or '-'):<11} {d['sym']:<10} "
                  f"{(d['lots'] or '-'):<7} {d['opens']:<3} {d['closes']:<3} "
                  f"{d['state']}")

    print()
    print("  checks:")
    icon = {"ok": "ok  ", "warn": "WARN", "fail": "FAIL", "info": "--  "}
    for level, text in r["_verdicts"]:
        print(f"    {icon[level]} {text}")

    if r["errors"]:
        print("  ERROR lines:")
        for e in r["errors"][:15]:
            print(f"    {e.ts} {e.msg}")
    if r["warnings"]:
        print("  WARNING lines:")
        for e in r["warnings"][:15]:
            print(f"    {e.ts} {e.msg}")
    if r["resync"]:
        print("  resync:")
        for ts, sid, ssid in r["resync"]:
            print(f"    {ts} sender={sid} session={ssid}")
    if r["silent"]:
        print("  silence:")
        for ts, sid, secs in r["silent"]:
            print(f"    {ts} sender={sid} silent >{secs}s")


def discover():
    """Find every copier log and sender state file on this machine.

    Walks %APPDATA%\\MetaQuotes\\Terminal\\<id>\\MQL4|MQL5\\Files, plus any
    extra roots listed in tools/targets.conf (which is how a PORTABLE
    install, whose data lives next to terminal.exe, is named).

    Exists so a Windows user can run this with no arguments at all - the
    shell wrapper's discovery is not available to someone double-clicking a
    .bat, and asking them to enumerate log paths by hand is not reasonable.
    """
    import glob
    import os

    roots = []

    appdata = os.environ.get("APPDATA") or os.path.join(
        os.path.expanduser("~"), "AppData", "Roaming")
    term_root = os.path.join(appdata, "MetaQuotes", "Terminal")

    #--- targets.conf: one terminal id or absolute data-folder path per line
    conf = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "targets.conf")
    targets = []
    if os.path.isfile(conf):
        with open(conf, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                targets.append(line)

    #--- targets.conf is shared with the bash tooling, which writes
    #--- portable installs in Git-Bash form ("/e/MetaTrader 5"). Windows
    #--- Python does not consider that absolute, so translate it.
    def _win_path(p):
        m = re.match(r"^/([A-Za-z])/(.*)$", p)
        if m:
            return m.group(1).upper() + ":\\" + m.group(2).replace("/", "\\")
        return p

    for t in targets:
        t = _win_path(t)
        if os.path.isabs(t) or ":" in t[:3]:
            #--- a portable install is named by its DATA ROOT (the folder
            #--- holding terminal64.exe), so the platform folder still has
            #--- to be appended. Accept either form.
            subs = [os.path.join(t, p) for p in ("MQL5", "MQL4")
                    if os.path.isdir(os.path.join(t, p))]
            roots += subs if subs else [t]
        else:
            for plat in ("MQL5", "MQL4"):
                roots.append(os.path.join(term_root, t, plat))

    #--- no targets.conf (or nothing usable): every terminal on the machine
    if not roots:
        for plat in ("MQL5", "MQL4"):
            roots += glob.glob(os.path.join(term_root, "*", plat))

    found = []
    for r in roots:
        files = os.path.join(r, "Files")
        if not os.path.isdir(files):
            continue
        found += sorted(glob.glob(os.path.join(files, "copier_*.log")))
        found += sorted(glob.glob(os.path.join(files, "copier_*.log.*")))
        found += sorted(glob.glob(os.path.join(files, "copier_sender_*.st")))
        found += sorted(glob.glob(os.path.join(files, "copier_receiver*.st")))
    return found


def main(argv):
    as_json = "--json" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if "--discover" in argv:
        paths = discover()
        if not paths:
            print("no copier logs found.")
            print("they live in <terminal data folder>\\MQL4|MQL5\\Files\\"
                  "copier_*.log and only appear once the EAs have run with"
                  " LogLevel>=2.")
            return 1
        print(f"discovered {len(paths)} copier file(s)")
    if not paths:
        print(__doc__)
        return 2

    #--- .st files carry authoritative state; everything else is a log.
    #---
    #--- Both kinds parse identically (HDR, POS records, END:n) but they
    #--- answer opposite questions: the SENDER's file says what SHOULD be
    #--- open on the receiving side, the RECEIVER's file says what actually
    #--- IS. Using the receiver's LOG for that second question is what made
    #--- a rotated-away close look like a stranded position.
    st_paths = [p for p in paths if p.endswith(".st")]
    log_paths = [p for p in paths if not p.endswith(".st")]

    def is_receiver_state(p):
        return p.replace("\\", "/").rsplit("/", 1)[-1] == "copier_receiver.st"

    sender_state, st_files = read_state([p for p in st_paths
                                         if not is_receiver_state(p)])
    recv_st = [p for p in st_paths if is_receiver_state(p)]
    receiver_state, recv_st_files = read_state(recv_st)

    #--- what each receiver terminal actually holds, keyed by terminal. A
    #--- state file that parsed but lists nothing means "flat", which is a
    #--- real answer and must not be confused with "no state file".
    receiver_held = {}
    for u, d in receiver_state.items():
        receiver_held.setdefault(source_key(d["file"]), set()).add(u)
    for p in recv_st_files:
        receiver_held.setdefault(source_key(p), set())

    events, per_file = read_logs(log_paths)

    #--- group by terminal
    groups = OrderedDict()
    for p in per_file:
        groups.setdefault(source_key(p), []).append(p)
    by_group = OrderedDict()
    for key in groups:
        by_group[key] = [e for e in events if source_key(e.src) == key]

    results = OrderedDict()
    for key, evs in by_group.items():
        results[key] = analyse(evs)

    #--- The set of positions a receiver must not be holding.
    #---
    #--- Prefer the sender's STATE FILE: it is authoritative and survives
    #--- log rotation. Only fall back to the log-derived union when no state
    #--- file was supplied, and remember that the log-derived version can
    #--- report a divergence that is really just rotated-away history.
    #---
    #--- NOTE the test is on st_files (files that PARSED), not on
    #--- sender_state (the positions they held). A state file that is
    #--- perfectly valid and says "0 positions" - which is the normal state
    #--- after a clean test, when every sender is flat - produced an empty
    #--- dict, and keying off that conflated three different situations:
    #--- no file at all, a torn file, and "everything is flat, all good".
    #--- The last one was reported as if something were wrong, and it also
    #--- silently downgraded this check to the log-derived source the
    #--- comment above warns about.
    st_terminals = {source_key(p) for p in st_files}

    if st_files:
        sender_open = set(sender_state.keys())
        sender_open_source = "sender state file (authoritative)"

        #--- A state file is authoritative only for the sender it belongs
        #--- to. A sender terminal with no state file must still be read
        #--- from its logs, or the positions it holds look like divergences.
        uncovered = [k for k, r in results.items()
                     if r["has_sender"] and k not in st_terminals]
        for k in uncovered:
            sender_open |= {u for u, d in results[k]["uid"].items()
                            if d["state"] == "open" and "sender" in d["src"]}
        if uncovered:
            sender_open_source = ("sender state file + logs for "
                                  f"{len(uncovered)} sender(s) without one")
    else:
        sender_open = set()
        for r in results.values():
            if r["has_sender"]:
                sender_open |= {u for u, d in r["uid"].items()
                                if d["state"] == "open" and "sender" in d["src"]}
        sender_open_source = ("sender logs (can be wrong: rotation removes "
                              "opens)") if sender_open else None

    for key, r in results.items():
        r["_verdicts"] = verdicts(r, sender_open if sender_open_source else None,
                                  sender_open_source, receiver_held.get(key))

    if as_json:
        print(json.dumps(
            {source_label(k): {
                "files": {p.rsplit("/", 1)[-1]: n
                          for p, n in per_file.items() if source_key(p) == k},
                "uid": {u: {kk: (sorted(vv) if isinstance(vv, set) else vv)
                            for kk, vv in d.items()}
                        for u, d in r["uid"].items()},
                "verdicts": r["_verdicts"],
             } for k, r in results.items()},
            indent=2, default=str))
        return 0

    print()
    print("=== copier logs ===")
    for p, n in per_file.items():
        print(f"  {side_of(p):<9} {n:>6} lines  {source_label(source_key(p))}")

    if st_files:
        print()
        print("=== sender state (authoritative, survives log rotation) ===")
        for p in st_files:
            print(f"  {source_label(source_key(p))}  {p.rsplit('/', 1)[-1]}")
        if sender_state:
            print(f"  {len(sender_state)} position(s) held:")
            for u, d in sender_state.items():
                print(f"    {u}  tkt={d['tkt']:<12} {d['sym']:<10} "
                      f"side={d['side']:<3} lots={d['lots']}")
        else:
            #--- valid file, zero positions: every sender is flat. That is a
            #--- clean result, not a missing one - say so rather than making
            #--- someone go looking for corruption that is not there.
            print("  0 position(s) held - every sender is flat")
    elif st_paths:
        print()
        print("=== sender state ===")
        print(f"  !! {len(st_paths)} state file(s) present but TORN (no END")
        print("     marker), so they are ignored - matching the EA, which")
        print("     also refuses a torn file. The sender rebuilds identity")
        print("     from order comments on restart.")

    if recv_st_files:
        print()
        print("=== receiver state (what each receiver actually holds) ===")
        for p in recv_st_files:
            k = source_key(p)
            held = sorted(receiver_held.get(k, set()))
            if held:
                shown = ", ".join(held[:8]) + ("..." if len(held) > 8 else "")
                print(f"  {source_label(k)}  {len(held)} position(s): {shown}")
            else:
                print(f"  {source_label(k)}  flat (0 position(s))")

    for key, r in results.items():
        render_group(source_label(key), r, {p: n for p, n in per_file.items()
                                            if source_key(p) == key})

    #--- a summary across terminals
    total_fail = sum(1 for r in results.values()
                     for lvl, _ in r["_verdicts"] if lvl == "fail")
    total_warn = sum(1 for r in results.values()
                     for lvl, _ in r["_verdicts"] if lvl == "warn")
    print()
    print("=== overall ===")
    print(f"  {len(results)} terminal(s): {total_fail} failing check(s), "
          f"{total_warn} warning(s)")
    if total_fail == 0:
        print("  no failing checks")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
