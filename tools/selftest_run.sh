#!/usr/bin/env bash
# ---------------------------------------------------------------------
# selftest_run.sh - run CopierSelfTest in a HEADLESS portable MT5 and
#                   gate on the result.
#
# WHY THIS EXISTS
# ---------------
# `CopierSelfTest` is the only suite that exercises the real MQL code - every
# other test is Python against a re-implementation. It cannot live in
# tools/tests.sh because an MQL script only runs inside a terminal, so it was
# a manual step, and a manual step is a step that eventually stops happening:
# in November 2026 six of its assertions were found red, five of them from the
# day they were written. Three weeks of green builds over a broken gate.
#
# So: a disposable portable terminal, started with /config: and killed
# afterwards. Nothing an operator uses is touched - this terminal trades
# nothing, runs no EA, and is never the one a human is looking at.
#
# WHAT IT CHECKS
#   1. FRESHNESS   the .ex5 must be newer than every .mq4/.mqh in src/, and
#                  the deployed .mq5 must not be older than its source. A
#                  stale binary would happily report the last version's result.
#   2. ISOLATION   refuses to run if a terminal from that folder is already
#                  up (a second instance would attach to it and ignore the
#                  /config:).
#   3. RESULT      waits for the summary line, parses pass/fail, and exits
#                  non-zero unless fail=0.
#   4. BASELINE    optionally refuses a pass COUNT below the recorded one, so
#                  deleting a red assertion cannot turn the gate green.
#
# Usage:
#   tools/selftest_run.sh                 # run, print result, exit 0/1
#   tools/selftest_run.sh --verbose       # also echo the log as it grows
#   tools/selftest_run.sh --keep          # leave the terminal open (debug)
#   tools/selftest_run.sh --target PATH   # a different portable terminal
#   tools/selftest_run.sh --timeout 300
#   tools/selftest_run.sh --no-freshness  # skip check 1 (rarely wanted)
#
# Exit codes:
#   0  pass=N fail=0 (and >= baseline)
#   1  the self-test ran and FAILED
#   2  could not run: missing binary, stale build, terminal already up
#   3  timed out waiting for the summary line
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

#--- The disposable terminal. Kept OUT of the build-host seat in
#--- tools/targets.conf: it only receives the .ex5 the first MT5 target built.
TARGET="${MTC_SELFTEST_TARGET:-/e/MT5-Portable-Test}"
TIMEOUT=180
KEEP=0
VERBOSE=0
FRESH=1
#--- The recorded assertion count for MT5. Deleting a red assertion is not a
#--- fix, and without this check it would look exactly like a green run.
#--- Raise it DELIBERATELY when you add assertions; never lower it to make a
#--- build pass. (MT4 reports a few less: the platforms differ by ifdef'd
#--- assertions, which is why this is a constant here rather than derived.)
#--- 962 = 919 + 43 added by round 13 deep audit: CopierPipOf JPY/DJ precision,
#--- CopierExtractSessionSpan cross-midnight & t>86400, CopierNormalizeLot minLot
#--- precision & NaN/Inf rejection, CopierRisk cash-flow symmetry, CopierPanel
#--- truncation & cleanup, CopierEventPump OnEvent gate, CopierPeerTable probe/SeenAt.
BASELINE=985

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --baseline)     BASELINE="$2"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    --verbose|-v)   VERBOSE=1; shift ;;
    --no-freshness) FRESH=0; shift ;;
    -h|--help)      sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

ROOT="$TARGET"
TERM_EXE="$ROOT/terminal64.exe"
MQL="$ROOT/MQL5"
EX5="$MQL/Scripts/CopierSelfTest.ex5"
MQ5="$MQL/Scripts/CopierSelfTest.mq5"
LOG="$MQL/Files/copier_selftest.log"
INI="$ROOT/Config/selftest.ini"
#--- [StartUp] Symbol= makes MetaTrader OPEN A CHART, and the terminal saves it
#--- into the active profile. Run the gate twenty times and the chart bar has
#--- twenty identical EURUSD windows, forever - observed, 17 of them.
#---
#--- `[Charts] ProfileLast=<name>` in the /config: file does NOT redirect this:
#--- tested with the folder pre-created and MT5 still wrote to Default. So the
#--- active profile is READ from Config/common.ini and its saved charts are
#--- cleared before each launch. One chart in, one chart out.
#---
#--- This is safe only because the terminal is dedicated to the gate (see
#--- targets.conf): its profile holds nothing but the chart this script opens.
#--- It is still narrowly scoped - only chart*.chr and order.wnd inside the
#--- profile folder - never a recursive delete.
active_profile() {
  local cfg="$ROOT/Config/common.ini" p=""
  if [[ -f "$cfg" ]]; then
    p="$(sed -n 's/^ProfileLast=//p' "$cfg" | head -1 | tr -d '\r')"
  fi
  [[ -n "$p" ]] || p="Default"
  printf '%s' "$p"
}
PROFILE_NAME="$(active_profile)"
PROFILE_DIR="$MQL/Profiles/Charts/$PROFILE_NAME"

say()  { printf '%s\n' "$*"; }
die()  { printf '!! %s\n' "$*" >&2; exit 2; }

#--- processes belonging to THIS terminal folder. ps -W is MSYS's view of
#--- native processes: $4 is the Windows PID (the one taskkill wants), and
#--- the command column carries the install path, which is what separates
#--- this instance from the other terminals on the machine.
pids_for() {
  local needle="$1"
  ps -W 2>/dev/null | awk -v n="$needle" '
    index(tolower($0), tolower(n)) > 0 { print $4 }
  '
}

kill_all() {
  local needle="$1" p
  for p in $(pids_for "$needle"); do
    taskkill //F //PID "$p" >/dev/null 2>&1 || true
  done
}

#--- python is only needed to hide the terminal's windows; without it the run
#--- still works, it is just visible on screen.
find_python() {
  local c
  for c in "${PYTHON:-}" python3 python \
           "C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
           "/c/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
           "$HOME/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
           "$HOME/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"; do
    [[ -n "$c" ]] || continue
    if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

[[ -f "$TERM_EXE" ]] || die "no terminal64.exe at $TERM_EXE
   Pass --target <portable folder>, or add one to tools/targets.conf."
[[ -d "$MQL" ]] || die "no MQL5 folder at $MQL (is this a portable install?)"
[[ -f "$EX5" ]] || die "CopierSelfTest.ex5 is not deployed to $MQL/Scripts.
   Run:  tools/deploy.sh && tools/compile.sh"
[[ -f "$MQ5" ]] || die "CopierSelfTest.mq5 is not deployed to $MQL/Scripts.
   Run:  tools/deploy.sh"

#--- 1. freshness -----------------------------------------------------------
if [[ $FRESH -eq 1 ]]; then
  newer_src="$(find "$REPO/src" \( -name '*.mq4' -o -name '*.mqh' \) -newer "$EX5" -print -quit 2>/dev/null)"
  if [[ -n "$newer_src" ]]; then
    die "the deployed self-test binary is STALE.
   $EX5 is older than
   $newer_src
   A stale .ex5 reports the PREVIOUS version's result. Run:
     tools/deploy.sh && tools/compile.sh"
  fi
  if [[ "$REPO/src/Scripts/CopierSelfTest.mq4" -nt "$MQ5" ]]; then
    die "the deployed source is STALE (src/ is newer than $MQ5).
   Run:  tools/deploy.sh && tools/compile.sh"
  fi
fi

#--- 2. isolation -----------------------------------------------------------
needle="$(basename "$ROOT")/terminal64"
already="$(pids_for "$needle")"
if [[ -n "$already" ]]; then
  die "a terminal from $ROOT is already running (pid $already).
   A second launch would attach to it and ignore /config:, so the run would
   silently do nothing. Close that terminal, or use --target on another one."
fi

#--- 3. config --------------------------------------------------------------
#--- [StartUp] Script= runs the script on the chart it opens. A Symbol is
#--- given explicitly: a portable install can start with no chart at all, and
#--- then the script would never be attached. EURUSD exists on the demo server
#--- this instance auto-logs into, and the self-test does not care which.
mkdir -p "$ROOT/Config" "$MQL/Files"
cat > "$INI" <<'INIEOF'
; Generated by tools/selftest_run.sh - safe to delete.
; Starts CopierSelfTest on a chart and leaves the terminal running; the
; runner kills the process once the summary line appears in the log.
;
; [Experts] AllowDllImport=1 is REQUIRED, not a convenience: the self-test
; includes CopierCodec -> <Zmq/Z85.mqh>, and that header does
; `#import "libzmq.dll"` for zmq_z85_encode/decode. With DLL imports off the
; script does not fail an assertion - it never starts at all, and the only
; trace is "DLL loading is not allowed" in the Experts log:
;     script CopierSelfTest (EURUSD,H1) loaded successfully
;     initializing of CopierSelfTest (EURUSD,H1) failed with code 0
; which is why the runner also prints the terminal log tail on a timeout.
; The setting lives in the terminal's encrypted settings.ini, so it cannot be
; edited there; /config: accepts it as a startup option instead.
[Common]
NewsEnable=0
[Experts]
Enabled=1
AllowDllImport=1
[StartUp]
Symbol=EURUSD
Period=H1
Script=CopierSelfTest
INIEOF

INI_WIN="$INI"
if command -v cygpath >/dev/null 2>&1; then INI_WIN="$(cygpath -w "$INI")"; fi

#--- clear the run's own profile so this launch starts from one chart, not from
#--- every chart the gate has ever opened. Deliberately narrow: only chart files
#--- and the window layout INSIDE a folder this script owns by name - never a
#--- recursive delete of anything else.
case "$PROFILE_DIR" in
  "$MQL"/Profiles/Charts/*)
    if [[ -d "$PROFILE_DIR" ]]; then
      rm -f "$PROFILE_DIR"/chart*.chr "$PROFILE_DIR"/order.wnd 2>/dev/null
    fi
    ;;
  *)
    die "refusing to clean an unexpected profile path: $PROFILE_DIR"
    ;;
esac

#--- a stale log would be read as this run's result
rm -f "$LOG" 2>/dev/null
if [[ -f "$LOG" ]]; then
  mv -f "$LOG" "$LOG.old" 2>/dev/null || die "cannot clear $LOG (still open?)"
fi

say "selftest: $TERM_EXE"
say "selftest: waiting up to ${TIMEOUT}s for $LOG"

#--- 4. run -----------------------------------------------------------------
#--- cd into the install folder so /portable resolves to it, and so any
#--- relative path in the ini lands next to terminal64.exe.
( cd "$ROOT" && ./terminal64.exe /portable "/config:$INI_WIN" >/dev/null 2>&1 & )

#--- MetaTrader shows a Login dialog whenever it cannot authorise the account
#--- (expired demo, an account another terminal is already using, or a session
#--- it lost because the last run was killed). The dialog does not stop the
#--- script - the chart keeps running - but it sits on screen and needs a
#--- click, which is exactly what a headless gate must not require. There is no
#--- switch for it and the setting is in the encrypted settings.ini, so the
#--- window is hidden instead. Best effort: if python is missing, the run is
#--- simply visible.
HIDER_PID=""
PY="$(find_python || true)"
TERM_PID=""
for _ in $(seq 1 40); do
  TERM_PID="$(pids_for "$needle" | head -1)"
  [[ -n "$TERM_PID" ]] && break
  sleep 0.5
done
if [[ -n "$PY" && -n "$TERM_PID" && -f "$HERE/win_hide.py" ]]; then
  "$PY" "$HERE/win_hide.py" --pid "$TERM_PID" --seconds "$((TIMEOUT + 30))" --quiet &
  HIDER_PID=$!
fi

started=$SECONDS
done_line=""
while (( SECONDS - started < TIMEOUT )); do
  if [[ -f "$LOG" ]] && grep -q '^===========' "$LOG" 2>/dev/null; then
    done_line="$(grep '^===========' "$LOG" | tail -1)"
    break
  fi
  if [[ $VERBOSE -eq 1 && -f "$LOG" ]]; then
    tail -1 "$LOG" 2>/dev/null | sed 's/^/  | /'
  fi
  sleep 1
done

if [[ -n "$HIDER_PID" ]]; then
  kill "$HIDER_PID" >/dev/null 2>&1 || true
fi

if [[ $KEEP -eq 0 ]]; then
  kill_all "$needle"
  #--- MT5 spawns its editor to recompile the MQL5 folder when it changed;
  #--- that child outlives the terminal and would hold files open.
  kill_all "$(basename "$ROOT")/MetaEditor"
fi

#--- 5. verdict -------------------------------------------------------------
if [[ -z "$done_line" ]]; then
  say ""
  say "TIMEOUT: no summary line after ${TIMEOUT}s."
  if [[ -f "$LOG" ]]; then
    say "--- last lines of $LOG ---"
    tail -8 "$LOG" | sed 's/^/  /'
  else
    say "the log was never created - the script did not run to completion."
  fi
  #--- The reason is almost never in copier_selftest.log (the script may never
  #--- have reached its first Write): it is in the terminal's own log, which
  #--- says "DLL loading is not allowed", "cannot open file" and the like.
  #--- That log is written in a mix of ANSI and UTF-16, hence tr -d '\000'.
  tlog="$(ls -t "$ROOT"/logs/*.log 2>/dev/null | head -1)"
  if [[ -n "$tlog" ]]; then
    say "--- terminal log: $tlog (script/expert lines) ---"
    tr -d '\000' < "$tlog" | grep -iE "script|expert|dll|error|failed" | tail -12 | sed 's/^/  /'
  fi
  exit 3
fi

pass="$(printf '%s' "$done_line" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
fail="$(printf '%s' "$done_line" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')"
pass="${pass:-0}"; fail="${fail:-0}"

say ""
say "$done_line"

if [[ "$fail" -gt 0 ]]; then
  say ""
  say "--- failing assertions ---"
  grep '^FAIL' "$LOG" | sed 's/^/  /'
  exit 1
fi

if [[ "$BASELINE" -gt 0 && "$pass" -lt "$BASELINE" ]]; then
  say ""
  say "!! pass count DROPPED: $pass < baseline $BASELINE."
  say "   Assertions were removed. Deleting a red test is not a fix - either"
  say "   restore it, or lower the baseline deliberately (--baseline N) and say"
  say "   why in the commit message."
  exit 1
fi

say "selftest: OK ($pass assertions, 0 failures)"
exit 0
