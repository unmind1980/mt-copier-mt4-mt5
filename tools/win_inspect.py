#!/usr/bin/env python3
"""Dump the window tree of one process: class, title, rect, visibility, control id.

WHY THIS EXISTS
---------------
Diagnosing "the terminal starts but the script never runs" took an hour of
guessing. The answer was one line of this output: the Login dialog is a real
`#32770` window, its parent is DISABLED while it is up, and that is why a
script can be "loaded successfully" and then never execute a single statement.
Guessing again next time would cost the same hour.

Usage:
  win_inspect.py <pid>            # all top-level windows + children
  win_inspect.py <pid> --dialogs  # only #32770 dialogs and their buttons
"""

import ctypes, sys
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def text(h):
    n = user32.GetWindowTextLengthW(h)
    b = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(h, b, n + 1)
    return b.value

def cls(h):
    b = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(h, b, 256)
    return b.value

def rect(h):
    r = wintypes.RECT()
    user32.GetWindowRect(h, ctypes.byref(r))
    return (r.left, r.top, r.right - r.left, r.bottom - r.top)

def walk(h, depth, out):
    kids = []
    CB = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(ch, lp):
        kids.append(ch)
        return True
    user32.EnumChildWindows(h, CB(cb), 0)
    for k in kids:
        out.append(("  " * depth) + "child %s  cls=%s  text=%r  rect=%s  vis=%s id=%s" % (
            hex(k), cls(k), text(k), rect(k), bool(user32.IsWindowVisible(k)),
            user32.GetDlgCtrlID(k)))
        if depth < 2:
            walk(k, depth + 1, out)

pid = int(sys.argv[1])
tops = []
def cb(h, lp):
    p = wintypes.DWORD()
    user32.GetWindowThreadProcessId(h, ctypes.byref(p))
    if p.value == pid:
        tops.append(h)
    return True
user32.EnumWindows(WNDENUMPROC(cb), 0)

for h in tops:
    print("TOP %s cls=%s text=%r rect=%s vis=%s enabled=%s" % (
        hex(h), cls(h), text(h), rect(h), bool(user32.IsWindowVisible(h)),
        bool(user32.IsWindowEnabled(h))))
    out = []
    walk(h, 1, out)
    for line in out:
        print(line)
    print("-")
