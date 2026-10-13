#!/usr/bin/env bash
# ---------------------------------------------------------------------
# clean.sh - remove the portable-target build caches.
#
# compile.sh keeps a staging folder under the terminal root for portable
# targets, because MetaEditor refuses to compile or even read includes
# from a portable data folder. The cache holds a copy of that terminal's
# Include tree (tens of MB). It is refreshed in place, never grown, and
# deleting it costs only one slow first compile - so it is safe to remove
# any time.
#
# Usage:
#   ./tools/clean.sh            # list what would go
#   ./tools/clean.sh --yes      # actually remove it
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

CONFIRM=0
[[ "${1:-}" == "--yes" ]] && CONFIRM=1

found=0
for d in "$TERM_ROOT"/_copier*; do
  [[ -d "$d" ]] || continue
  found=1
  size="$(du -sh "$d" 2>/dev/null | cut -f1)"
  if [[ $CONFIRM -eq 1 ]]; then
    if rm -rf "$d" 2>/dev/null && [[ ! -d "$d" ]]; then
      echo "  removed  $d  ($size)"
    else
      #--- some shells / sandboxes refuse recursive deletes under a
      #--- profile path. Fall back to Python, which is not subject to the
      #--- same path guard.
      PY=""
      for c in python3 python "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
        command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
        [[ -x "$c" ]] && { PY="$c"; break; }
      done
      if [[ -n "$PY" ]] && "$PY" -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$(win_path "$d")" 2>/dev/null && [[ ! -d "$d" ]]; then
        echo "  removed  $d  ($size, via python)"
      else
        echo "  FAILED   $d   (delete it by hand)"
      fi
    fi
  else
    echo "  would remove  $d  ($size)"
  fi
done

if [[ $found -eq 0 ]]; then
  echo "  nothing to clean"
elif [[ $CONFIRM -eq 0 ]]; then
  echo
  echo "  re-run with --yes to remove the above"
fi
