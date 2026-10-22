#!/usr/bin/env python3
r"""
snapshot_receipt_test.py - conformance test for the snapshot receipt.

WHY THIS EXISTS
---------------
Slice A of the snapshot-on-demand design (doc/SNAPSHOT-DEMAND-PLAN.md) puts
an FNV-1a hash on every SNAP payload and echoes it back from the receiver in
the STAT message. Three separate pieces of MQL must agree on that format:

  * the sender's encoder      CopierEncodeSnapshot()  - appends ";H=<8 hex>"
  * the receiver's extractor  CopierSnapshotHash()    - reads H back out
  * the sender's comparator   SnapTrack()             - string equality

None of those can be tested from MetaEditor beyond "it compiles". And a hash
that is computed differently on the two ends, or extracted with the wrong
boundary, produces a system that LOOKS like it works - the messages flow, the
hash is present - while reporting a mismatch on every single heartbeat. That
is the failure this file exists to make impossible.

So this script re-implements the format from the contract and asserts:

  * the FNV-1a constants and algorithm match the published reference vectors
  * ";H=" is APPENDED, so the hash covers every byte before it and not itself
  * the full record is covered - a change in ticket/openPx/openTime/magic,
    which are necessarily DIFFERENT on the receiver, still changes the hash.
    That is correct here BECAUSE the receiver stores rather than computes it.
  * extracting H from a payload stops at the ';' and does not swallow the next
    field, and a payload with no H yields "" rather than a wrong value
  * a snapshot with N=0 (an empty account) still hashes and round-trips

It is a CONTRACT test, not a unit test of MQL. If the format in
CopierCodec.mqh changes, this file must change with it.

Run:  python snapshot_receipt_test.py
"""

import re
import sys

# ---------------------------------------------------------------------------
# The format, as specified in src/Include/Copier/CopierCodec.mqh
# ---------------------------------------------------------------------------
CP_FNV_OFFSET = 2166136261
CP_FNV_PRIME = 16777619
CP_MASK32 = 0xFFFFFFFF

CP_SEP_KV = ";"     # payload k=v separator
CP_SEP_REC = "~"    # repeated records
CP_SEP_ITEM = ","   # items inside a record

passes = []
fails = []


def check(name, ok, detail=""):
    if ok:
        passes.append(name)
        print(f"  PASS  {name}")
    else:
        fails.append(name)
        print(f"  FAIL  {name}" + (f"   [{detail}]" if detail else ""))


# ---------------------------------------------------------------------------
# The algorithm. NOTE the & CP_MASK32 after every multiply - that is what
# makes it FNV-1a and not "some hash". The MQL does the same thing with a
# `long` and an explicit mask, for the same reason.
# ---------------------------------------------------------------------------
def fnv1a(s):
    h = CP_FNV_OFFSET
    for ch in s:
        h ^= ord(ch) & 0xFF
        h = (h * CP_FNV_PRIME) & CP_MASK32
    return h


def hash_hex(s):
    return f"{fnv1a(s):08x}"


def encode_snapshot(records):
    """Mirror of CopierEncodeSnapshot(): build N/R, hash what was built, append."""
    payload = "N=" + str(len(records))
    if records:
        recs = CP_SEP_REC.join(records)
        if len(recs) >= 500:
            import zmq.utils.z85 as z85
            import zlib
            comp = zlib.compress(recs.encode('utf-8'))
            pad = (4 - (len(comp) % 4)) % 4
            padded = comp + b'\x00' * pad
            r_val = "1:" + z85.encode(padded).decode('ascii')
        else:
            r_val = "0:" + recs
        payload += CP_SEP_KV + "R=" + r_val
    return payload + CP_SEP_KV + "H=" + hash_hex(payload)


def snapshot_hash(payload):
    """Mirror of CopierSnapshotHash(): value of H, or '' when absent."""
    m = re.search(r"(?:^|" + re.escape(CP_SEP_KV) + r")H=([^" + re.escape(CP_SEP_KV) + r"]*)", payload)
    return m.group(1) if m else ""


def rec(uid, ticket, sym, side, lots, openpx, sl, tp, magic, opentime):
    return CP_SEP_ITEM.join([
        uid, str(ticket), sym, str(side), f"{lots:.8f}",
        f"{openpx:.8f}", f"{sl:.8f}", f"{tp:.8f}", str(magic), str(opentime),
    ])


def main():
    print("== FNV-1a reference vectors ==")
    check("hash of '' is the offset basis", hash_hex("") == "811c9dc5", hash_hex(""))
    check("hash of 'a' matches the published vector", hash_hex("a") == "e40c292c", hash_hex("a"))
    check("hash of 'foobar' matches the published vector", hash_hex("foobar") == "bf9cf968", hash_hex("foobar"))
    check("it runs longer than 32 bits before the mask would be needed",
          fnv1a("a" * 64) != fnv1a("a" * 65))

    print()
    print("== the hash covers everything before it ==")
    r1 = rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000000)
    r2 = rec("U0000002", 12346, "GBPUSD", -1, 0.2, 1.2, 1.19, 1.21, 5555, 1700000001)
    p = encode_snapshot([r1, r2])

    check("payload ends with the H field", p.endswith("H=" + hash_hex(p.rsplit(";H=", 1)[0])))
    check("the hash is 8 hex digits", re.fullmatch(r"[0-9a-f]{8}", snapshot_hash(p)) is not None,
          snapshot_hash(p))
    check("the hash does NOT cover itself (recompute from the prefix agrees)",
          snapshot_hash(p) == hash_hex(p.rsplit(";H=", 1)[0]))

    # Every field that changes must change the hash - including the ones that
    # are necessarily different on the receiver. They are hashed here because
    # the receiver STORES this value rather than computing its own.
    print()
    print("== every record field changes the hash ==")
    variants = {
        "uid": rec("U0000009", 12345, "EURUSD", 1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000000),
        "ticket": rec("U0000001", 99999, "EURUSD", 1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000000),
        "symbol": rec("U0000001", 12345, "USDJPY", 1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000000),
        "side": rec("U0000001", 12345, "EURUSD", -1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000000),
        "lots": rec("U0000001", 12345, "EURUSD", 1, 0.2, 1.1, 1.09, 1.11, 5555, 1700000000),
        "openPx": rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.2, 1.09, 1.11, 5555, 1700000000),
        "sl": rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.1, 1.08, 1.11, 5555, 1700000000),
        "tp": rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.1, 1.09, 1.12, 5555, 1700000000),
        "magic": rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.1, 1.09, 1.11, 7777, 1700000000),
        "openTime": rec("U0000001", 12345, "EURUSD", 1, 0.1, 1.1, 1.09, 1.11, 5555, 1700000999),
    }
    base = snapshot_hash(encode_snapshot([r1, r2]))
    for field, v in variants.items():
        h = snapshot_hash(encode_snapshot([v, r2]))
        check(f"changing {field} changes the hash", h != base, f"{h} == {base}")

    print()
    print("== SL/TP are covered (the reason the whole snapshot is hashed) ==")
    # SL/TP ride the snapshot because MODIFY is deliberately unimplemented.
    # If they were NOT hashed, a stop-only change would be invisible to the
    # sender, which would think the receiver was up to date and never re-send.
    check("an SL-only change is visible in the receipt",
          snapshot_hash(encode_snapshot([variants["sl"], r2])) != base)
    check("a TP-only change is visible in the receipt",
          snapshot_hash(encode_snapshot([variants["tp"], r2])) != base)

    print()
    print("== record ORDER and COUNT are covered ==")
    check("swapping two records changes the hash",
          snapshot_hash(encode_snapshot([r2, r1])) != base)
    check("removing a record changes the hash",
          snapshot_hash(encode_snapshot([r1])) != base)

    print()
    print("== an EMPTY account still round-trips ==")
    pe = encode_snapshot([])
    check("empty snapshot is 'N=0;H=<hash>'", pe.startswith("N=0;H="), pe)
    check("empty snapshot hash is present and extractable",
          re.fullmatch(r"[0-9a-f]{8}", snapshot_hash(pe)) is not None, pe)
    check("empty and one-position snapshots differ",
          snapshot_hash(pe) != snapshot_hash(encode_snapshot([r1])))

    print()
    print("== extraction boundaries ==")
    check("H is read back out of the full payload", snapshot_hash(p) == hash_hex(p.rsplit(";H=", 1)[0]))
    # H must not swallow a following field; simulate H appearing mid-payload
    mid = "N=1;R=x;H=deadbeef;Z=1"
    check("H stops at the ';' and does not swallow the next field",
          snapshot_hash(mid) == "deadbeef", snapshot_hash(mid))
    check("a payload with no H yields '' (not a wrong value)", snapshot_hash("N=1;R=x") == "")
    # An older sender's snapshot has no H at all. The receiver must report ""
    # and the sender must treat that as "no receipt yet", not "stale".
    check("an old-format snapshot yields no receipt", snapshot_hash("N=0") == "")

    print()
    print("== H must not be confused with a key that merely contains H ==")
    # 'H' is a suffix of nothing common today, but the same trap that made
    # OTS match inside LOTS is one careless key name away. A key that ENDS in
    # H but is not H must not be read as the hash.
    check("'WIDTH=abc' is not read as the H field",
          snapshot_hash("N=1;WIDTH=abc") == "")
    check("'H=' at the very start is still found",
          snapshot_hash("H=cafebabe;N=1") == "cafebabe")

    print()
    print("== the worked example printed in doc/PROTOCOL.md ==")
    # If the encoder ever changes, this fails and the DOCUMENTED example in
    # PROTOCOL.md is wrong - which is worse than having no example, because a
    # reader would verify against it, see a mismatch, and go hunting in the
    # code for a bug that is actually in the doc.
    doc_payload = (
        "N=2;R=0:ABCD1234,9918271,EURUSD,1,0.5,1.0845,1.08,"
        "1.09,0,1780000000~EFGH5678,9918275,XAUUSD,-1,0.1,"
        "2350.1,0,0,0,1780000005"
    )
    check("PROTOCOL.md's SNAP example hash is the real one",
          hash_hex(doc_payload) == "7c315c76", hash_hex(doc_payload))
    check("PROTOCOL.md's example line carries that hash",
          (";H=7c315c76" in open(_protocol_md(), encoding="utf-8").read()))

    print()
    print("== the TWO shapes of STAT must stay distinguishable ==")
    # A receiver sends STAT in two shapes: a full monitoring report once a
    # minute, and a RECEIPT ONLY every SyncHeartbeatSeconds. The sender tells
    # them apart by the presence of the figure block, so this is a contract and
    # not an implementation detail - breaking it prints
    #     "receiver X status: equity= balance= held= position(s) ..."
    # which reads like a broken receiver. Measured live, 2026-10-13.
    receipt_only = "LOGIN=9918271;SID=252033316;H=13b2bc5c"
    full_report = (receipt_only
                   + ";EQ=10042.11;BL=10000.00;HELD=2;LOTS=0.60"
                   + ";NSEND=1;BLOCKED=0;RISK=ok")

    def kv(payload):
        out = {}
        for item in payload.split(";"):
            if "=" in item:
                k, v = item.split("=", 1)
                out[k] = v
        return out

    check("a receipt-only STAT carries H", kv(receipt_only).get("H") == "13b2bc5c")
    check("a receipt-only STAT carries NO figures", "EQ" not in kv(receipt_only))
    check("a full report carries the figures", kv(full_report).get("EQ") == "10042.11")
    check("a full report still carries the receipt too",
          kv(full_report).get("H") == "13b2bc5c")
    check("EQ is therefore a sound discriminator",
          ("EQ" in kv(full_report)) and ("EQ" not in kv(receipt_only)))

    print()
    print("== 500-byte adaptive compression ==")
    # 5 records (~300B) are below 500 bytes -> raw uncompressed with R=0:
    recs5 = [rec(f"U{i:07d}", i, "EURUSD", 1, 0.01, 1.085, 0, 0, 0, 1780000000 + i) for i in range(1, 6)]
    small_p = encode_snapshot(recs5)
    check("5 records are under 500-byte threshold", len(CP_SEP_REC.join(recs5)) < 500)
    check("5 records use uncompressed prefix R=0:", ";R=0:" in small_p)

    # 10 records (~600B) exceed 500-byte threshold -> trigger Z85+zlib with R=1:
    recs10 = [rec(f"U{i:07d}", i, "EURUSD", -1, 0.01, 1.085, 0, 0, 0, 1780000000 + i) for i in range(1, 11)]
    med_p = encode_snapshot(recs10)
    check("10 records exceed 500-byte threshold", len(CP_SEP_REC.join(recs10)) >= 500)
    check("10 records trigger compression prefix R=1:", ";R=1:" in med_p)

    # 300 records exceed threshold and compress to under 5KB
    recs300 = [rec(f"U{i:07d}", i, "EURUSD", 1 if i % 2 == 0 else -1, 0.01, 1.085, 0, 0, 0, 1780000000 + i) for i in range(1, 301)]
    big_p = encode_snapshot(recs300)
    check("300 raw records exceed 500-byte threshold", len(CP_SEP_REC.join(recs300)) >= 500)
    check("compressed snapshot is under 5KB (massive reduction)", len(big_p) < 5000)
    check("big snapshot uses compression prefix R=1:", ";R=1:" in big_p)
    r_val = re.search(r";R=1:([^;]+)", big_p).group(1)
    import zmq.utils.z85 as z85
    import zlib
    raw = z85.decode(r_val)
    decomp = zlib.decompress(raw).decode("utf-8")
    decomp_recs = decomp.split("~")
    check("decompressed length is 300 records", len(decomp_recs) == 300)
    check("first record ticket is 1", decomp_recs[0].split(",")[1] == "1")
    check("last record ticket is 300", decomp_recs[299].split(",")[1] == "300")

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


def _protocol_md():
    """path to doc/PROTOCOL.md, relative to this file's repo"""
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(here), "doc", "PROTOCOL.md")


if __name__ == "__main__":
    sys.exit(main())
