#!/usr/bin/env bash
# ---------------------------------------------------------------------
# deploy.sh - copy the copier sources + ZeroMQ runtime into the MT4/MT5
#             terminal data folders.
#
# One source tree, two targets: .mq4 and .mq5 files have identical
# content (the same approach mql-zmq itself uses), so there is no second
# copy of the logic to keep in sync.
#
# WHICH TERMINALS ARE TOUCHED is controlled by tools/targets.conf.
# If that file lists no ids, every terminal found on this machine is
# used. Run ./tools/status.sh first to see the list and the install path
# of each - a data folder can belong to an installation you never open.
#
# Usage:
#   ./tools/deploy.sh            # targets.conf (or all)
#   ./tools/deploy.sh --all      # every terminal found, ignoring targets.conf
#   ./tools/deploy.sh --list     # show what would be touched, change nothing
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SRC="$REPO/src"
ZMQ="$REPO/third_party/mql-zmq-master"

LIST_ONLY=0
SHOW_ALL=0
for a in "$@"; do
  [[ "$a" == "--list" ]] && LIST_ONLY=1
  [[ "$a" == "--all"  ]] && SHOW_ALL=1
done

list_terminals() {
  if [[ $SHOW_ALL -eq 1 ]]; then discover_terminals; else target_terminals; fi
}

# --- The char/uchar fix that mql-zmq needed on modern MetaTrader builds is
# --- already APPLIED UPSTREAM in the 2.0.0 headers (every `char` buffer is
# --- declared `uchar`), so this is now a no-op that prints "already ok".
# --- Kept as a cheap safety net in case helpers are ever re-derived from an
# --- older upstream tarball. It is idempotent either way.
if [[ $LIST_ONLY -eq 0 && -f "$REPO/tools/patch-zmq.py" ]]; then
  PY=""
  for c in python3 python "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
    command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
    [[ -x "$c" ]] && { PY="$c"; break; }
  done
  if [[ -n "$PY" ]]; then
    "$PY" "$REPO/tools/patch-zmq.py" | tail -2
  else
    echo "!! python not found - run tools/patch-zmq.py manually, otherwise"
    echo "!! the ZeroMQ headers will not compile on modern MetaTrader builds"
  fi
fi

echo
echo "=== targets ==="
print_targets
echo

if [[ -z "$(list_terminals)" ]]; then
  echo "no terminals to act on."
  echo "run './tools/status.sh --all' to list what is installed, then put"
  echo "the ids you use into tools/targets.conf"
  exit 1
fi

deploy_into() {
  local id="$1" plat="$2" label="$3"
  local mql; mql="$(resolve_data_dir "$id" "$plat")"
  local ext="mq4"; [[ "$plat" == "MQL5" ]] && ext="mq5"

  if [[ $LIST_ONLY -eq 1 ]]; then
    echo "  [plan] $mql"
    return
  fi

  echo "--> $id  ($plat)  ${label:-unknown install}"
  mkdir -p "$mql/Include/Copier" "$mql/Experts" "$mql/Scripts" \
           "$mql/Libraries" "$mql/Files" "$mql/Include/Zmq" "$mql/Include/Mql"

  # 1) our headers (identical for both platforms)
  cp -f "$SRC/Include/Copier/"*.mqh "$mql/Include/Copier/"

  # 2) EAs and scripts, renamed to the platform's extension
  local f base
  for f in "$SRC/Experts/"*.mq4; do
    base="$(basename "$f" .mq4)"
    cp -f "$f" "$mql/Experts/$base.$ext"
  done
  for f in "$SRC/Scripts/"*.mq4; do
    base="$(basename "$f" .mq4)"
    cp -f "$f" "$mql/Scripts/$base.$ext"
  done

  # 2b) PRUNE scripts that no longer exist in src/Scripts.
  #
  # Copying only ADDS files. A script retired upstream therefore stayed in
  # every terminal forever - and because compile.sh compiles whatever it
  # finds in Scripts/, the retired script kept being rebuilt and redeployed
  # on every run. That is how CopierKeygen survived its own deletion and
  # still reported "ok" in the build summary.
  #
  # The match is deliberately narrow: only Copier<Name>.{mq4,mq5,ex4,ex5}
  # inside Scripts/, so nothing the operator put there by hand is removed.
  local sbase
  for f in "$mql/Scripts/"Copier*.mq4 "$mql/Scripts/"Copier*.mq5 "$mql/Scripts/"Copier*.ex4 "$mql/Scripts/"Copier*.ex5; do
    [[ -f "$f" ]] || continue
    sbase="$(basename "$f")"; sbase="${sbase%.*}"
    if [[ ! -f "$SRC/Scripts/$sbase.mq4" && ! -f "$SRC/Scripts/$sbase.mq5" ]]; then
      rm -f "$f"
      echo "    pruned retired script: Scripts/$(basename "$f")"
    fi
  done

  # 3) mql-zmq headers
  if [[ -d "$ZMQ/Include" ]]; then
    cp -rf "$ZMQ/Include/Zmq" "$mql/Include/"
    cp -rf "$ZMQ/Include/Mql" "$mql/Include/"
  else
    echo "    !! mql-zmq not found - run tools/fetch-deps.sh first"
  fi

  # 4) ZeroMQ runtime DLLs (MT4 = 32-bit, MT5 = 64-bit)
  #
  # NOTE the name mapping: mql-zmq ships these under Library/MT4 and
  # Library/MT5, NOT Library/MQL4 and Library/MQL5. Using the platform
  # folder name here silently copies nothing - the guard below fails, the
  # EA compiles fine, and it only breaks at runtime with "DLL not found".
  local zdir
  if [[ "$plat" == "MQL5" ]]; then zdir="MT5"; else zdir="MT4"; fi
  if [[ -d "$ZMQ/Library/$zdir" ]]; then
    for dll in "$ZMQ/Library/$zdir/"*.dll; do
      [[ -f "$dll" ]] || continue
      dst="$mql/Libraries/$(basename "$dll")"
      if [[ -f "$dst" ]] && cmp -s "$dll" "$dst"; then
        continue
      fi
      cp -f "$dll" "$mql/Libraries/" 2>/dev/null || true
    done
    echo "    dlls: $(ls "$ZMQ/Library/$zdir" | tr '\n' ' ')"
    #--- libsodium.dll was a SEPARATE dependency up to libzmq 4.2.x. From
    #--- 4.3.5 it is linked statically, so leaving an old copy behind would
    #--- be a stale file that no longer matches libzmq.dll. Remove it if a
    #--- previous deploy put one there.
    if [[ -f "$mql/Libraries/libsodium.dll" ]]; then
      rm -f "$mql/Libraries/libsodium.dll"
      echo "    removed stale libsodium.dll (not needed since libzmq 4.3.5)"
    fi
  else
    echo "    !! $ZMQ/Library/$zdir not found - run tools/fetch-deps.sh"
  fi
}

while IFS='|' read -r id plat label; do
  [[ -n "$id" ]] || continue
  deploy_into "$id" "$plat" "$label"
done < <(list_terminals)

echo
if [[ $LIST_ONLY -eq 1 ]]; then
  echo "(dry run - nothing was written)"
  exit 0
fi

echo "Done. In MetaEditor press F7 on each file to compile, or run:"
echo "  ./tools/compile.sh"
echo
echo "REMINDERS"
echo "  * MT4 terminals are 32-bit -> use Library/MT4 DLLs (handled above)."
echo "  * A 32-bit MT5 needs the 32-bit DLLs and __X64__ commented out in"
echo "    Include/Mql/Lang/Native.mqh."
echo "  * No Visual C++ runtime is needed any more (MinGW-w64 build, libsodium"
echo "    linked statically) - libzmq.dll is self-contained."
echo "  * Enable 'Allow DLL imports' in the EA properties, and AutoTrading."
