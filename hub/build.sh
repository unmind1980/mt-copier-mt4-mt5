#!/usr/bin/env bash
# ---------------------------------------------------------------------
# hub/build.sh - build the Rust hub against the SAME libzmq the EAs use.
#
# WHY THIS SCRIPT EXISTS AT ALL
# =============================
#
# "Just run cargo build" does not work on a machine that has never built this,
# and the reasons are not obvious from any error message:
#
#   1. Rust is installed in an ISOLATED location, not on PATH, so `cargo` is
#      not a command you can just type. RUSTUP_HOME/CARGO_HOME must be set or
#      rustup looks in ~/.rustup and finds nothing.
#
#   2. The build needs LIBZMQ_PREFIX. Without it zmq-sys falls back to
#      pkg-config, which is not installed, and the error is a confusing
#      "Unable to locate libzmq".
#
#   3. `dlltool` must be able to RUN for the windows-gnu target. It is on this
#      machine and still cannot run: the Rust GNU toolchain ships it without the
#      assembler it calls, so it fails as "CreateProcess" - a message that names
#      neither dlltool's caller nor what it could not start. Section 2 below
#      vendors a complete-enough binutils and explains the PATH order, which is
#      the part that is easy to get backwards.
#
# So the environment setup lives here, in one place, instead of in a README
# that drifts.
#
# Usage:
#   bash hub/build.sh            # debug
#   bash hub/build.sh --release  # optimised (what you deploy)
#   bash hub/build.sh --test     # unit tests only
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# --- 1. the isolated Rust toolchain -----------------------------------
RUSTROOT="${WORKBUDDY_RUST_ROOT:-$HOME/.workbuddy-ai/binaries/rust}"
if [[ ! -d "$RUSTROOT/rustup" ]]; then
  # Git Bash home may differ from the Windows user profile; try the usual one.
  RUSTROOT="/c/Users/Administrator/.workbuddy-ai/binaries/rust"
fi
export RUSTUP_HOME="$RUSTROOT/rustup"
export CARGO_HOME="$RUSTROOT/cargo"

CARGO="$CARGO_HOME/bin/cargo.exe"
[[ -x "$CARGO" ]] || CARGO="$CARGO_HOME/bin/cargo"
if [[ ! -x "$CARGO" ]]; then
  echo "hub/build.sh: no Rust toolchain at $CARGO_HOME/bin"
  echo "  install it with rustup, or set WORKBUDDY_RUST_ROOT"
  exit 1
fi

# --- 2. dlltool, which the windows-gnu target needs and never mentions ---
#
# THE SUBTLETY, since it cost a day of wrong conclusions:
#
# The Rust GNU toolchain ships its OWN dlltool/ld/gcc in `self-contained` - but
# that dlltool cannot run here. It shells out to an assembler, and the GNU
# toolchain does not ship one, so every crate that builds an import library
# dies with a message that says only:
#
#     dlltool.exe: CreateProcess
#
# i.e. "I could not start something", with no hint of WHAT. The first
# conclusion written down here was "tokio cannot build on this machine". That
# was wrong, and it stayed wrong for a while because the failure looks the same
# whether the dependency is tokio, axum, or rust-embed.
#
# It is not about any crate. It is about `as`/`ar` being absent, and the fix is
# a *complete* binutils for dlltool to call: `dlltool` AND `as` AND `ar`. Any
# subset fails - `as` alone still leaves dlltool unable to finish.
#
# THE ORDER MATTERS AS MUCH AS THE FILES:
#
#   third_party/binutils:self-contained:$PATH   <- correct
#   self-contained:third_party/binutils:$PATH   <- hub fails to link
#
# Putting the full mingw64 tree first breaks the hub with `ld: cannot find
# crt2.o`, because it also shadows Rust's `ld` and `gcc`, which know where the
# CRT objects live. So this directory holds ONLY the three tools dlltool needs
# and nothing else - no `ld`, no `gcc`, no `dlltool` from somewhere else. That
# is why it is vendored rather than found: the whole point is that it is small,
# fixed, and does not shadow anything.
BINUTILS="$REPO/third_party/binutils"
if [[ ! -f "$BINUTILS/dlltool.exe" || ! -f "$BINUTILS/as.exe" || ! -f "$BINUTILS/ar.exe" ]]; then
  # Fall back to an MSYS2 install, so a fresh clone still builds here.
  for c in /e/msys64/msys64/mingw64/bin /c/msys64/mingw64/bin /d/msys64/mingw64/bin; do
    if [[ -f "$c/dlltool.exe" && -f "$c/as.exe" && -f "$c/ar.exe" ]]; then
      BINUTILS="$c"; break
    fi
  done
fi
if [[ ! -f "$BINUTILS/dlltool.exe" || ! -f "$BINUTILS/as.exe" || ! -f "$BINUTILS/ar.exe" ]]; then
  echo "hub/build.sh: no binutils for dlltool (looked in $BINUTILS and the usual MSYS2 paths)."
  echo
  echo "  Any crate that generates a Windows import library - which on this GNU"
  echo "  target includes tokio, axum and rust-embed - will fail with the"
  echo "  unhelpful 'dlltool.exe: CreateProcess'. This is NOT a crate problem."
  echo
  echo "  Fix once, from an MSYS2 mingw64:"
  echo "    cp <msys2>/mingw64/bin/{as,ar,dlltool}.exe $REPO/third_party/binutils/"
  exit 1
fi

SELF_CONTAINED="$RUSTROOT/rustup/toolchains/stable-x86_64-pc-windows-gnu/lib/rustlib/x86_64-pc-windows-gnu/bin/self-contained"
# binutils FIRST: dlltool must come from there, while ld/gcc must still come
# from self-contained. See the note above for what happens when that inverts.
if [[ -d "$SELF_CONTAINED" ]]; then
  export PATH="$BINUTILS:$SELF_CONTAINED:$PATH"
else
  export PATH="$BINUTILS:$PATH"
fi

# --- 3. point zmq-sys at the libzmq we ship ---------------------------
#
# NOT the one a crate would download. The plan's §14 is explicit: the hub must
# use the SAME libzmq as the EA side, or CURVE/HWM behaviour can differ between
# the two ends of one link. third_party/zmq-prefix holds exactly that DLL, a
# matching zmq.h, and a linker script that makes `-lzmq` resolve to it.
#
# Since the 4.3.5 upgrade the prefix ships ONE DLL, not two: libsodium is
# linked statically into libzmq.dll, so there is no libsodium.dll any more.
# See hub/README.md.
PREFIX="$REPO/third_party/zmq-prefix"
if [[ ! -f "$PREFIX/lib/libzmq.a" || ! -f "$PREFIX/include/zmq.h" ]]; then
  echo "hub/build.sh: $PREFIX is incomplete"
  echo "  expected include/zmq.h and lib/libzmq.a - see hub/README.md"
  exit 1
fi
# zmq-sys reads this as a native path, so it needs the Windows form.
export LIBZMQ_PREFIX="$(cygpath -w "$PREFIX" 2>/dev/null || echo "$PREFIX")"

# --- 4. build ---------------------------------------------------------
cd "$HERE"

# The DLL is linked BY NAME and resolved at RUN time, so it has to sit next to
# whatever binary is about to run - including the test harness, which cargo puts
# in target/debug/deps and which would otherwise die with a bare
# STATUS_DLL_NOT_FOUND that names no missing file.
#
# Only libzmq.dll: libsodium is statically linked since 4.3.5, and copying a
# stale libsodium.dll here would silently shadow nothing while looking like it
# mattered.
copy_dlls() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  cp -f "$PREFIX/lib/libzmq.dll" "$d/" 2>/dev/null
}

if [[ "${1:-}" == "--test" ]]; then
  mkdir -p "$HERE/target/debug/deps"
  copy_dlls "$HERE/target/debug"
  copy_dlls "$HERE/target/debug/deps"
  #--- anything AFTER --test goes to the harness (e.g. a test-name filter);
  #--- --test itself must not, or cargo reads it as a target selector.
  shift
  exec "$CARGO" test "$@"
fi

"$CARGO" build "$@" || exit 1

PROFILE="debug"
for a in "$@"; do [[ "$a" == "--release" ]] && PROFILE="release"; done
OUT="$HERE/target/$PROFILE"
copy_dlls "$OUT"
if [[ -f "$OUT/copier-hub.exe" ]]; then
  echo
  echo "built: $OUT/copier-hub.exe"
  echo "  with libzmq from: $PREFIX/lib/libzmq.dll"
fi
