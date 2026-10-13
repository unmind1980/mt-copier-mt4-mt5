#!/usr/bin/env bash
# ---------------------------------------------------------------------
# memwatch.sh - memory watchdog for the copier terminals
#
# The whole reason this project exists is that the copier it replaces
# grows in memory until the terminal has to be restarted. That claim is
# only worth making if it is measured, and MQL has no API for its own
# process footprint - so this samples the terminal processes from
# outside, over time, and reports the trend.
#
# Usage:
#   bash tools/memwatch.sh [intervalSec] [samples]
#
# A flat line is the expected result. A rising one means something is
# accumulating, and the per-PID columns tell you which terminal.
#
# NOTE: WorkingSet is the OS's current resident set, which legitimately
# moves as the terminal caches quotes and history. What matters is the
# TREND across the run, not any single reading.
#
# Two traps this script has already fallen into, both silent:
#   * Git Bash path-mangles "/FI" into a filesystem path, so tasklist
#     errors out and every sample is missing. MSYS_NO_PATHCONV=1 fixes it.
#   * tasklist's memory field is "204,996 K" - a COMMA INSIDE QUOTES - so
#     splitting on comma shreds it into two fields and truncates the value.
# Both produce an empty dataset, which is why the verdict below refuses to
# report success when it has nothing to report on.
# ---------------------------------------------------------------------
set -u
export MSYS_NO_PATHCONV=1

IV="${1:-30}"
N="${2:-40}"
OUT="${3:-memwatch.csv}"

echo "sampling every ${IV}s for ${N} samples (~$((IV*N/60)) min)"
: > "$OUT"

#--- One function, one parse. Prints "pid,name,memKB,ts".
sample() {
  local img="$1" t
  t="$(date +%H:%M:%S)"
  tasklist /FI "IMAGENAME eq ${img}" /FO CSV /NH 2>/dev/null | tr -d '"' \
    | awk -F, -v t="$t" -v nm="$img" '
        NF<5 { next }
        {
          #--- fields 5..NF are the memory figure: commas inside the quoted
          #--- value split it across several fields, so rejoin them all
          m="";
          for(i=5;i<=NF;i++){ v=$i; gsub(/[^0-9]/,"",v); m=m v; }
          if(m+0>0) print $2","nm","m","t;
        }' >> "$OUT"
}

for i in $(seq 1 "$N"); do
  sample "terminal.exe"
  sample "terminal64.exe"
  sleep "$IV"
done

echo
echo "=== trend per process ($(grep -c . "$OUT") rows) ==="
awk -F, 'NR>1 { k=$1"|"$2; n[k]++;
               if(!(k in first)) first[k]=$3;
               last[k]=$3;
               if(!(k in mn) || $3+0<mn[k]) mn[k]=$3;
               if(!(k in mx) || $3+0>mx[k]) mx[k]=$3;
             } END {
               printf "%-8s %-14s %9s %9s %9s %9s %9s\n","pid","name","first","last","delta","min","max";
               for(k in n) { split(k,p,"|");
                 printf "%-8s %-14s %9d %9d %+9d %9d %9d\n",p[1],p[2],first[k],last[k],last[k]-first[k],mn[k],mx[k]; }
             }' "$OUT"

echo
echo "=== verdict ==="
ROWS=$(awk 'NR>1' "$OUT" | grep -c . || true)
if [ "$ROWS" -eq 0 ]; then
  echo "  NO DATA COLLECTED - the watchdog ran but sampled nothing."
  echo "  This is NOT a pass. Check that the terminals are running and that"
  echo "  tasklist works in this shell (see MSYS_NO_PATHCONV above)."
  exit 2
fi

awk -F, 'NR>1 { k=$1"|"$2; n[k]++;
               if(!(k in first)) first[k]=$3;
               last[k]=$3 } END {
  bad=0;
  for(k in n){ d=last[k]-first[k]; pct=(first[k]>0)?(d*100.0/first[k]):0;
    split(k,p,"|");
    if(pct > 15){ printf "  GROWING  %s (%s)  %+d KB (%.1f%%)\n",p[1],p[2],d,pct; bad=1 }
    else        { printf "  flat     %s (%s)  %+.0f KB (%.1f%%)\n",p[1],p[2],d,pct } }
  if(bad) { print ""; print "  ^ investigate: a rising resident set means state is accumulating"; exit 1 }
  else    { print ""; print "  no process grew materially over the run" }
}' "$OUT"

echo
echo "full samples: $OUT"
