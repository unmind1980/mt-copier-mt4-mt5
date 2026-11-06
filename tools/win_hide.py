#!/usr/bin/env python3
"""Keep one MetaTrader process's windows out of the way, and get past its Login dialog.

WHY THIS EXISTS
---------------
`tools/selftest_run.sh` starts a portable MetaTrader to run CopierSelfTest, and
MetaTrader insists on showing a **Login** dialog when it has no usable account.
That dialog is not cosmetic: it is modal, it blocks the terminal's message loop,
and the StartUp script does not run until it is dismissed. Measured: with the
dialog up, the terminal log shows

    script CopierSelfTest (EURUSD,H1) loaded successfully

and then nothing - the self-test never starts. The only reason earlier runs
"worked" is that the operator clicked OK by hand.

The dialog is modal: while it is up the terminal's main window is DISABLED and
the StartUp script is loaded but never executed. Measured with a two-line probe
script - "script ProbeStartup (EURUSD,H1) loaded successfully" and then nothing,
no file, no output. So it has to be dismissed, not just hidden.

**OK, not Cancel.** Cancel looks like the polite way to "go offline", but it
aborts the startup path: the probe script still never ran. OK completes the
attempt (which fails, harmlessly - the self-test needs no broker), the dialog
closes, and the script runs immediately. Verified with the same probe: the log
file appeared within seconds of the click.

So this tool:
  * presses OK on a "Login" dialog (and on the error boxes a failed attempt can
    raise), and
  * hides every other top-level window, so a run is invisible on screen.

Both are ordinary Win32 calls (ShowWindow / BM_CLICK); nothing is injected into
the target process and nothing is written to disk. Stdlib only.

Usage:
  win_hide.py --pid 1234 --seconds 180     # run alongside the terminal
  win_hide.py --pid 1234 --once            # single pass, for testing
"""

import argparse
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
SW_HIDE = 0
BM_CLICK = 0x00F5
WM_COMMAND = 0x0111
IDOK = 1


def _title(h):
    n = user32.GetWindowTextLengthW(h)
    b = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(h, b, n + 1)
    return b.value


def _cls(h):
    b = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(h, b, 256)
    return b.value


def _children(h):
    out = []

    def _cb(ch, _lp):
        out.append(ch)
        return True

    user32.EnumChildWindows(h, WNDENUMPROC(_cb), 0)
    return out


def _top_level(pid):
    out = []

    def _cb(h, _lp):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(h, ctypes.byref(owner))
        if owner.value == pid:
            out.append(h)
        return True

    user32.EnumWindows(WNDENUMPROC(_cb), 0)
    return out


#--- Dialogs that block the terminal and that we want OUT of the way. "Login"
#--- is the one that appears on every start; the others are what a failed
#--- attempt can raise behind it. Matching is case-insensitive substring.
BLOCKING_TITLES = ("login", "invalid account", "authorization", "failed", "error")


def _is_blocking(title):
    t = title.lower()
    return any(k in t for k in BLOCKING_TITLES)


def dismiss_login(pid):
    """Press OK on a modal Login (or error) dialog. True if one was dismissed."""
    for h in _top_level(pid):
        if _cls(h) != "#32770":
            continue
        title = _title(h)
        if not _is_blocking(title):
            continue
        kids = _children(h)
        ok = None
        for ch in kids:
            if _cls(ch) == "Button" and _title(ch) == "OK":
                ok = ch
                break
        if ok is not None:
            user32.SendMessageW(ok, BM_CLICK, 0, 0)
            return True
        #--- no OK button: the dialog is a plain message box; WM_COMMAND with
        #--- IDOK is what its default button would send.
        user32.PostMessageW(h, WM_COMMAND, IDOK, 0)
        return True
    return False


def hide_visible(pid):
    hidden = 0
    for h in _top_level(pid):
        # Never hide a blocking dialog before it is dismissed: a hidden modal
        # dialog is still modal, and then nothing can click it.
        if _cls(h) == "#32770" and _is_blocking(_title(h)):
            continue
        if user32.IsWindowVisible(h) and user32.ShowWindow(h, SW_HIDE):
            hidden += 1
    return hidden


def tick(pid, do_hide=True):
    dismissed = dismiss_login(pid)
    hidden = hide_visible(pid) if do_hide else 0
    return dismissed, hidden


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--seconds", type=float, default=180.0)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-hide", action="store_true",
                    help="only dismiss Login dialogs; leave windows visible")
    args = ap.parse_args()

    hid = 0
    dismissed = 0
    if args.once:
        d, h = tick(args.pid, not args.no_hide)
        dismissed += 1 if d else 0
        hid += h
    else:
        deadline = time.time() + args.seconds
        while time.time() < deadline:
            d, h = tick(args.pid, not args.no_hide)
            dismissed += 1 if d else 0
            hid += h
            time.sleep(0.25)

    if not args.quiet:
        print(
            "win_hide: pid %d - %d login dialog(s) dismissed, %d window(s) hidden"
            % (args.pid, dismissed, hid),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
