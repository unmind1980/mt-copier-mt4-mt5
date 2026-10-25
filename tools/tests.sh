#!/usr/bin/env bash
# ---------------------------------------------------------------------
# tests.sh - run every contract test that needs no broker and no terminal.
#
#   ./tools/tests.sh           # the Python suites (fast, ~20 s)
#   ./tools/tests.sh --all     # + hub unit tests + the four-terminal EA build
#
# WHY THIS EXISTS
# ================
# The Python suites were being run one at a time with a hand-typed interpreter
# path, which is how `snapshot_receipt_test.py` went for days without being
# wired into anything. A test nobody runs is a test that does not exist.
#
# It also settles the interpreter question that the README kept getting wrong:
# `python` IS on PATH here, but it is the BASE interpreter, and pyzmq lives in
# the isolated venv. So `python tools/hub_positions_test.py` dies with
# ModuleNotFoundError - which reads like a broken test rather than a broken
# command. This script tries the venv FIRST for that reason.
# ---------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# --- 1. an interpreter that can actually import zmq -------------------
# Order matters. The venv is known-good here, so it goes first; the PATH
# candidates only follow so the script still works somewhere that has pyzmq
# installed in the base interpreter.
#
# PYTHON=/full/path/to/python skips the search entirely - which is the escape
# hatch when none of the candidates has pyzmq and the advice below is not it.
if [[ -n "${PYTHON:-}" ]]; then
  if command -v "$PYTHON" >/dev/null 2>&1 || [[ -x "$PYTHON" ]]; then
    if "$PYTHON" -c "import zmq" >/dev/null 2>&1; then
      PY="$PYTHON"
    else
      echo "PYTHON=$PYTHON cannot import zmq - it is the interpreter, not the package."
      echo "run: $PYTHON -m pip install pyzmq"
      exit 1
    fi
  else
    echo "PYTHON=$PYTHON is not executable."
    exit 1
  fi
fi

PY="${PY:-}"
for c in "$HOME/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
         python3 python \
         "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" \
         "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python"; do
  [[ -n "$PY" ]] && break
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
    if "$c" -c "import zmq" >/dev/null 2>&1; then PY="$c"; break; fi
  fi
done

if [[ -z "$PY" ]]; then
  echo "no interpreter with pyzmq found."
  echo "install it once, then re-run:"
  echo "  pip install pyzmq"
  echo "or point me at one:"
  echo "  PYTHON=/full/path/to/python ./tools/tests.sh"
  exit 1
fi

# --- 2. the suites -----------------------------------------------------
#--- NOTE on what is NOT here: zmq_bidir_test.py, zmq_fanout_test.py and
#--- zmq_conflate_size_test.py each need their own hub/sender process and a
#--- free port, so they are run by hand against a live deployment rather than
#--- in this sweep. zmq_topic_test.py IS here because it is self-contained.
PY_TESTS="
snapshot_receipt_test.py
snapshot_repair_test.py
modify_event_test.py
hub_stat_path_test.py
hub_positions_test.py
hub_api_test.py
hub_config_test.py
hub_commands_test.py
hub_alerts_test.py
hub_users_test.py
hub_curve_test.py
hub_notifications_test.py
hub_audit_rotation_test.py
curve_keyfile_test.py
hub_proto_test.py
inputcheck.py
zmq_topic_test.py
dash_check.py
"

echo "== Python contract tests =="
echo "   interpreter: $PY"
rc=0
for t in $PY_TESTS; do
  printf "   %-26s " "$t"
  if out="$("$PY" "$HERE/$t" 2>&1)"; then
    #--- dash_check.py reports "dashboard OK: ..." rather than "pass=", and it
    #--- is the only thing that catches a JS syntax error in dashboard.html -
    #--- which blanks the whole page - so it must be in this sweep.
    echo "$out" | grep -E "pass=|dashboard OK" || echo "ran (no summary line)"
  else
    echo "FAILED"
    echo "$out" | tail -12
    rc=1
  fi
done

printf "   %-26s " "toolchain_check.py"
if out="$("$PY" "$HERE/toolchain_check.py" 2>&1)"; then
  echo "$out" | grep -E "TOOLCHAIN OK" || { echo "FAILED"; echo "$out" | tail -8; rc=1; }
else
  echo "FAILED"
  echo "$out" | tail -8
  rc=1
fi

if [[ "${1:-}" != "--all" ]]; then
  echo
  if [[ $rc -eq 0 ]]; then echo "ALL PYTHON SUITES GREEN"; else echo "SOME SUITES FAILED"; fi
  exit $rc
fi

# --- 3. the optional slow half ----------------------------------------
#
# The hub RELEASE build is in here on purpose. The Python suites cannot catch a
# broken toolchain - see the note in toolchain_check.py about why - and the
# release binary is the artifact that gets deployed, so it is the only thing
# that proves "this machine can still build what ships".
echo
echo "== hub release build =="
hub_build_out=$(bash "$REPO/hub/build.sh" --release 2>&1)
res=$?
echo "$hub_build_out" | grep -E "built:" || true
if [[ $res -ne 0 ]] || echo "$hub_build_out" | grep -Eq "error:|CreateProcess"; then
  echo "$hub_build_out"
  echo "hub release build FAILED ($res)"
  rc=1
fi

echo
echo "== hub unit tests =="
hub_test_out=$(bash "$REPO/hub/build.sh" --test 2>&1)
res=$?
echo "$hub_test_out" | grep -E "test result:" || true
if [[ $res -ne 0 ]] || echo "$hub_test_out" | grep -Eq "FAILED"; then
  echo "$hub_test_out"
  echo "hub unit tests FAILED ($res)"
  rc=1
fi

echo
echo "== EA build (four terminals) =="
ea_build_out=$(bash "$HERE/build.sh" 2>&1)
res=$?
echo "$ea_build_out" | grep -E "ALL GREEN" || true
if [[ $res -ne 0 ]] || echo "$ea_build_out" | grep -Eq "[1-9][0-9]* (file\(s\) with errors|problem\(s\) across)"; then
  echo "$ea_build_out"
  echo "EA build FAILED ($res)"
  rc=1
fi

echo
if [[ $rc -eq 0 ]]; then echo "EVERYTHING GREEN"; else echo "SOMETHING FAILED"; fi
exit $rc
