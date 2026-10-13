#!/usr/bin/env bash
# ---------------------------------------------------------------------
# compile.sh - compile every deployed copier file, for every target in
#              tools/targets.conf, and print the logs.
#
# Five things learned the hard way and baked in:
#
#  1. MetaEditor resolves <Angle/Bracket.mqh> includes against ITS OWN
#     data folder, not against the file being compiled, so /include: is
#     mandatory when the editor and the terminal are different installs.
#
#  2. /log: needs an explicit file path; a bare /log writes nothing you
#     can find reliably.
#
#  3. A MetaEditor that ships with a PORTABLE install can refuse the
#     command line outright - it exits without writing a log or a binary,
#     and without an error. Another install's editor compiles the same
#     file happily. So editors are tried in order until one works.
#
#  4. MetaEditor only compiles reliably when the SOURCE is under the
#     standard %APPDATA%\MetaQuotes\Terminal root. For a portable target
#     the sources are staged there, compiled, and the binaries copied
#     back. See prepare_build_dir() in lib.sh.
#
#  5. MetaEditor.exe returns from the command line IMMEDIATELY (it is a
#     GUI app) and compiles in a background process. The log therefore
#     appears some time AFTER the process exits, and how long varies with
#     both the file and the machine. Polling for the log is the only
#     correct way to wait - and the budget must be generous, because the
#     MT5 compiler is genuinely slow on large sources (measured: ~5-10 ms
#     per source line, so a 4300-line EA takes ~26 s). See
#     CP_COMPILE_TIMEOUT_TICKS below; the old 10 s budget is what made a
#     healthy compile look like a hang.
#
# COMPILE ONCE PER PLATFORM, THEN COPY
# ------------------------------------
# Every MT4 target compiles the SAME .mq4 sources, and every MT5 target the
# same .mq5 ones. There is no per-terminal branching anywhere in this code
# base - the platform is the only variable, and it is chosen by the file
# extension.
#
# So compiling CopierReceiver once per TERMINAL is compiling identical bytes
# to identical machine code over and over. On this machine that is 16
# compiles where 4 would do, and because the MT5 compiler is the slow one
# the waste is almost entirely MT5 time: measured 27 s for CopierReceiver
# and 11 s for CopierSender, done twice.
#
# The binaries are NOT byte-identical when compiled separately (MetaEditor
# encrypts the code section per run, so two compiles of one source differ in
# ~98% of their bytes) - but they are equivalent, and a COPIED binary is
# provably fine because this script already relies on exactly that for
# portable targets: the .ex5 is compiled in a staging folder and copied into
# the portable data folder, and MT5 runs it. Copying between two terminals
# of the same platform is the same operation.
#
# So: compile once per platform (first target of that platform wins as the
# "build host"), then copy the resulting binaries to every other target of
# that platform. Fall back to a real compile per target when --no-reuse is
# passed, or when no earlier target of that platform compiled successfully.
#
# The reuse key includes the PLATFORM, so an .ex4 is only ever copied to
# another MT4 target and an .ex5 only to another MT5 one.
#
# Usage:
#   ./tools/compile.sh            # targets.conf (or all); reuse across targets
#   ./tools/compile.sh --all
#   ./tools/compile.sh --no-reuse # compile per target (old behaviour)
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SHOW_ALL=0
REUSE=1
for arg in "$@"; do
  case "$arg" in
    --all)      SHOW_ALL=1 ;;
    --no-reuse) REUSE=0 ;;
  esac
done
list_terminals() {
  if [[ $SHOW_ALL -eq 1 ]]; then discover_terminals; else target_terminals; fi
}

#--- How long to wait for a compiler log, in 0.25 s ticks.
#---
#--- 240 ticks = 60 s. Chosen from measurement, not taste: the slowest real
#--- file here (CopierReceiver.mq5, 4323 lines) takes ~27 s on this machine,
#--- and a cold first run on a loaded machine can be slower still. The old
#--- budget of 20 ticks (10 s) was under a quarter of that, so it expired
#--- while the compiler was still working - and report() then printed
#--- "no compiler log produced", which reads as a failure but was in fact
#--- the script giving up.
CP_COMPILE_TIMEOUT_TICKS=240

#--- Binaries produced for a platform in this run, keyed "MQL4:CopierSender"
#--- -> absolute path of the built .ex4/.ex5 in the build host's folder.
#--- Filled by the first target of each platform; consumed by every later
#--- target of the same platform (see the reuse block in the main loop).
declare -A BUILT=()
#--- Which target id built the binary above, for the "(reused from ...)" line.
declare -A REUSE_SRC=()

#--- run one compile and wait for its log; echoes the log path (which may
#--- not exist if this editor refused the job)
compile_one() {
  local editor="$1" file="$2" incdir="$3"
  local log="$file.compile.log"
  rm -f "$log"
  "$editor" /compile:"$(win_path "$file")" \
            /include:"$(win_path "$incdir")" \
            /log:"$(win_path "$log")" >/dev/null 2>&1
  local i
  for ((i=0; i<CP_COMPILE_TIMEOUT_TICKS; i++)); do
    [[ -f "$log" ]] && break
    sleep 0.25
  done
  printf '%s\n' "$log"
}

log_text() {
  local log="$1"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16LE -t UTF-8 "$log" 2>/dev/null || cat "$log"
  else
    cat "$log"
  fi
}

report() {
  local file="$1" log="$2" txt summary
  local name; name="$(basename "$file")"
  if [[ ! -f "$log" ]]; then
    echo "  ??   $name  (no compiler log produced)"
    return 2
  fi
  txt="$(log_text "$log")"
  summary="$(printf '%s\n' "$txt" | grep -a "Result:" | tail -1)"
  if printf '%s' "$summary" | grep -aq "0 errors"; then
    echo "  ok   $name   ${summary#*Result: }"
    printf '%s\n' "$txt" | grep -ai "warning" | head -5 | sed 's/^/         /'
    return 0
  fi
  echo "  FAIL $name"
  printf '%s\n' "$txt" | grep -aiE "error" | head -25 | sed 's/^/         /'
  [[ -n "$summary" ]] && echo "         $summary"
  return 1
}

#--- find an editor that actually produces a log for this target, by
#--- probing with the SMALLEST source file available.
#---
#--- The probe only needs to answer "does this editor produce a compiler
#--- log at all" - the CONTENT of the file is irrelevant to that question.
#--- Probing with the first file in the folder picked CopierReceiver, the
#--- 4323-line, 26-second file, and so burned ~26 s per target just to
#--- learn that the editor works. Probing with the smallest file (the
#--- ~330-line probe script, ~1.4 s) answers the same question for a
#--- twentieth of the cost.
pick_editor() {
  local plat="$1" label="$2" build="$3" ext="$4"
  local probe="" f ed log size best=0
  #--- smallest Copier*.{ext} across Experts/ and Scripts/
  for f in "$build/Experts/"*."$ext" "$build/Scripts/"*."$ext"; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == Copier* ]] || continue
    size="$(wc -c <"$f" 2>/dev/null)"
    if [[ -z "$probe" || ${size:-0} -lt $best ]]; then
      probe="$f"; best="${size:-0}"
    fi
  done
  [[ -n "$probe" ]] || return 1

  while IFS= read -r ed; do
    [[ -n "$ed" ]] || continue
    log="$(compile_one "$ed" "$probe" "$build")"
    if [[ -f "$log" ]]; then
      rm -f "$log"
      printf '%s' "$ed"
      return 0
    fi
  done < <(editor_candidates "$plat" "$label")
  return 1
}

echo
echo "=== targets ==="
print_targets
echo

total_fail=0
while IFS='|' read -r id plat label; do
  [[ -n "$id" ]] || continue
  real_dir="$(resolve_data_dir "$id" "$plat")"
  if [[ "$plat" == "MQL5" ]]; then ext="mq5"; binext="ex5"; else ext="mq4"; binext="ex4"; fi

  echo "=== $plat  $id  ${label:-unknown install} ==="
  tgt_start=$(date +%s)
  if [[ ! -d "$real_dir" ]]; then
    echo "  data folder missing: $real_dir"
    echo
    continue
  fi

  build="$(prepare_build_dir "$id" "$plat" "$real_dir" "$ext")"
  [[ "$build" != "$real_dir" ]] && echo "  staging build in: $build"

  editor="$(pick_editor "$plat" "$label" "$build" "$ext" || true)"
  if [[ -z "$editor" ]]; then
    echo "  no usable MetaEditor found for this target."
    echo "  Every candidate refused to produce a compiler log:"
    editor_candidates "$plat" "$label" | sed 's/^/    /'
    echo "  Open that terminal's MetaEditor and press F7 on the files"
    echo "  in Experts/ and Scripts/ instead."
    echo
    total_fail=$((total_fail+1))
    continue
  fi
  echo "  editor : $editor"

  fails=0
  reused=0
  compiled=0
  for sub in Experts Scripts; do
    for f in "$build/$sub/"*."$ext"; do
      [[ -f "$f" ]] || continue
      [[ "$(basename "$f")" == Copier* ]] || continue
      bname="$(basename "$f")"; stem="${bname%.*}"

      #--- Reuse: if an earlier target of THIS platform already built this
      #--- exact source file, copy that binary instead of compiling again.
      #---
      #--- The identity being relied on is the SOURCE, not the target: every
      #--- target of a platform stages the same bytes from the same src/, so
      #--- the binary another MT5 terminal produced is the one this MT5
      #--- terminal would have produced itself (modulo MetaEditor's per-run
      #--- encryption of the code section, which does not change behaviour -
      #--- the portable-staging path already depends on exactly this).
      #---
      #--- Platform is part of the key: an .ex4 cannot run on MT5 and vice
      #--- versa, so a cross-platform reuse would be a silent, total failure.
      key="$plat:$stem"
      if [[ $REUSE -eq 1 && -s "${BUILT[$key]:-}" ]]; then
        if cp -f "${BUILT[$key]}" "$build/$sub/$stem.$binext" 2>/dev/null \
           && [[ -s "$build/$sub/$stem.$binext" ]]; then
          printf '  ==   %s  (reused from %s)\n' "$bname" "${REUSE_SRC[$key]}"
          reused=$((reused+1))
          continue
        fi
        #--- copy failed (locked/absent) - fall through and compile it here
        #--- rather than report a file we did not actually produce.
        echo "  !!   $bname  reuse failed, compiling locally"
      fi

      log="$(compile_one "$editor" "$f" "$build")"
      if report "$f" "$log"; then
        built="$build/$sub/$stem.$binext"
        if [[ -f "$built" ]]; then
          BUILT[$key]="$built"
          REUSE_SRC[$key]="$id"
          compiled=$((compiled+1))
        fi
      else
        fails=$((fails+1))
      fi
      rm -f "$log"
    done
  done

  if [[ $REUSE -eq 1 && $reused -gt 0 ]]; then
    echo "  ($compiled compiled, $reused reused from this platform's first target)"
  fi

  if [[ "$build" != "$real_dir" ]]; then
    copy_binaries_back "$build" "$real_dir" "$binext"
    echo "  binaries copied back to $real_dir"
    echo "  (build cache kept at $(dirname "$build") - see ./tools/clean.sh)"
  fi

  echo "  --- $fails file(s) with errors"
  echo "  (target wall time: $(( $(date +%s) - tgt_start ))s)"
  echo
  total_fail=$((total_fail+fails))
done < <(list_terminals)

echo "==============================================="
if [[ $total_fail -eq 0 ]]; then
  echo " ALL GREEN - 0 errors across every target"
else
  echo " $total_fail problem(s) across every target"
fi
echo "==============================================="
exit $(( total_fail > 0 ? 1 : 0 ))
