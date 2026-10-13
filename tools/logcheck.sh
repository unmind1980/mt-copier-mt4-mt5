#!/usr/bin/env bash
# ---------------------------------------------------------------------
# logcheck.sh - find every copier log on the configured terminals and
#               turn it into a verdict (see tools/logcheck.py).
#
# This is how you run the pilot's destructive checks without squinting at
# two log files. The failures worth catching are mostly the ABSENCE of a
# line, which is exactly what the eye skips.
#
# Usage:
#   ./tools/logcheck.sh                 # all configured terminals
#   ./tools/logcheck.sh --all           # every terminal found
#   ./tools/logcheck.sh path/to/a.log   # specific files
#   ./tools/logcheck.sh --json          # machine-readable
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SHOW_ALL=0
EXPLICIT=()
PASSTHRU=()
for a in "$@"; do
  case "$a" in
    --all)  SHOW_ALL=1 ;;
    --json) PASSTHRU+=("$a") ;;
    --*)    PASSTHRU+=("$a") ;;
    *)      EXPLICIT+=("$a") ;;
  esac
done

#--- find python: this is the one dependency the checker has
PY=""
for c in python3 python "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
  command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
  [[ -x "$c" ]] && { PY="$c"; break; }
done
if [[ -z "$PY" ]]; then
  echo "python not found - needed by tools/logcheck.py"
  exit 1
fi

FILES=()
if [[ ${#EXPLICIT[@]} -gt 0 ]]; then
  FILES=("${EXPLICIT[@]}")
else
  list_terminals() {
    if [[ $SHOW_ALL -eq 1 ]]; then discover_terminals; else target_terminals; fi
  }
  while IFS='|' read -r id plat label; do
    [[ -n "$id" ]] || continue
    dir="$(resolve_data_dir "$id" "$plat")"
    [[ -d "$dir/Files" ]] || continue
    #--- logs, plus BOTH state files. They are the authoritative records and
    #--- they survive log rotation, so the checker prefers them over anything
    #--- derived from logs:
    #---   copier_sender_*.st   what a sender SHOULD have open
    #---   copier_receiver.st   what a receiver actually DOES have open
    #--- Without the receiver's file the checker falls back to the receiver's
    #--- log, and a rotated-away generation makes already-closed positions
    #--- look stranded.
    while IFS= read -r f; do
      [[ -n "$f" ]] && FILES+=("$f")
    done < <(ls -1 "$dir/Files"/copier_*.log \
                    "$dir/Files"/copier_sender_*.st \
                    "$dir/Files"/copier_receiver.st 2>/dev/null)
  done < <(list_terminals)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no copier logs found."
  echo "the logs live in <terminal data folder>\\<PLAT>\\Files\\copier_*.log"
  echo "and only appear once the EAs have actually run with LogLevel>=2."
  exit 1
fi

"$PY" "$HERE/logcheck.py" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" "${FILES[@]}"
