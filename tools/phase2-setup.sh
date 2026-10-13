#!/usr/bin/env bash
# ---------------------------------------------------------------------
# phase2-setup.sh - prepare P2 phase 2: MT4 as SENDER, MT5 as receiver.
#
# Writes the two-sender copier.ini to the MT5 receiver terminal, then
# prints exactly what to set in the MT4 sender EA.
#
# Why two senders: the MT5 sender from phase 1 keeps running, so the
# receiver ends up serving both at once. That exercises the N:M path -
# per-sender sequence counter, magic and desired set - for free.
#
# Usage:
#   ./tools/phase2-setup.sh
#   MT4_SENDER=... MT5_RECEIVER=... ./tools/phase2-setup.sh
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# --- which terminal plays which role ---------------------------------
# MT4 A (Alpari MT4) stays the receiver from phase 1; MT4 B (Alpari
# MT4-2) becomes the sender here.
MT4_SENDER="${MT4_SENDER:-311584BE9969960C78E0200E53528ECB}"
MT5_RECEIVER="${MT5_RECEIVER:-D0E8209F77C8CF37AD8BF550E51FF075}"

INI_SRC="$REPO/config/copier.mt5receiver.2senders.ini"

echo
echo "=== P2 phase 2 setup ==="
echo "  MT4 sender     : $MT4_SENDER"
echo "  MT5 receiver   : $MT5_RECEIVER"
echo

ALL_TERMS="$(discover_terminals)"
for want in "$MT4_SENDER" "$MT5_RECEIVER"; do
  if [[ "$ALL_TERMS" != *"$want|"* ]]; then
    echo "!! terminal $want not found - run ./tools/status.sh --all"
    exit 1
  fi
done

RECV_DIR="$TERM_ROOT/$MT5_RECEIVER/MQL5"
if [[ ! -d "$RECV_DIR" ]]; then
  echo "!! $RECV_DIR does not exist"
  exit 1
fi
mkdir -p "$RECV_DIR/Files"

if [[ ! -f "$INI_SRC" ]]; then
  echo "!! $INI_SRC missing"
  exit 1
fi

cp -f "$INI_SRC" "$RECV_DIR/Files/copier.ini"
echo "  wrote $RECV_DIR/Files/copier.ini  (two senders)"
echo

# --- make sure the ports the MT4 sender will need are actually free --
for p in 5565; do
  if netstat -ano 2>/dev/null | grep -q ":$p .*LISTENING"; then
    owner="$(netstat -ano 2>/dev/null | grep ":$p .*LISTENING" | awk '{print $NF}' | head -1)"
    echo "  note: port $p is already bound (PID ${owner:-?})."
    echo "        If the MT4 sender is ALREADY RUNNING that is it, and"
    echo "        everything is fine. If it is not, something else owns the"
    echo "        port and the sender will fail with errno=48 - change"
    echo "        EventsPort in BOTH the EA and copier.ini."
  fi
done

cat <<EOF

=== now do this ===

MT4 SENDER  (terminal $MT4_SENDER)

  Drag CopierSender onto a chart, Common tab -> Allow DLL imports,
  AutoTrading ON, logged into a DEMO account.

  Inputs - only the first two need changing from the defaults:
    BindAddress    = tcp://127.0.0.1
    EventsPort     = 5565           <- the ONLY port bound, and also the
                                       sender's identity: a receiver's id=
                                       must equal it.
    UseCurve       = false
    LogLevel       = 2

  Expected in MQL4\\Files\\copier_sender_5565.0.log:
    sender 5565 listening on port 5565 (one socket, both streams) ssid=XXXXXX

MT5 RECEIVER (terminal $MT5_RECEIVER)

  Remove and re-add CopierReceiver so it re-reads the config.
  Expected:  receiver up, 2 sender(s), magic base=770000

  Then open a trade on the MT4 account. It should mirror on the MT5
  receiver while the MT5 sender's own positions keep working.

WATCH FOR (this is the point of the phase)

  * the MT4 sender logs "open <uid> tkt=<n> ..." - that ticket is what
    the receiver writes into its order comment, so they should match
  * the MT5 receiver logs "exec open mt4demo <uid> ..." - a SECOND
    sender id, proving per-sender routing works
  * partially close a position on the MT4 account. MT4 makes the broker
    replace the ticket, with "from #<old>" in the comment; the sender
    inherits the UID so the receiver does NOT see a close+reopen. You
    will see one throttled "volume changed" warning instead.

  Also note: the MT4 sender broadcasts EVERY position on that account
  that is not filtered out - including anything the user's other EAs
  opened. Use IncludeSymbols / IncludeMagicNumbers on the sender if you
  only want some of them copied.

EOF
