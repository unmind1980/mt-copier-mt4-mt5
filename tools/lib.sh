#!/usr/bin/env bash
# ---------------------------------------------------------------------
# lib.sh - shared terminal discovery for deploy.sh / compile.sh /
#          status.sh / pilot-setup.sh. Source it, do not execute it.
#
# WHERE METATRADER KEEPS ITS DATA
#
# Normal install:  %APPDATA%\MetaQuotes\Terminal\<32-hex-id>\
#                  The id is derived from the INSTALL PATH, so a second
#                  installation of the same platform gets a different id
#                  and a completely separate data folder.
#
# Portable install: <install folder>\     (terminal64.exe /portable)
#                  The data lives next to the executable. %APPDATA% may
#                  ALSO hold a folder for the same install, left over
#                  from running it non-portable - and which one is live
#                  depends on how you launched it. Deploying into the
#                  wrong one is completely silent: the files are on disk,
#                  the compiler is happy, and no running terminal reads
#                  them.
#
# So we enumerate BOTH kinds, label each one with its install path, and
# let the user pick explicitly.
#
# A target id is either the 32-hex AppData folder name, or an absolute
# path to a data folder (which is how portable installs are named).
# ---------------------------------------------------------------------

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rm() { /usr/bin/rm "$@"; }

if command -v cygpath >/dev/null 2>&1; then
  _APPDATA="$(cygpath -u "${APPDATA:-$HOME/AppData/Roaming}")"
else
  _APPDATA="${APPDATA:-$HOME/AppData/Roaming}"
fi
TERM_ROOT="$_APPDATA/MetaQuotes/Terminal"

win_to_posix() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}
win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

#--- origin.txt holds the install path: UTF-16LE, with a BOM
term_origin() {
  local dir="$1"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16LE -t UTF-8 "$dir/origin.txt" 2>/dev/null \
      | tr -d '\r\n\0' | sed 's/^\xef\xbb\xbf//'
  else
    tr -d '\0' < "$dir/origin.txt" 2>/dev/null | tr -d '\r\n'
  fi
}

#--- is this a portable install (does the install folder hold MQL4/MQL5)?
#--- takes a Windows install path
portable_roots() {
  local org="$1" p plat
  p="$(win_to_posix "$org")"
  [[ -d "$p" ]] || return 0
  for plat in MQL5 MQL4; do
    [[ -d "$p/$plat" ]] || continue
    printf '%s|%s|%s\n' "$p" "$plat" "portable, at $org"
  done
}

#--- emit "<id>|<PLATFORM>|<label>" for every data folder found.
#--- id is either a 32-hex folder name or an absolute path.
discover_terminals() {
  local d id plat org pr
  for d in "$TERM_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/origin.txt" ]] || continue
    id="$(basename "$d")"
    org="$(term_origin "$d")"
    for plat in MQL5 MQL4; do
      [[ -d "$d$plat" ]] || continue
      printf '%s|%s|%s\n' "$id" "$plat" "${org:-unknown install}"
    done
    #--- plus this install's own portable data folder, if it has one.
    #--- portable_roots does NOT end in a newline; if it is printed bare,
    #--- its last line fuses with the next target's first line and both
    #--- become unparseable. Print it through a variable so the trailing
    #--- newline is guaranteed.
    if [[ -n "$org" ]]; then
      pr="$(portable_roots "$org")"
      [[ -n "$pr" ]] && printf '%s\n' "$pr"
    fi
  done
}

#--- resolve a target id to the absolute data folder for a platform
resolve_data_dir() {
  local id="$1" plat="$2"
  case "$id" in
    /*|[A-Za-z]:*) printf '%s' "$id/$plat" ;;   # absolute path (portable)
    *)            printf '%s' "$TERM_ROOT/$id/$plat" ;;
  esac
}

#--- is this id a portable/absolute one?
is_path_id() {
  case "$1" in
    /*|[A-Za-z]:*) return 0 ;;
    *)            return 1 ;;
  esac
}

#--- honour tools/targets.conf when it names ids or paths; otherwise act
#--- on every data folder found
target_terminals() {
  local conf="$REPO/tools/targets.conf"
  local want=() line id plat label w
  if [[ -f "$conf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      # trim, but keep spaces that are part of a path
      line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "$line" ]] && want+=("$line")
    done < "$conf"
  fi

  if [[ ${#want[@]} -eq 0 ]]; then
    discover_terminals
    return
  fi

  #--- Emit targets in CONF ORDER, not discovery order. The first target of
  #--- each platform becomes that platform's BUILD HOST (the one that really
  #--- compiles; every other target of the platform copies its binary), so
  #--- the order is load-bearing: the operator uses it to keep the portable
  #--- MT5 out of the host seat, because its staging-compile environment is
  #--- the least reliable of the four.
  local w dline
  local all_discovered; all_discovered="$(discover_terminals)"
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    while IFS='|' read -r dline; do
      id="${dline%%|*}"
      if [[ "$w" == "$id" ]]; then
        printf '%s\n' "$dline"
      fi
    done <<< "$all_discovered"
  done < <(printf '%s\n' "${want[@]}")
}

#--- every MetaEditor that might be able to compile for this target, most
#--- appropriate first. The caller tries them in order until one actually
#--- produces a compiler log.
#---
#--- This matters because a MetaEditor shipped with a portable install can
#--- refuse the command line entirely (it exits without writing anything),
#--- while a different install's editor compiles the very same file fine.
#--- Rather than guess, try them.
editor_candidates() {
  local plat="$1" label="$2" cand org
  org="$label"
  case "$label" in
    portable,\ at\ *) org="${label#portable, at }" ;;
  esac
  org="$(win_to_posix "$org")"

  if [[ "$plat" == "MQL5" ]]; then
    for cand in "$org/MetaEditor64.exe" "$org/metaeditor.exe" \
                "/c/Program Files/MetaTrader 5/MetaEditor64.exe" \
                "/c/Program Files (x86)/MetaTrader 5/MetaEditor64.exe"; do
      [[ -f "$cand" ]] && printf '%s\n' "$cand"
    done
  else
    for cand in "$org/metaeditor.exe" \
                /c/Program\ Files\ \(x86\)/*/metaeditor.exe \
                /c/Program\ Files/*/metaeditor.exe; do
      [[ -f "$cand" ]] && printf '%s\n' "$cand"
    done
  fi
}

#--- MetaEditor has two hard requirements that a portable install breaks:
#---
#---  1. It only compiles reliably when the SOURCE lives under the standard
#---     %APPDATA%\MetaQuotes\Terminal root. Point /compile: at a file in a
#---     portable data folder and it produces no log, no binary and NO
#---     ERROR - it just silently does nothing.
#---  2. It cannot even READ includes from a portable data folder. Verified:
#---     /include:E:\MetaTrader 5\MQL5 with the source staged locally still
#---     produces no log.
#---
#--- So for such a target we build in a staging folder under the terminal
#--- root, with its own copy of the Include tree, then copy the binaries
#--- back to the portable folder.
#---
#--- The staging folder is a persistent BUILD CACHE, refreshed in place:
#--- the Include tree is copied once, and only our own headers and sources
#--- are re-copied each run. Nothing is ever recursively deleted, which
#--- keeps the script safe to run and immune to path-guard quirks.
#---
#--- echoes the directory to compile in
prepare_build_dir() {
  local id="$1" plat="$2" real="$3" ext="$4"
  if [[ "$real" == "$TERM_ROOT"/* ]]; then
    printf '%s' "$real"
    return 0
  fi

  local safe stage
  safe="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')"
  stage="$TERM_ROOT/_copier_build_$safe/$plat"
  mkdir -p "$stage/Experts" "$stage/Scripts" "$stage/Include/Copier"

  #--- 1. standard library: once. It only changes when the terminal updates.
  if [[ ! -d "$stage/Include/Trade" && -d "$real/Include" ]]; then
    cp -r "$real/Include/." "$stage/Include/" 2>/dev/null
  fi

  #--- 2. our own headers: every run, so the build can never use stale ones
  rm -f "$stage/Include/Copier/"*.mqh 2>/dev/null
  cp -f "$real/Include/Copier/"*.mqh "$stage/Include/Copier/" 2>/dev/null

  #--- 3. sources: every run. Clear our own files first so a renamed or
  #---    deleted source cannot linger and get compiled.
  rm -f "$stage/Experts/Copier"*.* "$stage/Scripts/Copier"*.* 2>/dev/null
  cp -f "$real/Experts/"*."$ext" "$stage/Experts/" 2>/dev/null
  cp -f "$real/Scripts/"*."$ext" "$stage/Scripts/" 2>/dev/null

  printf '%s' "$stage"
}

#--- copy compiled binaries from the staging folder back into the real
#--- (portable) data folder
copy_binaries_back() {
  local stage="$1" real="$2" binext="$3" f
  [[ "$stage" == "$real" ]] && return 0
  mkdir -p "$real/Experts" "$real/Scripts"
  for f in "$stage/Experts/"*."$binext"; do
    [[ -f "$f" ]] && cp -f "$f" "$real/Experts/"
  done
  for f in "$stage/Scripts/"*."$binext"; do
    [[ -f "$f" ]] && cp -f "$f" "$real/Scripts/"
  done
  return 0
}

#--- print the resolved target list as a readable table
print_targets() {
  local id plat label
  printf '  %-34s %-6s %s\n' "TARGET" "PLAT" "DATA FOLDER / INSTALL"
  while IFS='|' read -r id plat label; do
    [[ -n "$id" ]] || continue
    printf '  %-34s %-6s %s\n' "$id" "$plat" "$label"
  done < <(target_terminals)
}
