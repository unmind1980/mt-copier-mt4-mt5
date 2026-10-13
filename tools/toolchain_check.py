#!/usr/bin/env python3
"""
toolchain_check.py - can this machine still BUILD the hub?

Not "is cargo installed". The hub has compiled for months while one
capability was quietly broken, and nothing tested for it.

WHY THIS TEST EXISTS
====================
The Rust GNU toolchain ships its own `dlltool` but not the assembler that
dlltool calls. So any crate that generates a Windows import library - on this
target that is tokio, axum, rust-embed, and much else - dies with:

    dlltool.exe: CreateProcess

A message that names neither the caller nor what could not be started. The
first conclusion written down from it was "tokio cannot build on this
machine", which was wrong, and it stayed wrong because the error looks
identical whichever crate pulls `windows-sys`.

The fix lives in hub/build.sh and third_party/binutils, and it has two parts
that each fail on their own:

  * a COMPLETE set - dlltool AND as AND ar. `as` alone still leaves dlltool
    unable to finish.
  * the right PATH ORDER - binutils BEFORE Rust's self-contained. Inverted,
    the hub links with `ld: cannot find crt2.o`, because the full mingw64 tree
    also shadows Rust's `ld` and `gcc`.

Both are easy to undo by accident, so both are asserted here. The check that
matters is the last one: dlltool actually PRODUCES an import library. A file
existing and a tool being runnable are not the same claim.

WHAT THIS CANNOT SEE, so it is not mistaken for a full guard
-------------------------------------------------------------
Windows' CreateProcess searches the *launching application's own directory*
before PATH. `as.exe` sits next to `dlltool.exe` here, so ANY dlltool placed in
this directory can call it - which means swapping vendored `dlltool.exe` for a
broken one still passes this check. (That is also why the fix works at all, and
why `as` on PATH alone was enough in the end.)

So the test that actually guards M8/M10 is `bash hub/build.sh --release` with
the new dependencies in Cargo.toml, which `tests.sh --all` now runs. This file
is the fast diagnostic that names WHICH tool is missing when that fails.

Run:  python tools/toolchain_check.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VENDORED = os.path.join(REPO, "third_party", "binutils")

MSYS_CANDIDATES = [
    r"E:\msys64\msys64\mingw64\bin",
    r"C:\msys64\mingw64\bin",
    r"D:\msys64\mingw64\bin",
    "/e/msys64/msys64/mingw64/bin",
    "/c/msys64/mingw64/bin",
]

NEED = ("dlltool.exe", "as.exe", "ar.exe")


def find_binutils():
    """The directory build.sh will ACTUALLY use, or None.

    Mirrors build.sh's precedence exactly: the vendored copy wins when it is
    complete, and the MSYS2 install is only a fallback. That precedence is the
    point of this function.

    An earlier version searched in the other spirit - "any complete set
    anywhere" - and that made this test useless in exactly the case it exists
    for: break the vendored dlltool and the test still passed, because it fell
    back to MSYS2 and happily tested that instead. The build would have broken.
    """
    if all(os.path.isfile(os.path.join(VENDORED, f)) for f in NEED):
        return VENDORED, False
    for c in MSYS_CANDIDATES:
        if all(os.path.isfile(os.path.join(c, f)) for f in NEED):
            return c, True          # (dir, using_fallback)
    return None, False


def main() -> int:
    bu, fallback = find_binutils()
    if bu is None:
        print("FAIL  no binutils found")
        print(f"      looked in {VENDORED}")
        for c in MSYS_CANDIDATES:
            print(f"      and {c}")
        print()
        print("      Without them the hub still builds, but anything needing an")
        print("      import library (tokio, axum, rust-embed) fails as an")
        print("      unhelpful 'dlltool.exe: CreateProcess'.")
        return 1
    print(f"binutils: {bu}")
    if fallback:
        # Not an error - build.sh would do the same - but it is fragile: it
        # depends on where MSYS2 happens to be installed, and the whole reason
        # the tools are vendored is that "happens to be" is not a guarantee.
        print("  note  using the MSYS2 FALLBACK; third_party/binutils is")
        print("        incomplete. The build works, but only here.")
    rc = 0

    # --- each tool runs -------------------------------------------------
    for tool in NEED:
        path = os.path.join(bu, tool)
        try:
            out = subprocess.run([path, "--version"], capture_output=True,
                                 timeout=30)
            ver = (out.stdout or out.stderr).decode("utf-8", "replace")
            first = next((l for l in ver.splitlines() if l.strip()), "")
            print(f"  ok    {tool:12s} {first[:60]}")
        except Exception as e:                       # noqa: BLE001
            print(f"  FAIL  {tool:12s} {e}")
            rc = 1

    # --- and the one that actually matters: it PRODUCES a library -------
    # A .def with an export is the same shape windows-sys feeds dlltool, so
    # this is the real capability rather than a proxy for it.
    with tempfile.TemporaryDirectory() as td:
        deff = os.path.join(td, "probe.def")
        libf = os.path.join(td, "probe.lib")
        with open(deff, "w", encoding="ascii") as fh:
            fh.write("EXPORTS\n  CopierProbeSymbol\n")
        cmd = [
            os.path.join(bu, "dlltool.exe"),
            "-d", deff, "-D", "kernel32.dll", "-l", libf,
            "-m", "i386:x86-64", "-f", "--64", "--no-leading-underscore",
            "--temp-prefix", "kernel32.dll",
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, timeout=60)
            if res.returncode != 0:
                err = (res.stderr or res.stdout).decode("utf-8", "replace")
                print(f"  FAIL  dlltool exited {res.returncode}: {err.strip()[:90]}")
                rc = 1
            else:
                size = os.path.getsize(libf) if os.path.isfile(libf) else 0
                if size > 0:
                    print(f"  ok    import library generated ({size} bytes)")
                else:
                    # This is the failure that hides: dlltool can print
                    # CreateProcess, exit 0, and leave an EMPTY file. An
                    # import lib of zero bytes links nothing.
                    print("  FAIL  import library is EMPTY (0 bytes)")
                    rc = 1
        except Exception as e:                       # noqa: BLE001
            print(f"  FAIL  dlltool raised {e}")
            rc = 1

    print()
    if rc == 0:
        print("TOOLCHAIN OK")
    else:
        print("TOOLCHAIN BROKEN - see hub/build.sh section 2 for the PATH order")
    return rc


if __name__ == "__main__":
    sys.exit(main())
