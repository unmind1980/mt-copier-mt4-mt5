#!/usr/bin/env python3
r"""
curve_keyfile_test.py - conformance test for the CURVE key-file format.

WHY THIS EXISTS
---------------
The MQL module src/Include/Copier/CopierCurveKey.mqh decides, on every EA
start, whether the file MQL\Files\copier_curve.key is usable and whether it
must be replaced. That decision has four branches, and every one of them is
a branch that only runs in a live terminal - the "file was corrupt" path in
particular is one nobody exercises on purpose.

MetaEditor can only tell us the module COMPILES. It cannot tell us the
format is the one the module claims to read. So this script re-implements
the same rules against the same libzmq primitives (pyzmq, libzmq 4.3.5 -
the same library the EAs link), and asserts that:

  * a file this module writes is accepted by these rules   (round trip)
  * the four rejection cases are all actually rejected

It is a CONTRACT test, not a unit test of MQL. If the format in the header
of CopierCurveKey.mqh changes, this file must change with it - which is the
point: the format is written down in two places and they must agree.

Run:  python curve_keyfile_test.py
"""

import os
import re
import sys
import tempfile

import zmq

MAGIC = "copier-curve-key v1"
HUB_MAGIC = "copier-hub-key v1"
KEY_LEN = 40

fails = []
passes = []


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
        print(f"  PASS  {name}")
    else:
        fails.append(name)
        print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))


# ----------------------------------------------------------------------
# The format, exactly as CopierCurveKey.mqh implements it.
# ----------------------------------------------------------------------
def field(line, name):
    """Mirror of CopierCurveKey::Field(): prefix compared case-insensitively,
    value returned verbatim (Z85 is case-significant)."""
    n = len(name)
    if len(line) < n + 1:
        return ""
    if line[:n].upper() != name.upper():
        return ""
    if line[n] != "=":
        return ""
    return line[n + 1:].strip()


def parse_keyfile(text):
    """Return (pub, sec, reason). reason != '' means unusable."""
    lines = text.splitlines()
    if not lines:
        return "", "", "empty file"
    if lines[0].strip() != MAGIC:
        return "", "", "bad magic line"
    pub = sec = ""
    for line in lines[1:]:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        p = field(s, "PUBLIC")
        k = field(s, "SECRET")
        if p:
            pub = p
        if k:
            sec = k
    if len(pub) != KEY_LEN or len(sec) != KEY_LEN:
        return "", "", f"bad length pub={len(pub)} sec={len(sec)}"
    if zmq.curve_public(sec.encode()).decode() != pub:
        return "", "", "PUBLIC does not match SECRET"
    return pub, sec, ""


def parse_hub_keyfile(text):
    """Mirror of CopierParseHubKeyFileHandle()."""
    lines = text.splitlines()
    if not lines:
        return "", "empty file"
    first = True
    pub = ""
    for line in lines:
        s = line.strip()
        if not s:
            continue
        if first:
            first = False
            if s != HUB_MAGIC:
                return "", "bad magic line"
            continue
        if s.startswith("#"):
            continue
        p = field(s, "PUBLIC")
        if p:
            pub = p
        elif len(s) == KEY_LEN:
            pub = s
    if len(pub) != KEY_LEN:
        return "", f"bad length pub={len(pub)}"
    return pub, ""


def write_keyfile(path, pub, sec, magic=MAGIC):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(magic + "\n")
        fh.write("# generated for the conformance test\n")
        fh.write("#\n")
        fh.write("PUBLIC=" + pub + "\n")
        fh.write("SECRET=" + sec + "\n")


def write_hub_keyfile(path, pub, magic=HUB_MAGIC):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(magic + "\n")
        fh.write("# Hub CurveZMQ Public Key file\n")
        fh.write("# Downloaded from Copier Hub Web Dashboard\n")
        fh.write("PUBLIC=" + pub + "\n")


# ----------------------------------------------------------------------
def main():
    print("== curve key-file conformance ==")
    print(f"libzmq {zmq.zmq_version()} / pyzmq {zmq.pyzmq_version()}")

    with tempfile.TemporaryDirectory() as td:
        kp = os.path.join(td, "copier_curve.key")

        # --- 1. round trip: what the module writes must load back
        pub, sec = zmq.curve_keypair()
        pub, sec = pub.decode(), sec.decode()
        write_keyfile(kp, pub, sec)
        gp, gs, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("round trip: written file loads back", why == "", why)
        check("round trip: keys survive byte-for-byte", gp == pub and gs == sec)
        check("round trip: derived public matches",
              zmq.curve_public(gs.encode()).decode() == gp)

        # --- 2. the rejection cases
        # 2a. wrong magic (a file from a future build / another tool)
        write_keyfile(kp, pub, sec, magic="copier-curve-key v99")
        _, _, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("rejects a foreign/unversioned magic line", why == "bad magic line", why)

        # 2b. truncated key (a paste that lost its tail)
        write_keyfile(kp, pub[:37], sec)
        _, _, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("rejects a truncated PUBLIC", "bad length" in why, why)

        # 2c. wrapped key (a paste that gained a newline) - the second line
        #     is a bare continuation with no KEY=, so PUBLIC stays short
        with open(kp, "w", encoding="ascii", newline="\n") as fh:
            fh.write(MAGIC + "\nPUBLIC=" + pub[:20] + "\n" + pub[20:]
                     + "\nSECRET=" + sec + "\n")
        _, _, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("rejects a PUBLIC wrapped over two lines", "bad length" in why, why)

        # 2d. PUBLIC that does not match SECRET (two halves from different pairs)
        other_pub, _ = zmq.curve_keypair()
        write_keyfile(kp, other_pub.decode(), sec)
        _, _, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("rejects a PUBLIC that does not match SECRET", "does not match" in why, why)

        # 2e. lowercase key name tolerated (hand-retyped), value case preserved
        write_keyfile(kp, pub, sec)
        txt = open(kp, encoding="ascii").read().replace("PUBLIC=", "public=")
        gp2, gs2, why = parse_keyfile(txt)
        check("accepts a lowercased PUBLIC= key name", why == "", why)
        check("...and keeps the value case-sensitive", gp2 == pub and gs2 == sec)

        # --- 3. an empty file must not crash the loader
        open(kp, "w").close()
        _, _, why = parse_keyfile(open(kp, encoding="ascii").read())
        check("rejects an empty file", why == "empty file", why)

        # --- 4. Hub public key file (copier_hub.key) tests
        hkp = os.path.join(td, "copier_hub.key")
        hpub, _ = zmq.curve_keypair()
        hpub = hpub.decode()
        write_hub_keyfile(hkp, hpub)
        read_hpub, hwhy = parse_hub_keyfile(open(hkp, encoding="utf-8").read())
        check("hub key: written copier_hub.key loads back", hwhy == "", hwhy)
        check("hub key: public key matches exactly", read_hpub == hpub)

        # 4a. foreign magic
        write_hub_keyfile(hkp, hpub, magic="copier-hub-key v99")
        _, hwhy = parse_hub_keyfile(open(hkp, encoding="utf-8").read())
        check("hub key: rejects foreign magic", hwhy == "bad magic line", hwhy)

        # 4b. truncated key
        write_hub_keyfile(hkp, hpub[:35])
        _, hwhy = parse_hub_keyfile(open(hkp, encoding="utf-8").read())
        check("hub key: rejects truncated public key", "bad length" in hwhy, hwhy)

        # 4c. naked key fallback without PUBLIC= prefix
        with open(hkp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(HUB_MAGIC + "\n# comment\n" + hpub + "\n")
        read_hpub, hwhy = parse_hub_keyfile(open(hkp, encoding="utf-8").read())
        check("hub key: accepts naked 40-character key line", hwhy == "" and read_hpub == hpub)

    print()
    print("== result ==")
    print(f"  pass={len(passes)}  fail={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
