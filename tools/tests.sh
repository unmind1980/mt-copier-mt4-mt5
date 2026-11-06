#!/usr/bin/env bash
# ---------------------------------------------------------------------
# tests.sh - run every contract test that needs no broker and no terminal.
#
#   ./tools/tests.sh           # the Python suites (fast, ~20 s)
#   ./tools/tests.sh --all     # + hub unit tests, the four-terminal EA build,
#                              #   and the headless MQL self-test
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

HAS_ZMQ=1
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
  # TOOL-02: Fallback to any python interpreter for lightweight checks (dash, i18n, inputcheck)
  for c in "$HOME/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
           python3 python \
           "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" \
           "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python"; do
    if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
      PY="$c"
      HAS_ZMQ=0
      break
    fi
  done
  if [[ -z "$PY" ]]; then
    echo "no python interpreter found. install python to run tests."
    exit 1
  fi
  echo "NOTE: pyzmq is not installed; running lightweight static and UI validation suites only."
  echo "      install pyzmq to run full ZMQ contract tests: pip install pyzmq"
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
ha_probe_test.py
hub_cluster_test.py
ha_chaos_test.py
hub_tls_test.py
i18n_check.py
dash_check.py
"

echo "== Python contract tests =="
echo "   interpreter: $PY"
rc=0
for t in $PY_TESTS; do
  printf "   %-26s " "$t"
  if [[ "$HAS_ZMQ" -eq 0 && "$t" != "dash_check.py" && "$t" != "i18n_check.py" && "$t" != "inputcheck.py" ]]; then
    echo "SKIPPED (pyzmq not installed)"
    continue
  fi
  if out="$("$PY" "$HERE/$t" 2>&1)"; then
    #--- Capture pass= or explicit summary/verdict line for full test auditability (O-02)
    echo "$out" | grep -E "pass=|dashboard OK|ALL .*PASSED|ALL .*GREEN|VERDICT:|comment\(s\) checked" | tail -1 || echo "ran (no summary line)"
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

# --- 4. the MQL self-test --------------------------------------------
#
# CopierSelfTest is the only suite that exercises the real MQL code; every
# other test here is Python against a re-implementation. It needs a terminal,
# so it runs against the DISPOSABLE portable MT5 (tools/selftest_run.sh starts
# it, drives it, kills it) rather than against anything an operator is using.
#
# It belongs in the slow half and AFTER the EA build, because it consumes the
# .ex5 that build just produced - and its freshness gate fails loudly if that
# binary is older than src/, which is the whole point.
echo
echo "== MQL self-test (headless portable MT5) =="
ST_TARGET="${MTC_SELFTEST_TARGET:-/e/MT5-Portable-Test}"
if [[ ! -f "$ST_TARGET/terminal64.exe" ]]; then
  echo "  skipped: no portable terminal at $ST_TARGET"
  echo "  (set MTC_SELFTEST_TARGET, or see doc/HANDOFF.md 4.6)"
elif [[ ! -f "$ST_TARGET/MQL5/Scripts/CopierSelfTest.ex5" ]]; then
  echo "  skipped: CopierSelfTest.ex5 is not deployed there"
else
  st_out=$(bash "$HERE/selftest_run.sh" --target "$ST_TARGET" 2>&1)
  res=$?
  echo "$st_out" | grep -E "^===========|^selftest: OK" || true
  if [[ $res -ne 0 ]]; then
    echo "$st_out"
    echo "MQL self-test FAILED ($res)"
    rc=1
  fi
fi

echo
if [[ $rc -eq 0 ]]; then echo "EVERYTHING GREEN"; else echo "SOMETHING FAILED"; fi
exit $rc
