#!/usr/bin/env python3
"""
patch-zmq.py - make mql-zmq compile on current MetaTrader builds.

WHY THIS IS NEEDED
------------------
mql-zmq was last touched in 2017 (with a tiny commit in 2023). Since
then MetaQuotes made `char` and `uchar` strictly distinct types in MQL,
and the built-in helpers changed signature:

    int  StringToUtf8 (const string str, uchar &utf8[], bool ending=true)
    string StringFromUtf8 (const uchar &utf8[])

The binding still declares everything as `char`, so on any reasonably
recent MT4/MT5 build it fails with a wall of:

    error 246: parameter convertion type 'char[]' to 'uchar[] &' is not allowed
    error 199: wrong parameters count

The fix is mechanical and safe: every `char` buffer here is a raw byte
buffer handed to a C function that only ever sees a pointer, so `uchar`
is an equally correct - and now the only accepted - spelling.

The patch is idempotent: running it twice changes nothing.
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZMQ = os.path.join(REPO, "third_party", "mql-zmq-master", "Include")

# (relative path, [(old, new), ...])
RULES = [
    ("Zmq/Socket.mqh", [
        ("int zmq_bind(intptr_t s,const char &addr[]);",
         "int zmq_bind(intptr_t s,const uchar &addr[]);"),
        ("int zmq_connect(intptr_t s,const char &addr[]);",
         "int zmq_connect(intptr_t s,const uchar &addr[]);"),
        ("int zmq_unbind(intptr_t s,const char &addr[]);",
         "int zmq_unbind(intptr_t s,const uchar &addr[]);"),
        ("int zmq_disconnect(intptr_t s,const char &addr[]);",
         "int zmq_disconnect(intptr_t s,const uchar &addr[]);"),
        ("int zmq_socket_monitor(intptr_t s,const char &addr[],int events);",
         "int zmq_socket_monitor(intptr_t s,const uchar &addr[],int events);"),
        ("   char arr[];", "   uchar arr[];"),
    ]),
    ("Zmq/SocketOptions.mqh", [
        ("   char buf[];", "   uchar buf[];"),
    ]),
    ("Zmq/Z85.mqh", [
        ("intptr_t zmq_z85_encode(char &str[],const uchar &data[],size_t size);",
         "intptr_t zmq_z85_encode(uchar &str[],const uchar &data[],size_t size);"),
        ("intptr_t zmq_z85_decode(uchar &dest[],const char &str[]);",
         "intptr_t zmq_z85_decode(uchar &dest[],const uchar &str[]);"),
        ("int zmq_curve_keypair(char &z85_public_key[],char &z85_secret_key[]);",
         "int zmq_curve_keypair(uchar &z85_public_key[],uchar &z85_secret_key[]);"),
        ("int zmq_curve_public(char &z85_public_key[],const char &z85_secret_key[]);",
         "int zmq_curve_public(uchar &z85_public_key[],const uchar &z85_secret_key[]);"),
        ("   char str[];", "   uchar str[];"),
    ]),
    ("Zmq/ZmqMsg.mqh", [
        ("intptr_t zmq_msg_gets(zmq_msg_t &msg,const char &property[]);",
         "intptr_t zmq_msg_gets(zmq_msg_t &msg,const uchar &property[]);"),
    ]),
    ("Zmq/Zmq.mqh", [
        ("int zmq_has(const char &capability[]);",
         "int zmq_has(const uchar &capability[]);"),
    ]),
]


def detect_encoding(raw: bytes) -> str:
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"
    if raw[:3] == b"\xef\xbb\xbf":
        return "utf-8-sig"
    return "utf-8"


def patch(path: str, rules) -> int:
    if not os.path.exists(path):
        print(f"  !! missing {path}")
        return -1
    raw = open(path, "rb").read()
    enc = detect_encoding(raw)
    text = raw.decode(enc)
    changed = 0
    for old, new in rules:
        n = text.count(old)
        if n:
            text = text.replace(old, new)
            changed += n
    if changed:
        open(path, "wb").write(text.encode(enc))
    print(f"  {'patched' if changed else 'already ok'}  "
          f"{os.path.relpath(path, ZMQ)}  ({changed} replacement(s))")
    return changed


def main() -> int:
    if not os.path.isdir(ZMQ):
        print(f"mql-zmq not found at {ZMQ}\nrun tools/fetch-deps.sh first")
        return 1

    print("patching mql-zmq for modern MQL char/uchar strictness")
    total = 0
    missing = 0
    for rel, rules in RULES:
        r = patch(os.path.join(ZMQ, rel), rules)
        if r < 0:
            missing += 1
        else:
            total += r

    print(f"done: {total} replacement(s), {missing} missing file(s)")

    # A sanity check: nothing may still pass a `char` buffer to a zmq
    # import or to StringToUtf8/StringFromUtf8.
    leftovers = []
    for rel, _ in RULES:
        p = os.path.join(ZMQ, rel)
        if not os.path.exists(p):
            continue
        t = open(p, "rb").read().decode(detect_encoding(open(p, "rb").read()),
                                        errors="replace")
        for i, line in enumerate(t.splitlines(), 1):
            if "char" in line and "uchar" not in line and "//" not in line:
                leftovers.append(f"{rel}:{i}: {line.strip()}")
    if leftovers:
        print("\nWARNING - leftover bare `char` declarations:")
        for l in leftovers:
            print("  " + l)
    else:
        print("sanity check: no bare `char` declarations remain")

    return 0


if __name__ == "__main__":
    sys.exit(main())
