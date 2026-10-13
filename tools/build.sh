#!/usr/bin/env bash
# ---------------------------------------------------------------------
# build.sh - deploy the sources, THEN compile them. One command.
#
# This exists because the two steps have an ORDER, and the order is not
# obvious from their names:
#
#   deploy.sh    copies src/ into each terminal's data folder
#   compile.sh   compiles whatever source is ALREADY in that folder
#
# compile.sh never looks at src/. Run it first and it builds the PREVIOUS
# revision; deploy.sh then copies the new sources in WITHOUT recompiling,
# and every terminal ends up running code one revision old while still
# reporting "4/4 compiled". That happened here once - ./tools/status.sh
# now reports it as FRESH=no.
#
# Usage:
#   ./tools/build.sh            # the terminals in tools/targets.conf
#   ./tools/build.sh --all      # every terminal found on this machine
#
# Extra arguments are forwarded to BOTH steps, so --all means the same
# thing to each of them.
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 0/3  input comments ======================================"
# The text after `//` on an `input` line IS the label MetaTrader prints in the
# Inputs dialog, and the column is a fixed width - anything longer is cut off
# with no ellipsis and no tooltip. A sentence that stops mid-word is how an
# operator configures the EA wrongly, and the author never sees it, because in
# the source the line is complete. So it is checked here, before it ships.
#
# Not fatal when Python is missing: the check is a convenience, and refusing to
# build over an absent interpreter would be worse than the problem it guards.
PY_CHECK=""
for c in python3 python \
         "$HOME/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
         "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
  command -v "$c" >/dev/null 2>&1 && { PY_CHECK="$c"; break; }
  [[ -x "$c" ]] && { PY_CHECK="$c"; break; }
done
if [[ -n "$PY_CHECK" ]]; then
  if ! "$PY_CHECK" "$HERE/inputcheck.py"; then
    echo
    echo "input comment check FAILED - fix the lines above before building."
    echo "The comment is what the operator reads in the Inputs dialog; a"
    echo "truncated one is a wrong configuration waiting to happen."
    exit 1
  fi
else
  echo "  (python not found - skipped; run tools/inputcheck.py by hand)"
fi

echo
echo "== 1/3  deploy =============================================="
if ! bash "$HERE/deploy.sh" "$@"; then
  echo
  echo "deploy.sh failed - stopping BEFORE compile, so the terminals are"
  echo "never left with sources newer than their binaries."
  exit 1
fi

echo
echo "== 2/3  compile ============================================="
bash "$HERE/compile.sh" "$@"
rc=$?

echo
if [[ $rc -eq 0 ]]; then
  echo "Build complete - binaries are in every target's Experts/ and Scripts/."
  echo
  echo "STILL REQUIRED, AND NOT A COMPILE STEP: MetaTrader does NOT reload an"
  echo "EA whose .ex4/.ex5 was replaced by an external compiler. Re-attach the"
  echo "EA on each chart (or restart the terminal) or the running instance"
  echo "keeps executing the old code. Confirm with the 'build=...' stamp the"
  echo "EA prints at startup."
fi
exit $rc
