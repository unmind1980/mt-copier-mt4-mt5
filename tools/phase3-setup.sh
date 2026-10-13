#!/usr/bin/env bash
# ---------------------------------------------------------------------
# phase3-setup.sh - prepare P2 phase 3: MT4 as SENDER, MT4 as RECEIVER.
#
# The last untested combination, and the one you would actually deploy:
# order-based on BOTH sides. No trade events on either terminal - both
# poll OrdersTotal/OrderSelect - and MT4's partial close replaces the
# order ticket, which is the thing worth watching here.
#
# Writes the receiver's copier.ini, checks the ports, then prints
# exactly what to set on each EA.
#
# Usage:
#   ./tools/phase3-setup.sh
#   MT4_SENDER=... MT4_RECEIVER=... SENDER_PORT=... ./tools/phase3-setup.sh
# ---------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# --- which terminal plays which role ---------------------------------
# MT4 B (Alpari MT4-2) sends, MT4 A (Alpari MT4) receives. That is the
# reverse of phase 1, where MT4 A received from the MT5 sender - so if
# you have just come from phase 2, MT4 A is already the receiver and you
# only need to repoint its config.
MT4_SENDER="${MT4_SENDER:-311584BE9969960C78E0200E53528ECB}"
MT4_RECEIVER="${MT4_RECEIVER:-287469DEA9630EA94D0715D755974F1B}"
SENDER_PORT="${SENDER_PORT:-5565}"

INI_SRC="$REPO/config/copier.mt4to4.ini"

echo
echo "=== P2 phase 3 setup (MT4 -> MT4) ==="
echo "  MT4 sender   : $MT4_SENDER"
echo "  MT4 receiver : $MT4_RECEIVER"
echo "  sender id    : $SENDER_PORT"
echo

# --- both terminals must exist, and both must be MT4 -----------------
#
# NOTE: do NOT test this with `discover_terminals | grep -q ...`.
# `grep -q` exits on the first match, the producer gets SIGPIPE, and under
# `set -o pipefail` the whole pipeline is then reported as failed - so a
# perfectly good match looks like "not found". Capture once and pattern
# match in bash instead.
ALL_TERMS="$(discover_terminals)"

for want in "$MT4_SENDER" "$MT4_RECEIVER"; do
  if [[ "$ALL_TERMS" != *"$want|MQL4|"* ]]; then
    echo "!! terminal $want not found (or is not an MT4 install)"
    echo "   run ./tools/status.sh --all to see what is available, then set"
    echo "   MT4_SENDER=... MT4_RECEIVER=... and run again"
    exit 1
  fi
done

SEND_DIR="$(resolve_data_dir "$MT4_SENDER" MQL4)"
RECV_DIR="$(resolve_data_dir "$MT4_RECEIVER" MQL4)"

for d in "$SEND_DIR" "$RECV_DIR"; do
  if [[ ! -d "$d" ]]; then
    echo "!! $d does not exist"
    exit 1
  fi
done

if [[ "$MT4_SENDER" == "$MT4_RECEIVER" ]]; then
  echo "!! sender and receiver are the same terminal; that copies a"
  echo "   terminal onto itself and will fight with its own orders."
  exit 1
fi

# --- write the receiver config ---------------------------------------
mkdir -p "$RECV_DIR/Files"

if [[ ! -f "$INI_SRC" ]]; then
  echo "!! $INI_SRC missing"
  exit 1
fi

# The id in the file must equal the sender's EventsPort, because that port IS
# the sender's identity - the receiver routes by id, and an unknown id is
# dropped rather than guessed at, so a mismatch looks exactly like "nothing is
# being sent". Substituting here is what guarantees they cannot drift apart.
#
# This used to substitute a NAME ("mt4demo"), which was right when the sender
# carried a SenderId input. It does not any more, and the substitution was
# quietly overwriting the correct id=5565 in the source ini with a name no
# sender would ever publish - a config that receives nothing, silently.
sed "s|^id[[:space:]]*=.*|id          = ${SENDER_PORT}|" \
    "$INI_SRC" > "$RECV_DIR/Files/copier.ini"

written="$(grep -E '^id[[:space:]]*=' "$RECV_DIR/Files/copier.ini" | head -1)"
echo "  wrote $RECV_DIR/Files/copier.ini  ($written)"
echo

# --- make sure the port the MT4 sender will need is free ------------
# --- (one port now, not two: events and snapshots share a socket)
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

# --- is the MT5 sender still broadcasting? ---------------------------
#
# Not an error - the receiver routes by id and will drop it - but it is
# worth knowing, because "the other sender is still up" is the usual
# reason a cross-phase test looks like it is working when it is not.
if netstat -ano 2>/dev/null | grep -q ":5555 .*LISTENING"; then
  echo "  note: port 5555 is still bound - the MT5 sender from phase 1 is"
  echo "        probably still running. Harmless (this receiver's config"
  echo "        names only '$SENDER_PORT' and will ignore it), but stop it"
  echo "        if you want the test to be unambiguous."
fi

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

MT4 RECEIVER  (terminal $MT4_RECEIVER)

  Remove and re-add CopierReceiver so it re-reads copier.ini.
  Expected:  receiver up, 1 sender(s), magic base=770000

  If it was receiving from the MT5 sender in phase 2, this config has
  just replaced that one. You can run both by adding a [sender1] section
  instead - that is the N:M path, and it works, but it makes phase 3
  harder to read.

WATCH FOR (this is the point of the phase)

  1. open a trade on MT4 B
     * sender logs  "open <uid> tkt=<n> ..."  - that ticket is what the
       receiver writes into its order comment, so the two must match
     * receiver logs "exec open $SENDER_PORT <uid> ..."
     * IN THE TERMINAL, the mirrored order's comment must read
       tc|<uid>|<ticket> - complete, not truncated. MT4 caps comments at
       31 characters and some brokers cut at 27; a truncated comment that
       still parses is the failure mode that hides.

  2. PARTIALLY CLOSE on MT4 B - the crux of this phase
     * MT4 replaces the ticket and writes "from #<old>" into the comment.
       The sender inherits the UID across that hop, so the receiver does
       NOT see a close+reopen - it sees one smaller volume in the next
       snapshot, and logs:
         exec partial-close $SENDER_PORT <uid> ...
     * The receiver's OWN order is re-ticketed by its broker too, and its
       comment becomes "from #<old>". THAT IS EXPECTED AND CANNOT BE
       PREVENTED: OrderClose() takes no comment, and OrderModify() does
       not touch comments. There is no API to write it back.
     * Identity survives anyway via copier_receiver.st. Confirm no line
       says "unmanageable".

  3. CONFIRM THE IDENTITY STORE IS LIVE - do this before anything else
     * Within 10 seconds of attaching, this file must exist:
         $RECV_DIR/Files/copier_receiver.st
       and its timestamp must keep moving (it is rewritten every 10 s).
     * The receiver logs this ONCE per session, as proof:
         I identity store copier_receiver.st written (N position(s))
       If you instead see
         I no usable copier_receiver.st yet - identity will come from ...
       at startup, that is normal on the FIRST run. If you never see the
       "written" line, the write is failing and the log will say so.
     * Why it matters: this file is the only durable identity on MT4. A
       partial close makes the broker replace the ticket AND rewrite the
       comment to "from #<old>", and there is no API to write a comment
       back. Without this file those positions are stranded.

  4. RESTART the MT4 receiver - the test that actually matters here
     * Stop and re-add CopierReceiver. It must re-identify the orders
       whose comments are now "from #<old>".
     * Expected at startup: "restored N known position(s) from state",
       no "unmanageable order(s)" error, and positions keep converging
       (trim one on the sender, watch it trim here).
     * DO NOT DELETE MQL4\\Files\\copier_receiver.st. On MT4 it is the
       only durable identity - the comment has been overwritten and the
       chain lookup needs the record to resolve the old ticket.

  5. SL/TP MIRRORING (independent of the phases above)
     * open a trade on MT4 B WITH a stop-loss and take-profit
     * on MT4 A the mirrored order must carry both, at the SAME DISTANCE
       from its own entry - not at the same absolute price, which would be
       wrong here because the two terminals fill at slightly different
       prices. Check the receiver log:
         I exec set-stops 5565 <uid> USDJPY sl=... tp=...
     * move the stop on MT4 B. Within ~2 s (one snapshot) MT4 A follows.
       The receiver queues a modify ONLY when the value actually differs,
       so a quiet log here is the correct result once it has settled.
     * set the stop on MT4 B to 0 / remove it. MT4 A removes its own too.
       This is deliberate faithful convergence - do not read it as a bug.
     * the mirror appears ~100 ms AFTER the position, not with it: a
       position is opened without stops and picks them up on the next
       converge pass. That is deliberate - see doc/PROTOCOL.md.
     * if the sender's stop is closer than this broker's minimum distance
       you will see ONE warning that it was widened. The mirror is then
       wider than the sender's, which is the safe direction.

  6. close everything on MT4 B
     * receiver logs "exec close" for each, and the account goes flat.

REMINDERS

  * The MT4 sender broadcasts EVERY position on that account that is not
    filtered out - including anything your other EAs opened. Use
    IncludeSymbols / IncludeMagicNumbers on the sender if you only want
    some of them copied.
  * Both terminals need 'Allow DLL imports' AND AutoTrading. A receiver
    with AutoTrading off logs the trade attempt and the broker error,
    which looks like a copier bug and is not.
  * Read the logs with ./tools/logcheck.sh when you are done - it checks
    the divergence rules rather than just grepping for errors.

EOF
