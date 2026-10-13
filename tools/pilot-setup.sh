#!/usr/bin/env bash
# ---------------------------------------------------------------------
# pilot-setup.sh - prepare the on-machine loopback pilot (see doc/PILOT.md)
#
# Does the three tedious steps:
#   1. enable the second MT5 install in tools/targets.conf
#   2. deploy + compile the copier into BOTH MT5 terminals
#   3. write config/copier.loopback.ini to the RECEIVER's MQL5\Files
#
# Idempotent: safe to re-run.
#
# Usage:
#   ./tools/pilot-setup.sh
#   SENDER_ID=... RECEIVER_ID=... ./tools/pilot-setup.sh
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# --- which terminal plays which role ---------------------------------
# default: the Program Files install is the RECEIVER, the portable E:
# install is the SENDER.
#
# NOTE the sender is given as an absolute PATH, not a 32-hex id. The E:
# install is portable (Mt5-Portable.bat -> terminal64.exe /portable), so
# its live data lives in the install folder. %APPDATA% also holds a
# folder for the same install, but it is stale - deploying there looks
# like it worked and reaches nothing. Run ./tools/status.sh --all to see
# the LAST USED column, which is what tells the two apart.
RECEIVER_ID="${RECEIVER_ID:-D0E8209F77C8CF37AD8BF550E51FF075}"
SENDER_ID="${SENDER_ID:-/e/MetaTrader 5}"

CONF="$REPO/tools/targets.conf"
INI_SRC="$REPO/config/copier.loopback.ini"

echo
echo "=== pilot setup ==="
echo "  sender   : $SENDER_ID"
echo "  receiver : $RECEIVER_ID"
echo

# --- 0. both terminals must actually exist ---------------------------
#
# NOTE: do NOT test this with `discover_terminals | grep -q ...`.
# `grep -q` exits on the first match, the producer gets SIGPIPE, and under
# `set -o pipefail` the whole pipeline is then reported as failed - so a
# perfectly good match looks like "not found". Capture once and pattern
# match in bash instead.
ALL_TERMS="$(discover_terminals)"

for want in "$SENDER_ID" "$RECEIVER_ID"; do
  if [[ "$ALL_TERMS" != *"$want|MQL5|"* ]]; then
    echo "!! terminal $want not found (or is not an MT5 install)"
    echo "   run ./tools/status.sh --all to see what is available, then set"
    echo "   SENDER_ID=... RECEIVER_ID=... and run again"
    exit 1
  fi
done

# --- 1. make sure both are listed in targets.conf --------------------
if [[ -f "$CONF" ]]; then
  changed=0
  for id in "$SENDER_ID" "$RECEIVER_ID"; do
    if ! grep -qE "^[[:space:]]*${id}[[:space:]]*$" "$CONF"; then
      if grep -qE "^#[[:space:]]*${id}[[:space:]]*$" "$CONF"; then
        # commented out -> enable it in place, keeping the comment above
        sed -i "s|^#[[:space:]]*\(${id}\)[[:space:]]*$|\1|" "$CONF"
      else
        printf '\n# added by pilot-setup.sh\n%s\n' "$id" >> "$CONF"
      fi
      changed=1
    fi
  done
  [[ $changed -eq 1 ]] && echo "  targets.conf updated"
else
  printf '%s\n%s\n' "$SENDER_ID" "$RECEIVER_ID" > "$CONF"
  echo "  targets.conf created"
fi

# --- 2. deploy --------------------------------------------------------
echo
bash "$HERE/deploy.sh" || exit 1

# --- 3. receiver config ----------------------------------------------
#
# Done BEFORE compiling on purpose. An earlier version compiled first and
# bailed out on any compile error, which meant a single failing target
# silently left the receiver with no copier.ini at all - the one step the
# user cannot easily do by hand.
echo
RECV_DIR="$TERM_ROOT/$RECEIVER_ID/MQL5"
if [[ ! -d "$RECV_DIR" ]]; then
  echo "!! $RECV_DIR does not exist - is that terminal installed?"
  exit 1
fi
mkdir -p "$RECV_DIR/Files"

if [[ -f "$INI_SRC" ]]; then
  cp -f "$INI_SRC" "$RECV_DIR/Files/copier.ini"
  echo "  wrote $RECV_DIR/Files/copier.ini"
else
  echo "!! $INI_SRC missing"
  exit 1
fi

# --- 4. compile -------------------------------------------------------
echo
if ! bash "$HERE/compile.sh"; then
  echo
  echo "!! compilation reported problems - fix those before running the pilot."
  echo "!! the config above is already in place, so nothing else is lost."
fi

# --- checklist --------------------------------------------------------
cat <<EOF

=== ready ===

  SENDER    terminal : $SENDER_ID
            inputs   : SenderId=sender01  BindAddress=tcp://127.0.0.1
                       EventsPort=5555
                       UseCurve=false     LogLevel=2
            (SenderId must equal the id= in the receiver's copier.ini)

  RECEIVER  terminal : $RECEIVER_ID
            config   : MQL5\\Files\\copier.ini (written above)
            inputs   : ConfigFile=copier.ini  LogLevel=2

  In BOTH terminals:
    * EA Common tab -> tick "Allow DLL imports"
    * receiver also needs "Allow live trading"
    * AutoTrading button ON
    * log into a DEMO account

  Then follow doc/PILOT.md section 3 for the five checks:
    3.1 mirror      3.2 event loss      3.3 receiver restart
    3.4 sender restart                 3.5 disconnect

EOF
