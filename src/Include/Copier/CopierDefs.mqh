//+------------------------------------------------------------------+
//| CopierDefs.mqh - constants, structs and platform-neutral helpers |
//| MT4/MT5 Trade Copier over ZeroMQ                                  |
//|                                                                   |
//| Design rule: everything that differs between MT4 and MT5 lives in |
//| THIS file (and CopierModel.mqh). The rest of the codebase is      |
//| platform-agnostic.                                                |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_DEFS_MQH__
#define __COPIER_DEFS_MQH__

//=====================================================================
// Bounded-state hard limits. These are the anti-bloat contract.
// Do NOT raise these without also adding eviction logic.
//=====================================================================
//--- Open-position / working-order table, fixed size.
//---
//--- 512 was too small. Plenty of platforms allow 1000 orders, and a broker's
//--- quota is positions + pending COMBINED, so a sender on such an account
//--- can legitimately exceed 512 - at which point the receiver silently
//--- mirrored only part of it. 2048 covers a 1000-order platform with room
//--- for a second sender and headroom.
//---
//--- The cost is bounded and known: CopierPos is ~150 bytes with its three
//--- strings, and the largest consumer is the per-sender desired set
//--- (nSenders * this). Two senders is ~1.2 MB total - trivial against a
//--- terminal's couple of hundred MB, and unlike a leak it does not grow.
//--- Raise CP_MAX_MSG_LEN with this or large snapshots are rejected.
#define CP_MAX_POSITIONS   2048   // open-position table, fixed size
#define CP_SEEN_RING       4096   // dedup ring buffer, fixed size
//--- Senders one receiver can mirror, and peers one sender can track.
//---
//--- 100, NOT 16, and the number is chosen to match a limit the operator
//--- already knows: MT5's chart ceiling (maxcharts, about 100 by default; MT4
//--- is the same order of magnitude). In DIRECT mode one receiver is one
//--- chart, so "how many senders can I mirror" was answered by the TERMINAL -
//--- about 100 - while HUB mode answered it with this constant, which used to
//--- be 16. That asymmetry was indefensible in public documentation: the same
//--- deployment could mirror 100 senders one way and silently 16 the other,
//--- with nothing in any log saying so.
//---
//--- So both modes now share one ceiling, and the honest framing is "hub mode
//--- costs one chart where direct mode costs one chart per sender". Raising
//--- this PAST the terminal's chart ceiling would make the hub-mode number
//--- larger than what direct mode can express, which is the reverse mistake
//--- and just as hard to explain.
//---
//--- What it costs - published in README so a downloader can decide, and all
//--- three bounds move together or a valid config is refused:
//---   * the per-sender slice of g_desired is CP_MAX_POSITIONS entries, and it
//---     is allocated ONLY for senders actually configured, so a 1-sender
//---     receiver still allocates 2048 and not 100x that
//---   * a full 100-sender config measures ~5,000 ini rows / ~100 KB (hub key
//---     set) up to ~7,400 / ~270 KB (receiver serializer) - which is what
//---     CP_INI_MAX, CP_INI_MAX_BYTES and the hub's MAX_INI_BYTES are sized for
#define CP_MAX_SENDERS     100    // senders per receiver (hub) / peers per sender
//--- Outbound trade-action queue.
//---
//--- 64 was too small for a burst. Measured live: a sender opening ~74
//--- positions at once filled it, and the overflow produced 585 deferral
//--- warnings inside one minute. The queue drains at MaxActionsPerTick per
//--- 100 ms (5 -> 50/s), so it recovers in a second or two and nothing is
//--- lost - but a queue that overflows on an ordinary burst is set too low.
//--- 256 absorbs a 200-position burst, and is still bounded.
#define CP_MAX_ACTIONS     256    // outbound trade-action queue
#define CP_MAX_IGNORE      64     // "leave this one alone" list (the IgnoreUids input)
#define CP_MAX_LOG_BYTES   1048576 // 1 MB per log file
#define CP_LOG_GENERATIONS 3      // log.0 current, then .1 .2
#define CP_STATE_MAX_LINES CP_MAX_POSITIONS // hard cap on state file (matches position capacity)
//--- Sized so the documented CP_MAX_POSITIONS capacity is actually
//--- REACHABLE. 8192 was not: a market record is ~65 bytes and a pending
//--- one ~90 (the pending fields are appended only for pending entries),
//--- so 8192 held barely ~100 records while the position table allows 512.
//---
//--- A sender past ~100 open positions therefore produced a snapshot that
//--- was rejected as CP_ERR_TRUNCATED and NEVER APPLIED - the receiver
//--- would keep converging against stale desired state, with nothing but a
//--- one-line "bad message err=1" to show it. A limit that silently caps
//--- real capacity is worse than no limit, because the failure looks like
//--- a parsing nitpick rather than a lost state update.
//---
//--- 2048 records at the WORST-CASE record size. A record is fixed-width in
//--- its fields, so the worst case is computable rather than guessable:
//---
//---   uid 8 + ticket 19 + symbol 24 + side 1 + lots 16
//---     + openPx/sl/tp 15 each + magic 9 + openTime 10 + 9 separators = 141
//---   a PENDING record adds kind + ptype + pprice + pstop + pexpire
//---     + 5 separators                                                  =  47
//---                                                              total  = 188
//---
//--- 2048 * 188 + record separators + envelope ~= 378 KB.
//---
//--- This used to read "2048 * 90 ~= 185 KB, so 256 KB leaves headroom", and
//--- 90 was simply wrong: DoubleToString(v,8) keeps all eight decimals, a
//--- symbol can be CP_SYM_MAXLEN=24 characters, and a ticket is a long. The
//--- old figure came from a self-test that filled the snapshot with SHORT
//--- symbols and seven-digit tickets, so it proved nothing - it passed at 2048
//--- records while a real ~1400-position sender was already over the limit and
//--- silently losing every snapshot.
//---
//--- 1 MB is ~2.7x the true worst case. The margin is deliberate: being one
//--- byte short here discards the WHOLE snapshot, and the receiver then
//--- converges against stale state behind a one-line warning.
#define CP_MAX_MSG_LEN     1048576 // max wire message we will parse (1 MB)

//--- The same bound, handed to libzmq as ZMQ_MAXMSGSIZE.
//---
//--- CP_MAX_MSG_LEN alone does NOT protect against a hostile peer: it is
//--- checked by the parser, which sees the message only AFTER libzmq has read
//--- the entire frame off the wire and buffered it. A peer announcing a
//--- multi-gigabyte frame therefore costs this process the allocation first
//--- and gets rejected second - which is exactly backwards.
//---
//--- ZMQ_MAXMSGSIZE is enforced DURING the frame read, and libzmq disconnects
//--- the peer instead of buffering anything. Same number, one layer earlier,
//--- so the two cannot drift apart.
#define CP_MAXMSGSIZE      CP_MAX_MSG_LEN
//--- R58-03: derived from CP_MAX_MSG_LEN instead of being its own magic number.
//---
//--- 64 KB capped the Z85 TEXT, but Z85 inflates by 5/4 while the snapshot itself
//--- is allowed to be 1 MB - so the text cap silently cut the real snapshot
//--- budget to ~52 KB of compressed bytes. At the documented worst case of 188
//--- B/record that is roughly 1,100 records, not the 2048 that CP_MAX_POSITIONS
//--- promises: a large account's snapshot would be rejected wholesale
//--- ("exceeds CP_Z85_MAX - rejected" -> CopierDecompressField returns "" ->
//--- HandleSnapshot refuses the whole frame) while the hub, whose limit is 4 MiB,
//--- decodes the very same frame fine. The symptom is the worst kind: the
//--- dashboard shows current positions, the receiver's mirror has silently
//--- stopped converging, and nothing looks offline.
//---
//--- The decompression-bomb guard is the post-decode length check, not this
//--- constant - this one only needs to bound a preposterous input.
#define CP_Z85_MAX         ((CP_MAX_MSG_LEN/5)*6)   // room for 1 MB in Z85 form

//=====================================================================
// ZMQ CURVE key sizes.
//
// A CURVE key is 32 raw bytes, conventionally written as 40 Z85
// characters (Z85 packs 4 bytes into 5 printable characters, so
// 32 bytes -> 40 chars, with no padding and no way to be short).
//
// Both numbers are named because both are load-bearing in different
// places, and mixing them up is the failure this project already hit:
//   * the FILE and the operator see 40 (Z85, printable);
//   * zmq_setsockopt wants exactly 32 (binary).
// Handing libzmq 40 characters' worth of STRING - which is what the
// binding's string overloads do, plus a NUL - fails with EINVAL and
// never completes a handshake. See CopierTransport::CurveRaw().
//=====================================================================
#define CP_CURVE_KEY_LEN   40
#define CP_CURVE_KEY_BYTES 32

//=====================================================================
// Compile-time build stamp.
//
// Answers "which binary is actually running?" from the log, instead of
// leaving it to be inferred from file timestamps. That inference has cost
// real time twice on this project:
//
//   * two MT4 receivers had no state file, which looked like "MQL4 cannot
//     write one" - they were simply running a build from before the write
//     existed;
//   * an MT5 receiver silently ran an ELEVEN-HOUR-OLD build, because
//     MetaTrader does NOT reload an EA whose .ex5 was replaced by an
//     external compiler. The new feature was simply not in the running
//     process, and nothing said so.
//
// Guarded so it can never break a build: if the compiler has no
// __DATETIME__, the stamp degrades to "unknown" rather than failing.
//=====================================================================
#ifdef __DATETIME__
#define CP_BUILD_STAMP TimeToString(__DATETIME__,TIME_DATE|TIME_MINUTES)
#else
#error DATETIME_MACRO_NOT_AVAILABLE
#endif

//=====================================================================
// Receiver trade-action kinds. They live here rather than in the
// receiver so the self-test can reach CopierSeenRingApplies() below.
//=====================================================================
#define CP_ACT_OPEN   1
#define CP_ACT_CLOSE  2
#define CP_ACT_TRIM   3   // reduce a position to match the sender's size
//--- DEDUP is its own kind rather than a CLOSE so that its dedup key cannot
//--- collide with a real CLOSE for the same UID in the same tick. That
//--- collision is not hypothetical: when a duplicate is removed and the
//--- survivor is ALSO no longer desired, both must be queued, and a shared
//--- (sender, kind, uid) key would silently drop the second one.
#define CP_ACT_DEDUP  4   // remove a second position carrying the same UID
#define CP_ACT_MODIFY 5   // set a position's SL/TP

//=====================================================================
// Which actions the "already done" ring applies to.
//
// The ring answers "have I already performed this action?", which is a
// meaningful question for a one-shot, irreversible action - an open, a
// close, a trim to a smaller size. It is the WRONG question for an
// idempotent state assignment, and set-stops is one.
//
// Why it matters, from a live pilot: the key is the TARGET state, and the
// ring remembers it for ten minutes. A sender that removed its stop, had it
// re-added, then removed it again was suppressed the second time - the
// receiver kept a stop the sender no longer had. The target (none,none) had
// been reached at 17:04:18, and the identical target at 17:04:45 was
// silently dropped. Changing the take-profit changed the key, which is why
// it looked like "touching the TP fixes it".
//
// The correct guard for an idempotent assignment is not "have I done this"
// but "does the current state differ from the target" - evaluated fresh on
// every converge pass. So the ring is bypassed for MODIFY, and that
// comparison carries the whole burden.
//
// TRIM is safe to keep in the ring precisely because it is NOT idempotent:
// it only ever shrinks, so a target volume cannot recur.
//=====================================================================
bool CopierSeenRingApplies(const int kind)
  {
   return (kind!=CP_ACT_MODIFY);
  }

//=====================================================================
// Wire separators. Chosen so they never collide with each other and
// are extremely unlikely to appear in broker symbol names.
//   envelope fields : |
//   payload k=v     : ;
//   repeated records: ~
//   items in record : ,
//=====================================================================
#define CP_SEP_FIELD "|"
#define CP_SEP_KV    ";"
#define CP_SEP_REC   "~"
#define CP_SEP_ITEM  ","

#define CP_PROTO_V   1
#define CP_MSG_MAX   16

// message types
#define CP_T_SNAP    "SNAP"   // full open-position snapshot (authoritative)
#define CP_T_OPEN    "OPEN"   // event: position opened
#define CP_T_CLOSE   "CLOSE"  // event: position closed
#define CP_T_PARTIAL "PARTIAL"// event: partial close      (RESERVED - never emitted)
//--- MODIFY is LIVE: the sender emits it when a mirrored position's SL/TP
//--- changes (CopierSender.mq4, Emit(CP_T_MODIFY,...)) and the receiver acts on
//--- it in HandleModifyEvent. The comment here said "(P4, reserved)" long after
//--- that landed, which is the kind of note that makes a reader skip the one
//--- message type they are looking for.
#define CP_T_MODIFY  "MODIFY" // event: sl/tp changed
#define CP_T_HBT     "HBT"    // heartbeat + account state
#define CP_T_STAT    "STAT"   // receiver -> sender status
#define CP_T_CFG     "CFG"    // hub -> node : apply this config (M4b)
#define CP_T_ACK     "ACK"    // node -> hub : the result of a CFG
#define CP_T_CFGR    "CFGR"   // node -> hub : send me my config again
#define CP_T_CFGREPORT "CFGRPT" // node -> hub : current effective config report
#define CP_T_CMD     "CMD"    // hub -> node : operational command (M5b)
//--- SNAPSHOT RECEIPT, hub -> sender (central channel only).
//---
//--- In DIRECT mode the receiver's STAT reaches the sender on its own, and the
//--- receipt rides in it. In CENTRAL mode it CANNOT: the hub consumes every
//--- '@'-prefixed message, and D13 (CENTRAL-HUB-PLAN.md) says the receiver's
//--- status belongs to the hub rather than to any one sender. So the hub
//--- extracts just the delivery receipt and relays THAT.
//---
//--- A new T rather than more fields on STAT, for the reason set out below:
//--- the sender must be able to tell "the hub relayed a receipt" from "a
//--- receiver reported its status". They arrive on different paths and only
//--- one of them is addressed to this sender.
//---
//--- This is a REFINEMENT of D13, not an exception to it. D13 keeps the
//--- monitoring figures - equity, lots, risk, what the receiver IS - at the
//--- hub. What travels here is not status: it is "did my bytes arrive", which
//--- only the sender can act on and which no other node can observe.
#define CP_T_RCPT    "RCPT"
//--- Liveness probe. This exists because the messages that already flow are
//--- NOT frequent enough in both directions to judge liveness:
//---   sender -> receiver : snapshot every 2s, heartbeat every 1s   (plenty)
//---   receiver -> sender : STAT once a MINUTE                      (far too slow)
//--- With a 15s timeout and a 60s status cadence, the sender declares the
//--- receiver dead 45 seconds before the next thing it would hear arrives, so
//--- every peer flaps down-and-up forever and the operator gets a popup per
//--- cycle. Liveness needs a message rate on BOTH sides, and only a probe
//--- provides that in the upward direction.
//---
//--- PING carries the sender's monotonic millisecond clock; PONG echoes that
//--- number back VERBATIM, so the originator computes (now - echoed) as a true
//--- round trip WITHOUT either side needing a synchronised clock. Comparing
//--- two machines' wall clocks would measure the clock difference, not the link.
#define CP_T_PING    "PING"
#define CP_T_PONG    "PONG"

//--- CENTRAL CHANNEL (Tier 2) control, node -> hub and hub -> all.
//---
//--- NEW T VALUES, deliberately, rather than more fields on HBT. A node parses
//--- a payload by splitting on ';' and reading k=v, so an added key is usually
//--- harmless - but a MISSING one is not, and the hub has to keep talking to
//--- nodes built before it. A new T costs nothing and removes the question.
//--- That rule was set in v1 and this is the first time it applies.
//---
//--- REG exists because the hub is stateless across a restart. A node that
//--- connects and says nothing is invisible; the hub cannot discover it, and
//--- the firewall will not tell it either. So every node ANNOUNCES itself, and
//--- re-announces on demand (WHO).
#define CP_T_REG     "REG"    // node -> hub : here I am, this is who I am
#define CP_T_HBT2    "HBT2"   // node -> hub : still here. Central channel only
#define CP_T_WHO     "WHO"    // hub -> all  : re-register, my table is empty
#define CP_T_TOPOLOGY "TOPOLOGY" // hub -> node : cluster topology with primary and standby endpoints

//--- Sequence stream channels for receiver deduplication
#define CP_STREAM_EVENTS 0
#define CP_STREAM_SNAP   1
#define CP_STREAM_HBT    2
#define CP_STREAM_COUNT  3

#define CP_MAX_CLUSTER_HUBS 2

//--- The version a node reports in REG/HBT2.
//---
//--- The CENTRAL-CHANNEL protocol version, NOT the build stamp. The hub uses it
//--- to decide whether it can talk to a node at all; a build stamp is a
//--- datetime that changes on every compile and would make every node look
//--- "upgraded" for no reason.
#define CP_NODE_VER  "2.0"

//--- How often a node says "still here" on the central channel.
//---
//--- 5 s against the hub's 15 s stale threshold - three missed heartbeats
//--- before anyone is called stale, which rides out a single lost message
//--- without flapping and still notices a real death inside 15 s. The two
//--- numbers are a PAIR: changing one without the other either makes every
//--- node look dead on one dropped packet, or makes a dead node look alive
//--- for a minute.
//---
//--- The cost is a ~70-byte message every 5 s per node. At fifty nodes that is
//--- still under a kilobyte a second.
#define CP_HBT2_MS   5000

//--- How many of a node's first announcements are REG rather than HBT2.
//---
//--- The startup REG CAN BE LOST, and this is not hypothetical - it was
//--- measured. The socket is opened with ZMQ_IMMEDIATE, so a send made before
//--- the TCP connection completes is DISCARDED rather than queued, and the
//--- very first thing a node sends is exactly that: a REG fired immediately
//--- after connect().
//---
//--- The consequence is subtle and was mistaken for a broken hub. The node is
//--- still VISIBLE - HBT2 creates it - but it is ANONYMOUS, because only REG
//--- carries a name. So the hub counted nodes and printed no line explaining
//--- any of them.
//---
//--- Repeating REG three times closes the race inside one heartbeat interval
//--- (10 s) and costs three extra messages, once per attach. REG is idempotent,
//--- so a repeat that arrives after the first one has landed is ignored.
#define CP_REG_REPEATS 3

// trade directions
#define CP_SIDE_BUY   1
#define CP_SIDE_SELL -1

//=====================================================================
// Entry kind. A pending order is the same mirroring problem as a market
// position - open it, size it, cancel it when the sender cancels - so it
// travels in the same record and the same desired set rather than in a
// parallel universe.
//=====================================================================
#define CP_ORD_MARKET  0
#define CP_ORD_PENDING 1

#define CP_PEND_BUYLIMIT      1
#define CP_PEND_SELLLIMIT     2
#define CP_PEND_BUYSTOP       3
#define CP_PEND_SELLSTOP      4
#define CP_PEND_BUYSTOPLIMIT  5   // stop-limit: pprice triggers, pstop is the limit
#define CP_PEND_SELLSTOPLIMIT 6

//--- A pending entry that is not one of the six above cannot be mirrored
//--- faithfully, so it is skipped and reported rather than approximated.
bool CopierPendingTypeKnown(const int t)
  {
   return (t>=CP_PEND_BUYLIMIT && t<=CP_PEND_SELLSTOPLIMIT);
  }

//--- Does this pending type need the second (limit) price?
bool CopierPendingNeedsStop(const int t)
  {
   return (t==CP_PEND_BUYSTOPLIMIT || t==CP_PEND_SELLSTOPLIMIT);
  }

//--- Side a pending type belongs to.
int CopierPendingSide(const int t)
  {
   if(t==CP_PEND_BUYLIMIT || t==CP_PEND_BUYSTOP || t==CP_PEND_BUYSTOPLIMIT)
      return CP_SIDE_BUY;
   return CP_SIDE_SELL;
  }

// UID: 8 chars of Crockford base32 (no i/l/o/u), written into the
// receiver's order comment as "tc|<uid>|<senderTicket>" (see
// CopierCommentForUid below for why the UID comes first).
#define CP_UID_LEN     8
//--- On-chart panel colours.
//---
//--- The background is opaque and dark on purpose. A panel is drawn over
//--- candles, gridlines and whatever background colour the chart template
//--- happens to use; translucent or light-on-light loses to all of them. The
//--- status colours are picked to stay readable against THAT background, not
//--- against the chart.
#define CP_PANEL_BG      C'22,30,44'
#define CP_PANEL_BORDER  C'96,118,148'
#define CP_PANEL_TITLE   clrWhite
#define CP_PANEL_TEXT    C'208,216,228'
#define CP_PANEL_DIM     C'138,152,172'
#define CP_PANEL_OK      C'120,230,140'
#define CP_PANEL_WARN    C'255,196,84'
#define CP_PANEL_BAD     C'255,104,104'

#define CP_COMMENT_PFX "tc|"
#define CP_UID_ALPHA   "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

//=====================================================================
// Normalised position. This is the ONLY position representation that
// crosses module boundaries - never pass raw MT4 orders / MT5
// positions around.
//=====================================================================
struct CopierPos
  {
   string            uid;
   string            sym;      // symbol name AS SEEN BY THE OWNER
   string            cmt;      // broker comment (LOCAL ONLY - never on wire)
   int               side;     // CP_SIDE_BUY / CP_SIDE_SELL
   double            lots;
   double            openPx;
   double            sl;
   double            tp;
   long              ticket;   // MT4: order ticket / MT5: POSITION_IDENTIFIER
   long              magic;
   long              openTime; // broker server time, seconds
   //--- pending entries. `kind` is CP_ORD_MARKET for a normal position, in
   //--- which case the four fields below are 0 and mean nothing. Keeping
   //--- them in the same struct is what lets one converge loop, one desired
   //--- set and one record format cover both - a pending order is the same
   //--- mirroring problem, not a separate feature.
   int               kind;     // CP_ORD_MARKET / CP_ORD_PENDING
   int               ptype;    // CP_PEND_* when kind==CP_ORD_PENDING
   double            pprice;   // trigger price
   double            pstop;    // stop-limit only: the limit price
   long              pexpire;  // broker server time, 0 = good till cancelled
   bool              used;     // slot occupied (fixed-size table)
  };

//=====================================================================
// Parse errors
//=====================================================================
#define CP_ERR_NONE        0
#define CP_ERR_TRUNCATED   1
#define CP_ERR_BAD_ENVELOPE 2
#define CP_ERR_BAD_VERSION 3
#define CP_ERR_BAD_TYPE    4
#define CP_ERR_BAD_RECORD  5

//=====================================================================
// Platform-neutral helpers
//=====================================================================
// Monotonic-ish clock in milliseconds, used only for intervals inside
// one process. Uses high-resolution microsecond timer where available for sub-1ms accuracy.
long CopierNowMs()
  {
#ifdef __MQL5__
   return (long)(GetMicrosecondCount()/1000);
#else
   return (long)(GetMicrosecondCount()/1000);
#endif
  }

// Broker server time in seconds. This is the only timestamp we ever
// put on the wire - VPS wall clocks are not to be trusted.
long CopierServerTime()
  {
#ifdef __MQL5__
   return (long)TimeTradeServer();
#else
   return (long)TimeCurrent();
#endif
  }

long CopierAccountLogin()
  {
#ifdef __MQL5__
   return (long)AccountInfoInteger(ACCOUNT_LOGIN);
#else
   return (long)AccountNumber();
#endif
  }

//--- The terminal's own name, for the hub's node table.
//---
//--- An operator recognises "Alpari MT4 - Demo" instantly and a NID not at
//--- all, so this is what the registry shows beside the account. It is
//--- DISPLAY ONLY: nothing routes on it, and two terminals may legitimately
//--- share one. Do not be tempted to make it an identity - the account is the
//--- identity, and a name that can be edited is not one.
string CopierTerminalName()
  {
#ifdef __MQL5__
   return TerminalInfoString(TERMINAL_NAME);
#else
   return TerminalName();
#endif
  }

//--- The BROKER's own caps, not ours.
//---
//--- A platform may allow 200 open positions, or 500, or something else
//--- entirely. Our tables (CP_MAX_POSITIONS) are a separate, internal
//--- question. Asking the broker is the only way to know, and sending an
//--- order it is going to refuse - over and over - is how an account gets
//--- throttled or blocked.
//---
//--- The cap brokers impose (200, 500, ...) is on ORDERS, and it is a
//--- quota over BOTH pools together - a working order sits in the orders
//--- pool on MT5 and is NOT counted under positions, so counting positions
//--- alone would miss every pending order. The caller therefore checks
//--- (open positions + pending orders) against this number, which is how a
//--- broker's order quota actually works.
//---
//--- 0 or less means UNKNOWN, and callers must treat it that way - never as
//--- "unlimited", because guessing unlimited is the dangerous direction.
//---
//--- The property is ACCOUNT_LIMIT_ORDERS. There is no ACCOUNT_LIMIT_POSITIONS
//--- - it does not compile on the MT5 build here, and inventing a numeric
//--- property id to work around that is worse than not asking: a wrong id
//--- silently returns 0, which reads as "no limit", which is exactly the
//--- dangerous direction.
//---
//--- This used to return -1 on MT4, on the claim that "MT4 exposes no
//--- equivalent (no AccountInfoInteger at all)". That claim was wrong: MQL4
//--- gained AccountInfoInteger with the build-600 API, and
//--- ACCOUNT_LIMIT_ORDERS with it. The cost of the wrong claim was that MT4
//--- accounts went without the protection the MT5 side already had, and the
//--- startup log told their operators there was nothing to discover.
//---
//--- Verified by compiling, not by reading the docs: if the constant did not
//--- exist on MT4, this file would not build there at all.
long CopierBrokerOrderLimit()
  {
   return (long)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
  }

double CopierAccountEquity()
  {
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_EQUITY);
#else
   return AccountEquity();
#endif
  }

double CopierAccountBalance()
  {
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_BALANCE);
#else
   return AccountBalance();
#endif
  }

string CopierAccountCurrency()
  {
#ifdef __MQL5__
   return AccountInfoString(ACCOUNT_CURRENCY);
#else
   return AccountCurrency();
#endif
  }

//=====================================================================
// Small string helpers (MQL has no regex and a weak string API)
//=====================================================================
// Count occurrences of a single character.
int CopierCharCount(const string s,const string c)
  {
   int n=0;
   int pos=0;
   while(true)
     {
      int p=StringFind(s,c,pos);
      if(p<0) break;
      n++;
      pos=p+1;
     }
   return n;
  }

// Replace every occurrence of substring 'from' with 'to' across string 's'.
string CopierReplaceAll(string s,const string from,const string to)
  {
   if(StringLen(from)==0) return s;
   if(from==to) return s;
   StringReplace(s,from,to);
   return s;
  }

// Trim leading/trailing whitespace.
//
// Hand-rolled on purpose. MQL4 and MQL5 disagree about
// StringTrimLeft/StringTrimRight: one trims in place via a `string&`
// parameter, the other returns the trimmed value and leaves the argument
// alone. Calling them and discarding the result therefore works on MT5
// and silently does NOTHING on MT4 - which produced config keys with a
// trailing space ("id " instead of "id"), so every lookup of a key written
// as `id = value` missed while `id=value` worked. That asymmetry is
// exactly the kind of bug that only shows up on one platform.
bool CopierIsSpaceChar(const ushort c)
  {
   return c==' ' || c=='\t' || c=='\r' || c=='\n';
  }

string CopierTrim(string s)
  {
   int n=StringLen(s);
   if(n==0) return s;
   int a=0;
   while(a<n && CopierIsSpaceChar(StringGetCharacter(s,a))) a++;
   int b=n;
   while(b>a && CopierIsSpaceChar(StringGetCharacter(s,b-1))) b--;
   if(a==0 && b==n) return s;
   return StringSubstr(s,a,b-a);
  }

//+------------------------------------------------------------------+
// Accept "host:port" as well as "tcp://host:port".
//
// Writing the scheme out every time is pure noise - it is the only transport
// this copier speaks - and omitting it produces a ZeroMQ error that says
// nothing about a missing prefix, so the fix is not obvious from the message.
//
// An explicit scheme is left alone rather than overwritten: if a future
// transport appears (ipc://, inproc://), spelling it out must still work.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
// "90000" tells a reader nothing; "1d 1h" does.
//
// Separate from CopierBackoffText(), which takes a FAILURE COUNT and looks up
// the ladder. Passing a duration into that one silently returns the ladder's
// first rung instead - which is exactly how a "waiting for 60s" message came
// to print "waiting for 2s" and made a working feature look broken.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
// Has a P&L reading reached the configured profit threshold?
//
// The threshold points in a DIRECTION and the trade has to travel to it:
//   +10 -> 10 pips in profit
//   -10 -> 10 pips in LOSS, i.e. wait for a pullback and enter cheaper
//     0 -> disabled, always satisfied
//
// A single `profitPips < threshold` comparison covers only the positive
// half: for a negative threshold it is true at entry, so the gate silently
// does nothing and the setting looks broken. Both sides are explicit.
//+------------------------------------------------------------------+
bool CopierProfitTargetReached(const double profitPips,const double threshold)
  {
   if(threshold==0.0) return true;
   return (threshold>0.0)?(profitPips>=threshold)
                         :(profitPips<=threshold);
  }

string CopierSecText(long sec)
  {
   if(sec<0) sec=0;
   if(sec<60)    return (string)sec+"s";
   if(sec<3600)  return (string)(sec/60)+"m "+(string)(sec%60)+"s";
   if(sec<86400) return (string)(sec/3600)+"h "+(string)((sec%3600)/60)+"m";
   return (string)(sec/86400)+"d "+(string)((sec%86400)/3600)+"h";
  }

string CopierNormalizeEndpoint(const string ep)
  {
   string s=CopierTrim(ep);
   if(StringLen(s)==0) return s;
   if(StringFind(s,"://")>=0) return s;
   return "tcp://"+s;
  }

int CopierParseEndpoints(const string inputStr,string &outEndpoints[],const int maxEndpoints)
  {
   int count=0;
   string s=CopierTrim(inputStr);
   if(StringLen(s)==0 || maxEndpoints<=0) return 0;

   int semiPos=StringFind(s,";");
   if(semiPos<0)
     {
      outEndpoints[0]=CopierNormalizeEndpoint(s);
      return 1;
     }

   string parts[];
   int n=StringSplit(s,';',parts);
   for(int i=0;i<n;i++)
     {
      string p=CopierTrim(parts[i]);
      if(StringLen(p)==0) continue;
      string norm=CopierNormalizeEndpoint(p);
      bool dup=false;
      for(int k=0;k<count;k++)
        {
         if(outEndpoints[k]==norm) { dup=true; break; }
        }
      if(!dup && count<maxEndpoints)
        {
         outEndpoints[count++]=norm;
        }
     }
   return count;
  }

// Strip anything that could break the wire format out of a broker
// supplied string (symbol, comment). Also truncates.
string CopierSanitize(string s,const int maxLen)
  {
   // NM-09: Fast check - if string has no forbidden separators and satisfies length,
   // return immediately with zero reallocations.
   int n=StringLen(s);
   if(n<=0) return s;
   bool need=false;
   for(int i=0;i<n;i++)
     {
      ushort c=StringGetCharacter(s,i);
      if(c=='|' || c==';' || c=='~' || c==',' || c=='=') { need=true; break; }
     }
   if(!need && n<=maxLen) return s;
   if(need)
     {
      s=CopierReplaceAll(s,CP_SEP_FIELD,"_");
      s=CopierReplaceAll(s,CP_SEP_KV,"_");
      s=CopierReplaceAll(s,CP_SEP_REC,"_");
      s=CopierReplaceAll(s,CP_SEP_ITEM,"_");
      s=CopierReplaceAll(s,"=","_");
     }
   if(StringLen(s)>maxLen) s=StringSubstr(s,0,maxLen);
   return s;
  }

#define CP_SYM_MAXLEN   24
#define CP_COMM_MAXLEN  24
#define CP_UID_MAXLEN   16

string CopierSanitizeSymbol(const string s)  { return CopierSanitize(s,CP_SYM_MAXLEN);  }
string CopierSanitizeComment(const string s) { return CopierSanitize(s,CP_COMM_MAXLEN); }

// Extract value of "KEY=" from a ";"-separated payload.
// Returns false when the key is absent.
bool CopierKvGet(const string payload,const string key,string &out)
  {
   out="";
   string needle=key+"=";
   int p=StringFind(payload,needle);

   //--- KEEP LOOKING. One key can be a SUFFIX of another in the same payload
   //--- - "OTS" sits inside "LOTS" - so the first textual match is often the
   //--- wrong one. Returning false there does not just miss the key: it
   //--- reports the key as ABSENT, and the caller falls back to its default.
   //---
   //--- That is exactly what happened. "OTS=" matched inside "LOTS=0.01", the
   //--- preceding character was not a separator, and the function gave up -
   //--- so every OPEN EVENT decoded openTime as 0. Snapshot records decode by
   //--- POSITION and were unaffected, which made the fault look intermittent:
   //--- positions already open had a correct time, and the newly opened ones
   //--- - precisely the ones the wait and fill-timeout gates exist for - did
   //--- not.
   while(p>=0)
     {
      if(p==0) break;                                    // at the very start
      if(StringSubstr(payload,p-1,1)==CP_SEP_KV) break;   // preceded by ';'
      p=StringFind(payload,needle,p+1);                   // try the next match
     }
   if(p<0) return false;

   int start=p+StringLen(needle);
   int end=StringFind(payload,CP_SEP_KV,start);
   if(end<0) end=StringLen(payload);
   out=StringSubstr(payload,start,end-start);
   return true;
  }

double CopierKvGetDouble(const string payload,const string key,const double deflt)
  {
   string v;
   if(!CopierKvGet(payload,key,v)) return deflt;
   return StringToDouble(v);
  }

//+------------------------------------------------------------------+
// Decimal string -> 64-bit long, by hand.
//
// StringToInteger is 32-BIT on MQL4 and 64-bit on MQL5, so a value above
// 2^31 silently wraps on one platform and not the other. That matters here:
// the monotonic millisecond clock passes 2^31 after about 25 days of uptime,
// and a wrapped tick count turns the link-delay arithmetic into noise on a VPS
// that has simply been up a long time - a failure that looks like a network
// problem and is not.
//+------------------------------------------------------------------+
//=====================================================================
// Chunked string builder.
//
// WHY THIS EXISTS
// ===============
// MQL strings have no capacity doubling: `s += x` allocates a NEW string and
// copies the WHOLE of `s` every time. A builder that appends 126 fixed lines
// per sender is therefore O(total^2): a 100-sender config is ~270 KB, which
// works out to roughly a gigabyte of memcpy per serialisation - on the EA's
// main thread, which is also the thread that receives snapshots and sends
// orders. The same shape appears in the INI escaper (one append PER CHARACTER,
// ~36 GB of copying at 270 KB) and in the snapshot encoder (one append per
// record).
//
// This collects into ~4 KB chunks and merges them pairwise, which is
// O(n log n) copying with no exotic API: ArrayResize, `+`, and StringLen are
// available and identical on every MetaTrader build this project compiles
// under. StringJoin/StringSetLength are NOT used deliberately - they are the
// kind of thing that compiles on one build and not the other, and this header
// has to compile on both.
//=====================================================================
#define CP_SB_FLUSH 4096

class CopierStrBuilder
  {
private:
   string            m_buf;      // pending chunk, kept under ~CP_SB_FLUSH
   string            m_parts[];  // flushed chunks
   int               m_n;

public:
                     CopierStrBuilder() { m_buf=""; m_n=0; }

   void              Reset()
     {
      m_buf="";
      for(int i=0;i<m_n;i++) m_parts[i]="";
      m_n=0;
     }

   int               ChunkCount() const { return m_n; }

   void              Flush()
     {
      if(StringLen(m_buf)==0) return;
      if(m_n>=ArraySize(m_parts)) ArrayResize(m_parts,m_n+1,64);
      m_parts[m_n]=m_buf;
      m_n++;
      m_buf="";
     }

   void              Add(const string s)
     {
      m_buf+=s;
      if(StringLen(m_buf)>=CP_SB_FLUSH) Flush();
     }

   //--- Join and consume. The builder is reusable afterwards.
   string            Result()
     {
      Flush();
      if(m_n==0) return "";
      if(m_n==1)
        {
         string one=m_parts[0];
         m_parts[0]="";
         m_n=0;
         return one;
        }
      //--- pairwise merge: each round halves the chunk count, so the total
      //--- copied is O(n log n) rather than O(n^2)
      int w=m_n;
      while(w>1)
        {
         int r=0;
         for(int i=0;i+1<w;i+=2)
           {
            //--- R60-01: Take merged temporary first!
            //--- When i=0 and r=0, m_parts[r]=m_parts[i]+m_parts[i+1] followed
            //--- immediately by m_parts[i]="" erased m_parts[0] on the first pair.
            //--- Any string spanning >= 2 chunks (>= 4KB) returned empty string.
            string merged=m_parts[i]+m_parts[i+1];
            m_parts[i]="";
            m_parts[i+1]="";
            m_parts[r]=merged;
            r++;
           }
         if((w&1)!=0)
           {
            string tail=m_parts[w-1];
            m_parts[w-1]="";
            m_parts[r]=tail;
            r++;
           }
         w=r;
        }
      string out=m_parts[0];
      m_parts[0]="";
      m_n=0;
      m_buf="";
      return out;
     }
  };

long CopierParseLong(const string s)
  {
   long v=0;
   bool neg=false;
   int n=StringLen(s);
   int i=0;
   if(n>0 && StringGetCharacter(s,0)=='-') { neg=true; i=1; }
   for(;i<n;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c<'0' || c>'9') break;
      v=v*10+(long)(c-'0');
     }
   return neg?-v:v;
  }

//=====================================================================
// Parse a signed integer that occupies s[start..end) WITHOUT building a
// substring.
//
// The snapshot decoder calls this seven times per record (ticket, side, magic,
// openTime, kind, ptype, pexpire). StringSubstr allocates a fresh string each
// time, so at 2048 records that is ~14,000 throwaway allocations per snapshot
// purely to feed a parser that only wants the digits.
//=====================================================================
long CopierParseLongRange(const string s,const int start,const int end)
  {
   if(start<0 || end<=start) return 0;
   long v=0;
   bool neg=false;
   int i=start;
   if(i<end && StringGetCharacter(s,i)=='-') { neg=true; i++; }
   for(;i<end;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c<'0' || c>'9') break;
      v=v*10+(long)(c-'0');
     }
   return neg?-v:v;
  }

bool CopierIsDigits(const string s)
  {
   int len=StringLen(s);
   if(len==0) return false;
   for(int i=0;i<len;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c<'0' || c>'9') return false;
     }
   return true;
  }

long CopierKvGetLong(const string payload,const string key,const long deflt)
  {
   string v;
   if(!CopierKvGet(payload,key,v)) return deflt;
   return CopierParseLong(v);
  }

int CopierKvGetInt(const string payload,const string key,const int deflt)
  {
   string v;
   if(!CopierKvGet(payload,key,v)) return deflt;
   return (int)StringToInteger(v);
  }

//=====================================================================
// Number formatting: always invariant ('.'), never locale dependent.
// Strips unnecessary trailing zeroes and trailing dot to cut wire bandwidth.
//=====================================================================
string CopierFmtDouble(const double v,const int digits)
  {
   if(MathAbs(v)<0.000000001) return "0";
   string s=DoubleToString(v,digits);
   int dot=StringFind(s,".");
   if(dot<0) return s;
   int len=StringLen(s);
   while(len>dot+1 && StringGetCharacter(s,len-1)=='0') len--;
   if(len==dot+1) len--; // remove dot if integer
   return StringSubstr(s,0,len);
  }

#ifndef CP_DIGITS_LOTS
#define CP_DIGITS_LOTS 8
#endif

//--- N72-01: Structure-level lot encodability predicate.
//--- Directly queries CopierFmtDouble to guarantee that any lot passing this check
//--- formats to a non-zero representation, preventing snapshot rejection deadlocks.
bool CopierLotEncodable(const double lots)
  {
   if(lots<=0.0) return false;
   return (CopierFmtDouble(lots,CP_DIGITS_LOTS)!="0");
  }

//=====================================================================
// UID generation
//=====================================================================
// NH-05: Robust UID generator.
// Avoids MSVC LCG low-5-bit cycle defect (MathRand()%32) by mixing
// 64-bit monotonic time, account number, sequential counter, and FNV-1a
// cross-bit avalanche diffusion to achieve full 32^8 (1.1e12) entropy space.
string CopierNewUid()
  {
   static uint s_seq=0;
   s_seq++;
   long t=CopierNowMs();
   long acc=CopierAccountLogin();
   long mix = t ^ (acc<<17) ^ ((long)s_seq * (long)0x9E3779B97F4A7C15);
   uint h = (uint)CopierHash32((string)mix+"|"+(string)t+"|"+(string)s_seq+"|"+(string)acc);
   uint h2 = (uint)CopierHash32((string)h+"|uid_salt_2");

   string s="";
   for(int i=0;i<CP_UID_LEN;i++)
     {
      uint nib = (h >> (i*4)) ^ (h2 >> (i*3)) ^ (uint)(mix >> (i*7));
      s += StringSubstr(CP_UID_ALPHA, (int)(nib & 31), 1);
     }
   return s;
  }

//=====================================================================
// Order comment written by the RECEIVER onto the orders it opens.
//
//   tc|<uid>|<senderTicket>        e.g.  tc|ABCD1234|9918271
//
// Ordering is deliberate and load-bearing: the UID comes FIRST, the
// human-friendly sender ticket SECOND.
//
//   * MT4 caps comments at 31 characters and some brokers cap them at 27,
//     so the comment can be truncated by the venue at any time. With the
//     UID first, truncation costs you the sender ticket - which is only
//     used for eyeballing an order against the sender's terminal - and
//     never the UID, which is what every mapping in the system depends on.
//   * The UID is a fixed 8 chars, so a parser can find it by position
//     regardless of what follows.
//
// The sender ticket is the SENDER's own ticket / MT5 position identifier
// for the position being mirrored, taken straight off the wire. It is
// stable across partial closes on MT5 (it is the identifier, not the
// position ticket), so it stays meaningful for the life of the position.
//=====================================================================
#define CP_COMMENT_MAX 30        // stays clear of the 31-char MT4 limit
#define CP_TICKET_MAXLEN 18      // room left for the ticket inside the cap

string CopierCommentForUid(const string uid,const long senderTicket=0)
  {
   string c=CP_COMMENT_PFX+uid;
   if(senderTicket!=0)
     {
      string t=(string)senderTicket;
      if(StringLen(t)>CP_TICKET_MAXLEN) t=StringSubstr(t,0,CP_TICKET_MAXLEN);
      c+="|"+t;
     }
   if(StringLen(c)>CP_COMMENT_MAX) c=StringSubstr(c,0,CP_COMMENT_MAX);
   return c;
  }

// The NODE ID: an account number reduced to at most 9 digits.
//
// Used on the central channel as the sender's SID, as the ZMQ topic that
// carries its data, and as the magic its mirrors are opened under. One value,
// three uses - so it has to be a pure function of the account number, and it
// has to be the same function everywhere.
//
// WHY 9 DIGITS: MT4's OrderSend takes a 32-bit SIGNED int magic, so nothing
// above 2147483647 can be a magic at all. Nine digits tops out at 999999999,
// which is always safe. MT5 would not need this, but ONE rule is worth more
// than a per-platform rule nobody can remember.
//
// WHY THE LAST NINE, not the first: a broker's account numbers usually share a
// leading broker/type prefix and differ in the trailing serial, so the last
// nine discriminate better. 1234567890 -> 234567890.
//
// WHY PURE: it is recomputed on every start, on both ends, and again after any
// config the hub pushes. A value that differed between runs would change a
// sender's magic and orphan every position already open under the old one -
// which is the exact failure the magic handling elsewhere exists to prevent.
//
// Truncation CAN collide (1234567890 and 1234567891 both give 234567890), but
// that is caught rather than suffered: two senders on one magic are refused at
// startup, loudly. See ReportMagicConfig() in the receiver.
long CopierNid(const long account)
  {
   // NL-03: Ensure non-positive accounts (e.g. unlogged terminal account 0)
   // never return 0, protecting the "magic 0 = manual trade" invariant.
   if(account <= 0) return 999999998;
   if(account < 1000000000) return account;

   long nid=account % 1000000000;
   //--- 0 is NOT a harmless result here.
   //---
   //--- Magic 0 is meaningful in this codebase: it is what a hand-placed trade
   //--- carries, and the sender's own IncludeMagicNumbers filter reads "0" as
   //--- "the manual trades". A receiver whose mirror magic was 0 would find
   //--- its own mirrors and the operator's manual trades in the SAME set, and
   //--- would manage both - closing trades it was never told about.
   //---
   //--- Only accounts that are exact multiples of 1e9 land here, which is rare
   //--- but not impossible. Nudge to a value that cannot be confused with
   //--- "manual". A collision with another account is possible either way, and
   //--- is caught loudly at startup rather than suffered (two senders on one
   //--- magic are refused).
   if(nid==0) nid=999999999;
   return nid;
  }

// Is this a well-formed UID?
//
// Exactly CP_UID_LEN characters, all drawn from the Crockford base32 alphabet.
//
// Shared on purpose. The UID is now typed BY HAND into a receiver input as
// well as read out of an order comment, and those two must agree: if the
// input accepted something the comment parser rejects, the operator would add
// a UID that is silently never matched, and the position they asked to be left
// alone would be managed anyway. One rule, two callers, no drift.
//
// Note it does NOT normalise I/L -> 1 or O -> 0 the way full Crockford does.
// The comment parser does not either, so doing it here would create exactly
// the mismatch this function exists to prevent.
bool CopierUidValid(const string uid)
  {
   if(StringLen(uid)!=CP_UID_LEN) return false;
   for(int i=0;i<CP_UID_LEN;i++)
     {
      ushort c=StringGetCharacter(uid,i);
      if((c>='0' && c<='9') || (c>='A' && c<='Z' && c!='I' && c!='L' && c!='O' && c!='U'))
         continue;
      return false;
     }
   return true;
  }

// Recover the UID out of an order comment written earlier by a receiver.
// Returns "" when the comment is not one of ours.
//
// Reads the UID by POSITION (8 chars right after "tc|"), so it is
// unaffected by the sender ticket that now follows, and it still works on
// comments written before that field existed.
string CopierUidFromComment(const string comment)
  {
   int p=StringFind(comment,CP_COMMENT_PFX);
   if(p<0) return "";
   int start=p+StringLen(CP_COMMENT_PFX);
   if(start+CP_UID_LEN>StringLen(comment)) return "";
   string uid=StringSubstr(comment,start,CP_UID_LEN);
   if(!CopierUidValid(uid)) return "";
   return uid;
  }

// Recover the sender's ticket from one of our comments. 0 when absent -
// which is the normal case for orders opened before this field existed.
long CopierSenderTicketFromComment(const string comment)
  {
   if(StringLen(CopierUidFromComment(comment))==0) return 0;
   int p=StringFind(comment,CP_COMMENT_PFX);
   int start=p+StringLen(CP_COMMENT_PFX)+CP_UID_LEN;
   if(start>=StringLen(comment)) return 0;
   if(StringSubstr(comment,start,1)!="|") return 0;
   start++;
   string digits="";
   for(int i=start;i<StringLen(comment);i++)
     {
      string c=StringSubstr(comment,i,1);
      if(c<"0" || c>"9") break;
      digits+=c;
     }
   if(StringLen(digits)==0) return 0;
   return CopierParseLong(digits);
  }

//=====================================================================
// Which of two positions sharing one UID should survive.
//
// One UID must map to exactly one position - LocalFindUid, the seen-ring
// and the state file all assume it. When that breaks, the extra position is
// invisible to every loop and just doubles the exposure, so the receiver
// removes it. This decides which one to keep.
//
// Priority order, most significant first:
//
//   1. agrees with the volume the sender holds right now - the truth beats
//      everything, and it is what makes a stale duplicate lose
//   2. still identifiable from its own comment - it is the one the rest of
//      the system can see, so keeping it needs no further recovery
//   3. the OLDEST position - the original, so what gets removed is the copy
//      we added rather than the position the trade started from
//   4. the smaller identifier - a pure tie-break, so the outcome never
//      depends on the order the terminal enumerates positions in
//
// Returns true when `a` is the better survivor than `b`.
// `want` is the sender's volume for this UID, or <= 0 when unknown.
//
// Lives here, not in the receiver, purely so CopierSelfTest can reach it:
// the ordering is the whole safety argument for closing a live position,
// and it is exactly the kind of thing that regresses silently.
//=====================================================================
bool CopierPreferSurvivor(const CopierPos &a,const CopierPos &b,const double want)
  {
   if(want>0.0)
     {
      bool am=(MathAbs(a.lots-want)<0.0000001);
      bool bm=(MathAbs(b.lots-want)<0.0000001);
      if(am!=bm) return am;
     }
   bool ac=(StringLen(CopierUidFromComment(a.cmt))>0);
   bool bc=(StringLen(CopierUidFromComment(b.cmt))>0);
   if(ac!=bc) return ac;
   if(a.openTime!=b.openTime) return (a.openTime<b.openTime);
   return (a.ticket<b.ticket);
  }

//=====================================================================
// Map a sender's stop/limit price onto the receiver's own position.
//
// The two sides hold the same trade at DIFFERENT prices - a different
// broker, and a fill seconds later. So the sender's stop cannot be copied
// as a price: a 20-pip stop on the sender can land on the wrong side of
// the receiver's entry, which is an instant stop-out or a rejected modify.
//
// What is copied instead is the DISTANCE from the entry. That is also the
// quantity that actually carries the risk: under lotmode=multiplier the
// receiver's exposure scales with its volume, and a distance-based stop
// scales with it in the same proportion. It is additionally immune to the
// two brokers quoting at different digit precision, because a distance in
// price units means the same thing either way.
//
// Returns 0.0 when there is nothing usable to mirror:
//
//   * the sender has no stop (0), or
//   * either entry price is unknown, or
//   * the sender's stop is on the WRONG SIDE of its own entry, so the
//     value cannot be trusted as a stop at all.
//
// That last case is refused rather than guessed at: mirroring it would
// place a stop that is already breached, and a wrong stop is worse than no
// stop. The caller logs it.
//
// The result is NOT rounded - the caller owns the symbol's digits.
//=====================================================================
double CopierMirrorStop(const double senderStop,const double senderOpen,
                        const double localOpen,const int side,const bool isSl)
  {
   if(senderStop<=0.0) return 0.0;
   if(senderOpen<=0.0) return 0.0;
   if(localOpen<=0.0)  return 0.0;

   //--- a stop-loss sits against the trade, a take-profit with it
   bool below=(isSl ? (side==CP_SIDE_BUY) : (side==CP_SIDE_SELL));

   double dist=0.0;
   if(below)
     {
      if(senderStop>=senderOpen) return 0.0;   // wrong side of its own entry
      dist=senderOpen-senderStop;
     }
   else
     {
      if(senderStop<=senderOpen) return 0.0;   // wrong side of its own entry
      dist=senderStop-senderOpen;
     }
   if(dist<=0.0) return 0.0;

   return (below ? (localOpen-dist) : (localOpen+dist));
  }

//+------------------------------------------------------------------+
// Which of the sender's levels feeds OUR stop, and which feeds OUR target?
//
// An inverted mirror swaps them. The sender's stop-out level is where we take
// profit, and the sender's take-profit level is where we are stopped out -
// because the two sides lose and gain at opposite prices.
//
//   sender BUY @1.1000, SL 1.0950, TP 1.1100
//   our SELL  ->  SL 1.1100 (the sender's target), TP 1.0950 (the sender's stop)
//
// Keeping SL as SL and TP as TP leaves our protective stop at the sender's
// RISK distance and our target at the sender's REWARD distance - risk and
// reward swapped, so the mirror is stopped out exactly where the sender banks
// its profit. It is a one-line mistake that produces a plausible-looking pair
// of numbers, which is why it lives in a function with a test.
//+------------------------------------------------------------------+
void CopierMapInvertedStops(const bool invert,
                            const double senderSl,const double senderTp,
                            double &feedSl,double &feedTp)
  {
   if(invert)
     {
      feedSl=senderTp;
      feedTp=senderSl;
     }
   else
     {
      feedSl=senderSl;
      feedTp=senderTp;
     }
  }

//+------------------------------------------------------------------+
// The same thing for an INVERTED mirror.
//
// The difference is the two "wrong side of its own entry" guards above.
// They exist because a stop that sits on the wrong side of the sender's
// own entry is nonsense and must be refused. But when the direction is
// inverted, the sender's stop is ALWAYS on the "wrong" side relative to
// our new side - so those guards reject every stop and the mirror is
// left with NONE.
//
// That failure is quiet and lethal: not a stop on the wrong side (which
// would at least be visible as an instant loss), but no stop at all, on
// a position the operator believes is protected.
//
// So for an inverted mirror the sender's stop is measured purely as a
// MAGNITUDE, and re-applied on whichever side our own direction calls
// for. The distances are preserved exactly; only the side is ours.
//+------------------------------------------------------------------+
double CopierMirrorStopInverted(const double senderStop,
                                const double senderOpen,
                                const double localOpen,
                                const int side,const bool isSl)
  {
   if(senderStop<=0.0) return 0.0;
   if(senderOpen<=0.0) return 0.0;
   if(localOpen<=0.0)  return 0.0;

   double dist=MathAbs(senderStop-senderOpen);
   if(dist<=0.0) return 0.0;

   //--- where OUR stop belongs, given OUR side
   bool below=(isSl ? (side==CP_SIDE_BUY) : (side==CP_SIDE_SELL));
   return (below ? (localOpen-dist) : (localOpen+dist));
  }

//=====================================================================
// Target topic check for Central Hub stream (Pure, testable)
//=====================================================================
bool CopierIsTopicTarget(const string topic,const string myNid,const string myAcc,
                         const string &sids[],const int nSids,const string envSid="")
  {
   if(StringLen(topic)==0) return true;
   if(StringSubstr(topic,0,1)=="@")
     {
      return (topic=="@all" || topic=="@"+myNid || topic=="@"+myAcc);
     }
   // N73-07: Precise topic & sender matching preventing ZMQ prefix collision bypass
   if(topic==myNid || topic==myAcc)
     {
      // Target topic: slice-B targeted repair sent by one of our senders
      if(StringLen(envSid)==0) return true;
      for(int i=0;i<nSids;i++) if(envSid==sids[i]) return true;
      return false;
     }
   for(int i=0;i<nSids;i++)
     {
      if(topic==sids[i] && (StringLen(envSid)==0 || envSid==sids[i])) return true;
     }
   return false;
  }

#endif
//+------------------------------------------------------------------+
