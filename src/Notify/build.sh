#!/usr/bin/env bash
# ---------------------------------------------------------------------
# build.sh - Compile copier_notify.dll (32-bit for MT4 and 64-bit for MT5)
# ---------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

BIN32="/e/msys64/msys64/mingw32/bin"
BIN64="/e/msys64/msys64/mingw64/bin"

OUT32="$REPO/third_party/mql-zmq-master/Library/MT4/copier_notify.dll"
OUT64="$REPO/third_party/mql-zmq-master/Library/MT5/copier_notify.dll"

echo "Building 32-bit copier_notify.dll (MT4)..."
PATH="$BIN32:$PATH" "$BIN32/gcc.exe" -shared -O3 -s -static -static-libgcc \
  -Wall -Wextra \
  "$HERE/copier_notify.c" \
  -o "$OUT32" \
  -luser32 -lkernel32

echo "Building 64-bit copier_notify.dll (MT5)..."
PATH="$BIN64:$PATH" "$BIN64/gcc.exe" -shared -O3 -s -static -static-libgcc \
  -Wall -Wextra \
  "$HERE/copier_notify.c" \
  -o "$OUT64" \
  -luser32 -lkernel32

echo "Done. Built:"
ls -lh "$OUT32" "$OUT64"
