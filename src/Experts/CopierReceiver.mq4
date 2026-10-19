//+------------------------------------------------------------------+
//|                                                CopierReceiver.mq4 |
//| MT4 / MT5 Trade Copier - RECEIVER (execution side)                |
//|                                                                   |
//| ONE instance subscribes to N senders. That is deliberate: N:M is  |
//| handled by configuration, not by running N copies of an EA, which |
//| is exactly what makes the FX Blue equivalent painful to manage.   |
//|                                                                   |
//| Correctness model:                                                |
//|   * the SNAPSHOT is authoritative, events are only a latency      |
//|     optimisation. Losing an event costs nothing but a few seconds |
//|     of divergence, which the next snapshot repairs.               |
//|   * every sender is tracked independently (own sequence counter,  |
//|     own magic number, own desired-position set), so two senders   |
//|     can hold opposing positions on the same symbol without        |
//|     interfering with each other.                                  |
//|   * all trade calls are queued and executed from OnTimer only -   |
//|     never from inside a receive loop, never re-entrantly.         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Trade copier receiver: subscribes to N senders and mirrors them."

#include <Copier/CopierDefs.mqh>
#include <Copier/CopierCodec.mqh>
#include <Copier/CopierLog.mqh>
#include <Copier/CopierState.mqh>
#include <Copier/CopierModel.mqh>
#include <Copier/CopierSymbol.mqh>
#include <Copier/CopierSizing.mqh>
#include <Copier/CopierConfig.mqh>
#include <Copier/CopierFilter.mqh>
#include <Copier/CopierPeers.mqh>
#include <Copier/CopierPanel.mqh>
#include <Copier/CopierIgnore.mqh>
#include <Copier/CopierRisk.mqh>
#include <Copier/CopierTransport.mqh>
#include <Copier/CopierCurveKey.mqh>

//--- configuration --------------------------------------------------
//--- NOTE every comment below STARTS WITH THE VARIABLE NAME.
//--- MetaTrader's input dialog shows the comment INSTEAD of the variable
//--- name whenever one is present, so "0 = off. Cap on concurrent positions"
//--- appears with no clue which input it belongs to. Five risk switches all
//--- reading "0 = off." is exactly what that produces in practice.
//--- The ini path is FIXED now - it is no longer an input.
//---
//--- copier.ini belongs to CENTRAL (hub) mode: the hub generates it and pushes
//--- it, and nothing else reads it. A direct-mode receiver runs from the inputs
//--- below, ONE SENDER PER INSTANCE.
//---
//--- UPGRADE NOTE: a direct-mode receiver no longer reads copier.ini AT ALL.
//--- If the file is present it is ignored, and the receiver says so at startup.
//--- A multi-sender DIRECT setup is now several CopierReceiver instances, one
//--- per sender, on separate charts - which is what a beginner was always
//--- doing anyway, since they never had the file.
//--- CP_INI_PATH is defined in CopierConfig.mqh, which owns the file helpers
//--- that use it. Defining it again here is a redefinition warning, and the
//--- literal living in two places is a drift risk for no benefit.

//--- CENTRAL (hub) mode. Leave EMPTY for the normal direct setup.
//---
//--- Fill it in when the senders are spread across machines that cannot each
//--- reach this one: the receiver then connects to the hub alone and takes its
//--- sender list from the copier.ini the hub owns. Every input below is then
//--- IGNORED, exactly as a config file always used to override them.
//---
//--- Note this is decided by HubEndpoint ALONE, not by whether copier.ini
//--- exists. If a missing file could push the receiver back to direct mode, a
//--- hub-mode receiver's FIRST configuration would deadlock: it would never
//--- connect, so the hub could never push the file that would make it connect.

#ifdef __MQL5__
input group "--- Connectivity & Mode ---"
#else
input string _g_conn_ = ""; // --- Connectivity & Mode ---
#endif
input string HubEndpoint     = "";            // HubEndpoint - e.g. 10.8.0.1:6000; empty = direct mode
input string SenderIP        = "127.0.0.1";    // SenderIP - the sender's address
input int    SenderPort      = 5555;           // SenderPort - the sender's EventsPort (1024-49151)
input bool   UseCurve        = false;          // UseCurve - turn Curve encryption on (key is automatic)
input string SenderServerKey = "";            // SenderServerKey - SENDER public key; needs UseCurve ON
input string InpMagic        = "";            // Magic Number - blank=Auto (uses SenderPort)

//--- Direct mode runtime magic (resolved from InpMagic or SenderPort)
long         Magic           = 0;

//--- Hardcoded gates & hub link CURVE (M4b / M9)
bool         AcceptConfigPush = true;          // apply a copier.ini the hub pushed
bool         AcceptCommands   = true;          // act on operational commands (pause/resume/closeall/reload)
const bool   HubUseCurve      = true;          // Hub link CURVE encryption permanently enabled

#ifdef __MQL5__
input group "--- Sizing & Symbol Mapping ---"
#else
input string _g_sizing_ = ""; // --- Sizing & Symbol Mapping ---
#endif
enum ENUM_LOT_MODE
  {
   LOT_OFF        = CP_SIZE_OFF,          // Off - mirror the sender's lots unchanged
   LOT_MULTIPLIER = CP_SIZE_MULTIPLIER,   // Multiplier - sender lots x SenderLotParam
   LOT_FIXED      = CP_SIZE_FIXED         // Fixed - always SenderLotParam
  };
input ENUM_LOT_MODE SenderLotMode = LOT_MULTIPLIER; // SenderLotMode - 0=multiplier 1=fixed 2=off
input double        SenderLotParam = 1.0;            // SenderLotParam - multiplier, or fixed lots
input string        SenderSuffix   = "";             // SenderSuffix - appended to unmapped symbols
input string        SenderSymbolMap= "";             // SenderSymbolMap - FROM=TO pairs, e.g. GOLD=XAUUSD

#ifdef __MQL5__
input group "--- Risk Limits ---"
#else
input string _g_risk_ = ""; // --- Risk Limits ---
#endif
input double InpMaxLotsPerPosition = 0.0;   // MaxLotsPerPosition - 0=off; cap on ONE position
double       MaxLotsPerPosition    = 0.0;
input double InpMaxTotalLots       = 0.0;   // MaxTotalLots - 0 = off. Cap on TOTAL mirrored volume
double       MaxTotalLots          = 0.0;
input int    InpMaxOpenPositions   = 0;     // MaxOpenPositions - 0=off; cap on open count
int          MaxOpenPositions      = 0;
input double InpDailyLossPct       = 0.0;   // DailyLossPct - 0=off; stop the day after this % loss
double       DailyLossPct          = 0.0;
input double InpMaxDrawdownPct     = 0.0;   // MaxDrawdownPct - 0 = off. Stop until reload
double       MaxDrawdownPct        = 0.0;
input bool   InpRiskCloseAllOnTrip = false; // RiskCloseAllOnTrip - also close held positions
bool         RiskCloseAllOnTrip    = false;

#ifdef __MQL5__
input group "--- Execution & Stops ---"
#else
input string _g_exec_ = ""; // --- Execution & Stops ---
#endif
input int    InpDeviationPoints      = 30;    // DeviationPoints - slippage allowed, in points
int          DeviationPoints         = 30;
input double InpEmergencySLPips      = 0.0;   // EmergencySLPips - 0=off; local stop at open
double       EmergencySLPips         = 0.0;
input double InpEmergencyTPPips      = 0.0;   // EmergencyTPPips - 0=off; local target at open
double       EmergencyTPPips         = 0.0;
input bool   InpMirrorStops          = true;  // MirrorStops - copy the sender's SL/TP, as a distance
bool         MirrorStops             = true;
input bool   InpInvertTrades         = false; // InvertTrades - mirror the opposite direction
bool         InvertTrades            = false;
input bool   InpReopenClosedMirrors  = false; // ReopenClosedMirrors - restore vanished mirrors
bool         ReopenClosedMirrors     = false;
input bool   InpDedupDuplicates      = true;  // DedupDuplicates - remove a 2nd position, same UID
bool         DedupDuplicates         = true;
input int    InpStopsThrottleSeconds = 2;     // StopsThrottleSeconds - min gap between stop edits
int          StopsThrottleSeconds    = 2;

#ifdef __MQL5__
input group "--- Filters & Direction ---"
#else
input string _g_filter_ = ""; // --- Filters & Direction ---
#endif
input string InpPermittedSymbols      = "";    // PermittedSymbols - (A,B)=accept; (!A,B)=reject
string       PermittedSymbols         = "";
input string InpPermittedMagic        = "";    // PermittedMagic - "5,6"=only; "!5,6"=all but; ""=all
string       PermittedMagic           = "";
input double InpMinSenderLotSize      = 0.0;   // MinSenderLotSize - 0 = off. On SENDER volume
double       MinSenderLotSize         = 0.0;
input double InpMaxSenderLotSize      = 0.0;   // MaxSenderLotSize - 0 = off. On SENDER volume
double       MaxSenderLotSize         = 0.0;
input string InpIgnoreUids            = "";    // IgnoreUids - uids to leave alone, e.g. ABCD1234
string       IgnoreUids               = "";
input bool   InpNoBuy                 = false; // NoBuy - refuse Buy entries
bool         NoBuy                    = false;
input bool   InpNoSell                = false; // NoSell - refuse Sell entries
bool         NoSell                   = false;
input bool   InpIgnoreNewEntrySignals = false; // IgnoreNewEntrySignals - open nothing new
bool         IgnoreNewEntrySignals    = false;
input bool   InpIgnoreAllExitSignals  = false; // IgnoreAllExitSignals - close nothing; manage by hand
bool         IgnoreAllExitSignals     = false;

#ifdef __MQL5__
input group "--- Anti-Stack & Delays ---"
#else
input string _g_antistack_ = ""; // --- Anti-Stack & Delays ---
#endif
enum ENUM_EXISTING_CHECK
  {
   EXIST_OFF       = 0,   // Off
   EXIST_SAME_SYM  = 1,   // Any mirror on the same symbol
   EXIST_SAME_DIR  = 2    // Same symbol AND same direction
  };
input ENUM_EXISTING_CHECK InpCheckForExistingPosition = EXIST_OFF; // CheckForExistingPosition - 0=off 1=sym 2=dir
ENUM_EXISTING_CHECK       CheckForExistingPosition    = EXIST_OFF;
input int    InpWaitForSeconds                   = 0;   // WaitForSeconds - delay after the sender opened
int          WaitForSeconds                      = 0;
input int    InpWaitForMinutes                   = 0;   // WaitForMinutes - added to the above
int          WaitForMinutes                      = 0;
input int    InpWaitForHours                     = 0;   // WaitForHours - added to the above
int          WaitForHours                        = 0;
input double InpWaitForProfitPips                = 0.0; // WaitForProfitPips - 0=off; +N profit, -N dip
double       WaitForProfitPips                   = 0.0;
input int    InpWaitForMinutesBar                = 0;   // WaitForMinutesBar - delay this many M1 bars
int          WaitForMinutesBar                   = 0;
input int    InpRequirePositionFillWithinSeconds = 0;   // FillWithinSeconds - see the two below. 0 = off
int          RequirePositionFillWithinSeconds    = 0;
input int    InpRequirePositionFillWithinMinutes = 0;   // FillWithinMinutes - added to the above
int          RequirePositionFillWithinMinutes    = 0;
input int    InpRequirePositionFillWithinHours   = 0;   // FillWithinHours - added to the above
int          RequirePositionFillWithinHours      = 0;
input int    InpFillWithinMinutesBar             = 0;   // FillWithinMinutesBar - drop after this many M1 bars
int          FillWithinMinutesBar                = 0;

#ifdef __MQL5__
input group "--- Schedule & Timeout ---"
#else
input string _g_sched_ = ""; // --- Schedule & Timeout ---
#endif
input string InpIncludeTradingTimes = "";  // IncludeTradingTimes - "HH:MM-HH:MM,..." in SERVER time
string       IncludeTradingTimes    = "";
input string InpDayTradingTimes     = "";  // DayTradingTimes - "Mon=08:00-17:00"; blank=closed
string       DayTradingTimes        = "";
input int    InpStaleSeconds        = 15;  // StaleSeconds - silence stops new entries
int          StaleSeconds           = 15;

#ifdef __MQL5__
input group "--- System & Display ---"
#else
input string _g_sys_ = ""; // --- System & Display ---
#endif
input int    InpPollMs               = 100;   // PollMs - timer interval in milliseconds
int          PollMs                  = 100;
input int    InpMaxActionsPerTick    = 5;     // MaxActionsPerTick - trades executed per timer tick
int          MaxActionsPerTick       = 5;
input int    InpLogLevel             = 2;     // LogLevel - 0=errors 1=warnings 2=info 3=debug
int          LogLevel                = 2;
input bool   InpStatusEnabled        = true;  // StatusEnabled - report this account once a minute
bool         StatusEnabled           = true;
input int    InpSyncHeartbeatSeconds = 1;     // SyncHeartbeatSeconds - snapshot receipt, 0=off
int          SyncHeartbeatSeconds    = 1;
input bool   InpShowPanel            = true;  // ShowPanel - draw the status panel on the chart
bool         ShowPanel               = true;
input bool   InpShowOrphanedList     = false; // ShowOrphanedList - list orphans on the panel
bool         ShowOrphanedList        = false;

//=====================================================================
// Per-sender state. Parallel fixed arrays - no maps, no dictionaries,
// nothing that can grow without bound.
//=====================================================================
struct CopierSenderSettings
  {
   int                 deviationPoints;
   double              emergencySLPips;
   double              emergencyTPPips;
   bool                reopenclosedmirrors;
   bool                dedupduplicates;
   bool                ignorenewentrysignals;
   bool                ignoreallexitsignals;
   string              ignoreuids;
   bool                nobuy;
   bool                nosell;
   string              permittedsymbols;
   string              permittedmagic;
   double              minsenderlotsize;
   double              maxsenderlotsize;
   ENUM_EXISTING_CHECK checkforexistingposition;
   int                 requirepositionfillwithinseconds;
   int                 requirepositionfillwithinminutes;
   int                 requirepositionfillwithinhours;
   int                 fillwithinminutesbar;
   int                 waitforseconds;
   int                 waitforminutes;
   int                 waitforhours;
   double              waitforprofitpips;
   int                 waitforminutesbar;
   string              includetradingtimes;
   string              daytradingtimes;
   bool                inverttrades;
   bool                mirrorstops;
   int                 stopsThrottleSeconds;
   double              maxLotsPerPosition;
   double              maxTotalLots;
   int                 maxOpenPositions;
   int                 staleSeconds;
  };

CopierSenderSettings g_senderCfg[CP_MAX_SENDERS];
CopierRisk           g_senderRisk[CP_MAX_SENDERS];
CopierList           g_senderPermitted[CP_MAX_SENDERS];
CopierList           g_senderPermittedMagic[CP_MAX_SENDERS];
CopierTradingTimes   g_senderHours[CP_MAX_SENDERS];
CopierIgnore         g_senderIgnore[CP_MAX_SENDERS];

string  g_sid[CP_MAX_SENDERS];
string  g_epEvents[CP_MAX_SENDERS];
string  g_epSnap[CP_MAX_SENDERS];
string  g_serverKey[CP_MAX_SENDERS];
//--- This receiver's OWN public key, loaded from the key file at startup and
//--- never typed - see CopierCurveKey.mqh. Kept in a global so the log line
//--- and the socket setup use the SAME string; deriving it twice would be
//--- harmless today and a trap the moment anything about it changes.
string  g_myPublicKey="";
string  g_suffix[CP_MAX_SENDERS];
long    g_magic[CP_MAX_SENDERS];
bool    g_magicPinned[CP_MAX_SENDERS];  // true when magic came from copier.ini
int     g_lotMode[CP_MAX_SENDERS];
double  g_lotParam[CP_MAX_SENDERS];
//--- One sequence watermark PER STREAM, not per sender.
//---
//--- The sender numbers both sockets from a single counter, and the
//--- receiver drains snapshots BEFORE events each tick. With one shared
//--- watermark, a snapshot at seq 115 processed first silently invalidated
//--- every buffered event at seq <= 115 - so after any pause the receiver
//--- threw away the entire event backlog and converged from the snapshot
//--- alone. That is why a stalled receiver came back and opened eight
//--- positions at once instead of following them as they happened.
//--- [0] = events stream, [1] = snapshot stream.
#define CP_STREAM_EVENTS 0
#define CP_STREAM_SNAP   1
long    g_lastSeq[CP_MAX_SENDERS][2];
//--- How far the sender's server clock is ahead of ours, in seconds.
//---
//--- The sender reports its own broker's server time, and two brokers are
//--- routinely in different timezones. Comparing its timestamps with ours
//--- directly is therefore wrong by the difference - often an hour or more,
//--- which is the whole scale of the delays being measured here.
//---
//--- The envelope's TS field IS the sender's server time (see Emit on the
//--- sender), so the offset is measurable from any message. Taken from the
//--- APPLIED snapshot, which is the newest of each batch and therefore the
//--- least delayed - a message that sat in the queue would overstate it.
long    g_senderClockOffset[CP_MAX_SENDERS];
bool    g_senderClockKnown[CP_MAX_SENDERS];
string  g_ssidSeen[CP_MAX_SENDERS];
long    g_lastMsgMs[CP_MAX_SENDERS];
long    g_firstMsgMs[CP_MAX_SENDERS];   // first message ever heard
long    g_lastSnapMs[CP_MAX_SENDERS];   // last ACCEPTED snapshot
//--- The receipt hash of the last snapshot RECEIVED from each sender - the
//--- value that sender put on the wire, stored verbatim and echoed back in our
//--- status. We never compute one ourselves: it is a delivery receipt, so
//--- there is nothing to compare locally and no way for the two sides to
//--- disagree about what it should be. See doc/SNAPSHOT-DEMAND-PLAN.md.
string  g_snapHash[CP_MAX_SENDERS];
bool    g_stale[CP_MAX_SENDERS];
bool    g_ready[CP_MAX_SENDERS];
int     g_dropped[CP_MAX_SENDERS];   // discarded by the sequence guard
long    g_lastDropReport=0;
long    g_lastRiskReport=0;

//--- Per-UID stop state, for the MODIFY event path ---------------------
//---
//--- A MODIFY is an EVENT: it says what the sender's stops are RIGHT NOW,
//--- which may be newer than the snapshot the convergence pass is holding. So
//--- it is kept as an OVERRIDE beside the snapshot's value rather than folded
//--- into it - convergence takes the override when there is one, and drops it
//--- as soon as the snapshot catches up and agrees.
//---
//--- Why an override at all, rather than just applying the change directly:
//--- convergence re-derives the target from the snapshot on EVERY pass, so a
//--- stop applied straight to the position would be reverted by the next pass
//--- (the snapshot still carries the old value until SnapshotSeconds elapses).
//--- The override is what makes the two sources agree instead of fighting.
//---
//--- g_stLastMs is the throttle: the moment a stop edit was last queued for
//--- this uid, so a trailing stop cannot become ten broker calls a second.
string  g_stUid[];
bool    g_stHasOv[];
double  g_stOvSl[];
double  g_stOvTp[];
double  g_stOvOpn[];
long    g_stLastMs[];
//--- A tripped risk switch is a STEADY STATE, not an event: the receiver is
//--- deliberately doing nothing and will keep doing it. Once an hour is
//--- plenty to notice that in a log; once a minute is 1440 lines a day.
#define CP_RISK_REPORT_MS (60*60*1000)
int     g_snapSkipped=0;             // superseded snapshots collapsed in the drain
int     g_qDeferred=0;               // actions deferred by a full queue
//--- Entries a WAIT gate is holding back this pass.
//---
//--- These are NOT in the action queue, and deliberately so: the wait gate
//--- `continue`s before PushAction, so the mirror is never queued at all. That
//--- makes the queue count a lie about "waiting to open" - a receiver holding
//--- ten delayed entries reports zero, which reads as "nothing pending" when
//--- the truth is "everything is pending".
//---
//--- Reset at the top of each converge sweep, incremented by every wait gate.
int     g_waitHeld=0;
double  g_waitLots=0.0;
//--- Same problem, third container: entries skipped because the market is
//--- shut are neither queued nor delayed. Counted separately so the panel's
//--- "waiting to open" does not quietly exclude them.
int     g_mktHeld=0;
double  g_mktHeldLots=0.0;

//--- Is the terminal's SERVER CLOCK advancing?
//---
//--- MT4's TimeCurrent() only moves when a QUOTE ARRIVES. With the market
//--- closed - or the feed down - it FREEZES at the last tick's server time and
//--- every timestamp the EA produces becomes that same value forever. Observed
//--- live: a receiver started at 11:53 local logged "receiver up" with a
//--- server timestamp of 23:54:59, and every line after it carried the same
//--- one.
//---
//--- That is not cosmetic. The trading-session schedule is evaluated against
//--- that frozen instant, so it returns the same answer indefinitely - and if
//--- the frozen instant happens to fall INSIDE the session, the schedule check
//--- waves through every attempt while the broker refuses them all. Meanwhile
//--- the cooldown, which runs on GetTickCount(), keeps expiring normally. The
//--- two clocks disagree and the result is an endless retry loop.
//---
//--- Nothing can be priced from a stale clock, so a stalled feed is reason
//--- enough to hold entries on its own, whatever the schedule says.
long    g_srvSeenTime=0;      // last CopierServerTime() value observed
long    g_srvChangedMs=0;     // when it last differed from the previous one
//--- Has the server clock EVER moved since this instance started?
//---
//--- This is the gate that matters at startup. A "has it been still for 60s"
//--- test cannot fire during the first 60 seconds of a session, so a receiver
//--- attached while the market is closed got exactly one doomed attempt before
//--- the stall was recognised - visible in the log as a single err=132 at the
//--- moment of attaching, then silence.
//---
//--- Requiring the clock to have moved ONCE costs nothing when the market is
//--- open (it moves within a second) and blocks from the very first pass when
//--- it is not.
bool    g_srvEverMoved=false;
#define CP_FEED_STALL_MS 60000
//--- The PER-SYMBOL equivalent, and it is not redundant with the line above.
//---
//--- The global gate watches the server clock, which freezes at the weekly
//--- close on MT4 but KEEPS ADVANCING on MT5 (TimeCurrent() there is kept alive
//--- by the trade-server connection). So on MT5 the global gate never fires,
//--- and the receiver went on trying to open positions against a shut market -
//--- once per cooldown, all weekend.
//---
//--- This one asks the narrower question that works on both platforms: has
//--- THIS instrument quoted recently? Generous, because being wrong costs a
//--- delayed mirror (converge re-derives it) rather than a missed trade.
#define CP_SYM_STALL_MS 60000
long    g_lastStatusMs=0;            // STAT cadence
long    g_lastSyncMs=0;              // snapshot-receipt cadence (SyncHeartbeatSeconds)
long    g_lastSummaryMs=0;           // summary telemetry cadence (routine 5s)
long    g_lastPosDetailMs=0;         // detailed position/waitlist table cadence (routine 60s)
bool    g_forcePosReport=false;      // WebUI on-demand position update request
long    g_lastPruneMs=0;             // stop-override table sweep
long    g_statusSeq=0;
int     g_riskBlocked=0;             // entries refused by a risk switch since the last STAT
long    g_lastMapSave=0;
bool    g_stateSaveOk=false;   // announced the identity store once per session
int     g_nSenders=0;

struct CopierWaitItem
  {
   string uid;
   string sym;
   int    side;
   double lots;
   double openPx;
   long   magic;
   string stage;
   string reason;
  };

CopierWaitItem g_waitItems[];
int            g_waitItemsCount=0;

void ClearWaitItems()
  {
   g_waitItemsCount=0;
   ArrayResize(g_waitItems,0,64);
  }

void AddWaitItem(const string uid,const string sym,const int side,const double lots,const double openPx,const long magic,const string stage,const string reason)
  {
   if(g_waitItemsCount>=128) return;
   ArrayResize(g_waitItems,g_waitItemsCount+1,64);
   g_waitItems[g_waitItemsCount].uid=uid;
   g_waitItems[g_waitItemsCount].sym=sym;
   g_waitItems[g_waitItemsCount].side=side;
   g_waitItems[g_waitItemsCount].lots=lots;
   g_waitItems[g_waitItemsCount].openPx=openPx;
   g_waitItems[g_waitItemsCount].magic=magic;
   g_waitItems[g_waitItemsCount].stage=stage;
   g_waitItems[g_waitItemsCount].reason=reason;
   g_waitItemsCount++;
  }

//--- flattened per-sender symbol maps -------------------------------
string  g_mapFrom[];
string  g_mapTo[];
int     g_mapSender[];
int     g_nMap=0;

//--- desired-position sets: nSenders * CP_MAX_POSITIONS --------------
CopierPos g_desired[];
int       g_desiredCount[CP_MAX_SENDERS];
CopierPos g_scratch[];        // decode buffer, allocated once

//--- action queue ---------------------------------------------------
//--- CP_ACT_* kinds and the "does the seen-ring apply?" rule live in
//--- CopierDefs.mqh so the self-test can reach them.
struct CopierAction
  {
   int    senderIdx;
   int    kind;
   string uid;
   string sym;
   int    side;
   double lots;
   long   ticket;        // CLOSE/TRIM/MODIFY: the receiver's own identifier
   long   senderTicket;  // OPEN : the sender's ticket, written into the
                         //        comment so a human can match the two
                         //        orders by eye in the two terminals
   double sl;            // MODIFY: the resolved target, in RECEIVER prices.
   double tp;            //   0 means "remove it" - the receiver mirrors the
                         //   sender's stops faithfully, including removal
   //--- OPEN of a PENDING entry: the order to place. ordKind is CP_ORD_MARKET
   //--- for a normal entry, in which case the rest are 0 and unused.
   int    ordKind;
   int    ptype;
   double pprice;
   double pstop;
   long   pexpire;
   string key;           // the dedup key this action was admitted under, so
                         // the seen-ring records the SAME key PushAction
                         // tested (TRIM keys carry the target volume, MODIFY
                         // keys carry the target stops)
  };
CopierAction g_q[CP_MAX_ACTIONS];
int    g_qn=0;

CopierTransport g_tp;
CopierLog       g_log;
CopierSeenRing  g_seen;
//--- Actions that FAILED, parked for a short while so a refused request is
//--- not repeated on every converge pass. Deliberately bounded by the
//--- snapshot period: the snapshot re-derives the action anyway, so waiting
//--- longer buys nothing and waiting less just repeats a refusal.
#define CP_RETRY_BACKOFF_MS 2000
//--- Beyond the FIRST refusal the gap ESCALATES per key - 1m, 5m, 15m, 1h,
//--- 6h, 12h, 24h - because a broker refusing the same order twice is
//--- describing a standing condition, and retrying it fast is what gets an
//--- account throttled or blocked rather than merely refused.
//---
//--- The ladder lives in CopierBackoffMs() so the receiver, the log text and
//--- the tests all read the same numbers, and so the long end is visibly
//--- deliberate rather than an arbitrary constant.
CopierBackoff   g_backoff;   // escalating retry gap, keyed on the action key
//--- Entries this platform can never PLACE, but which may still become
//--- something it CAN mirror.
//---
//--- MT4 has no stop-limit order type, so a stop-limit pending can never be
//--- placed there. It will, however, eventually TRIGGER - and a filled order
//--- is an ordinary market position, which MT4 mirrors perfectly.
//---
//--- So this must NOT be a permanent block. Suppressing the pending attempt
//--- for a few minutes keeps the log quiet, and the key carries the entry
//--- KIND, so the moment the sender's order fills the market open has a
//--- different key and is not suppressed at all.
//---
//--- Getting this wrong costs a trade rather than a log line: an earlier
//--- version added the key to the seen-ring instead, which silently
//--- swallowed the position when the stop-limit filled.
#define CP_UNSUPPORTED_MS (5*60*1000)
CopierSeenRing  g_unsupported;
CopierOnceLog   g_once;      // conditions that stay true on every tick (10 min)
CopierOnceLog   g_onceHbt;   // heartbeat DEBUG tick (60 s)
CopierOnceLog   g_onceNoSnap; // "events but no snapshot" alarm (10 min)
CopierOnceLog   g_onceFail;  // repeated trade failures (60 s)
CopierOnceLog   g_onceHour;  // routine housekeeping: once an hour, not once a
                             // minute - "1 superseded snapshot" every minute
                             // buries everything that matters
CopierIgnore    g_ignore;    // UIDs the copier must not touch (the IgnoreUids input)

//--- CENTRAL (hub) mode state.
//---
//--- g_nid is this receiver's identity on the hub: its own account number
//--- reduced to at most 9 digits (see CopierNid). It is what the receiver
//--- subscribes to for control addressed to it, and what the hub uses to find
//--- it - so it must be the SAME value on both ends, which is why it is a pure
//--- function of the account rather than something either side assigns.
bool            g_hubOn=false;
long            g_nid=0;
//--- HubEndpoint, NORMALISED once. "10.8.0.1:6000" is what people type; the
//--- scheme is what ZMQ needs. Normalising in one place means the log and the
//--- connect agree on what was actually dialled, and a scheme-less endpoint
//--- never reaches the socket - where it would fail silently.
string          g_hubEp="";
//--- When central mode came up. Used ONLY for the "subscribed but nothing has
//--- arrived" warning, which is the one failure of this topology that is
//--- otherwise completely silent.
long            g_hubUpMs=0;
//--- REG/HBT2 cadence, and this node's own uptime for the UP= field.
//---
//--- A receiver registers for the same reason a sender does, and it is worth
//--- stating because it is not obvious: in central mode a receiver is a NODE
//--- the hub must know about, even though it publishes no trade data. Without
//--- it the hub's view is "senders exist, receivers are imaginary", and the
//--- first question anyone asks a dashboard - "is this receiver actually
//--- connected?" - has no answer.
long            g_bootMs=0;
long            g_lastHbt2Ms=0;
int             g_announceCount=0;      // first CP_REG_REPEATS are REG, then HBT2
//--- M4b: the last config push we applied, and the revision we now report.
//--- Both persist across restarts (see CopierCfgRevSave) so a receiver that
//--- comes back up does not claim rev 0 and get sent a config it already has.
string          g_cfgId="";             // the last applied command id
long            g_cfgRev=0;             // the revision currently on disk
string          g_cfgAck="";            // the ACK body to repeat for a duplicate id
//--- M5b: the last CMD we answered, and the pause flag. id/ack follow the
//--- g_cfgId/g_cfgAck pattern (in-memory; see HandleCmd for why the four ops
//--- being idempotent is what bounds a repeat after a crash). PAUSED is
//--- PERSISTED via CmdStateSave, because a restart that silently un-paused
//--- would converge straight back into every position the operator just
//--- flattened - the one outcome a pause exists to prevent.
string          g_cmdId="";             // the last command id we answered
string          g_cmdAck="";            // the ACK body to repeat for a duplicate id
bool            g_cmdPaused=false;      // set by CMD pause / closeall, cleared by resume
long            g_lastCfgrMs=0;         // when we last asked the hub for a config
                                        // NOT reset on a WHO reply - same reason as
                                        // the sender; see its declaration.
CopierList      g_permitted; // PermittedSymbols, matched on the RECEIVER's names
CopierList      g_permittedMagic; // PermittedMagic, matched on the SENDER's position magic

//--- peers, latency probes and the on-chart panel -------------------
//--- Keyed on the SENDER's account number, which arrives in the heartbeat.
//--- The routing id is a port number, and a port is not something an operator
//--- recognises at a glance on a chart.
CopierPeerTable  g_peers;              // senders we have heard from
//--- This receiver's OWN CURVE keypair, loaded from (or generated into)
//--- MQL\Files\copier_curve.key. The sender never sees the secret half; only
//--- the derived public key is printed. See CopierCurveKey.mqh.
CopierCurveKey   g_key;

CopierPanel      g_panel;
string           g_hubPeerName="hub";
long             g_lastHubPingMs=0;
long             g_lastPingMs=0;
//--- Edge-triggered: see the note on the sender's copy. A repeating popup
//--- teaches people to dismiss the channel without reading it.
bool             g_peerWasDown[CP_MAX_PEERS];
long             g_peerAlerted[CP_MAX_PEERS];   // when we last popped up
//--- The account number each sender reported, so the panel can name it even
//--- before the first heartbeat arrives.
string           g_senderAcc[CP_MAX_SENDERS];
#define CP_PEER_TIMEOUT_MS 15000
#define CP_PING_MS          10000
//--- One popup per outage: see the note on the sender's copy.
#define CP_ALERT_QUIET_MS  (5*60*1000)
CopierTradingTimes g_hours;  // IncludeTradingTimes / DayTradingTimes, server time
CopierSeenRing  g_fillDropped; // UIDs given up on - sticky, so it is not
                               // re-derived and re-alerted every pass
CopierRisk      g_risk;      // circuit breakers (all off unless configured)
//--- Our own exposure, refreshed once per tick so every sender's converge
//--- pass gates against the SAME numbers. Computing it per sender would let
//--- two senders each see room that only exists once.
int             g_ourCount=0;
double          g_ourLots=0.0;
//--- Number of copier-tagged positions whose magic belongs to no configured
//--- sender. Computed during the same per-timer account scan as our exposure;
//--- shipped as ORPHAN with HELD/LOTS on each SyncHeartbeatSeconds receipt.
int             g_orphanCount=0;
//--- The BROKER's caps, discovered once at startup. -1 = UNKNOWN, which
//--- must never be read as "unlimited": on MT4 there is no way to ask, so
//--- unknown is the normal case there, and assuming unlimited is exactly
//--- what leads to hammering a broker that is refusing orders.
long            g_brokerOrdLimit=-1;
//--- Account-wide counts of BOTH kinds, because the broker caps positions
//--- and pending orders separately. Counting only our own would be wrong
//--- here: a broker limit applies to the whole account, including positions
//--- opened by anything else.
int             g_acctPositions=0;
int             g_acctOrders=0;
//--- Keys that failed and then failed AGAIN. Parked far longer than the
//--- normal two-second retry, because a broker refusing the same order
//--- repeatedly is not a transient condition, and retrying it every two
//--- seconds is how an account gets throttled or blocked.
long            g_lastRealizedMs=0;      // CopierRealizedToday walks history
long            g_riskDay=0;             // server day the baseline belongs to
double          g_riskDayStartEquity=0.0;
CopierPosTable  g_recKnown;  // UID <-> identifier, because the comment is
                             // destroyed by a partial close on MT5
//--- Symbols the broker has just told us are CLOSED.
//---
//--- Keyed on the SYMBOL, not on the order, because "the market is shut" is a
//--- property of the instrument. The retry backoff is per-UID, so with 190
//--- pending entries on one symbol every one of them backs off independently
//--- and the total is still hundreds of attempts a minute against a market
//--- that cannot accept any of them. One cooldown per symbol collapses that to
//--- a single probe a minute, and it clears itself - the first attempt after
//--- the cooldown either succeeds (the market reopened) or re-arms the flag.
//--- Scratch table for SaveReceiverMap.
//---
//--- It used to be a LOCAL. A CopierPosTable embeds CP_MAX_POSITIONS records,
//--- which at 2048 is roughly 400 KB - and MQL's stack for locals is 512 KB, so
//--- one of these is most of the budget and two is an overflow. Globals are not
//--- stack-allocated, which is why every other table in this file already is
//--- one. Moved here after the compiler started warning about it.
//--- NOTE it must be CLEARED per use: as a local it was constructed fresh on
//--- every call, and a global is constructed once.
CopierPosTable  g_saveScratch;

CopierSeenRing  g_mktClosed;
#define CP_MKTCLOSED_MS 60000

CopierSeenRing  g_everOpened;// UIDs this receiver has ever opened, so a
                             // re-open can be reported as a RESTORE rather
                             // than looking like a fresh entry
CopierSeenRing  g_reopenExpected;
                             // UIDs the copier closed ITSELF intending to
                             // open the replacement on the very next pass -
                             // a pending order that filled on the sender, so
                             // the mirror is cancelled and re-placed as a
                             // market position. That is the copier's own
                             // bookkeeping, not an operator closing a mirror,
                             // so ReopenClosedMirrors=false must not block
                             // the follow-up open: doing so would drop the
                             // mirror entirely, which no one asked for.

//=====================================================================
// Symbol map (flattened)
//=====================================================================
void MapAdd(const int si,const string from,const string to)
  {
   for(int i=0;i<g_nMap;i++)
     {
      //--- (si,from) is the key: two senders may map the same symbol
      //--- differently, and that is deliberate.
      if(g_mapSender[i]==si && g_mapFrom[i]==from) { g_mapTo[i]=to; return; }
     }
   if(g_nMap>=CP_MAX_SENDERS*CP_MAX_SYMBOL_MAP) return;
   ArrayResize(g_mapFrom,g_nMap+1,16);
   ArrayResize(g_mapTo,g_nMap+1,16);
   ArrayResize(g_mapSender,g_nMap+1,16);
   g_mapFrom[g_nMap]=from;
   g_mapTo[g_nMap]=to;
   g_mapSender[g_nMap]=si;
   g_nMap++;
  }

//--- Drop every symbol mapping. Called at the TOP of both LoadConfig paths.
//---
//--- MapAdd only ever APPENDS (or updates an exact (si,from) match), so a
//--- SECOND load - a CFG push re-reading the ini, or any re-initialisation -
//--- would stack the old rows under the new ones. MapSymbol returns the
//--- FIRST (si,from) match, so the stale row would win: a changed mapping
//--- never applies and a DELETED one survives until the terminal restarts,
//--- routing orders to a symbol the operator just removed from the config.
//--- The same stale rows also ride CFGRPT (the serializer walks this table),
//--- so the hub's "current setting" would drift from what the receiver is
//--- actually running. Clearing on load makes "the mapping in effect" exactly
//--- "the mapping in the file" - which is the whole point of a runtime reload.
void MapClear()
  {
   ArrayResize(g_mapFrom,0);
   ArrayResize(g_mapTo,0);
   ArrayResize(g_mapSender,0);
   g_nMap=0;
  }

string MapSymbol(const int si,const string sym,const string suffix)
  {
   for(int i=0;i<g_nMap;i++)
     {
      if(g_mapSender[i]==si && g_mapFrom[i]==sym) return g_mapTo[i];
     }
   if(StringLen(suffix)>0)
     {
      string cand=(StringSubstr(suffix,0,1)==".")?(sym+suffix):(sym+"."+suffix);
      if(CopierSymbolExists(cand)) return cand;
     }
   return sym;
  }

//=====================================================================
// Config
//=====================================================================
//--- Build the single sender from the EA inputs. This IS direct mode: one
//--- sender should not require a file, and now nothing else uses one either.
//---
//--- The fields map 1:1 onto a [sender0] section, with one exception: the
//--- symbol map. A file can carry any number of "symbol.X=Y" lines, but an EA
//--- input is one fixed string - so it is packed as "FROM=TO;FROM2=TO2",
//--- using the same ';' the wire format already uses for key=value pairs.
bool LoadConfigFromInputs()
  {
   ResetRuntimeInputsFromInputs();
   g_nSenders=1;

   //--- Same rule as the hub path: g_desired is indexed
   //--- si*CP_MAX_POSITIONS+i, so its size IS the sender count. Direct
   //--- mode never re-loads its config after OnInit today, but the resize
   //--- is one line and makes the invariant local rather than depending on
   //--- which caller ran first.
   ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS);

   //--- Start from an empty symbol map on every load - see MapClear.
   MapClear();

   //--- The routing id IS the port, exactly as on the sender. Both ends derive
   //--- it from the same number, so there is nothing to keep in step and no
   //--- way to mistype one side into silence.
   if(SenderPort<=0 || SenderPort>65535)
     {
      g_log.Error("SenderPort is not a usable port. Set it to the sender's"
                  +" EventsPort - and to the same number on both sides,"
                  +" because it is also how this receiver identifies which"
                  +" sender a message came from.");
      return false;
     }
   g_sid[0]      =(string)SenderPort;
   g_epEvents[0] =CopierNormalizeEndpoint(SenderIP+":"+(string)SenderPort);
   g_serverKey[0]=SenderServerKey;
   g_suffix[0]   =SenderSuffix;

   if(StringLen(SenderIP)==0)
     {
      g_log.Error("SenderIP is empty. Use 127.0.0.1 when the sender runs on"
                  +" this machine, otherwise its address on your private"
                  +" network.");
      return false;
     }
   if(Magic<=0)
     {
      g_log.Error("Magic is not set. Every sender MUST pin its magic: it is"
                  +" how this receiver finds that sender's positions, so a"
                  +" guess would orphan real orders. Set Magic to a number"
                  +" unique to this sender.");
      return false;
     }
   g_magic[0]=Magic;
   g_magicPinned[0]=true;

   //--- The input enum's numbers ARE the internal CP_SIZE_* ones now, so this
   //--- is a normalisation rather than a mapping - it exists so that anything
   //--- unrecognised becomes MULTIPLIER in exactly ONE place, not to translate
   //--- between two numberings.
   g_lotMode[0] =CopierLotModeInternal(SenderLotMode);
   g_lotParam[0]=SenderLotParam;

   //--- "FROM=TO;FROM2=TO2"
   string pairs[];
   int np=StringSplit(SenderSymbolMap,StringGetCharacter(";",0),pairs);
   for(int i=0;i<np;i++)
     {
      string pr=CopierTrim(pairs[i]);
      if(StringLen(pr)==0) continue;
      int eq=StringFind(pr,"=");
      if(eq<=0) continue;
      string from=CopierTrim(StringSubstr(pr,0,eq));
      string to=CopierTrim(StringSubstr(pr,eq+1));
      if(StringLen(from)==0 || StringLen(to)==0) continue;
      MapAdd(0,from,to);
     }

   CopierIni emptyIni;
   InitSenderSettings(0, emptyIni, "sender0");

   g_log.Info("configured from EA inputs: one sender ("+g_sid[0]
              +"), magic "+(string)g_magic[0]+", endpoint "+g_epEvents[0]);
   return true;
  }

void ResetRuntimeInputsFromInputs()
  {
   string mStr = CopierTrim(InpMagic);
   if(StringLen(mStr) == 0 || mStr == "0")
     {
      if(SenderPort > 0 && SenderPort <= 65535)
         Magic = (long)SenderPort;
      else
         Magic = 0;
     }
   else
     {
      Magic = StringToInteger(mStr);
     }

   DeviationPoints                  = InpDeviationPoints;
   EmergencySLPips                  = InpEmergencySLPips;
   EmergencyTPPips                  = InpEmergencyTPPips;
   ReopenClosedMirrors              = InpReopenClosedMirrors;
   DedupDuplicates                  = InpDedupDuplicates;
   IgnoreNewEntrySignals            = InpIgnoreNewEntrySignals;
   IgnoreAllExitSignals             = InpIgnoreAllExitSignals;
   IgnoreUids                       = InpIgnoreUids;
   NoBuy                            = InpNoBuy;
   NoSell                           = InpNoSell;
   PermittedSymbols                 = InpPermittedSymbols;
   PermittedMagic                   = InpPermittedMagic;
   MinSenderLotSize                 = InpMinSenderLotSize;
   MaxSenderLotSize                 = InpMaxSenderLotSize;
   CheckForExistingPosition         = InpCheckForExistingPosition;
   RequirePositionFillWithinSeconds = InpRequirePositionFillWithinSeconds;
   RequirePositionFillWithinMinutes = InpRequirePositionFillWithinMinutes;
   RequirePositionFillWithinHours   = InpRequirePositionFillWithinHours;
   FillWithinMinutesBar             = InpFillWithinMinutesBar;
   WaitForSeconds                   = InpWaitForSeconds;
   WaitForMinutes                   = InpWaitForMinutes;
   WaitForHours                     = InpWaitForHours;
   WaitForProfitPips                = InpWaitForProfitPips;
   WaitForMinutesBar                = InpWaitForMinutesBar;
   IncludeTradingTimes              = InpIncludeTradingTimes;
   DayTradingTimes                  = InpDayTradingTimes;
   InvertTrades                     = InpInvertTrades;
   MirrorStops                      = InpMirrorStops;
   StopsThrottleSeconds             = InpStopsThrottleSeconds;
   MaxLotsPerPosition               = InpMaxLotsPerPosition;
   MaxTotalLots                     = InpMaxTotalLots;
   MaxOpenPositions                 = InpMaxOpenPositions;
   DailyLossPct                     = InpDailyLossPct;
   MaxDrawdownPct                   = InpMaxDrawdownPct;
   RiskCloseAllOnTrip               = InpRiskCloseAllOnTrip;
   PollMs                           = InpPollMs;
   StaleSeconds                     = InpStaleSeconds;
   MaxActionsPerTick                = InpMaxActionsPerTick;
   LogLevel                         = InpLogLevel;
   StatusEnabled                    = InpStatusEnabled;
   SyncHeartbeatSeconds             = InpSyncHeartbeatSeconds;
   ShowPanel                        = InpShowPanel;
   ShowOrphanedList                 = InpShowOrphanedList;
  }

void ApplyCommonConfig(const CopierIni &ini)
  {
   if(!ini.HasSection("common")) return;

   int oldLogLevel = LogLevel;
   int oldPollMs   = PollMs;

   if(ini.Has("common","deviationpoints"))
      DeviationPoints = ini.GetInt("common","deviationpoints",DeviationPoints);
   if(ini.Has("common","emergencyslpips"))
      EmergencySLPips = ini.GetDouble("common","emergencyslpips",EmergencySLPips);
   if(ini.Has("common","emergencytppips"))
      EmergencyTPPips = ini.GetDouble("common","emergencytppips",EmergencyTPPips);
   if(ini.Has("common","reopenclosedmirrors"))
      ReopenClosedMirrors = ini.GetBool("common","reopenclosedmirrors",ReopenClosedMirrors);
   if(ini.Has("common","dedupduplicates"))
      DedupDuplicates = ini.GetBool("common","dedupduplicates",DedupDuplicates);
   if(ini.Has("common","ignorenewentrysignals"))
      IgnoreNewEntrySignals = ini.GetBool("common","ignorenewentrysignals",IgnoreNewEntrySignals);
   if(ini.Has("common","ignoreallexitsignals"))
      IgnoreAllExitSignals = ini.GetBool("common","ignoreallexitsignals",IgnoreAllExitSignals);
   if(ini.Has("common","ignoreuids"))
      IgnoreUids = ini.Get("common","ignoreuids",IgnoreUids);
   if(ini.Has("common","nobuy"))
      NoBuy = ini.GetBool("common","nobuy",NoBuy);
   if(ini.Has("common","nosell"))
      NoSell = ini.GetBool("common","nosell",NoSell);
   if(ini.Has("common","permittedsymbols"))
      PermittedSymbols = ini.Get("common","permittedsymbols",PermittedSymbols);
   if(ini.Has("common","permittedmagic"))
      PermittedMagic = ini.Get("common","permittedmagic",PermittedMagic);
   if(ini.Has("common","minsenderlotsize"))
      MinSenderLotSize = ini.GetDouble("common","minsenderlotsize",MinSenderLotSize);
   if(ini.Has("common","maxsenderlotsize"))
      MaxSenderLotSize = ini.GetDouble("common","maxsenderlotsize",MaxSenderLotSize);
   if(ini.Has("common","checkforexistingposition"))
      CheckForExistingPosition = (ENUM_EXISTING_CHECK)ini.GetInt("common","checkforexistingposition",(int)CheckForExistingPosition);
   if(ini.Has("common","requirepositionfillwithinseconds"))
      RequirePositionFillWithinSeconds = ini.GetInt("common","requirepositionfillwithinseconds",RequirePositionFillWithinSeconds);
   if(ini.Has("common","requirepositionfillwithinminutes"))
      RequirePositionFillWithinMinutes = ini.GetInt("common","requirepositionfillwithinminutes",RequirePositionFillWithinMinutes);
   if(ini.Has("common","requirepositionfillwithinhours"))
      RequirePositionFillWithinHours = ini.GetInt("common","requirepositionfillwithinhours",RequirePositionFillWithinHours);
   if(ini.Has("common","fillwithinminutesbar"))
      FillWithinMinutesBar = ini.GetInt("common","fillwithinminutesbar",FillWithinMinutesBar);
   if(ini.Has("common","waitforseconds"))
      WaitForSeconds = ini.GetInt("common","waitforseconds",WaitForSeconds);
   if(ini.Has("common","waitforminutes"))
      WaitForMinutes = ini.GetInt("common","waitforminutes",WaitForMinutes);
   if(ini.Has("common","waitforhours"))
      WaitForHours = ini.GetInt("common","waitforhours",WaitForHours);
   if(ini.Has("common","waitforprofitpips"))
      WaitForProfitPips = ini.GetDouble("common","waitforprofitpips",WaitForProfitPips);
   if(ini.Has("common","waitforminutesbar"))
      WaitForMinutesBar = ini.GetInt("common","waitforminutesbar",WaitForMinutesBar);
   if(ini.Has("common","includetradingtimes"))
      IncludeTradingTimes = ini.Get("common","includetradingtimes",IncludeTradingTimes);
   if(ini.Has("common","daytradingtimes"))
      DayTradingTimes = ini.Get("common","daytradingtimes",DayTradingTimes);
   if(ini.Has("common","inverttrades"))
      InvertTrades = ini.GetBool("common","inverttrades",InvertTrades);
   if(ini.Has("common","mirrorstops"))
      MirrorStops = ini.GetBool("common","mirrorstops",MirrorStops);
   if(ini.Has("common","stopsthrottleseconds"))
      StopsThrottleSeconds = ini.GetInt("common","stopsthrottleseconds",StopsThrottleSeconds);
   if(ini.Has("common","maxlotsperposition"))
      MaxLotsPerPosition = ini.GetDouble("common","maxlotsperposition",MaxLotsPerPosition);
   if(ini.Has("common","maxtotallots"))
      MaxTotalLots = ini.GetDouble("common","maxtotallots",MaxTotalLots);
   if(ini.Has("common","maxopenpositions"))
      MaxOpenPositions = ini.GetInt("common","maxopenpositions",MaxOpenPositions);
   if(ini.Has("common","dailylosspct"))
      DailyLossPct = ini.GetDouble("common","dailylosspct",DailyLossPct);
   if(ini.Has("common","maxdrawdownpct"))
      MaxDrawdownPct = ini.GetDouble("common","maxdrawdownpct",MaxDrawdownPct);
   if(ini.Has("common","riskcloseallontrip"))
      RiskCloseAllOnTrip = ini.GetBool("common","riskcloseallontrip",RiskCloseAllOnTrip);
   if(ini.Has("common","pollms"))
      PollMs = ini.GetInt("common","pollms",PollMs);
   if(ini.Has("common","staleseconds"))
      StaleSeconds = ini.GetInt("common","staleseconds",StaleSeconds);
   if(ini.Has("common","maxactionspertick"))
      MaxActionsPerTick = ini.GetInt("common","maxactionspertick",MaxActionsPerTick);
   if(ini.Has("common","loglevel"))
      LogLevel = ini.GetInt("common","loglevel",LogLevel);
   if(ini.Has("common","statusenabled"))
      StatusEnabled = ini.GetBool("common","statusenabled",StatusEnabled);
   if(ini.Has("common","syncheartbeatseconds"))
      SyncHeartbeatSeconds = ini.GetInt("common","syncheartbeatseconds",SyncHeartbeatSeconds);
   if(ini.Has("common","showpanel"))
      ShowPanel = ini.GetBool("common","showpanel",ShowPanel);
   if(ini.Has("common","showorphanedlist"))
      ShowOrphanedList = ini.GetBool("common","showorphanedlist",ShowOrphanedList);

   // Apply to live runtime modules
   CopierRiskLimits rl;
   rl.maxLotsPerPosition = MaxLotsPerPosition;
   rl.maxTotalLots       = MaxTotalLots;
   rl.maxOpenPositions   = MaxOpenPositions;
   rl.dailyLossPct       = DailyLossPct;
   rl.maxDrawdownPct     = MaxDrawdownPct;
   g_risk.Configure(rl);

   g_permitted.Set(PermittedSymbols);
   g_permittedMagic.Set(PermittedMagic);
   g_hours.Set(IncludeTradingTimes,DayTradingTimes);
   g_ignore.SetText(IgnoreUids);

   if(LogLevel != oldLogLevel)
      g_log.Init("receiver"+InstanceSuffix(),LogLevel);
   if(PollMs != oldPollMs && PollMs > 0)
     {
      EventKillTimer();
      EventSetMillisecondTimer(PollMs);
     }
  }

void InitSenderSettings(const int si, const CopierIni &ini, const string sec)
  {
   if(si < 0 || si >= CP_MAX_SENDERS) return;

   g_senderCfg[si].deviationPoints                  = ini.GetInt(sec, "deviationpoints", DeviationPoints);
   g_senderCfg[si].emergencySLPips                  = ini.GetDouble(sec, "emergencyslpips", EmergencySLPips);
   g_senderCfg[si].emergencyTPPips                  = ini.GetDouble(sec, "emergencytppips", EmergencyTPPips);
   g_senderCfg[si].reopenclosedmirrors              = ini.GetBool(sec, "reopenclosedmirrors", ReopenClosedMirrors);
   g_senderCfg[si].dedupduplicates                  = ini.GetBool(sec, "dedupduplicates", DedupDuplicates);
   g_senderCfg[si].ignorenewentrysignals            = ini.GetBool(sec, "ignorenewentrysignals", IgnoreNewEntrySignals);
   g_senderCfg[si].ignoreallexitsignals             = ini.GetBool(sec, "ignoreallexitsignals", IgnoreAllExitSignals);
   g_senderCfg[si].ignoreuids                       = ini.Get(sec, "ignoreuids", IgnoreUids);
   g_senderCfg[si].nobuy                            = ini.GetBool(sec, "nobuy", NoBuy);
   g_senderCfg[si].nosell                           = ini.GetBool(sec, "nosell", NoSell);
   g_senderCfg[si].permittedsymbols                 = ini.Get(sec, "permittedsymbols", PermittedSymbols);
   g_senderCfg[si].permittedmagic                   = ini.Get(sec, "permittedmagic", PermittedMagic);
   g_senderCfg[si].minsenderlotsize                 = ini.GetDouble(sec, "minsenderlotsize", MinSenderLotSize);
   g_senderCfg[si].maxsenderlotsize                 = ini.GetDouble(sec, "maxsenderlotsize", MaxSenderLotSize);
   g_senderCfg[si].checkforexistingposition         = (ENUM_EXISTING_CHECK)ini.GetInt(sec, "checkforexistingposition", (int)CheckForExistingPosition);
   g_senderCfg[si].requirepositionfillwithinseconds = ini.GetInt(sec, "requirepositionfillwithinseconds", RequirePositionFillWithinSeconds);
   g_senderCfg[si].requirepositionfillwithinminutes = ini.GetInt(sec, "requirepositionfillwithinminutes", RequirePositionFillWithinMinutes);
   g_senderCfg[si].requirepositionfillwithinhours   = ini.GetInt(sec, "requirepositionfillwithinhours", RequirePositionFillWithinHours);
   g_senderCfg[si].fillwithinminutesbar             = ini.GetInt(sec, "fillwithinminutesbar", FillWithinMinutesBar);
   g_senderCfg[si].waitforseconds                   = ini.GetInt(sec, "waitforseconds", WaitForSeconds);
   g_senderCfg[si].waitforminutes                   = ini.GetInt(sec, "waitforminutes", WaitForMinutes);
   g_senderCfg[si].waitforhours                     = ini.GetInt(sec, "waitforhours", WaitForHours);
   g_senderCfg[si].waitforprofitpips                = ini.GetDouble(sec, "waitforprofitpips", WaitForProfitPips);
   g_senderCfg[si].waitforminutesbar                = ini.GetInt(sec, "waitforminutesbar", WaitForMinutesBar);
   g_senderCfg[si].includetradingtimes              = ini.Get(sec, "includetradingtimes", IncludeTradingTimes);
   g_senderCfg[si].daytradingtimes                  = ini.Get(sec, "daytradingtimes", DayTradingTimes);
   g_senderCfg[si].inverttrades                     = ini.GetBool(sec, "inverttrades", InvertTrades);
   g_senderCfg[si].mirrorstops                      = ini.GetBool(sec, "mirrorstops", MirrorStops);
   g_senderCfg[si].stopsThrottleSeconds             = ini.GetInt(sec, "stopsthrottleseconds", StopsThrottleSeconds);
   g_senderCfg[si].maxLotsPerPosition               = ini.GetDouble(sec, "maxlotsperposition", MaxLotsPerPosition);
   g_senderCfg[si].maxTotalLots                     = ini.GetDouble(sec, "maxtotallots", MaxTotalLots);
   g_senderCfg[si].maxOpenPositions                 = ini.GetInt(sec, "maxopenpositions", MaxOpenPositions);
   g_senderCfg[si].staleSeconds                     = ini.GetInt(sec, "staleseconds", StaleSeconds);

   CopierRiskLimits rl;
   rl.maxLotsPerPosition = g_senderCfg[si].maxLotsPerPosition;
   rl.maxTotalLots       = g_senderCfg[si].maxTotalLots;
   rl.maxOpenPositions   = g_senderCfg[si].maxOpenPositions;
   rl.dailyLossPct       = 0.0;
   rl.maxDrawdownPct     = 0.0;
   g_senderRisk[si].Configure(rl);

   g_senderPermitted[si].Set(g_senderCfg[si].permittedsymbols);
   g_senderPermittedMagic[si].Set(g_senderCfg[si].permittedmagic);
   g_senderHours[si].Set(g_senderCfg[si].includetradingtimes, g_senderCfg[si].daytradingtimes);
   g_senderIgnore[si].SetText(g_senderCfg[si].ignoreuids);
  }

void PendingOpensForSender(const int si, int &cnt, double &lots)
  {
   cnt = 0;
   lots = 0.0;
   for(int i = 0; i < g_qn; i++)
     {
      if(g_q[i].senderIdx == si && g_q[i].kind == CP_ACT_OPEN)
        {
         cnt++;
         lots += g_q[i].lots;
        }
     }
  }

string SerializeCurrentConfigToIni()
  {
   string out = "; copier.ini (active current settings)\n";
   out += "[common]\n";
   out += "deviationpoints=" + (string)DeviationPoints + "\n";
   out += "emergencyslpips=" + DoubleToString(EmergencySLPips, 1) + "\n";
   out += "emergencytppips=" + DoubleToString(EmergencyTPPips, 1) + "\n";
   out += "reopenclosedmirrors=" + (ReopenClosedMirrors ? "1" : "0") + "\n";
   out += "dedupduplicates=" + (DedupDuplicates ? "1" : "0") + "\n";
   out += "ignorenewentrysignals=" + (IgnoreNewEntrySignals ? "1" : "0") + "\n";
   out += "ignoreallexitsignals=" + (IgnoreAllExitSignals ? "1" : "0") + "\n";
   out += "ignoreuids=" + IgnoreUids + "\n";
   out += "nobuy=" + (NoBuy ? "1" : "0") + "\n";
   out += "nosell=" + (NoSell ? "1" : "0") + "\n";
   out += "permittedsymbols=" + PermittedSymbols + "\n";
   out += "permittedmagic=" + PermittedMagic + "\n";
   out += "minsenderlotsize=" + DoubleToString(MinSenderLotSize, 2) + "\n";
   out += "maxsenderlotsize=" + DoubleToString(MaxSenderLotSize, 2) + "\n";
   out += "checkforexistingposition=" + (string)((int)CheckForExistingPosition) + "\n";
   out += "requirepositionfillwithinseconds=" + (string)RequirePositionFillWithinSeconds + "\n";
   out += "requirepositionfillwithinminutes=" + (string)RequirePositionFillWithinMinutes + "\n";
   out += "requirepositionfillwithinhours=" + (string)RequirePositionFillWithinHours + "\n";
   out += "fillwithinminutesbar=" + (string)FillWithinMinutesBar + "\n";
   out += "waitforseconds=" + (string)WaitForSeconds + "\n";
   out += "waitforminutes=" + (string)WaitForMinutes + "\n";
   out += "waitforhours=" + (string)WaitForHours + "\n";
   out += "waitforprofitpips=" + DoubleToString(WaitForProfitPips, 1) + "\n";
   out += "waitforminutesbar=" + (string)WaitForMinutesBar + "\n";
   out += "includetradingtimes=" + IncludeTradingTimes + "\n";
   out += "daytradingtimes=" + DayTradingTimes + "\n";
   out += "inverttrades=" + (InvertTrades ? "1" : "0") + "\n";
   out += "mirrorstops=" + (MirrorStops ? "1" : "0") + "\n";
   out += "stopsthrottleseconds=" + (string)StopsThrottleSeconds + "\n";
   out += "maxlotsperposition=" + DoubleToString(MaxLotsPerPosition, 2) + "\n";
   out += "maxtotallots=" + DoubleToString(MaxTotalLots, 2) + "\n";
   out += "maxopenpositions=" + (string)MaxOpenPositions + "\n";
   out += "dailylosspct=" + DoubleToString(DailyLossPct, 2) + "\n";
   out += "maxdrawdownpct=" + DoubleToString(MaxDrawdownPct, 2) + "\n";
   out += "riskcloseallontrip=" + (RiskCloseAllOnTrip ? "1" : "0") + "\n";
   out += "pollms=" + (string)PollMs + "\n";
   out += "staleseconds=" + (string)StaleSeconds + "\n";
   out += "maxactionspertick=" + (string)MaxActionsPerTick + "\n";
   out += "loglevel=" + (string)LogLevel + "\n";
   out += "statusenabled=" + (StatusEnabled ? "1" : "0") + "\n";
   out += "syncheartbeatseconds=" + (string)SyncHeartbeatSeconds + "\n";
   out += "showpanel=" + (ShowPanel ? "1" : "0") + "\n";
   out += "showorphanedlist=" + (ShowOrphanedList ? "1" : "0") + "\n";

   if(g_nSenders > 0)
     {
      for(int i = 0; i < g_nSenders; i++)
        {
         out += "\n[sender" + (string)i + "]\n";
         out += "id=" + g_sid[i] + "\n";
         out += "magic=" + (string)g_magic[i] + "\n";
         out += "lotmode=" + CopierLotModeText(g_lotMode[i]) + "\n";
         out += "lotparam=" + DoubleToString(g_lotParam[i], 4) + "\n";
         if(StringLen(g_suffix[i]) > 0)
            out += "suffix=" + g_suffix[i] + "\n";
         for(int m = 0; m < g_nMap; m++)
           {
            if(g_mapSender[m] == i)
               out += "symbol." + g_mapFrom[m] + "=" + g_mapTo[m] + "\n";
           }
         out += "deviationpoints=" + (string)g_senderCfg[i].deviationPoints + "\n";
         out += "emergencyslpips=" + DoubleToString(g_senderCfg[i].emergencySLPips, 1) + "\n";
         out += "emergencytppips=" + DoubleToString(g_senderCfg[i].emergencyTPPips, 1) + "\n";
         out += "reopenclosedmirrors=" + (g_senderCfg[i].reopenclosedmirrors ? "1" : "0") + "\n";
         out += "dedupduplicates=" + (g_senderCfg[i].dedupduplicates ? "1" : "0") + "\n";
         out += "ignorenewentrysignals=" + (g_senderCfg[i].ignorenewentrysignals ? "1" : "0") + "\n";
         out += "ignoreallexitsignals=" + (g_senderCfg[i].ignoreallexitsignals ? "1" : "0") + "\n";
         out += "ignoreuids=" + g_senderCfg[i].ignoreuids + "\n";
         out += "nobuy=" + (g_senderCfg[i].nobuy ? "1" : "0") + "\n";
         out += "nosell=" + (g_senderCfg[i].nosell ? "1" : "0") + "\n";
         out += "permittedsymbols=" + g_senderCfg[i].permittedsymbols + "\n";
         out += "permittedmagic=" + g_senderCfg[i].permittedmagic + "\n";
         out += "minsenderlotsize=" + DoubleToString(g_senderCfg[i].minsenderlotsize, 2) + "\n";
         out += "maxsenderlotsize=" + DoubleToString(g_senderCfg[i].maxsenderlotsize, 2) + "\n";
         out += "checkforexistingposition=" + (string)((int)g_senderCfg[i].checkforexistingposition) + "\n";
         out += "requirepositionfillwithinseconds=" + (string)g_senderCfg[i].requirepositionfillwithinseconds + "\n";
         out += "requirepositionfillwithinminutes=" + (string)g_senderCfg[i].requirepositionfillwithinminutes + "\n";
         out += "requirepositionfillwithinhours=" + (string)g_senderCfg[i].requirepositionfillwithinhours + "\n";
         out += "fillwithinminutesbar=" + (string)g_senderCfg[i].fillwithinminutesbar + "\n";
         out += "waitforseconds=" + (string)g_senderCfg[i].waitforseconds + "\n";
         out += "waitforminutes=" + (string)g_senderCfg[i].waitforminutes + "\n";
         out += "waitforhours=" + (string)g_senderCfg[i].waitforhours + "\n";
         out += "waitforprofitpips=" + DoubleToString(g_senderCfg[i].waitforprofitpips, 1) + "\n";
         out += "waitforminutesbar=" + (string)g_senderCfg[i].waitforminutesbar + "\n";
         out += "includetradingtimes=" + g_senderCfg[i].includetradingtimes + "\n";
         out += "daytradingtimes=" + g_senderCfg[i].daytradingtimes + "\n";
         out += "inverttrades=" + (g_senderCfg[i].inverttrades ? "1" : "0") + "\n";
         out += "mirrorstops=" + (g_senderCfg[i].mirrorstops ? "1" : "0") + "\n";
         out += "stopsthrottleseconds=" + (string)g_senderCfg[i].stopsThrottleSeconds + "\n";
         out += "maxlotsperposition=" + DoubleToString(g_senderCfg[i].maxLotsPerPosition, 2) + "\n";
         out += "maxtotallots=" + DoubleToString(g_senderCfg[i].maxTotalLots, 2) + "\n";
         out += "maxopenpositions=" + (string)g_senderCfg[i].maxOpenPositions + "\n";
         out += "staleseconds=" + (string)g_senderCfg[i].staleSeconds + "\n";
        }
     }
   else if(!g_hubOn)
     {
      out += "\n[sender0]\n";
      out += "id=" + (string)SenderPort + "\n";
      out += "magic=" + (string)Magic + "\n";
      out += "lotmode=" + CopierLotModeText((int)SenderLotMode) + "\n";
      out += "lotparam=" + DoubleToString(SenderLotParam, 4) + "\n";
      if(StringLen(SenderSuffix) > 0)
         out += "suffix=" + SenderSuffix + "\n";
      out += "deviationpoints=" + (string)g_senderCfg[0].deviationPoints + "\n";
      out += "emergencyslpips=" + DoubleToString(g_senderCfg[0].emergencySLPips, 1) + "\n";
      out += "emergencytppips=" + DoubleToString(g_senderCfg[0].emergencyTPPips, 1) + "\n";
      out += "reopenclosedmirrors=" + (g_senderCfg[0].reopenclosedmirrors ? "1" : "0") + "\n";
      out += "dedupduplicates=" + (g_senderCfg[0].dedupduplicates ? "1" : "0") + "\n";
      out += "ignorenewentrysignals=" + (g_senderCfg[0].ignorenewentrysignals ? "1" : "0") + "\n";
      out += "ignoreallexitsignals=" + (g_senderCfg[0].ignoreallexitsignals ? "1" : "0") + "\n";
      out += "ignoreuids=" + g_senderCfg[0].ignoreuids + "\n";
      out += "nobuy=" + (g_senderCfg[0].nobuy ? "1" : "0") + "\n";
      out += "nosell=" + (g_senderCfg[0].nosell ? "1" : "0") + "\n";
      out += "permittedsymbols=" + g_senderCfg[0].permittedsymbols + "\n";
      out += "permittedmagic=" + g_senderCfg[0].permittedmagic + "\n";
      out += "minsenderlotsize=" + DoubleToString(g_senderCfg[0].minsenderlotsize, 2) + "\n";
      out += "maxsenderlotsize=" + DoubleToString(g_senderCfg[0].maxsenderlotsize, 2) + "\n";
      out += "checkforexistingposition=" + (string)((int)g_senderCfg[0].checkforexistingposition) + "\n";
      out += "requirepositionfillwithinseconds=" + (string)g_senderCfg[0].requirepositionfillwithinseconds + "\n";
      out += "requirepositionfillwithinminutes=" + (string)g_senderCfg[0].requirepositionfillwithinminutes + "\n";
      out += "requirepositionfillwithinhours=" + (string)g_senderCfg[0].requirepositionfillwithinhours + "\n";
      out += "fillwithinminutesbar=" + (string)g_senderCfg[0].fillwithinminutesbar + "\n";
      out += "waitforseconds=" + (string)g_senderCfg[0].waitforseconds + "\n";
      out += "waitforminutes=" + (string)g_senderCfg[0].waitforminutes + "\n";
      out += "waitforhours=" + (string)g_senderCfg[0].waitforhours + "\n";
      out += "waitforprofitpips=" + DoubleToString(g_senderCfg[0].waitforprofitpips, 1) + "\n";
      out += "waitforminutesbar=" + (string)g_senderCfg[0].waitforminutesbar + "\n";
      out += "includetradingtimes=" + g_senderCfg[0].includetradingtimes + "\n";
      out += "daytradingtimes=" + g_senderCfg[0].daytradingtimes + "\n";
      out += "inverttrades=" + (g_senderCfg[0].inverttrades ? "1" : "0") + "\n";
      out += "mirrorstops=" + (g_senderCfg[0].mirrorstops ? "1" : "0") + "\n";
      out += "stopsthrottleseconds=" + (string)g_senderCfg[0].stopsThrottleSeconds + "\n";
      out += "maxlotsperposition=" + DoubleToString(g_senderCfg[0].maxLotsPerPosition, 2) + "\n";
      out += "maxtotallots=" + DoubleToString(g_senderCfg[0].maxTotalLots, 2) + "\n";
      out += "maxopenpositions=" + (string)g_senderCfg[0].maxOpenPositions + "\n";
      out += "staleseconds=" + (string)g_senderCfg[0].staleSeconds + "\n";
     }

   return out;
  }

void SendCurrentConfigReport()
  {
   if(!g_hubOn) return;
   CopierEnv e;
   e.v = CP_PROTO_V;
   e.sid = (string)g_nid;
   e.ssid = (string)CopierAccountLogin();
   e.seq = ++g_statusSeq;
   e.ts = CopierServerTime();
   e.ms = CopierNowMs();
   e.type = CP_T_CFGREPORT;
   e.payload = "REV=" + (string)g_cfgRev + ";ROLE=receiver;ACC=" + (string)CopierAccountLogin()
               + ";INI=" + CopierIniEscape(SerializeCurrentConfigToIni());
   g_tp.SendUp("@hub", CopierEncodeEnv(e));
  }

//--- CENTRAL (hub) mode.
//---
//--- The ini is the SAME format, with two differences:
//---
//---   * `events=` is NOT read. This receiver connects to the hub and nowhere
//---     else, so a per-sender endpoint would be a second, contradictory source
//---     of truth - and exactly the thing a beginner gets wrong.
//---   * `id=` is the SENDER'S NID, not its port, because the NID is what the
//---     hub puts in the topic.
//---
//--- A MISSING ini is NOT an error here. It is the first step of the
//--- hub-driven bootstrap: connect, subscribe to your own control topic, mirror
//--- nothing, and say so - then the hub pushes the file. Refusing to start
//--- would make that bootstrap impossible, and the receiver would be stuck
//--- waiting for a file it can only receive by starting.
bool LoadConfigForHub()
  {
   g_hubOn=true;
   g_nid=CopierNid(CopierAccountLogin());
   g_hubEp=CopierNormalizeEndpoint(HubEndpoint);   // bare IP:port gains tcp://

   CopierIni ini;
   if(!ini.Load(CP_INI_PATH))
     {
      g_nSenders=0;
      //--- THE ARRAY FOLLOWS THE COUNT. This function runs a SECOND time
      //--- when the hub pushes a CFG, and the documented hub bootstrap is
      //--- exactly that: connect with no ini (zero senders), let the hub
      //--- push the file, load it here. g_desired was allocated in OnInit
      //--- at the THEN-current count - zero - so without this resize the
      //--- first SNAP after the push writes g_desired[base+i] on a
      //--- zero-length array and the receiver dies with "array out of
      //--- range": the chart goes, not just the mirror. Growing preserves
      //--- what is there, and every sender's g_desiredCount is reset to 0
      //--- below, so nothing stale is readable before the next SNAP.
      ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS);
      g_log.Warn("central mode: no "+CP_INI_PATH+" yet, so this receiver mirrors"
                 +" NOTHING. It is connected to the hub and waiting - the hub"
                 +" owns this file and pushes it. If it never arrives, check"
                 +" that the hub is running and that account "
                 +(string)CopierAccountLogin()+" is configured in it.");
      return true;                    // connected, zero senders - NOT a failure
     }

   ApplyCommonConfig(ini);

   //--- Start from an empty symbol map on every load - see MapClear. A CFG
   //--- push re-runs this whole function, and without the clear the old
   //--- rows stay underneath the new ones.
   MapClear();

   g_nSenders=ini.SenderCount();
   if(g_nSenders>CP_MAX_SENDERS) g_nSenders=CP_MAX_SENDERS;
   //--- Same resize as the no-ini branch above: a CFG push re-runs this
   //--- whole function, and the count can go from N to M in either
   //--- direction. g_desired is indexed as si*CP_MAX_POSITIONS + i, so its
   //--- size IS the sender count - re-reading the ini without resizing it
   //--- is the crash the bootstrap path hits first.
   ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS);
   if(g_nSenders<=0)
     {
      g_log.Warn("central mode: "+CP_INI_PATH+" has no [senderN] sections, so"
                 +" this receiver mirrors nothing.");
      return true;
     }

   for(int i=0;i<g_nSenders;i++)
     {
      string sec="sender"+(string)i;
      g_sid[i]=ini.Get(sec,"id","");
      if(StringLen(g_sid[i])==0)
        {
         g_log.Error("central mode: "+sec+" has no id=. It must be the SENDER'S"
                     +" NID - the number that sender prints as nid= in its"
                     +" startup line. Without it there is no topic to subscribe"
                     +" to, and this sender would be mirrored by nobody.");
         return false;
        }
      //--- cleared, NOT read - see the note above
      g_epEvents[i] ="";
      g_epSnap[i]   ="";
      g_serverKey[i]="";
      g_suffix[i]   =ini.Get(sec,"suffix","");

      //--- magic= is REQUIRED, exactly as in the direct path. There is no
      //--- fallback: a guessed magic orphans whatever is already open under the
      //--- real one. The hub knows every sender's NID, so it can always write a
      //--- correct value here.
      bool pinned=false;
      g_magic[i]=CopierResolveMagic(ini.Get(sec,"magic",""),pinned);
      g_magicPinned[i]=pinned;
      if(g_magic[i]<0)
        {
         g_log.Error("central mode: sender "+g_sid[i]+" has no magic= in "
                     +CP_INI_PATH+". Every sender MUST pin its magic - it is how"
                     +" this receiver finds that sender's positions, so a guess"
                     +" would orphan real orders.");
         return false;
        }

      bool lotOk=false;
      g_lotMode[i] =CopierLotModeFromText(ini.Get(sec,"lotmode","multiplier"),
                                          lotOk);
      if(!lotOk)
         g_log.Warn("sender "+g_sid[i]+": lotmode=\""
                    +ini.Get(sec,"lotmode","")+"\" is not recognised - falling"
                    +" back to multiplier. Use off / multiplier / fixed, or the"
                    +" codes 2 / 0 / 1.");
      g_lotParam[i]=ini.GetDouble(sec,"lotparam",1.0);

      for(int k=0;k<ini.Count();k++)
        {
         if(ini.SecAt(k)!=sec) continue;
         string key=ini.KeyAt(k);
         if(StringFind(key,"symbol.")!=0) continue;
         MapAdd(i,StringSubstr(key,StringLen("symbol.")),ini.ValAt(k));
        }

      //--- reset this sender's stream state. Globals SURVIVE a reinitialisation,
      //--- so a stale watermark here would make the receiver discard the first
      //--- messages from a sender it has only just been told about.
      g_lastSeq[i][CP_STREAM_EVENTS]=-1;
      g_lastSeq[i][CP_STREAM_SNAP]=-1;
      g_ssidSeen[i]="";
      g_lastMsgMs[i]=0;
      g_firstMsgMs[i]=0;
      g_lastSnapMs[i]=0;
      g_snapHash[i]="";
      g_stale[i]=false;
      g_ready[i]=false;
      g_desiredCount[i]=0;

      InitSenderSettings(i, ini, sec);
     }

   g_log.Info("central mode: "+IntegerToString(g_nSenders)+" sender(s) from "
              +CP_INI_PATH+" - subscribing to each sender's NID, plus control"
              +" for this account (NID "+(string)g_nid+")");
   return true;
  }

bool LoadConfig()
  {
   //--- CENTRAL (hub) mode, decided by HubEndpoint ALONE.
   //---
   //--- Deliberately NOT "HubEndpoint set AND copier.ini exists". A hub-mode
   //--- receiver's first configuration arrives BY the hub, so if a missing file
   //--- could push it back to direct mode it would never connect - and then the
   //--- hub would have no way to push the file that would have made it connect.
   //---
   //--- What decides "am I on a hub" is therefore a switch the OPERATOR sets,
   //--- not a file's presence. Files come and go; the switch is the intent.
   if(StringLen(HubEndpoint)>0) return LoadConfigForHub();

   //--- DIRECT mode: the inputs, and ONLY the inputs.
   //---
   //--- copier.ini is the hub's config file now. A direct-mode receiver has no
   //--- hub to generate one, so reading it would mean two owners of one file.
   //--- A multi-sender DIRECT setup is one receiver instance per sender.
   //---
   //--- The warning is not decoration: an operator upgrading with a
   //--- three-sender ini would otherwise go from three senders to one in
   //--- silence, and "my other senders stopped" is a hard thing to trace back
   //--- to a file that is simply no longer read. It names both ways out,
   //--- because "the file is ignored" is not actionable on its own.
   CopierIni probe;
   if(probe.Load(CP_INI_PATH))
      g_log.Warn(CP_INI_PATH+" exists in MQL\\Files but is IGNORED - it is only"
                 +" used in central (hub) mode. This receiver is running from"
                 +" the inputs above, mirroring ONE sender. To mirror several"
                 +" directly, attach one CopierReceiver per sender on separate"
                 +" charts; to use the file, fill in HubEndpoint.");
   return LoadConfigFromInputs();
  }

//=====================================================================
// Local position discovery: which of MY positions belong to sender si?
// Identity comes from the comment WE wrote ourselves ("tc|<uid>").
// The magic number separates senders from each other and from any
// other EA running on the same account.
//=====================================================================
//=====================================================================
// Which UID does this local position belong to?
//
// Three sources, tried in order, because THE COMMENT IS NOT DURABLE:
//
//   1. the comment itself ("tc|<uid>|..."). The fast path, and the only one
//      that still works after a state-file loss - which is why it is first.
//   2. our own record, keyed on POSITION_IDENTIFIER. This is what survives a
//      partial close on MT5, where the terminal overwrites the position's
//      comment with the closing deal's (an empty one, if the close went
//      through CTrade).
//   3. the MT4 "from #<old>" chain. A partial close there replaces the
//      ticket AND the comment, so the chain is the only link back.
//
// Relying on (1) alone is what let a partial close orphan a position and
// make converge open a duplicate beside it.
//=====================================================================
string ResolveUid(const CopierPos &p)
  {
   string uid=CopierUidFromComment(p.cmt);
   if(StringLen(uid)>0) return uid;

   CopierPos prev;
   if(g_recKnown.GetByTicket(p.ticket,prev)) return prev.uid;

   long from=CopierMt4FromTicket(p.cmt);
   if(from>0 && g_recKnown.GetByTicket(from,prev)) return prev.uid;

   return "";
  }

int LocalForSender(const int si,const CopierPos &all[],const int n,CopierPos &out[])
  {
   int m=0;
   ArrayResize(out,0,CP_MAX_POSITIONS);
   for(int i=0;i<n;i++)
     {
      if(all[i].magic!=g_magic[si]) continue;

      string uid=ResolveUid(all[i]);
      if(StringLen(uid)==0) continue;

      CopierPos p=all[i];
      p.uid=uid;
      ArrayResize(out,m+1,CP_MAX_POSITIONS);
      out[m]=p;
      m++;

      //--- keep the record current (Upsert is a no-op when nothing changed
      //--- except lots, so this does not churn)
      g_recKnown.Upsert(p);
     }
   return m;
  }

//=====================================================================
// The receiver's own record of what it is managing: UID <-> broker
// identifier, persisted to disk.
//
// It exists because the comment is NOT durable. It is the primary
// identity while it survives, and a hint afterwards; the identifier is
// what actually persists, and this is what remembers the pairing.
//
// Rebuilt from the account each time (so closed positions drop out) and
// written back. Small, bounded, and rewritten whole - never appended.
//=====================================================================
//--- one receiver instance per terminal, so a fixed name is enough and
//--- avoids depending on the config having been read yet
//--- Per-instance file names. Two receivers in one terminal MUST NOT share
//--- the state file: it holds the UID<->ticket map, which is the only way to
//--- identify a position after an MT5 partial close overwrites the comment.
//--- Sharing it corrupts both instances' identity, silently.
//---
//--- DIRECT mode is one sender per instance, and Magic is unique per sender, so
//--- Magic identifies the instance exactly.
//---
//--- CENTRAL mode is one instance serving every sender in its ini, so Magic is
//--- the wrong key there - and it CANNOT be used, because the ini is what says
//--- which magics exist and it is read AFTER this runs. The ACCOUNT is the right
//--- key instead: the hub allows one receiver per account (two on one account
//--- could not be told apart), and the NID is computable from the account before
//--- any config is loaded.
//---
//--- Either way the suffix comes from something already known, which matters:
//--- the log file is named at the top of OnInit, long before LoadConfig runs.
string InstanceSuffix()
  {
   if(StringLen(HubEndpoint)>0)                             // central mode
      return "_"+(string)CopierNid(CopierAccountLogin());
   if(Magic<=0) return "";                                  // not configured yet
   return "_"+(string)Magic;                                // direct mode
  }

string ReceiverStatePath() { return "copier_receiver"+InstanceSuffix()+".st"; }

//--- The drawdown PEAK, persisted beside (but separate from) the position
//--- state.
//---
//--- WHY A SEPARATE FILE
//--- ===================
//--- `copier_receiver*.st` is the position-identity cache and its format is
//--- shared with the sender's writer; adding a field to it would mean
//--- changing a contract that protects real orders. This file holds one
//--- number that nothing else reads, so it can be added, lost or deleted
//--- without any effect on identity.
//---
//--- WHY IT IS KEYED BY ACCOUNT, NOT BY MAGIC
//--- ========================================
//--- The drawdown switch is ACCOUNT-wide (it is `g_risk`, not
//--- `g_senderRisk`), so the peak is a property of the account's equity curve.
//--- Keying it by a magic would silently start a second, unrelated peak the
//--- moment the operator edited the magic - which is the same
//--- "restart forgives the drawdown" hole in a different disguise.
string RiskPeakPath() { return "copier_risk_"+(string)CopierAccountLogin()+".dat"; }
long   g_lastPeakSave=0;

void RiskPeakLoad()
  {
   int h=FileOpen(RiskPeakPath(),FILE_READ|FILE_TXT|FILE_ANSI
                  |FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return;              // first run: no peak yet
   double peak=0.0;
   while(!FileIsEnding(h))
     {
      string line=CopierTrim(FileReadString(h));
      if(StringLen(line)==0) continue;
      string v="";
      if(CopierKvGet(line,"PEAK",v)) peak=StringToDouble(v);
     }
   FileClose(h);
   if(peak<=0.0) return;
   g_risk.SeedPeak(peak);
   if(g_risk.PeakEquity()>peak+0.005)
      g_log.Info("drawdown baseline restored from "+RiskPeakPath()
                 +": peak "+DoubleToString(peak,2)
                 +" (current equity is already higher, so that value stands)");
   else
      g_log.Info("drawdown baseline restored from "+RiskPeakPath()
                 +": peak "+DoubleToString(peak,2)
                 +" - a restart no longer re-bases the drawdown to today's"
                 +" equity");
  }

//--- `force` writes even inside the throttle window (used on shutdown).
void RiskPeakSave(const bool force)
  {
   double peak=g_risk.PeakEquity();
   if(peak<=0.0) return;
   long now=CopierNowMs();
   //--- Once a minute is enough: the peak only matters if the terminal dies,
   //--- and losing up to a minute of a RISING peak understates the baseline by
   //--- at most that minute's gain - never overstates it, which is the
   //--- direction that would falsely block trading.
   if(!force && now-g_lastPeakSave<60000) return;
   g_lastPeakSave=now;
   int h=FileOpen(RiskPeakPath(),FILE_WRITE|FILE_TXT|FILE_ANSI
                  |FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
     {
      if(g_once.ShouldEmit("peaksave"))
         g_log.Warn("cannot write "+RiskPeakPath()+" - the drawdown peak will"
                    +" NOT survive a restart (reported at most once per 10 min)");
      return;
     }
   FileWrite(h,"V=1");
   FileWrite(h,"PEAK="+DoubleToString(peak,2));
   FileFlush(h);
   FileClose(h);
  }

//--- Terminal-wide mutual exclusion for Receiver instances on the same account.
//--- Central mode allows strictly ONE receiver per account (it handles all senders via Hub).
//--- Direct mode allows multiple receivers for different senders, BUT each chart must have
//--- a unique Magic number to prevent state-file collisions and duplicate order execution.
bool g_lockAcquired=false;

string InstanceLockName()
  {
   if(StringLen(HubEndpoint)>0)
      return "CP_LOCK_RCV_C_"+(string)CopierNid(CopierAccountLogin());
   if(Magic<=0) return "";
   return "CP_LOCK_RCV_D_"+(string)Magic;
  }

bool ChartExists(const long id)
  {
   if(id<=0) return false;
   long curr=ChartFirst();
   while(curr>=0)
     {
      if(curr==id) return true;
      curr=ChartNext(curr);
     }
   return false;
  }

void SetLockChartId(const string name,const long chartId)
  {
   long hi=(chartId>>32)&0xFFFFFFFF;
   long lo=chartId&0xFFFFFFFF;
   GlobalVariableTemp(name+"_H");
   GlobalVariableSet(name+"_H",(double)hi);
   GlobalVariableTemp(name+"_L");
   GlobalVariableSet(name+"_L",(double)lo);
  }

long GetLockChartId(const string name)
  {
   if(!GlobalVariableCheck(name+"_H") || !GlobalVariableCheck(name+"_L"))
      return 0;
   long hi=(long)GlobalVariableGet(name+"_H");
   long lo=(long)GlobalVariableGet(name+"_L");
   return (hi<<32)|(lo&0xFFFFFFFF);
  }

void DelLockChartId(const string name)
  {
   GlobalVariableDel(name+"_H");
   GlobalVariableDel(name+"_L");
   GlobalVariableDel(name); // legacy cleanup
  }

bool AcquireInstanceLock()
  {
   string name=InstanceLockName();
   if(StringLen(name)==0) return true;
   long myChart=ChartID();
   if(GlobalVariableCheck(name+"_H") || GlobalVariableCheck(name+"_L"))
     {
      long holderChart=GetLockChartId(name);
      if(holderChart!=myChart)
        {
         if(ChartExists(holderChart))
           {
            string sym=ChartSymbol(holderChart);
            if(StringLen(sym)==0) sym="unknown";
            if(StringLen(HubEndpoint)>0)
              {
               g_log.Error("A CopierReceiver instance is ALREADY running on chart "
                           +(string)holderChart+" ("+sym+") with lock "+name
                           +". Running two receivers on the same account in Central mode causes"
                           +" state-file corruption and duplicate executions. Refusing to start.");
              }
            else
              {
               g_log.Error("A CopierReceiver instance with Magic "+(string)Magic
                           +" is ALREADY running on chart "+(string)holderChart
                           +" ("+sym+") with lock "+name
                           +". In Direct mode, each chart must use a unique Magic number to prevent"
                           +" state-file collisions and duplicate executions. Refusing to start.");
              }
            return false;
           }
         else
           {
            g_log.Warn("Reclaiming stale receiver lock "+name+" from non-existent chart "
                       +(string)holderChart);
           }
        }
     }
   SetLockChartId(name,myChart);
   g_lockAcquired=true;
   return true;
  }

void ReleaseInstanceLock()
  {
   if(!g_lockAcquired) return;
   g_lockAcquired=false;
   string name=InstanceLockName();
   if(StringLen(name)==0) return;
   long myChart=ChartID();
   if(GetLockChartId(name)==myChart)
      DelLockChartId(name);
  }

//--- M5b: the operational-command state, one small file, the same pattern
//--- CopierCfgRevSave uses for the config revision. The ACK body is stored
//--- percent-escaped (it is full of ';' and '='), which is exactly what the
//--- CFG push already does to a whole ini - the escape is proven on a much
//--- larger input, and CopierIniUnescape reverses it byte for byte.
//--- A torn file degrades safely: a failed parse yields paused=false, which
//--- is the pre-command default, and the hub's ladder re-asks anything the
//--- receiver never answered.
string CmdStatePath() { return "copier_cmd"+InstanceSuffix()+".st"; }

void CmdStateSave()
  {
   string body="PAUSED="+(g_cmdPaused?"1":"0")
              +"\nID="+g_cmdId
              +"\nACK="+CopierIniEscape(g_cmdAck);
   CopierIniWriteAll(CmdStatePath(),body);
  }

void CmdStateLoad()
  {
   g_cmdPaused=false; g_cmdId=""; g_cmdAck="";
   string text="";
   if(!CopierIniReadAll(CmdStatePath(),text)) return;
   string lines[];
   int n=CopierSplitLines(text,lines);
   for(int i=0;i<n;i++)
     {
      string line=CopierTrim(lines[i]);
      string v="";
      if(CopierKvGet(line,"PAUSED",v)) g_cmdPaused=(v=="1");
      if(CopierKvGet(line,"ID",v))     g_cmdId=v;
      if(CopierKvGet(line,"ACK",v))    CopierIniUnescape(v,g_cmdAck);
     }
  }

void SaveReceiverMap()
  {
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   //--- cleared per use: see the note on g_saveScratch
   g_saveScratch.Clear();

   for(int i=0;i<an;i++)
     {
      int si=-1;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { si=k; break; }
        }
      if(si<0) continue;                        // not ours

      string uid=ResolveUid(all[i]);
      if(StringLen(uid)==0) continue;           // unmanageable; reported elsewhere

      CopierPos p=all[i];
      p.uid=uid;
      g_saveScratch.Upsert(p);
     }

   g_recKnown.CopyFrom(g_saveScratch);

   CopierPos dense[];
   int dn=g_recKnown.CopyTo(dense);
   if(!CopierStateFile::Save(ReceiverStatePath(),"N="+(string)dn,dense,dn))
     {
      //--- Rate-limited. This is retried every 10 s, so a persistent
      //--- failure - a locked file, a full disk, a broker sandbox that
      //--- forbids the write - would otherwise add six lines a minute
      //--- forever. That is the same log-volume trap the per-tick symbol
      //--- warning fell into (2542 lines / 264 KB in 21 minutes).
      if(g_once.ShouldEmit("statesave"))
         g_log.Warn("cannot write "+ReceiverStatePath()+" - identity will NOT"
                    +" survive a restart on MT4 (retried every 10s, reported"
                    +" at most once per 10 min)");
     }
   else if(!g_stateSaveOk)
     {
      //--- Once per session, so a pilot can tell the durability mechanism
      //--- is actually live rather than merely present in the source.
      g_stateSaveOk=true;
      g_log.Info("identity store "+ReceiverStatePath()+" written ("
                 +(string)dn+" position(s))");
     }
  }

int LocalFindUid(const CopierPos &loc[],const int n,const string uid)
  {
   for(int i=0;i<n;i++) { if(loc[i].uid==uid) return i; }
   return -1;
  }

//--- Report orders that carry one of OUR magic numbers but whose comment
//--- does not yield a readable UID.
//---
//--- These are unmanageable: every mapping in the copier is keyed on the
//--- UID in the comment, so LocalForSender() skips them, ConvergeSender()
//--- never sees them, and nothing will ever close them. They just sit on
//--- the account until a human notices.
//---
//--- That is exactly what happened on the first MT4 pilot: two orders were
//--- orphaned for the whole session and NOT ONE LINE was logged, because
//--- skipping was silent. The receiver went on to close 13 other orders in
//--- the same run, so everything looked healthy. A diagnostic that prints
//--- the offending comment turns an invisible failure into a one-line
//--- answer - most likely a broker that rewrote or truncated the comment.
void ReportUnreadableOwnOrders()
  {
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   int bad=0;
   for(int i=0;i<an;i++)
     {
      int si=-1;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { si=k; break; }
        }
      if(si<0) continue;                                     // not ours
      //--- an unreadable comment is EXPECTED after a partial close (MT5
      //--- overwrites it, MT4 replaces the ticket). It is only a problem if
      //--- none of the three sources can name the position - then nothing
      //--- will ever match it, and it can never be closed.
      if(StringLen(ResolveUid(all[i]))>0) continue;

      bad++;
      g_log.Error("order "+all[i].sym+" ticket="+(string)all[i].ticket
                  +" magic="+(string)all[i].magic+" ("+g_sid[si]+")"
                  +" carries our magic but its comment yields no UID"
                  +" [comment=\""+all[i].cmt+"\"]"
                  +" - it can never be matched or closed by the copier");
     }
   if(bad>0)
      g_log.Error("found "+(string)bad+" unmanageable order(s) on this"
                  +" account; they will be left untouched until closed by"
                  +" hand");
  }

//--- The mirror image of the check above.
//---
//--- ReportUnreadableOwnOrders() catches "one of OUR magics, but no readable
//--- UID". This catches "one of OUR UIDs, but a magic no sender owns any
//--- more" - which is what a reordered copier.ini actually produces.
//---
//--- Those are the worst kind of leftover: the position is real money, it
//--- carries this copier's own comment tag, and it is invisible to every
//--- loop in this file, because all of them select on magic first. Nothing
//--- will ever close it, and the sender's live position gets opened again
//--- under the new magic - so the account ends up holding both.
//---
//--- Reporting it with the magic to add turns a silent loss into a one-line
//--- fix. Without this, reordering sections looks like it worked.
void ReportOrphanedMirrors()
  {
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   int bad=0;
   for(int i=0;i<an;i++)
     {
      //--- only positions WE tagged. Another EA may legitimately use any
      //--- magic, and none of those are ours to comment on.
      string uid=CopierUidFromComment(all[i].cmt);
      if(StringLen(uid)==0) continue;

      bool owned=false;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { owned=true; break; }
        }
      if(owned) continue;

      bad++;
      g_log.Error("ORPHAN: "+all[i].sym+" ticket="+(string)all[i].ticket
                  +" uid="+uid+" magic="+(string)all[i].magic
                  +" - it carries this copier's comment tag but no sender is"
                  +" configured with that magic (a reordered copier.ini or a"
                  +" changed MagicBase moves a sender onto a new one)."
                  +" Nothing will manage or close it. To adopt it, add"
                  +" magic="+(string)all[i].magic+" to that sender's section;"
                  +" otherwise close it by hand.");
     }
   if(bad>0)
      g_log.Error("found "+(string)bad+" orphaned position(s) left under a"
                  +" magic that is no longer configured - see the lines above");
  }

//--- Magic-number sanity at startup. Nothing here costs anything, and it is
//--- the only thing standing between an edited copier.ini and a position
//--- set the copier can no longer see.
void ReportMagicConfig()
  {
   //--- There is no "unpinned" case to warn about any more: a missing magic
   //--- is a startup error now, so by the time we are here every sender has
   //--- an explicit one. Report them so they can be checked against the
   //--- terminal, which is the only place a wrong-but-present magic shows up.
   for(int i=0;i<g_nSenders;i++)
      g_log.Info("sender "+g_sid[i]+" pinned to magic "
                 +(string)g_magic[i]);
   //--- Print the EFFECTIVE sizing rule in words, once per sender.
   //---
   //--- Not decoration: the input dropdown's numbering was aligned with the
   //--- internal codes in this build, so a saved input set where
   //--- SenderLotMode=2 used to mean "fixed" now means "off". A number in a
   //--- dialog is not something anyone re-checks; a sentence in the log is.
   for(int i=0;i<g_nSenders;i++)
      g_log.Info("sender "+g_sid[i]+" sizes mirrors as "
                 +CopierLotModeText(g_lotMode[i])
                 +" (param "+DoubleToString(g_lotParam[i],4)+")");

   //--- Two senders on one magic cannot be told apart: every lookup is by
   //--- magic alone, so they share a single position set and each will close
   //--- what the other opened.
   for(int i=0;i<g_nSenders;i++)
     {
      for(int k=i+1;k<g_nSenders;k++)
        {
         if(g_magic[i]!=g_magic[k]) continue;
         g_log.Error("sender "+g_sid[i]+" and "+g_sid[k]+" both use magic "
                     +(string)g_magic[i]+". The receiver tells senders apart"
                     +" by magic alone, so these two share one position set"
                     +" and each will close what the other opened. Give every"
                     +" sender a distinct magic= in copier.ini.");
        }
     }
  }

//--- What this BROKER actually allows, discovered once at startup.
//---
//--- Our own tables (CP_MAX_POSITIONS) are an internal question and answer a
//--- different one. A platform may cap open positions at 200, or 500, or
//--- anything else, and sending an order it is going to refuse - repeatedly -
//--- is how an account gets throttled or blocked rather than merely refused.
//---
//--- A broker may cap open positions at 200, or 500, or anything else, and
//--- sending an order it is going to refuse - repeatedly - is how an account
//--- gets throttled or blocked rather than merely refused.
//---
//--- Both platforms answer the same question now: MQL4 has had
//--- AccountInfoInteger/ACCOUNT_LIMIT_ORDERS since the build-600 API, and the
//--- old assumption that MT4 could not answer left MT4 accounts without the
//--- protection the MT5 side already had. 0 still means UNKNOWN, never
//--- "unlimited" - the gate must then fall back to the operator's own cap.
void ReportBrokerLimits()
  {
   g_brokerOrdLimit=CopierBrokerOrderLimit();

   //--- The cap a broker imposes (200, 500, ...) is on ORDERS, and a broker's
   //--- "order" quota counts BOTH pools together - a working order sits in the
   //--- orders pool and is not counted under positions. So the gate in
   //--- converge compares (open positions + pending orders) against this, not
   //--- the pending side alone.
   if(g_brokerOrdLimit>0)
      g_log.Info("broker limit: max ORDERS="+(string)g_brokerOrdLimit
                 +" (counted as open positions + pending orders together,"
                 +" which is how a broker's order quota works). New entries"
                 +" stop at it rather than being sent and refused.");
   else
      g_log.Warn("this broker reports no order limit (ACCOUNT_LIMIT_ORDERS is"
                 +" 0 or absent). That means UNKNOWN, not unlimited: if your"
                 +" broker does cap total orders, the copier cannot discover it"
                 +" and will find out by being refused - each repeat refusal"
                 +" then backs that order off further: "+CopierBackoffText(2)
                 +", "+CopierBackoffText(3)+", "+CopierBackoffText(4)+", "
                 +CopierBackoffText(5)+", up to "+CopierBackoffText(8)
                 +", with a loud log line so there is time to fix it by hand.");

   //--- A discoverable cap BELOW our own table is worth stating plainly:
   //--- the sender can hold more than this account may mirror, and that gap
   //--- is a configuration fact, not a runtime bug.
   if(g_brokerOrdLimit>0 && g_brokerOrdLimit<CP_MAX_POSITIONS)
      g_log.Warn("this broker allows only "+(string)g_brokerOrdLimit
                 +" pending order(s) while the copier's table holds "
                 +(string)CP_MAX_POSITIONS+". A sender holding more working"
                 +" orders than that cannot be mirrored in full: the excess"
                 +" is skipped before it is sent, so nothing is refused. The"
                 +" two accounts will differ by design here.");

   //--- Market entries are bounded by the operator's cap INSTEAD - but "no
   //--- MaxOpenPositions" must not be reported as "nothing is watching this".
   //---
   //--- The old wording said the account was "uncapped ... and there is
   //--- nothing to discover either", which was doubly wrong: the broker's
   //--- order quota IS discoverable and IS enforced (the gate in converge
   //--- checks positions + pending against it before every entry), and on MT4
   //--- it was not even being read. An operator told an account is
   //--- unprotected will go hunting for a problem that is not there - or stop
   //--- looking for one that is.
   if(MaxOpenPositions<=0)
     {
      if(g_brokerOrdLimit>0)
         g_log.Info("no MaxOpenPositions set: open positions are capped only"
                    +" by this broker's own order limit of "
                    +(string)g_brokerOrdLimit+" (open positions + pending"
                    +" orders, counted together and checked before every"
                    +" entry, so nothing is sent to be refused). Set"
                    +" MaxOpenPositions to hold fewer than that.");
      else
         g_log.Info("no MaxOpenPositions set, and this terminal reports no"
                    +" order limit either, so the only ceiling on open"
                    +" positions is the broker refusing one. A refusal is"
                    +" backed off rather than retried in a loop - but set"
                    +" MaxOpenPositions if you want a cap you control.");
     }
  }

//--- Say which entry gates are actually ON, at startup.
//---
//--- Without this, "the setting is not working" and "the setting is not set"
//--- look identical from the outside - the operator changed a field, saw no
//--- effect, and has no way to tell whether the EA read it. Printing the
//--- EFFECTIVE configuration turns that into a one-line answer.
void ReportEntryGates()
  {
   string on="";
   if(IgnoreNewEntrySignals)          on+="IgnoreNewEntrySignals ";
   //--- Not a configured gate but a runtime one, and it IS persisted - so a
   //--- receiver that starts up paused must say so in the same line that
   //--- lists every other gate, or the operator reads "none configured" and
   //--- believes it.
   if(g_cmdPaused)                    on+="HubPaused ";
   if(IgnoreAllExitSignals)           on+="IgnoreAllExitSignals ";
   if(NoBuy)                          on+="NoBuy ";
   if(NoSell)                         on+="NoSell ";
   if(g_permitted.Active())           on+="PermittedSymbols("
                                         +(string)g_permitted.Count()+") ";
   if(g_permittedMagic.Active())      on+="PermittedMagic("
                                         +(string)g_permittedMagic.Count()+") ";
   if(g_hours.Active())               on+="TradingTimes ";
   if(CheckForExistingPosition!=EXIST_OFF)
      on+="CheckForExistingPosition("
          +((CheckForExistingPosition==EXIST_SAME_DIR)?"same dir":"any")+") ";
   if(MinSenderLotSize>0.0 || MaxSenderLotSize>0.0) on+="SenderLotRange ";
   if(InvertTrades)                   on+="InvertTrades ";

   long waitSec=(long)WaitForHours*3600+(long)WaitForMinutes*60
               +(long)WaitForSeconds;
   long limitSec=(long)RequirePositionFillWithinHours*3600
                +(long)RequirePositionFillWithinMinutes*60
                +(long)RequirePositionFillWithinSeconds;

   if(waitSec>0)
      on+="WaitFor("+CopierSecText(waitSec)+") ";
   //--- != 0, not > 0: a NEGATIVE threshold is a real setting (wait for a
   //--- pullback), and testing for positive here would leave it out of the
   //--- startup summary - the one line that exists to prove a setting was
   //--- read at all.
   if(WaitForProfitPips!=0.0)
      on+="WaitForProfit("+CopierFmtDouble(WaitForProfitPips,1)+"p) ";
   if(limitSec>0)
      on+="FillTimeout("+CopierSecText(limitSec)+") ";
   if(FillWithinMinutesBar>0)
      on+="FillTimeout("+(string)FillWithinMinutesBar+" bars) ";
   if(WaitForMinutesBar>0)
      on+="WaitFor("+(string)WaitForMinutesBar+" bars) ";

   if(StringLen(on)==0)
      g_log.Info("entry gates: none configured - every sender entry is"
                 +" mirrored as it arrives");
   else
      g_log.Info("entry gates ACTIVE: "+on
                 +"- entries are filtered by these; exits never are");
  }

//=====================================================================
// Action queue
//=====================================================================
bool ActionQueued(const int si,const int kind,const string uid)
  {
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[i].senderIdx==si && g_q[i].kind==kind && g_q[i].uid==uid) return true;
     }
   return false;
  }

//--- Returns TRUE when the action was actually queued, false when it was
//--- suppressed (already seen, already queued, parked after a failure, or
//--- the queue is full). Callers that log "I am about to do X" MUST check
//--- it: logging the intent without the act is how a suppressed action
//--- turns into 4904 identical lines a minute.
bool PushAction(const int si,const int kind,const string uid,const string sym,
                const int side,const double lots,const long ticket,
                const long senderTicket=0,const string keyExtra="",
                const double sl=0.0,const double tp=0.0,
                const int ordKind=CP_ORD_MARKET,const int ptype=0,
                const double pprice=0.0,const double pstop=0.0,
                const long pexpire=0)
  {
   //--- keyExtra distinguishes actions that share a kind and a UID but are
   //--- genuinely different, e.g. two successive partial closes to two
   //--- different target volumes, or two successive stop changes
   string key=g_sid[si]+":"+(string)kind+":"+uid+keyExtra;
   //--- an idempotent state assignment is guarded by the state comparison
   //--- on every converge pass, NOT by the "already done" ring - see
   //--- CopierSeenRingApplies() for the pilot failure this caused
   if(CopierSeenRingApplies(kind) && g_seen.Has(key)) return false;
   //--- An action that just FAILED is parked briefly, so a refused request is
   //--- not repeated ten times a second forever.
   //---
   //--- Keyed on the SAME key the seen-ring uses, not on (sender, kind, uid).
   //--- That matters: the key carries what makes this action distinct, so a
   //--- parked PENDING open does not suppress the MARKET open that follows it
   //--- when the sender's pending order fills.
   //--- Parked after a failure. The gap ESCALATES with each consecutive
   //--- refusal - see CopierBackoff - so a standing condition (a broker
   //--- limit, an unsupported filling mode) backs off to hours instead of
   //--- being hammered every two seconds.
   if(g_backoff.Blocked(key)) return false;
   //--- and a longer park for something this platform cannot place at all,
   //--- for the same reason - the key keeps it from touching anything else.
   if(g_unsupported.Has(key)) return false;
   if(ActionQueued(si,kind,uid)) return false;
   if(g_qn>=CP_MAX_ACTIONS)
     {
      //--- COUNTED, not logged. A burst that fills the queue defers one
      //--- action per overflow per pass, so logging here produced 585 lines
      //--- in a single minute - the same unbounded-noise failure as the
      //--- superseded-snapshot line, reached the same way. The per-minute
      //--- report prints the total instead, and says it recovered.
      //---
      //--- Deferring is not a failure: the next snapshot re-derives the
      //--- action and it goes through as the queue drains. That is why this
      //--- is a warning about throughput, not an error about lost work.
      g_qDeferred++;
      return false;
     }
   g_q[g_qn].senderIdx=si;
   g_q[g_qn].kind=kind;
   g_q[g_qn].uid=uid;
   g_q[g_qn].sym=sym;
   g_q[g_qn].side=side;
   g_q[g_qn].lots=lots;
   g_q[g_qn].ticket=ticket;
   g_q[g_qn].senderTicket=senderTicket;
   //--- every field is written on every push. g_q is a fixed array of
   //--- structs and slots are reused, so a field left unset would silently
   //--- inherit the previous occupant's value.
   g_q[g_qn].sl=sl;
   g_q[g_qn].tp=tp;
   g_q[g_qn].ordKind=ordKind;
   g_q[g_qn].ptype=ptype;
   g_q[g_qn].pprice=pprice;
   g_q[g_qn].pstop=pstop;
   g_q[g_qn].pexpire=pexpire;
   g_q[g_qn].key=key;
   g_qn++;
   return true;
  }

void ShiftQueue()
  {
   for(int i=1;i<g_qn;i++) g_q[i-1]=g_q[i];
   g_qn--;
  }

double PipSize(const CopierSymInfo &si)
  {
   return (si.digits==3 || si.digits==5) ? si.point*10.0 : si.point;
  }

//--- Move the head of the queue to the back.
//--- Used to step past an action that must not be sent right now without
//--- dropping it: converge would re-derive an OPEN anyway, but a CLOSE has no
//--- other source, so nothing may be silently discarded here.
void RotateQueue()
  {
   if(g_qn<2) return;
   CopierAction h=g_q[0];
   for(int i=1;i<g_qn;i++) g_q[i-1]=g_q[i];
   g_q[g_qn-1]=h;
  }

void ExecuteQueue()
  {
   int done=0;
   int skipped=0;
   //--- `skipped` bounds a full rotation, so a queue in which EVERY action is
   //--- blocked does not spin through itself ten times a second.
   while(g_qn>0 && done<MaxActionsPerTick && skipped<=g_qn)
     {
      CopierAction a=g_q[0];
      int err=0;
      bool ok=false;

      //--- THE QUEUE DRAIN IS NOT THE CONVERGE LOOP, and it does not pass
      //--- through converge's gates. An action queued BEFORE the market shut
      //--- would otherwise still be sent - which is exactly what happened:
      //--- the log showed "market is closed, holding new entries" and a
      //--- failed attempt in the same second, because the gate stopped the
      //--- NEW entries while this one was already in the queue.
      //---
      //--- So the same check has to be applied on the way OUT as well. The
      //--- action is rotated to the back, not dropped, so other symbols keep
      //--- flowing and this one goes as soon as its session opens.
      //--- The stale-feed test is checked HERE TOO, and this is the one that
      //--- actually stops the weekly-close retry loop: the session schedule
      //--- is evaluated against the frozen clock, so at 23:54:59 on a Friday
      //--- it still reports "inside the session" and waves the send through.
      //--- A clock that is not advancing is the reliable signal.
      //---
      //--- IT COVERS EVERY ACTION KIND, NOT JUST OPEN. Gating only OPEN did
      //--- not fix the storm, it MOVED it: over the next weekly close the
      //--- sender had closed something, converge queued the CLOSE, the market
      //--- was shut, and the attempt failed with err=132 every two seconds
      //--- until Monday - exactly the same loop, one action kind over. The
      //--- log read "trade failed ... kind=2 err=132" while converge was
      //--- correctly refusing every new entry.
      //---
      //--- Nothing can be priced from a clock that is not advancing, so there
      //--- is nothing to attempt. Holding is safe because converge re-derives
      //--- every action from the next snapshot the moment the feed returns -
      //--- a held close is a DELAY, never a loss.
      if(!g_srvEverMoved
         || CopierNowMs()-g_srvChangedMs>CP_FEED_STALL_MS)
        {
         if(g_once.ShouldEmit("qstall|"+a.sym))
            g_log.Warn("no quotes for "
                       +(string)((CopierNowMs()-g_srvChangedMs)/1000)+"s -"
                       +" holding EVERY queued action, not just new entries."
                       +" The market is closed or the feed is down, and nothing"
                       +" can be priced from a stale clock. Everything is"
                       +" re-derived from the next snapshot when it returns.");
         RotateQueue();
         skipped++;
         continue;
        }

      //--- THIS SYMBOL'S OWN FEED, on the way out. Same test as in converge
      //--- and for the same reason: on MT5 the clock above keeps advancing
      //--- through the weekly close, so the gate above cannot see a shut
      //--- market. Without this, an action queued before the close is
      //--- re-attempted every time the cooldown expires, for the whole
      //--- weekend. Rotated, not dropped - a held action is a delay.
      if(CopierSymbolFeedStale(a.sym,CP_SYM_STALL_MS))
        {
         if(g_once.ShouldEmit("qsymstall|"+a.sym))
            g_log.Info(a.sym+" has not quoted for "
                       +(string)(CopierSymbolQuoteAgeMs(a.sym)/1000)+"s -"
                       +" holding every queued action on it until it quotes"
                       +" again");
         RotateQueue();
         skipped++;
         continue;
        }

      //--- MARKET CLOSED, per symbol. The broker said so for THIS symbol
      //--- within the last minute (g_mktClosed). Checked on the way OUT too,
      //--- for the same reason as the stale feed: converge skips it, but a
      //--- close queued BEFORE the broker said so still has to be held.
      //---
      //--- This is the case the stale-feed test cannot see: the feed is
      //--- healthy (other symbols are ticking, so the clock advances) but one
      //--- instrument is shut - a holiday, or a symbol with a different
      //--- session. Without this the retry loop returns for that symbol alone.
      if(g_mktClosed.Has(a.sym))
        {
         if(g_once.ShouldEmit("qclosed|"+a.sym))
            g_log.Info("market for "+a.sym+" is closed - holding every queued"
                       +" action on it; they go through when it reopens");
         RotateQueue();
         skipped++;
         continue;
        }

      //--- PAUSED BY HUB COMMAND, on the way OUT. Same reason as every gate
      //--- above: an open queued BEFORE the pause arrived would still fire
      //--- if only converge were gated. Rotated, not dropped - a held open
      //--- is a DELAY; RESUME releases it, and converge re-derives the open
      //--- from the sender's desired set if it is still desired by then.
      //--- Opens only: a pause must never hold the closes that reduce this
      //--- account's exposure.
      if(a.kind==CP_ACT_OPEN && g_cmdPaused)
        {
         if(g_once.ShouldEmit("qcmdpause"))
            g_log.Warn("paused by a hub command - holding queued OPEN"
                       +" actions; they go through on RESUME");
         RotateQueue();
         skipped++;
         continue;
        }

      if(a.kind==CP_ACT_OPEN && !CopierInTradingSession(a.sym))
        {
         RotateQueue();
         skipped++;
         continue;
        }

      //--- RISK RE-CHECK ON THE WAY OUT, for opens only. Converge gates an
      //--- open against the account-wide and per-sender risk switches before
      //--- queueing it - and the queue DRAIN used to send whatever was in
      //--- it, unchanged. So the risk state at QUEUE time was the only state
      //--- ever consulted: entries parked behind a nightly stall (market
      //--- shut, feed down, hub PAUSED) were released the moment the stall
      //--- cleared, against the account as it is NOW - twenty queued opens
      //--- sized against a balance that has since dropped, a daily loss that
      //--- has since tripped, or positions that opened in the meantime. The
      //--- gates were bypassed precisely when they mattered most.
      //---
      //--- Cheaper than the converge-time pair on purpose: the per-sender
      //--- counts here are the queue's own pending opens plus the current
      //--- account totals, which is the same information the gates act on.
      //--- A blocked entry is DROPPED, not rotated: it is not a delay, it is
      //--- a decision - and converge re-derives it from the sender's desired
      //--- set on the very next snapshot, where it is gated again. The seen
      //--- ring is deliberately NOT touched, so a risk state that later frees
      //--- allows the entry through the normal path.
      if(a.kind==CP_ACT_OPEN)
        {
         int    pCount=0;
         double pLots=0.0;
         PendingOpens(pCount,pLots);
         string why="";
         if(!g_risk.AllowOpen(a.lots,g_ourCount,g_ourLots,pCount,pLots,why))
           {
            g_riskBlocked++;
            if(g_once.ShouldEmit("drainrisk|"+a.uid))
               g_log.Warn("queued open "+a.uid+" "+a.sym+" dropped by the"
                          +" account risk gate after its wait: "+why
                          +". It is re-derived from the next snapshot and"
                          +" re-gated, so nothing is lost if the risk state"
                          +" frees (reported at most once per 10 min).");
            ShiftQueue();
            skipped++;
            continue;
           }
         int    sPendCount=0;
         double sPendLots=0.0;
         if(a.senderIdx>=0 && a.senderIdx<g_nSenders)
           {
            PendingOpensForSender(a.senderIdx,sPendCount,sPendLots);
            string sWhy="";
            if(!g_senderRisk[a.senderIdx].AllowOpen(a.lots,g_ourCount,g_ourLots,
                                                    sPendCount,sPendLots,sWhy))
              {
               g_riskBlocked++;
               if(g_once.ShouldEmit("drainsrisk|"+g_sid[a.senderIdx]+"|"+a.uid))
                  g_log.Warn("queued open "+a.uid+" "+a.sym+" dropped by"
                             +" sender "+g_sid[a.senderIdx]+"'s risk gate"
                             +" after its wait: "+sWhy+". Re-derived from the"
                             +" next snapshot and re-gated (reported at most"
                             +" once per 10 min).");
               ShiftQueue();
               skipped++;
               continue;
              }
           }
        }

      if(a.kind==CP_ACT_OPEN)
        {
         CopierSymInfo si;
         if(!CopierGetSymbolInfo(a.sym,si))
           {
            if(g_once.ShouldEmit("unknownsym|"+a.sym))
               g_log.Warn("unknown symbol "+a.sym+", dropping "
                          +a.uid+" (reported at most once per 10 min)");
            g_seen.Add(g_sid[a.senderIdx]+":"+(string)a.kind+":"+a.uid);
            ShiftQueue();
            done++;
            continue;
           }
         int dev = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].deviationPoints:DeviationPoints;
         double emSL = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].emergencySLPips:EmergencySLPips;
         double emTP = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].emergencyTPPips:EmergencyTPPips;

         if(a.ordKind==CP_ORD_PENDING)
           {
            //--- a working order, not a market entry. It keeps the sender's
            //--- trigger price and stops verbatim; see CopierPlacePending.
            CopierPos pp;
            pp.uid     =a.uid;
            pp.sym     =a.sym;
            pp.cmt     ="";
            pp.side    =a.side;
            pp.lots    =a.lots;
            pp.openPx  =a.pprice;
            pp.sl      =a.sl;
            pp.tp      =a.tp;
            pp.ticket  =a.senderTicket;   // the SENDER's ticket, for the comment
            pp.magic   =g_magic[a.senderIdx];
            pp.openTime=0;
            pp.kind    =CP_ORD_PENDING;
            pp.ptype   =a.ptype;
            pp.pprice  =a.pprice;
            pp.pstop   =a.pstop;
            pp.pexpire =a.pexpire;
            pp.used    =true;
            ok=CopierPlacePending(pp,a.sym,g_magic[a.senderIdx],
                                  dev,err);
           }
         else
           {
         double sl=0.0,tp=0.0;
         if(emSL>0.0)
           {
            int e2=0;
            sl=CopierEmergencySl(a.sym,a.side,0.0,emSL,si,e2);
           }
         if(emTP>0.0)
           {
            double px=0.0;
            if(CopierGetPrice(a.sym,a.side,px))
              {
               double pip=PipSize(si);
               tp=(a.side==CP_SIDE_BUY)?(px+emTP*pip):(px-emTP*pip);
               tp=NormalizeDouble(tp,si.digits);
              }
           }
         //--- the comment carries the UID (functional identity) and the
         //--- sender's ticket (so the two orders can be matched by eye)
         ok=CopierOpenMarket(a.sym,a.side,a.lots,sl,tp,
                             CopierCommentForUid(a.uid,a.senderTicket),
                             g_magic[a.senderIdx],dev,err);
           }
        }
      else if(a.kind==CP_ACT_MODIFY)
        {
         //--- NOTE this branch must come before the CLOSE fallback below.
         //--- Without it a MODIFY would fall through to
         //--- CopierClosePosition() and CLOSE the position it was only
         //--- meant to re-stop - the most expensive possible misroute here.
         ok=CopierModifyStops(a.ticket,a.sym,a.sl,a.tp,err);
        }
      else
        {
         int dev = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].deviationPoints:DeviationPoints;
         if(a.kind==CP_ACT_TRIM)
            ok=CopierClosePartial(a.ticket,a.lots,a.sym,a.side,
                                  g_magic[a.senderIdx],
                                  CopierCommentForUid(a.uid,a.senderTicket),
                                  dev,err);
         else
            ok=CopierClosePosition(a.ticket,dev,err);
        }

      if(ok)
        {
         //--- record the SAME key PushAction tested, or the dedup silently
         //--- stops working for TRIMs (whose key carries the target volume)
         //--- ...but NOT for MODIFY, which is idempotent - see
         //--- CopierSeenRingApplies()
         if(CopierSeenRingApplies(a.kind)) g_seen.Add(a.key);

         //--- A mirror now EXISTS on this account, so record it: this is what
         //--- makes a later disappearance a RESTORE rather than a first entry.
         //---
         //--- Recorded HERE, on success, and never at queue time. A queued open
         //--- that the broker refuses - AutoTrading off, symbol unavailable,
         //--- not enough margin - has not put anything on the account, and
         //--- treating it as if it had makes the retry look like a restore and
         //--- abandons the trade permanently.
         //---
         //--- The key matches the one converge tests, WITHOUT the entry-kind
         //--- suffix the action's own key carries.
         if(a.kind==CP_ACT_OPEN)
            g_everOpened.Add(g_sid[a.senderIdx]+":"+(string)CP_ACT_OPEN+":"
                             +a.uid);
         //--- It worked, so the standing condition is gone. Reset the ladder
         //--- rather than leaving a stale count to punish the next, unrelated
         //--- failure with an hours-long park it never earned.
         g_backoff.Clear(a.key);
         //--- the sender ticket is logged too: in a many-to-one setup it
         //--- is how you tell which sender an order came from without
         //--- reading the order comment in the terminal
         string ref=(a.senderTicket!=0)?(" senderTkt="+(string)a.senderTicket):"";
         string verb="exec close ";
         if(a.kind==CP_ACT_OPEN)
            //--- say WHICH it is. A working order and a market entry look
            //--- identical in a log that calls both "open", and telling them
            //--- apart is the first question anyone asks about a pending test.
            verb=(a.ordKind==CP_ORD_PENDING)?"exec place-pending ":"exec open ";
         else if(a.kind==CP_ACT_TRIM)   verb="exec partial-close ";
         else if(a.kind==CP_ACT_DEDUP)  verb="exec remove-duplicate ";
         else if(a.kind==CP_ACT_MODIFY) verb="exec set-stops ";

         //--- a MODIFY carries no volume, so reporting lots=0.00 for it
         //--- would be noise that reads like a bug. Report the stops.
         string detail="lots="+DoubleToString(a.lots,2);
         if(a.kind==CP_ACT_MODIFY)
           {
            CopierSymInfo msi;
            int dg=5;
            if(CopierGetSymbolInfo(a.sym,msi)) dg=msi.digits;
            detail="sl="+((a.sl>0.0)?DoubleToString(a.sl,dg):"none")
                   +" tp="+((a.tp>0.0)?DoubleToString(a.tp,dg):"none");
           }
         else if(a.kind==CP_ACT_OPEN && a.ordKind==CP_ORD_PENDING)
           {
            CopierSymInfo msi;
            int dg=5;
            if(CopierGetSymbolInfo(a.sym,msi)) dg=msi.digits;
            detail="ptype="+(string)a.ptype
                   +" trigger="+DoubleToString(a.pprice,dg)
                   +" lots="+DoubleToString(a.lots,2);
           }
         g_log.Info(verb+g_sid[a.senderIdx]+" "+a.uid+ref+" "+a.sym
                    +" "+detail);
        }
      else
        {
         //--- Park this action briefly. A failed action is shifted off the
         //--- queue and its key is never recorded as done, so converge
         //--- re-derives it on the very next pass - ten times a second,
         //--- forever, for something the broker has already refused. The
         //--- interval is bounded by the snapshot period, which is what
         //--- re-derives the action anyway.
         //--- An order type this platform does not have must not be retried
         //--- every two seconds forever, but it must NOT be dropped either.
         //---
         //--- -4 is "this platform has no such order type": an MT4 receiver
         //--- will never accept a stop-limit. It will, however, eventually
         //--- TRIGGER on the sender, and a filled order is an ordinary market
         //--- position that this platform mirrors perfectly.
         //---
         //--- So the attempt is parked for a few minutes rather than recorded
         //--- as done. An earlier version added it to the seen-ring, which
         //--- silently swallowed the position when the stop-limit filled -
         //--- losing the trade to keep the log quiet, which is the wrong way
         //--- round.
         //---
         //--- The key carries the entry kind, so the market open that follows
         //--- the fill is a different key and is not suppressed at all.
         if(err==-4)
           {
            g_unsupported.Add(a.key);
            if(g_onceFail.ShouldEmit("unsupported|"+g_sid[a.senderIdx]+"|"+a.uid))
               g_log.Warn("cannot place "+a.uid+" "+a.sym+" as a "
                          +((a.ordKind==CP_ORD_PENDING)?"pending":"market")
                          +" order - this platform has no such order type."
                          +" Retrying quietly every "
                          +((string)(CP_UNSUPPORTED_MS/60000))+" min; if it"
                          +" FILLS on the sender it becomes an ordinary"
                          +" position and WILL be mirrored.");
            ShiftQueue();
            done++;
            continue;
           }

         //--- ESCALATE. One refusal may be transient (requote, no quotes,
         //--- market momentarily closed). The same order refused TWICE is a
         //--- standing condition - a broker limit, an unsupported filling
         //--- mode, a symbol it will not trade - and retrying it every two
         //--- seconds turns a refusal into a request flood.
         //---
         //--- The broker's own position/order caps are the canonical case:
         //--- at 200 open positions every further open is refused, and a
         //--- two-second retry loop then sends ~30 refused orders a minute
         //--- per UID, which is how an account gets throttled or blocked.
         //--- ESCALATE, and SHOUT as it climbs. The first refusal is
         //--- usually transient and stays quiet. From the second on, the gap
         //--- doubles away from two seconds - 1m, 5m, 15m, 1h, 6h, 12h, 24h -
         //--- because a broker refusing the same order twice is describing a
         //--- STANDING condition, and retrying fast is what gets an account
         //--- throttled or blocked rather than merely refused.
         //---
         //--- The long end exists to give a HUMAN time to intervene, so the
         //--- alert is not optional: a silent 24-hour backoff is just a
         //--- slower way to lose trades. From one hour up it is logged as an
         //--- error and says so explicitly.
         //--- 4109 is "this terminal will not send" - AutoTrading off, or the
         //--- trade context busy. It is NOT the broker refusing the order:
         //--- nothing reaches the broker at all, so there is no request rate
         //--- to protect, and climbing the ladder would park the mirror for up
         //--- to 24 hours AFTER the operator has switched AutoTrading back on.
         //--- Park it at the base rate and leave the ladder alone.
         int fails;
         if(err==4109)
           {
            fails=1;
            g_backoff.Park(a.key,CP_RETRY_BACKOFF_MS);
           }
         //--- MARKET CLOSED. Not this order's fault and not the broker
         //--- refusing it - there is no market to refuse anything. Arm the
         //--- per-SYMBOL cooldown so the whole instrument stops being
         //--- attempted, and park this action without climbing the ladder:
         //--- the market reopens on a schedule, not after 24 hours.
         //---
         //--- The predicate covers BOTH platforms' codes. Checking only MT4's
         //--- 132 here - while the message text knew MT5's 10018 - meant that
         //--- on MT5 the cooldown never armed at all: every entry was retried
         //--- every two seconds for a whole weekend, with the log saying
         //--- "market closed" the entire time. Recognised in one place, acted
         //--- on in another, and only one of them learned about MT5.
         else if(CopierIsMarketClosed(err))
           {
            fails=1;
            g_mktClosed.Add(a.sym);
            //--- JITTER the cooldown per action. Every entry parked in the
            //--- same instant would otherwise become eligible in the same
            //--- instant, so the retry arrives as a burst of N attempts every
            //--- cooldown instead of a trickle - which is precisely what the
            //--- per-symbol cooldown was meant to stop.
            //---
            //--- Derived from the UID, so it is stable: the same action always
            //--- lands at the same offset rather than drifting each retry.
            long jitter=0;
            for(int ci=0;ci<StringLen(a.uid);ci++)
               jitter+=StringGetCharacter(a.uid,ci);
            jitter=(jitter%30000);              // spread over 30 seconds
            g_backoff.Park(a.key,CP_MKTCLOSED_MS+jitter);
           }
         else
            fails=g_backoff.Note(a.key);
         if(fails>=2 && g_onceFail.ShouldEmit("backoff|"+a.key))
           {
            long ms=CopierBackoffMs(fails);
            string why="refused "+((string)fails)+" time(s) running - "
                       +a.uid+" ("+a.sym+") parked for "
                       +CopierBackoffText(fails)+". A repeat refusal is a"
                       +" standing condition, not a transient one; retrying"
                       +" fast is what gets an account throttled or blocked.";
            if(ms>=60*60*1000)
               g_log.Error("ATTENTION NEEDED - "+why
                           +" It will keep retrying, but slowly: fix the"
                           +" cause by hand, or the mirror stays behind.");
            else
               g_log.Warn(why);
           }

         //--- rate-limited: the first occurrence always prints, a persistent
         //--- one reports at most once a minute. Logging every attempt would
         //--- bury the log exactly when it is needed.
         //--- The negative codes are OURS, not the broker's, and a bare
         //--- "err=-4" tells the reader nothing. The positive ones are the
         //--- broker's, and the two that matter most for the new features get
         //--- spelled out because "10015" does not say what to do about it.
         string e2=(string)err;
         if(err==-1)       e2="-1 (symbol not available at this broker)";
         else if(err==-2)  e2="-2 (no symbol info)";
         else if(err==-3)  e2="-3 (not a pending entry)";
         else if(err==-4)  e2="-4 (this platform has no such order type -"
                              +" MT4 has no stop-limit; the entry is skipped"
                              +" rather than approximated)";
         else if(err==10015) e2="10015 (invalid price - a pending order's"
                              +" trigger is on the wrong side of THIS broker's"
                              +" market. The price is copied verbatim by"
                              +" design, so it is not adjusted; the mirror"
                              +" appears once the sender's order fills)";
         else if(err==10016) e2="10016 (invalid stops - inside this broker's"
                              +" minimum distance)";
         //--- ONE branch for both platforms. They used to be two, and only the
         //--- message half knew about MT5's 10018 - see CopierIsMarketClosed().
         else if(CopierIsMarketClosed(err))
                             e2=(string)err+" (MARKET CLOSED - no market to"
                              +" send to. This SYMBOL is held for "
                              +(string)(CP_MKTCLOSED_MS/1000)+"s so that every"
                              +" entry waiting on it stops being attempted,"
                              +" and it is retried once per cooldown until the"
                              +" market reopens)";
         else if(err==10021) e2="10021 (no quotes for this symbol right now)";
         else if(err==4109)  e2="4109 (TRADE DISABLED at this terminal -"
                              +" AutoTrading is off, or the trade context is"
                              +" busy. Nothing is reaching the broker, so the"
                              +" order is retried at the base rate and the"
                              +" backoff ladder is deliberately NOT climbed:"
                              +" switch AutoTrading on and the mirror opens"
                              +" within a couple of seconds)";
         if(g_onceFail.ShouldEmit("fail|"+g_sid[a.senderIdx]+"|"
                                  +(string)a.kind+"|"+a.uid+"|"+(string)err))
            g_log.Warn("trade failed sender="+g_sid[a.senderIdx]+" uid="+a.uid
                       +" sym="+a.sym+" kind="+(string)a.kind
                       +" err="+e2
                       +" (retrying in "+(string)(CP_RETRY_BACKOFF_MS/1000)
                       +"s; further identical failures reported at most"
                       +" once a minute)");
        }
      ShiftQueue();
      done++;
     }
  }

//=====================================================================
// Partial-close propagation.
//
// A position that exists on both sides but is SMALLER on the sender means
// the sender took a partial profit. Rounding rules, deliberately
// conservative - over-trimming would make the receiver smaller than the
// sender, which is a worse divergence than being too big:
//
//   * act only when the difference is at least one whole lot step
//   * always round the amount to trim DOWN, so we can never overshoot
//   * if what would be left is below the broker's minimum lot, close the
//     whole position instead - a dust remainder cannot be managed, and
//     leaving it would strand a position forever
//
// Growing a position is NOT supported: on MT4 an add is a new order with a
// new ticket (hence a new UID, handled as a fresh open), and on MT5 it
// would need a second position under the same UID, which breaks the
// one-UID-one-position mapping the whole design rests on.
//=====================================================================
void QueueTrimIfNeeded(const int si,const CopierPos &desired,const CopierPos &local)
  {
   double diff=local.lots-desired.lots;
   if(diff<=0.0) return;                       // sender is not smaller

   CopierSymInfo si2;
   if(!CopierGetSymbolInfo(local.sym,si2)) return;

   double step=si2.lotStep;
   if(step<=0.0) return;
   if(diff<step*0.999999) return;              // sub-step noise

   int digits=CopierLotDigits(step);
   double trim=NormalizeDouble(MathFloor(diff/step+0.0000001)*step,digits);
   if(trim<=0.0) return;

   double remaining=NormalizeDouble(local.lots-trim,digits);
   if(remaining<si2.minLot-0.0000001)
     {
      PushAction(si,CP_ACT_CLOSE,desired.uid,local.sym,local.side,
                 local.lots,local.ticket);
      return;
     }

   //--- The comment on the CLOSING deal is what MT5 writes back onto the
   //--- position, so it has to carry the FULL identity. Passing 0 here
   //--- silently downgraded the comment from "tc|<uid>|<ticket>" to
   //--- "tc|<uid>" on every partial close - the ticket was lost for good,
   //--- because nothing else rewrites the comment afterwards.
   //---
   //--- desired.ticket is the sender's CURRENT ticket (it changes when an
   //--- MT4 sender partially closes, since the broker re-tickets the
   //--- remainder). If the sender did not supply one, keep whatever the
   //--- local order already advertises rather than dropping the field.
   long stk=desired.ticket;
   if(stk==0) stk=CopierSenderTicketFromComment(local.cmt);

   //--- the target volume is part of the dedup key: a SECOND partial close
   //--- on the same UID is a different action, not a duplicate
   PushAction(si,CP_ACT_TRIM,desired.uid,local.sym,local.side,trim,local.ticket,
              stk,":"+CopierFmtDouble(desired.lots,CP_DIGITS_LOTS));
  }

//=====================================================================
// Is a stop actually different, or just a rounding artefact?
//
// Prices reach this comparison through two different paths - the broker's
// own report and the wire - so an exact compare would queue a modify on
// every tick, forever, for a stop that is already right. Half a point is
// the tolerance: below the smallest increment either platform can express.
//
// "Absent" and "present" always count as different, in both directions.
// That is what makes removal propagate: a sender that clears its stop
// clears the mirror's too.
//=====================================================================
bool StopsDiffer(const double have,const double want,const CopierSymInfo &si)
  {
   if((have<=0.0)!=(want<=0.0)) return true;
   if(have<=0.0 && want<=0.0)   return false;
   double tol=si.point*0.5;
   if(tol<=0.0) tol=0.00000001;
   return (MathAbs(have-want)>tol);
  }

//=====================================================================
// Stop-loss / take-profit propagation.
//
// The sender's stops are copied as a DISTANCE from its entry, not as a
// price - see CopierMirrorStop() for why - re-anchored on the receiver's
// own entry price. So the mirror ends up with the same risk distance
// rather than the same absolute level, which is the only thing that means
// anything when the two sides filled at different prices.
//
// Precedence with EmergencySLPips: the SENDER's stop wins whenever it has
// one. The emergency stop is the backstop for the case that setting exists
// for - a sender that leaves positions unprotected - so it applies only
// when the sender has no stop of its own. Letting it override would
// silently discard the sender's risk management, which is not what a
// copier is for.
//
// Everything is decided here and the trade call is QUEUED, like every
// other operation: converge must never trade inline.
//=====================================================================
void QueueModifyIfNeeded(const int si,const CopierPos &desired,
                         const CopierPos &local)
  {
   if(!g_senderCfg[si].mirrorstops) return;

   CopierSymInfo si2;
   if(!CopierGetSymbolInfo(local.sym,si2)) return;

   //--- WHICH STOPS ARE CURRENT: the snapshot's, or a newer MODIFY event's.
   //---
   //--- A MODIFY says what the sender's stops are right now, and may be newer
   //--- than the snapshot this pass is working from. It is taken as an
   //--- override until the snapshot agrees with it, at which point the two
   //--- sources are the same thing and the override is dropped.
   //---
   //--- Without this the two paths would fight: convergence re-derives the
   //--- target from the snapshot on every pass, so an event applied directly
   //--- would be reverted on the very next one, and the mirror would oscillate
   //--- between the new stop and the old until SnapshotSeconds elapsed.
   double dSl=desired.sl,dTp=desired.tp,dOpn=desired.openPx;
   int oi=StopsOvIndex(desired.uid,false);
   if(oi>=0 && g_stHasOv[oi])
     {
      if(MathAbs(desired.sl-g_stOvSl[oi])<0.0000001
         && MathAbs(desired.tp-g_stOvTp[oi])<0.0000001)
         g_stHasOv[oi]=false;               // the snapshot caught up
      else
        {
         dSl=g_stOvSl[oi];
         dTp=g_stOvTp[oi];
         dOpn=g_stOvOpn[oi];
        }
     }

   //--- The sender's stops, as a distance, re-anchored on our own entry.
   double feedSl,feedTp;
   CopierMapInvertedStops(g_senderCfg[si].inverttrades,dSl,dTp,feedSl,feedTp);

   double wantSl,wantTp;
   if(g_senderCfg[si].inverttrades)
     {
      wantSl=CopierMirrorStopInverted(feedSl,dOpn,
                                      local.openPx,local.side,true);
      wantTp=CopierMirrorStopInverted(feedTp,dOpn,
                                      local.openPx,local.side,false);
     }
   else
     {
      wantSl=CopierMirrorStop(feedSl,dOpn,
                              local.openPx,local.side,true);
      wantTp=CopierMirrorStop(feedTp,dOpn,
                              local.openPx,local.side,false);
     }

   //--- the sender has no stop of its own, so the local backstop applies
   if(wantSl<=0.0 && g_senderCfg[si].emergencySLPips>0.0)
     {
      int e=0;
      wantSl=CopierEmergencySl(local.sym,local.side,local.openPx,
                               g_senderCfg[si].emergencySLPips,si2,e);
     }

   //--- clear the broker's minimum distance BEFORE comparing, or a stop
   //--- that can only ever be clamped would look like a difference on
   //--- every single tick and queue a modify forever
   bool clamped=false;
   wantSl=CopierFitStop(wantSl,local.sym,local.side,true,si2,clamped);
   if(clamped && g_once.ShouldEmit("slclamp|"+local.uid))
      g_log.Warn("stop for "+local.uid+" "+local.sym+" was inside this"
                 +" broker's minimum distance and has been widened; the"
                 +" mirror is now WIDER than the sender's stop");
   wantTp=CopierFitStop(wantTp,local.sym,local.side,false,si2,clamped);

   if(!StopsDiffer(local.sl,wantSl,si2) && !StopsDiffer(local.tp,wantTp,si2))
      return;

   //--- Say what was computed, once per UID.
   if(g_once.ShouldEmit("stopcalc|"+local.uid))
     {
      CopierSymInfo ci;
      int cg=CopierGetSymbolInfo(local.sym,ci)?ci.digits:5;
      g_log.Info("stops for "+local.uid+" "+local.sym
                 +(g_senderCfg[si].inverttrades?" (INVERTED, roles swapped)":"")
                 +": sender sl="+((dSl>0.0)?DoubleToString(dSl,cg):"none")
                 +" tp="+((dTp>0.0)?DoubleToString(dTp,cg):"none")
                 +" from its entry "+DoubleToString(dOpn,cg)
                 +"; ours is "+((local.side==CP_SIDE_BUY)?"BUY":"SELL")
                 +" at "+DoubleToString(local.openPx,cg)
                 +" -> our stop from "+DoubleToString(feedSl,cg)
                 +", our target from "+DoubleToString(feedTp,cg)
                 +" => setting sl="+((wantSl>0.0)?DoubleToString(wantSl,cg):"none")
                 +" tp="+((wantTp>0.0)?DoubleToString(wantTp,cg):"none"));
     }

   long nowMs=CopierNowMs();
   if(oi<0) oi=StopsOvIndex(desired.uid,true);
   if(g_senderCfg[si].stopsThrottleSeconds>0 && g_stLastMs[oi]>=0
      && nowMs-g_stLastMs[oi]<(long)g_senderCfg[si].stopsThrottleSeconds*1000)
      return;
   g_stLastMs[oi]=nowMs;

   //--- the target stops are part of the dedup key: a SECOND change to a
   //--- different level is a different action, not a duplicate. Without
   //--- this the seen-ring would suppress it for its whole TTL and the
   //--- mirror would keep the first stop it ever saw.
   PushAction(si,CP_ACT_MODIFY,desired.uid,local.sym,local.side,
              0.0,local.ticket,0,
              ":"+CopierFmtDouble(wantSl,CP_DIGITS_PX)
              +":"+CopierFmtDouble(wantTp,CP_DIGITS_PX),
              wantSl,wantTp);
  }

//=====================================================================
// Duplicate resolution: one UID must map to exactly ONE position.
//
// That invariant is what LocalFindUid, the seen-ring and the state file all
// assume. When it breaks, the extra position is invisible to every other
// loop - LocalFindUid returns the FIRST match - so the duplicate is never
// closed, never trimmed and never reported. It just sits there doubling the
// exposure. That is exactly what the pilot produced: a partial close wiped
// a comment, the mirror became unrecognisable, converge opened a second one
// and then could not see it.
//
// The survivor-selection rule itself lives in CopierDefs.mqh as
// CopierPreferSurvivor(), so the self-test can reach it - see the comment
// there for why the ordering is the safety argument.
//
// Positions listed in IgnoreUids are skipped entirely: the copier does
// not act on them, and that has to include not cleaning them up.
//=====================================================================

//--- Collapses `loc` in place so it holds one entry per UID, queueing a
//--- close for every position that loses. Returns the new count. The
//--- compaction matters as much as the queueing: it is what stops the loops
//--- below from trimming or closing a position already on its way out, and
//--- from picking the doomed copy as "the" local position.
int DedupLocal(const int si,const int base,CopierPos &loc[],const int ln)
  {
   if(ln<2) return ln;

   int drop[];
   ArrayResize(drop,ln);
   for(int i=0;i<ln;i++) drop[i]=0;

   int removed=0;
   for(int i=0;i<ln;i++)
     {
      if(drop[i]!=0) continue;
      if(g_ignore.Has(loc[i].uid)) continue;

      int groupN=0;
      for(int k=i;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         if(loc[k].uid==loc[i].uid) groupN++;
        }
      if(groupN<2) continue;

      if(!g_senderCfg[si].dedupduplicates)
        {
         //--- stays true on every tick until a human acts, so it must be
         //--- rate-limited or it drowns the log at ~10 Hz
         if(g_once.ShouldEmit("dup|"+g_sid[si]+"|"+loc[i].uid))
            g_log.Warn("duplicate position for "+loc[i].uid+" "+loc[i].sym
                       +": "+(string)groupN+" positions share one UID, and"
                       +" DedupDuplicates=false so they are left alone");
         continue;
        }

      //--- what the sender says this UID should be right now
      double want=-1.0;
      for(int d=0;d<g_desiredCount[si];d++)
        {
         if(g_desired[base+d].uid==loc[i].uid) { want=g_desired[base+d].lots; break; }
        }

      int keep=i;
      for(int k=i+1;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         if(loc[k].uid!=loc[i].uid) continue;
         if(CopierPreferSurvivor(loc[k],loc[keep],want)) keep=k;
        }

      for(int k=i;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         if(loc[k].uid!=loc[i].uid) continue;
         if(k==keep) continue;

         drop[k]=1;
         removed++;
         g_log.Warn("duplicate position for "+loc[k].uid+" "+loc[k].sym
                    +" lots="+DoubleToString(loc[k].lots,2)
                    +" ticket="+(string)loc[k].ticket
                    +" - keeping ticket "+(string)loc[keep].ticket
                    +" lots="+DoubleToString(loc[keep].lots,2)
                    +"; one UID must map to one position");
         PushAction(si,CP_ACT_DEDUP,loc[k].uid,loc[k].sym,loc[k].side,
                    loc[k].lots,loc[k].ticket,0,":"+(string)loc[k].ticket);
        }
     }

   if(removed==0) return ln;

   int w=0;
   for(int i=0;i<ln;i++)
     {
      if(drop[i]!=0) continue;
      if(w!=i) loc[w]=loc[i];
      w++;
     }
   return w;
  }

//=====================================================================
// Refresh the account-level risk view, once per tick.
//
// Two jobs:
//   1. count and total OUR positions, so every sender's converge pass gates
//      against the SAME numbers - computed per sender, two senders would
//      each see room that only exists once
//   2. feed the equity curve to the percentage switches
//
// CopierRealizedToday() walks the account's history, so the day baseline is
// only rebuilt once a minute - and it cannot drift in between, because
// balance-minus-realised stays constant as losses accumulate. It IS rebuilt
// immediately on a server-day change, where the cached value would be
// yesterday's and would mis-trip the daily switch for up to a minute.
//=====================================================================
CopierPos g_acctAllPos[];
int       g_acctAllPosCount=0;

string EncodeReceiverPositions()
  {
   if(g_acctAllPosCount<=0) return "";
   string out="";
   int count=0;
   for(int i=0;i<g_acctAllPosCount;i++)
     {
      bool ours=false;
      for(int k=0;k<g_nSenders;k++)
        {
         if(g_acctAllPos[i].magic==g_magic[k]) { ours=true; break; }
        }
      int isManaged=ours?1:0;
      if(count>0) out+=CP_SEP_REC;
      out+=(string)g_acctAllPos[i].ticket+CP_SEP_ITEM
          +g_acctAllPos[i].sym+CP_SEP_ITEM
          +(string)g_acctAllPos[i].side+CP_SEP_ITEM
          +CopierFmtDouble(g_acctAllPos[i].lots,2)+CP_SEP_ITEM
          +CopierFmtDouble(g_acctAllPos[i].openPx,5)+CP_SEP_ITEM
          +CopierFmtDouble(g_acctAllPos[i].sl,5)+CP_SEP_ITEM
          +CopierFmtDouble(g_acctAllPos[i].tp,5)+CP_SEP_ITEM
          +(string)g_acctAllPos[i].magic+CP_SEP_ITEM
          +(string)isManaged+CP_SEP_ITEM
          +CopierSanitizeComment(g_acctAllPos[i].cmt);
      count++;
      if(count>=128) break;
     }
   return CopierCompressField(out);
  }

string EncodeReceiverWaitList()
  {
   string out="";
   int count=0;
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[i].kind!=CP_ACT_OPEN) continue;
      if(count>0) out+=CP_SEP_REC;
      out+=g_q[i].uid+CP_SEP_ITEM
          +g_q[i].sym+CP_SEP_ITEM
          +(string)g_q[i].side+CP_SEP_ITEM
          +CopierFmtDouble(g_q[i].lots,2)+CP_SEP_ITEM
          +CopierFmtDouble(g_q[i].pprice>0.0?g_q[i].pprice:0.0,5)+CP_SEP_ITEM
          +"queued"+CP_SEP_ITEM
          +"Queued in broker dispatch";
      count++;
      if(count>=128) break;
     }
   for(int i=0;i<g_waitItemsCount;i++)
     {
      if(count>=128) break;
      if(count>0) out+=CP_SEP_REC;
      out+=g_waitItems[i].uid+CP_SEP_ITEM
          +g_waitItems[i].sym+CP_SEP_ITEM
          +(string)g_waitItems[i].side+CP_SEP_ITEM
          +CopierFmtDouble(g_waitItems[i].lots,2)+CP_SEP_ITEM
          +CopierFmtDouble(g_waitItems[i].openPx,5)+CP_SEP_ITEM
          +g_waitItems[i].stage+CP_SEP_ITEM
          +CopierSanitize(g_waitItems[i].reason,48);
      count++;
     }
   return CopierCompressField(out);
  }

void RefreshRisk()
  {
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   g_acctAllPosCount=an;
   ArrayResize(g_acctAllPos,an,64);
   for(int i=0;i<an;i++) g_acctAllPos[i]=all[i];
   int cnt=0;
   int orphan=0;
   double lots=0.0;
   int nPos=0,nOrd=0;
   for(int i=0;i<an;i++)
     {
      //--- counted for EVERYTHING on the account, not just ours: a broker's
      //--- position cap does not care who opened the position
      if(all[i].kind==CP_ORD_PENDING) nOrd++; else nPos++;
      bool ours=false;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { ours=true; break; }
        }
      if(!ours)
        {
         //--- Match the dashboard panel's orphan definition: only positions
         //--- carrying our copier UID comment count, never another EA's trades.
         if(StringLen(CopierUidFromComment(all[i].cmt))>0) orphan++;
         continue;
        }
      cnt++;
      lots+=all[i].lots;
     }
   g_acctPositions=nPos;
   g_acctOrders=nOrd;
   g_ourCount=cnt;
   g_ourLots=lots;
   g_orphanCount=orphan;

   long now=CopierNowMs();
   long dayStart=CopierServerDayStart();
   if(dayStart!=g_riskDay || now-g_lastRealizedMs>60000)
     {
      g_riskDay=dayStart;
      g_lastRealizedMs=now;
      g_riskDayStartEquity=CopierAccountBalance()-CopierRealizedToday(dayStart);
     }
   g_risk.ObserveAt(CopierAccountEquity(),dayStart/86400,g_riskDayStartEquity);
   //--- Persist the peak so a terminal restart cannot re-base the drawdown
   //--- switch. Internally throttled to once a minute; a rising peak that is
   //--- lost to a crash understates the baseline by that minute's gain, which
   //--- is the safe direction (it can never falsely block trading).
   if(g_risk.PeakEquity()>0.0) RiskPeakSave(false);
  }

//=====================================================================
// Opens sitting in the action queue, i.e. decided but not yet filled.
//
// The risk gate CANNOT use g_ourCount / g_ourLots on their own. Those count
// the positions that EXIST, and converge queues several opens in a SINGLE
// pass - so every one of them would be checked against the same pre-open
// numbers and every one of them would pass. Measured on a live test:
// MaxOpenPositions=3, four desired positions, four opened.
//
// Reading the live queue also covers opens queued earlier in the same tick
// by a DIFFERENT sender, which a per-sender counter would miss entirely.
//
// Only OPEN counts. CLOSE and TRIM would reduce the projection, but
// crediting them would let the gate spend room that does not exist yet. The
// safe direction is held-plus-adding, and let freed room be picked up on
// the next tick.
//=====================================================================
void PendingOpens(int &count,double &lots)
  {
   count=0;
   lots=0.0;
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[i].kind!=CP_ACT_OPEN) continue;
      count++;
      lots+=g_q[i].lots;
     }
  }

//=====================================================================
// Queue a close for everything we hold.
//
// Only reached when RiskCloseAllOnTrip is on and a percentage switch has
// just tripped. Queued rather than done inline, like every other trade
// operation, so MaxActionsPerTick still paces it.
//=====================================================================
//--- Enumerate every position that is OURS (magic matches a configured
//--- sender), skip the ones handed over to the operator, and queue a close
//--- for the rest through the SAME path converge uses - so throttling, the
//--- seen-ring, backoff and failure parking all apply unchanged.
//--- Returns how many closes were queued. Shared by the risk switch and by
//--- the hub's closeall command (M5b); the reason string is only for the log.
int CloseAllOurs(const string reason)
  {
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   int queued=0;
   for(int i=0;i<an;i++)
     {
      int si=-1;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { si=k; break; }
        }
      if(si<0) continue;                      // not ours
      string uid=ResolveUid(all[i]);
      if(StringLen(uid)==0) continue;         // unmanageable; reported elsewhere
      if(g_ignore.Has(uid)) continue;         // handed over to the operator
      PushAction(si,CP_ACT_CLOSE,uid,all[i].sym,all[i].side,all[i].lots,
                 all[i].ticket);
      queued++;
     }
   if(StringLen(reason)>0)
      g_log.Error(reason+" - queueing closes for "+(string)queued
                 +" of our position(s)");
   return queued;
  }

void RiskCloseEverything()
  {
   CloseAllOurs("RiskCloseAllOnTrip is on");
  }

//--- Convert a timestamp the SENDER reported into our own timebase.
//--- Returns 0 when the offset is not known yet, which callers treat as
//--- "cannot measure" rather than "long ago".
long SenderTimeToOurs(const int si,const long senderTime)
  {
   if(!g_senderClockKnown[si]) return 0;
   //--- Refuse to convert while OUR OWN clock is not advancing.
   //---
   //--- The offset is derived as (ourServerTime - theirTimestamp). If ours is
   //--- frozen and theirs is not, that difference grows without bound - the
   //--- log showed "sender 5565 server clock is 18119s ahead of ours" and
   //--- climbing. Converting an open time with that offset puts it hours in
   //--- the past, so the fill timeout would see an ancient position and
   //--- ABANDON it permanently, and the wait gates would all pass instantly.
   //---
   //--- 0 means "cannot measure", which every age-based gate already treats as
   //--- "do not act" - the right answer when the clock is unusable.
   if(!g_srvEverMoved) return 0;
   return senderTime+g_senderClockOffset[si];
  }

//--- How much exposure already exists on this ACCOUNT for this symbol?
//---
//--- Account-wide, not per sender. The goal is that the account never holds
//--- two of the same thing, because that is what actually caps the risk - a
//--- second copy adds no diversification, only size. So this deliberately
//--- counts exposure the copier did not open too: a manual trade or another
//--- EA's position is just as much exposure.
//---
//--- A consequence worth stating: with two senders this now lets the FIRST
//--- one hold a symbol and refuses the second. That is the intent here, and
//--- it is the opposite of the per-sender scoping the N:M notes describe.
//---
//--- Counts POSITIONS AND PENDING ORDERS - a working order is still exposure
//--- and lives in a different pool - plus opens already queued this pass.
//--- Without the queued half, a burst of ten opens on one symbol all pass
//--- (none is local yet) and all get queued, which is the stacking this
//--- exists to prevent.
int AccountExposure(const CopierPos &all[],const int an,
                    const string sym,const int side,const bool sameDirOnly)
  {
   int n=0;
   for(int i=0;i<an;i++)
     {
      if(all[i].sym!=sym) continue;
      if(sameDirOnly && all[i].side!=side) continue;
      n++;
     }
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[i].kind!=CP_ACT_OPEN) continue;      // a close is not exposure
      if(g_q[i].sym!=sym) continue;
      if(sameDirOnly && g_q[i].side!=side) continue;
      n++;
     }
   return n;
  }

//=====================================================================
// Convergence for one sender: diff the desired set against local
// reality. This one function is what makes the system self-healing.
//=====================================================================
void ConvergeSender(const int si)
  {
   if(!g_ready[si]) return;    // no snapshot yet -> do nothing at all

   //--- A stale sender (no SNAPSHOT within StaleSeconds) stops NEW entries,
   //--- and NOTHING ELSE. The gate used to return here, which also skipped
   //--- the close half: the mirror then held the sender's old positions for
   //--- as long as the sender was silent, with margin, swap and risk budget
   //--- locked in the whole time - a sender that goes quiet while holding a
   //--- large position froze the receiver's account indefinitely. Closing
   //--- on stale data only releases OUR capital; it cannot invent an entry.
   //--- Managing existing mirrors (re-stops, dedup) also continues: those
   //--- act on positions this account already holds.
   bool mayOpen=!g_stale[si];

   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   CopierPos loc[];
   int ln=LocalForSender(si,all,an,loc);
   int base=si*CP_MAX_POSITIONS;

   double sLots=0.0;
   for(int k=0;k<ln;k++) sLots+=loc[k].lots;

   //--- one UID, one position. Has to run BEFORE the diff below:
   //--- LocalFindUid returns the first match, so a duplicate left in place
   //--- could be the copy chosen for a trim while the real mirror is ignored.
   ln=DedupLocal(si,base,loc,ln);

   //--- desired but not mirrored -> open
   for(int i=0;i<g_desiredCount[si];i++)
     {
      CopierPos d=g_desired[base+i];

      //--- the operator asked us to leave this one alone (IgnoreUids)
      if(g_ignore.Has(d.uid) || g_senderIgnore[si].Has(d.uid)) continue;

      int li=LocalFindUid(loc,ln,d.uid);
      if(li>=0)
        {
         g_seen.ForgetPrefix(g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid);
         g_seen.ForgetPrefix(g_sid[si]+":"+(string)CP_ACT_CLOSE+":"+d.uid);
         g_seen.ForgetPrefix(g_sid[si]+":"+(string)CP_ACT_TRIM+":"+d.uid);

         g_everOpened.Add(g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid);

         if(loc[li].kind!=d.kind)
           {
            g_log.Info("uid "+d.uid+" changed kind on the sender ("
                       +(string)loc[li].kind+" -> "+(string)d.kind
                       +"); cancelling the mirror and re-opening it");
            g_reopenExpected.Add(g_sid[si]+":"+d.uid);
            PushAction(si,CP_ACT_CLOSE,d.uid,loc[li].sym,loc[li].side,
                       loc[li].lots,loc[li].ticket);
            continue;
           }

         QueueModifyIfNeeded(si,d,loc[li]);
         QueueTrimIfNeeded(si,d,loc[li]);
         continue;
        }

      //--- Desired but not mirrored = an OPEN. This is the one half the
      //--- stale gate holds back: with the sender silent there is no fresh
      //--- reason to take new risk in its name. Rate-limited log, because a
      //--- long silence would otherwise print once per position per tick.
      if(!mayOpen)
        {
         if(g_once.ShouldEmit("stalegate|"+g_sid[si]))
            g_log.Warn("sender "+g_sid[si]+" has been silent past its"
                       +" StaleSeconds - no new mirrors are opened for it,"
                       +" and existing ones keep converging (closes and"
                       +" stops still apply). The next snapshot clears this.");
         continue;
        }

      string rsym=MapSymbol(si,d.sym,g_suffix[si]);
      if(!CopierSymbolExists(rsym))
        {
         if(g_once.ShouldEmit(g_sid[si]+"|nosym|"+d.sym))
            g_log.Warn("sender "+g_sid[si]+" symbol "+d.sym+" -> "+rsym
                       +" is not available on this account. The copier HAS"
                       +" already tried adding it to Market Watch, so this is"
                       +" the broker genuinely not offering it - add the"
                       +" symbol by hand, or map it with SenderSymbolMap if"
                       +" your broker calls it something else. Skipped until"
                       +" this changes (reported at most once per 10 min).");
         continue;
        }
      CopierSymInfo si2;
      if(!CopierGetSymbolInfo(rsym,si2)) continue;

      bool rejected=false;
      double lots=CopierComputeLots(d.lots,g_lotMode[si],g_lotParam[si],1.0,si2,
                                    0.0,0.0,rejected);
      if(rejected || lots<=0.0)
        {
         g_log.Warn("lot sizing rejected "+d.uid+" "+rsym
                    +" senderLots="+DoubleToString(d.lots,2));
         continue;
        }

      //--- Account-wide risk gate
      int    pendCount=0;
      double pendLots=0.0;
      PendingOpens(pendCount,pendLots);
      string riskWhy="";
      if(!g_risk.AllowOpen(lots,g_ourCount,g_ourLots,pendCount,pendLots,riskWhy))
        {
         string blockKey=g_risk.BlockKey();
         if(StringLen(blockKey)==0) blockKey=riskWhy;
         g_riskBlocked++;
         if(g_once.ShouldEmit("risk|"+blockKey))
            g_log.Warn("risk switch blocked a new entry - "+riskWhy);
         continue;
        }

      //--- Per-sender specific risk gate
      int    sPendCount=0;
      double sPendLots=0.0;
      PendingOpensForSender(si,sPendCount,sPendLots);
      string sRiskWhy="";
      if(!g_senderRisk[si].AllowOpen(lots,ln,sLots,sPendCount,sPendLots,sRiskWhy))
        {
         string sBlockKey=g_senderRisk[si].BlockKey();
         if(StringLen(sBlockKey)==0) sBlockKey=sRiskWhy;
         g_riskBlocked++;
         if(g_once.ShouldEmit("senderrisk|"+g_sid[si]+"|"+sBlockKey))
            g_log.Warn("sender "+g_sid[si]+" risk switch blocked a new entry - "+sRiskWhy);
         continue;
        }

      double osl=(d.kind==CP_ORD_PENDING)?d.sl:0.0;
      double otp=(d.kind==CP_ORD_PENDING)?d.tp:0.0;

      if(g_senderCfg[si].inverttrades)
        {
         if(d.kind==CP_ORD_PENDING)
           {
            if(g_once.ShouldEmit("invpend|"+d.uid))
               g_log.Warn("InvertTrades is on and "+d.uid+" "+d.sym+" is a"
                          +" PENDING order. Inverting a working order is not"
                          +" supported - it is skipped, not guessed. Turn"
                          +" InvertTrades off, or cancel it on the sender.");
            continue;
           }
         d.side=(d.side==CP_SIDE_BUY)?CP_SIDE_SELL:CP_SIDE_BUY;
        }

      if(g_senderCfg[si].ignorenewentrysignals)
        {
         if(g_once.ShouldEmit("gatenew|"+g_sid[si]))
            g_log.Info("sender "+g_sid[si]+" IgnoreNewEntrySignals is on - no new mirrors are"
                       +" opened. Existing ones are still managed normally.");
         continue;
        }
      if(g_cmdPaused)
        {
         if(g_once.ShouldEmit("cmdpause"))
            g_log.Warn("paused by a hub command - no new mirrors are opened."
                       +" Existing ones are still managed normally. RESUME"
                       +" clears this.");
         continue;
        }
      if(g_senderCfg[si].nobuy && d.side==CP_SIDE_BUY)   continue;
      if(g_senderCfg[si].nosell && d.side==CP_SIDE_SELL) continue;

      if(!g_senderPermitted[si].Allows(rsym))
        {
         if(g_once.ShouldEmit("gatesym|"+g_sid[si]+"|"+rsym))
            g_log.Info("sender "+g_sid[si]+" symbol "+rsym+" is not in PermittedSymbols - its"
                       +" entries are skipped");
         continue;
        }

      if(!g_senderPermittedMagic[si].Allows((string)d.magic))
        {
         if(g_once.ShouldEmit("gatemagic|"+g_sid[si]+"|"+(string)d.magic))
            g_log.Info("sender "+g_sid[si]+" reports magic "+(string)d.magic
                       +" on "+d.sym+", which is not in PermittedMagic - its"
                       +" entries are skipped");
         continue;
        }

      if(g_senderCfg[si].minsenderlotsize>0.0 && d.lots<g_senderCfg[si].minsenderlotsize) continue;
      if(g_senderCfg[si].maxsenderlotsize>0.0 && d.lots>g_senderCfg[si].maxsenderlotsize) continue;

      if(!g_srvEverMoved
         || CopierNowMs()-g_srvChangedMs>CP_FEED_STALL_MS)
        {
         if(g_once.ShouldEmit("stall|"+g_sid[si]))
            g_log.Warn("no quotes for "
                       +(string)((CopierNowMs()-g_srvChangedMs)/1000)+"s - the server"
                       +" clock is not advancing, so the market is closed or"
                       +" the feed is down. Holding new entries; nothing can"
                       +" be priced from a stale clock.");
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Server clock halted / feed stall");
         continue;
        }

      if(CopierSymbolFeedStale(rsym,CP_SYM_STALL_MS))
        {
         if(g_once.ShouldEmit("symstall|"+rsym))
            g_log.Info(rsym+" has not quoted for "
                       +(string)(CopierSymbolQuoteAgeMs(rsym)/1000)+"s -"
                       +" its market is shut or its feed has stopped. Holding"
                       +" new entries for it; they go through as soon as it"
                       +" quotes again.");
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Symbol feed stale");
         continue;
        }

      if(!CopierInTradingSession(rsym))
        {
         if(g_once.ShouldEmit("sess|"+rsym))
            g_log.Info(rsym+" is outside its trading hours - holding new"
                       +" entries for it until the session opens");
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Outside trading hours");
         continue;
        }

      if(g_mktClosed.Has(rsym))
        {
         if(g_once.ShouldEmit("mktclosed|"+rsym))
            g_log.Info("market for "+rsym+" is closed - holding new entries"
                       +" for it; they will go through when it reopens");
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Market closed");
         continue;
        }

      if(g_senderHours[si].Active() && !g_senderHours[si].Allows(CopierServerTime()))
        {
         if(g_once.ShouldEmit("gatehours|"+g_sid[si]))
            g_log.Info("sender "+g_sid[si]+" outside configured trading window (server time "
                       +TimeToString(CopierServerTime(),TIME_MINUTES)
                       +") - new entries are held back. Existing mirrors are"
                       +" still managed and still close when the sender"
                       +" closes them.");
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Outside sender trading window");
         continue;
        }

      if(g_senderCfg[si].checkforexistingposition!=EXIST_OFF)
        {
         bool sameDirOnly=(g_senderCfg[si].checkforexistingposition==EXIST_SAME_DIR);
         if(AccountExposure(all,an,rsym,d.side,sameDirOnly)>0)
           {
            if(g_once.ShouldEmit("gateexist|"+g_sid[si]+"|"+rsym))
               g_log.Info("sender "+g_sid[si]+" CheckForExistingPosition: account already holds"
                          +" "+rsym+(sameDirOnly?" in this direction":"")
                          +" - skipping further entries for it.");
            continue;
           }
        }

      long openedOurs=0;
      if(d.openTime>0) openedOurs=SenderTimeToOurs(si,d.openTime);
      long ageSec=0;
      if(openedOurs>0)
        {
         ageSec=(long)CopierServerTime()-openedOurs;
         if(ageSec<0) ageSec=0;
        }
      else
        {
         if((g_senderCfg[si].waitforhours>0 || g_senderCfg[si].waitforminutes>0 || g_senderCfg[si].waitforseconds>0
             || g_senderCfg[si].requirepositionfillwithinhours>0
             || g_senderCfg[si].requirepositionfillwithinminutes>0
             || g_senderCfg[si].requirepositionfillwithinseconds>0)
            && g_once.ShouldEmit("noclocks|"+d.uid))
            g_log.Warn("cannot measure how old "+d.uid+" "+rsym+" is, so the"
                       +" configured wait / fill timeout CANNOT be applied and"
                       +" it enters immediately. sender openTime="
                       +(string)d.openTime+", sender clock known="
                       +(g_senderClockKnown[si]?"yes":"no")+", offset="
                       +(string)g_senderClockOffset[si]+"s");
        }

      {
       long waitSec=(long)g_senderCfg[si].waitforhours*3600+(long)g_senderCfg[si].waitforminutes*60
                   +(long)g_senderCfg[si].waitforseconds;
       if(waitSec>0 && openedOurs>0 && ageSec<waitSec)
         {
          if(g_once.ShouldEmit("wait|"+g_sid[si]+"|"+rsym))
             g_log.Info("holding "+rsym+" - the sender opened it "
                        +CopierSecText(ageSec)+" ago and the configured wait"
                        +" is "+CopierSecText(waitSec)+", so it will enter in"
                        +" "+CopierSecText(waitSec-ageSec));
          g_waitHeld++;
          g_waitLots+=lots;
          AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Wait open delay ("+CopierSecText(waitSec-ageSec)+")");
          continue;
         }
      }

      if(g_senderCfg[si].waitforminutesbar>0 && openedOurs>0)
        {
         int bars=CopierM1BarsSince(rsym,(datetime)openedOurs,
                                    g_senderCfg[si].waitforminutesbar);
         if(bars<g_senderCfg[si].waitforminutesbar)
           {
            if(g_once.ShouldEmit("waitbar|"+g_sid[si]+"|"+rsym))
               g_log.Info("holding "+rsym+" - waiting for "
                          +(string)g_senderCfg[si].waitforminutesbar+" M1 bar(s) and "
                          +(string)bars+" have formed since the sender opened"
                          +" it");
            g_waitHeld++;
            g_waitLots+=lots;
            AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Waiting for M1 bars ("+(string)bars+"/"+(string)g_senderCfg[si].waitforminutesbar+")");
            continue;
           }
        }

      if(g_senderCfg[si].waitforprofitpips!=0.0 && d.openPx>0.0)
        {
         CopierSymInfo pi;
         if(CopierGetSymbolInfo(rsym,pi))
           {
            double closePx=0.0;
            if(CopierGetClosePrice(rsym,d.side,closePx))
              {
               double pipSize=(pi.digits==3 || pi.digits==5)
                              ?pi.point*10.0:pi.point;
               double profitPips=(d.side==CP_SIDE_BUY)
                                 ?((closePx-d.openPx)/pipSize)
                                 :((d.openPx-closePx)/pipSize);

               if(!CopierProfitTargetReached(profitPips,g_senderCfg[si].waitforprofitpips))
                 {
                  if(g_once.ShouldEmit("waitpf|"+g_sid[si]+"|"+rsym))
                     g_log.Info("holding "+rsym+" - the sender's entry is at "
                                +CopierFmtDouble(profitPips,1)+" pips;"
                                +" waiting for it to reach "
                                +CopierFmtDouble(g_senderCfg[si].waitforprofitpips,1)
                                +" pips before entering");
                  g_waitHeld++;
                  g_waitLots+=lots;
                  AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Waiting for profit pullback ("+CopierFmtDouble(profitPips,1)+"/"+CopierFmtDouble(g_senderCfg[si].waitforprofitpips,1)+" pips)");
                  continue;
                 }
              }
           }
        }

      {
       long limitSec=(long)g_senderCfg[si].requirepositionfillwithinhours*3600
                    +(long)g_senderCfg[si].requirepositionfillwithinminutes*60
                    +(long)g_senderCfg[si].requirepositionfillwithinseconds;
       if(limitSec>0 && openedOurs>0)
         {
          if(g_fillDropped.Has(d.uid)) continue;
          if(ageSec>limitSec)
            {
             g_fillDropped.Add(d.uid);
             g_log.Error("DROPPED "+d.uid+" "+rsym+" - the sender opened it "
                         +CopierSecText(ageSec)+" ago, past the "
                         +CopierSecText(limitSec)+" fill timeout, so it is"
                         +" abandoned. THIS ACCOUNT IS NOW MISSING A TRADE"
                         +" THE SENDER HAS. Raise the timeout, or set it to 0"
                         +" to keep retrying.");
             continue;
            }
         }
      }

      if(g_senderCfg[si].fillwithinminutesbar>0 && openedOurs>0)
        {
         if(g_fillDropped.Has(d.uid)) continue;
         int bars=CopierM1BarsSince(rsym,(datetime)openedOurs,
                                    g_senderCfg[si].fillwithinminutesbar);
         if(bars>=g_senderCfg[si].fillwithinminutesbar)
           {
            g_fillDropped.Add(d.uid);
            g_log.Error("DROPPED "+d.uid+" "+rsym+" - "+(string)bars
                        +" M1 bar(s) have formed since the sender opened it,"
                        +" past the "+(string)g_senderCfg[si].fillwithinminutesbar
                        +"-bar fill timeout, so it is abandoned. THIS ACCOUNT"
                        +" IS NOW MISSING A TRADE THE SENDER HAS. Raise the"
                        +" timeout, or set it to 0 to keep retrying.");
            continue;
           }
        }

      if(g_brokerOrdLimit>0 && (g_acctPositions+g_acctOrders)>=g_brokerOrdLimit)
        {
         if(g_once.ShouldEmit("brokerlimit|any"))
            g_log.Warn("at this broker's order limit of "
                       +(string)g_brokerOrdLimit+" (positions "
                       +(string)g_acctPositions+" + pending "
                       +(string)g_acctOrders+") - not sending more. Skipped,"
                       +" not queued, so NOT ONE refused order is produced."
                       +" The sender holds more than this account may carry;"
                       +" the accounts will differ until room appears.");
         continue;
        }

      if(!g_senderCfg[si].reopenclosedmirrors
         && g_everOpened.Has(g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid)
         && !g_reopenExpected.Has(g_sid[si]+":"+d.uid))
        {
         if(g_once.ShouldEmit("noreopen|"+g_sid[si]+"|"+d.uid))
            g_log.Info("LEAVING "+d.uid+" "+rsym+" closed - the sender still"
                       +" holds it, but ReopenClosedMirrors=false and this"
                       +" account had it open before, so it stays closed."
                       +" Set the input to true to restore it.");
         continue;
        }

      if((g_senderCfg[si].waitforhours>0 || g_senderCfg[si].waitforminutes>0 || g_senderCfg[si].waitforseconds>0
          || g_senderCfg[si].waitforprofitpips!=0.0)
         && g_once.ShouldEmit("opened|"+d.uid))
         g_log.Info("opening "+d.uid+" "+rsym+" - the sender opened it "
                    +CopierSecText(ageSec)+" ago (openTime="
                    +(string)d.openTime+", offset="
                    +(string)g_senderClockOffset[si]+"s)");

      bool queued=PushAction(si,CP_ACT_OPEN,d.uid,rsym,d.side,lots,0,d.ticket,
                             ":"+(string)d.kind,osl,otp,
                             d.kind,d.ptype,d.pprice,d.pstop,d.pexpire);

      string openKey=g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid;
      if(queued && g_everOpened.Has(openKey)
         && g_once.ShouldEmit("restore|"+d.uid))
         g_log.Info("RESTORING "+d.uid+" "+rsym+" - the sender still holds it"
                    +" and this account does not (closed by hand, by another"
                    +" EA, or by a stop-out). To leave it alone, add "+d.uid
                    +" to the IgnoreUids input");
     }

   //--- mirrored but no longer desired -> close
   for(int i=0;i<ln;i++)
     {
      bool stillDesired=false;
      for(int k=0;k<g_desiredCount[si];k++)
        {
         if(g_desired[base+k].uid==loc[i].uid) { stillDesired=true; break; }
        }
      if(stillDesired) continue;

      if(g_ignore.Has(loc[i].uid) || g_senderIgnore[si].Has(loc[i].uid)) continue;

      if(g_senderCfg[si].ignoreallexitsignals)
        {
         if(g_once.ShouldEmit("gateexit|"+g_sid[si]+"|"+loc[i].uid))
            g_log.Warn("sender "+g_sid[si]+" IgnoreAllExitSignals is on - NOT closing "
                       +loc[i].uid+" "+loc[i].sym+" even though the sender"
                       +" has exited it. This account is still in that trade"
                       +" and nothing here will close it. Close it by hand, or"
                       +" add "+loc[i].uid+" to the IgnoreUids input to stop"
                       +" being told.");
         continue;
        }

      PushAction(si,CP_ACT_CLOSE,loc[i].uid,loc[i].sym,loc[i].side,loc[i].lots,loc[i].ticket);
     }
  }

//=====================================================================
// Message handling
//=====================================================================
int SenderIndexById(const string sid)
  {
   for(int i=0;i<g_nSenders;i++) { if(g_sid[i]==sid) return i; }
   return -1;
  }

void HandleSnapshot(const int si,const CopierEnv &e)
  {
   g_lastSnapMs[si]=CopierNowMs();

   //--- Store this sender's receipt hash BEFORE anything can fail below.
   //---
   //--- "Before anything can fail" is the whole point: the receipt means "I
   //--- received these bytes", and we HAVE received them - they are in
   //--- e.payload. A record that fails to decode is the sender's problem to
   //--- fix, not a reason to claim we never got the message. Reporting a
   //--- stale hash because one record was malformed would make the sender
   //--- re-send the same snapshot forever.
   //---
   //--- Per sender, because this receiver may mirror several: a single shared
   //--- variable would let one sender's hash answer for another's.
   g_snapHash[si]=CopierSnapshotHash(e.payload);

   //--- Learn the sender's clock offset. Taken here rather than on every
   //--- message because this is the snapshot that survived conflation - the
   //--- newest of its batch, so the one least delayed in the queue. A message
   //--- that waited would make the sender look further behind than it is.
   if(e.ts>0)
     {
      long off=(long)CopierServerTime()-(long)e.ts;
      bool first=!g_senderClockKnown[si];
      g_senderClockKnown[si]=true;
      g_senderClockOffset[si]=off;

      //--- Two very different situations produce a large offset, and they
      //--- must not be reported the same way:
      //---
      //---  a) OUR clock is frozen (market closed, no ticks) while theirs
      //---     keeps running. The offset then grows without bound - the log
      //---     showed "18119s ahead of ours" and climbing. That number reads
      //---     like a fault but is simply the weekly close: TimeCurrent()
      //---     stops dead, so every second the sender advances is charged
      //---     to us as skew. It is expected, and SenderTimeToOurs() refuses
      //---     to apply it until our clock moves again, so nothing is aged
      //---     wrongly and no position is abandoned by the fill timeout.
      //---
      //---  b) Both clocks run but genuinely disagree (two brokers in
      //---     different timezones). Then the offset is real and IS applied.
      //---
      //--- Rate-limited: (a) is true on every snapshot, so it is emitted
      //--- once per sender per re-warn interval; (b) only on first sight.
      //--- A 5-minute floor keeps a trivial startup gap from being reported
      //--- at all - this message exists to explain a number that would
      //--- otherwise look alarming, and a small one does not.
      if(!g_srvEverMoved)
        {
         if(MathAbs(off)>=300 && g_once.ShouldEmit("clockfrozen|"+g_sid[si]))
            g_log.Info("sender "+g_sid[si]+" server clock reads "
                       +CopierSecText(MathAbs(off))+" from ours, but OUR"
                       +" clock is not advancing (market closed or no ticks) -"
                       +" the gap is expected and is ignored until our clock"
                       +" moves again");
        }
      else if(first)
         g_log.Info("sender "+g_sid[si]+" server clock is "
                    +CopierSecText(MathAbs(off))
                    +((off>=0)?" behind":" ahead of")+" ours - its timestamps"
                    +" are converted before being compared");
     }

   int n=CopierDecodeSnapshot(e.payload,g_scratch,CP_MAX_POSITIONS);

   //--- A sender can hold more than our table. Decode caps at
   //--- CP_MAX_POSITIONS and drops the remainder SILENTLY - the worst
   //--- possible outcome, because the receiver then believes it holds the
   //--- full picture while mirroring only part of it. The divergence does
   //--- not show up as an error anywhere else: nothing is missing locally,
   //--- it was never known about.
   //---
   //--- So compare the sender's own count against what we actually took and
   //--- say so. Rate-limited because it is true on every snapshot.
   string cnt="";
   if(CopierKvGet(e.payload,"N",cnt))
     {
      int sent=(int)StringToInteger(cnt);
      if(sent>n && g_once.ShouldEmit("overflow|"+g_sid[si]))
         g_log.Error("sender "+g_sid[si]+" holds "+(string)sent
                     +" position(s) but this receiver can only track "
                     +(string)CP_MAX_POSITIONS+". The remaining "
                     +(string)(sent-n)+" are DROPPED - not queued, not"
                     +" deferred, simply unknown - so this account will not"
                     +" mirror them. Raise CP_MAX_POSITIONS, or the two"
                     +" accounts will differ with nothing in the log saying"
                     +" why.");
     }
   int base=si*CP_MAX_POSITIONS;
   for(int i=0;i<n;i++) g_desired[base+i]=g_scratch[i];
   g_desiredCount[si]=n;
   g_ready[si]=true;
  }

//--- index of `uid` in the stop-override table, growing it on demand.
int StopsOvIndex(const string uid,const bool create)
  {
   int n=ArraySize(g_stUid);
   for(int i=0;i<n;i++)
      if(g_stUid[i]==uid) return i;
   if(!create) return -1;
   ArrayResize(g_stUid,n+1,32);
   ArrayResize(g_stHasOv,n+1,32);
   ArrayResize(g_stOvSl,n+1,32);
   ArrayResize(g_stOvTp,n+1,32);
   ArrayResize(g_stOvOpn,n+1,32);
   ArrayResize(g_stLastMs,n+1,32);
   g_stUid[n]=uid;
   g_stHasOv[n]=false;
   g_stOvSl[n]=0.0;
   g_stOvTp[n]=0.0;
   g_stOvOpn[n]=0.0;
   //--- -1, not 0, for "never pushed". CopierNowMs() is a millisecond counter
   //--- that starts at zero when the terminal does, so a stop change in the
   //--- first second after attach would stamp a real 0 and read back as
   //--- "never" - which silently disables the throttle for the next change.
   g_stLastMs[n]=-1;
   return n;
  }

//--- Drop entries that are neither carrying an override nor recent enough for
//--- the throttle to still care about.
//---
//--- Without this the table grows once per position the account has EVER held,
//--- which on a copier left running for weeks is precisely the slow leak this
//--- project exists to avoid. An entry is kept only while it is doing one of
//--- its two jobs.
void StopsPrune(const long now)
  {
   long keep=(long)StopsThrottleSeconds*1000;
   for(int i=ArraySize(g_stUid)-1;i>=0;i--)
     {
      if(g_stHasOv[i]) continue;
      if(g_stLastMs[i]>=0 && now-g_stLastMs[i]<keep) continue;
      int last=ArraySize(g_stUid)-1;
      if(i!=last)
        {
         g_stUid[i]=g_stUid[last];
         g_stHasOv[i]=g_stHasOv[last];
         g_stOvSl[i]=g_stOvSl[last];
         g_stOvTp[i]=g_stOvTp[last];
         g_stOvOpn[i]=g_stOvOpn[last];
         g_stLastMs[i]=g_stLastMs[last];
        }
      ArrayResize(g_stUid,last);
      ArrayResize(g_stHasOv,last);
      ArrayResize(g_stOvSl,last);
      ArrayResize(g_stOvTp,last);
      ArrayResize(g_stOvOpn,last);
      ArrayResize(g_stLastMs,last);
     }
  }

//--- A stop change, delivered as an EVENT.
//---
//--- Kept as an OVERRIDE beside the snapshot rather than written into
//--- g_desired. g_desired is the SNAPSHOT's view and is replaced wholesale on
//--- every snapshot, so a snapshot built before the change - which is exactly
//--- the one already in flight - would quietly undo it and the mirror would
//--- hold a stale stop until the snapshot after that.
//---
//--- Nothing is applied here: convergence decides, and it needs the local
//--- position and this account's symbol metadata to re-anchor the distance.
//=====================================================================
// M4b: applying a config the hub pushed.
//
// THE ORDER OF THESE STEPS IS THE WHOLE DESIGN. In particular the config is
// WRITTEN AND VERIFIED BEFORE anything is torn down, so a push that turns out
// to be unusable leaves a receiver that is still running the old one.
//=====================================================================

void SendCfgAck(const string body)
  {
   //--- The same upward path STAT uses: @hub, this node's identity, the
   //--- shared status sequence. A second counter would only make the numbers
   //--- on the wire harder to read.
   CopierSendStatus(CP_T_ACK,body);
  }

//--- Subscribe to the senders we now mirror, and drop the ones we no longer
//--- do. Returns the number of topics added.
int ResubscribeSenders(const string &before[],const int beforeN)
  {
   int added=0;
   for(int i=0;i<g_nSenders;i++)
     {
      bool had=false;
      for(int j=0;j<beforeN;j++)
         if(before[j]==g_sid[i]) { had=true; break; }
      if(!had && StringLen(g_sid[i])>0)
        {
         g_tp.Subscribe(g_sid[i]);
         added++;
        }
     }
   //--- Unsubscribing matters as much as subscribing: a sender that was
   //--- removed from the config would otherwise keep streaming snapshots at a
   //--- receiver that no longer has a slot for it, which reads as data the
   //--- receiver ignores and a hub link that never goes quiet.
   for(int j=0;j<beforeN;j++)
     {
      if(StringLen(before[j])==0) continue;
      bool still=false;
      for(int i=0;i<g_nSenders;i++)
         if(g_sid[i]==before[j]) { still=true; break; }
      if(!still) g_tp.Unsubscribe(before[j]);
     }
   return added;
  }

void HandleCfg(const CopierEnv &e)
  {
   string id="",revs="",iniEsc="";
   CopierKvGet(e.payload,"ID",id);
   CopierKvGet(e.payload,"REV",revs);
   CopierKvGet(e.payload,"INI",iniEsc);
   long rev=(long)StringToInteger(revs);

   //--- No ID means there is nothing to acknowledge against, and the hub would
   //--- retry forever against a node that cannot answer. Reported, not ignored.
   if(StringLen(id)==0)
     {
      g_log.Error("CFG with no ID - cannot acknowledge it, so the hub will"
                  +" retry. Ignoring.");
      return;
     }

   //--- THE GATE. Answering at all is deliberate: silence would leave the hub
   //--- walking its retry ladder for a refusal it could have been told about
   //--- immediately.
   if(!AcceptConfigPush)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=config push disabled on this receiver");
      if(g_once.ShouldEmit("cfg|off"))
         g_log.Warn("the hub pushed a config (id="+id+") but AcceptConfigPush"
                    +" is false, so it was NOT applied. That switch exists"
                    +" because a CFG rewrites copier.ini and reloads - and"
                    +" until there is authentication on the hub link, anything"
                    +" that can reach it can send one.");
      return;
     }
   if(!g_hubOn)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=not in central mode");
      return;
     }

   //--- IDEMPOTENCY, the plan's §5.4 rule 2. A repeated ID re-sends the SAME
   //--- answer and does not re-apply. Under §11 primary/standby two hubs can
   //--- push one change, and the second copy must be a no-op rather than a
   //--- second reload.
   if(StringLen(g_cfgId)>0 && id==g_cfgId && StringLen(g_cfgAck)>0)
     {
      SendCfgAck(g_cfgAck);
      g_log.Info("CFG "+id+" is a repeat - re-sent the same ACK, not re-applied");
      return;
     }

   string ini="";
   if(!CopierIniUnescape(iniEsc,ini))
     {
      SendCfgAck("ID="+id+";OK=0;ERR=malformed escape in INI");
      g_log.Error("CFG "+id+": the INI field is not validly escaped. Refused.");
      return;
     }

   string err="";
   if(!CopierIniValidate(ini,err))
     {
      SendCfgAck("ID="+id+";OK=0;ERR="+err);
      g_log.Error("CFG "+id+": refused before touching the file - "+err);
      return;
     }

   //--- What is about to change, captured BEFORE the reload so the ACK can
   //--- report it. §10 layer 2: a magic change orphans whatever is open under
   //--- the old one, and that is worth saying out loud rather than leaving to
   //--- be discovered from the panel.
   string beforeSid[CP_MAX_SENDERS];
   long   beforeMagic[CP_MAX_SENDERS];
   //--- ArrayInitialize rather than a hand-written loop. MQL warns about
   //--- "possible use of uninitialised variable" and it is right: with zero
   //--- senders the fill loop below never runs, and the comparison further
   //--- down would read whatever was on the stack - a stale magic read as "the
   //--- previous magic" would invent an orphan warning out of nothing.
   //---
   //--- ArrayInitialize is used rather than a `for` loop because the analyser
   //--- recognises it and does not recognise the loop, so the loop silences
   //--- nothing.
   ArrayInitialize(beforeMagic,0);
   for(int z=0;z<CP_MAX_SENDERS;z++) beforeSid[z]="";
   int    beforeN=g_nSenders;
   for(int i=0;i<beforeN;i++)
     {
      beforeSid[i]=g_sid[i];
      beforeMagic[i]=g_magic[i];
     }

   if(!CopierIniWriteAtomic(ini,err))
     {
      SendCfgAck("ID="+id+";OK=0;ERR="+err);
      g_log.Error("CFG "+id+": "+err+". The receiver is still running the"
                  +" previous configuration.");
      return;
     }

   //--- The file is written and verified. NOW reload.
   if(!LoadConfig())
     {
      //--- The new ini parses as a FILE but the config is not usable - a
      //--- missing magic=, a bad id=. Put the old one back: a config that
      //--- cannot load is worse than the one that could.
      string old="";
      if(CopierIniReadAll(CP_INI_BAK_PATH,old) && StringLen(old)>0)
        {
         CopierIniWriteAll(CP_INI_PATH,old);
         LoadConfig();
         SendCfgAck("ID="+id+";OK=0;ERR=config rejected: "+err
                    +"; previous config restored");
         g_log.Error("CFG "+id+" rejected by LoadConfig - restored "+CP_INI_BAK_PATH);
        }
      else
        {
         SendCfgAck("ID="+id+";OK=0;ERR=config rejected and no backup to restore");
         g_log.Error("CFG "+id+" rejected by LoadConfig and there is no backup");
        }
      return;
     }

   int added=ResubscribeSenders(beforeSid,beforeN);

   //--- Warnings, counted the way §10 asks: a magic change orphans positions.
   int warnings=0;
   for(int i=0;i<g_nSenders;i++)
     {
      long was=0;
      for(int j=0;j<beforeN;j++)
         if(beforeSid[j]==g_sid[i]) { was=beforeMagic[j]; break; }
      if(was!=0 && was!=g_magic[i]) warnings++;
     }
   if(beforeN!=g_nSenders) warnings++;

   g_cfgId=id;
   g_cfgRev=rev;
   g_cfgAck="ID="+id+";OK=1;REV="+(string)rev+";WARN="+(string)warnings;
   CopierCfgRevSave(id,rev);
   SendCfgAck(g_cfgAck);
   SendCurrentConfigReport();

   g_log.Info("CFG "+id+" applied: rev "+(string)rev+", "
              +IntegerToString(beforeN)+" -> "+IntegerToString(g_nSenders)
              +" sender(s), "+IntegerToString(added)+" new subscription(s), "
              +IntegerToString(warnings)+" warning(s)");
   if(warnings>0)
      g_log.Warn("CFG "+id+": "+IntegerToString(warnings)+" warning(s) - a magic"
                 +" or sender-set change leaves positions that are no longer"
                 +" managed. Check the panel's orphan rows.");
  }

// M5b: acting on an operational command the hub pushed.
//
// The skeleton is HandleCfg's ON PURPOSE: gate, then idempotency, then act,
// then answer - on the same upward path, with the same ACK frame. The one
// structural difference is what gets PERSISTED. HandleCfg records the id and
// the answer because a config must not be applied twice; here only the PAUSE
// flag is, because the four ops are idempotent by nature (pause twice is
// pause, a second closeall finds nothing left to close, a reload re-reads
// the same file) - which is exactly the fallback the plan's §5.4 rule 1
// leans on for the crash window. A repeated OLD id answered after a restart
// re-executes the op; for these four that is bounded and harmless, and it
// still never leaves the hub without an answer.
//
// OK=0 refusals at the GATE are deliberately NOT recorded (like HandleCfg):
// the operator may flip the switch on and the hub's retry should then
// succeed without anyone re-issuing the command. Refusals from the op
// itself (a failed reload) ARE recorded, so the hub sees the same answer
// on every retry instead of a fresh failure each time.
void HandleCmd(const CopierEnv &e)
  {
   string id="",op="";
   CopierKvGet(e.payload,"ID",id);
   CopierKvGet(e.payload,"OP",op);
   //--- ARGS is reserved and ignored here, on purpose. A future op that
   //--- needs parameters reads them itself; today's four take none.

   //--- No ID means there is nothing to acknowledge against, and the hub
   //--- would retry forever against a node that cannot answer.
   if(StringLen(id)==0)
     {
      g_log.Error("CMD with no ID - cannot acknowledge it, so the hub will"
                  +" retry. Ignoring.");
      return;
     }

   //--- THE GATE, the twin of AcceptConfigPush in HandleCfg.
   if(!AcceptCommands)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=commands disabled on this receiver");
      if(g_once.ShouldEmit("cmd|off"))
         g_log.Warn("the hub sent a command (id="+id+", op="
                    +(StringLen(op)>0?op:"(none)")
                    +") but AcceptCommands is false, so it was NOT acted on."
                    +" That switch exists because a CMD can pause this"
                    +" receiver and close every mirror it holds - and until"
                    +" there is authentication on the hub link, anything that"
                    +" can reach it can send one.");
      return;
     }
   if(!g_hubOn)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=not in central mode");
      return;
     }

   //--- IDEMPOTENCY, the plan's §5.4 rule 2 - same as HandleCfg.
   if(StringLen(g_cmdId)>0 && id==g_cmdId && StringLen(g_cmdAck)>0)
     {
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+" is a repeat - re-sent the same ACK, not re-applied");
      return;
     }

   if(StringLen(op)==0)
     {
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=0;ERR=no OP in command";
      SendCfgAck(g_cmdAck);
      g_log.Error("CMD "+id+": no OP field. Refused.");
      return;
     }

   if(op=="pause")
     {
      g_cmdPaused=true;
      CmdStateSave();
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Warn("CMD "+id+": PAUSED by the hub - no new mirrors will be"
                 +" opened. Existing positions are still managed normally"
                 +" (stops, trims, sender closes). RESUME clears this.");
      return;
     }

   if(op=="resume")
     {
      bool was=g_cmdPaused;
      g_cmdPaused=false;
      CmdStateSave();
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      if(was) g_log.Info("CMD "+id+": RESUMED by the hub - new mirrors are"
                         +" opened again");
      else    g_log.Info("CMD "+id+": RESUME - the receiver was not paused");
      return;
     }

   if(op=="closeall")
     {
      //--- Pause FIRST, and save it, because converge runs on every snapshot:
      //--- a flatten that leaves the sender's desired set mirrored re-opens
      //--- everything within seconds, and the operator would watch closeall
      //--- undo itself. Pausing is also what makes closeall and pause two
      //--- buttons the operator can reason about: closeall is "stop AND
      //--- flatten", resume is the way back.
      g_cmdPaused=true;
      CmdStateSave();
      int n=CloseAllOurs("CMD "+id+": CLOSEALL from the hub");
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Warn("CMD "+id+": closeall queued "+(string)n+" close(s); the"
                 +" receiver also paused itself - leaving the sender's"
                 +" desired set mirrored would re-open everything. RESUME"
                 +" re-enables opening.");
      return;
     }

   if(op=="reload")
     {
      //--- The file is NOT rewritten (that is CFG's job): reload re-reads
      //--- whatever copier.ini says NOW. The sender set is captured first so
      //--- the log can say what the reload changed, the way HandleCfg does.
      //--- No backup/restore dance either: the file on disk is the one
      //--- already running, and LoadConfig failing leaves it untouched.
      string beforeSid[CP_MAX_SENDERS];
      long   beforeMagic[CP_MAX_SENDERS];
      ArrayInitialize(beforeMagic,0);
      for(int z=0;z<CP_MAX_SENDERS;z++) beforeSid[z]="";
      int beforeN=g_nSenders;
      for(int i=0;i<beforeN;i++)
        {
         beforeSid[i]=g_sid[i];
         beforeMagic[i]=g_magic[i];
        }
      if(!LoadConfig())
        {
         g_cmdId=id;
         g_cmdAck="ID="+id+";OK=0;ERR=config reload failed";
         SendCfgAck(g_cmdAck);
         g_log.Error("CMD "+id+": reload failed - the receiver keeps running"
                     +" the configuration it had");
         return;
        }
      int added=ResubscribeSenders(beforeSid,beforeN);
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+": reload applied - "
                 +IntegerToString(beforeN)+" -> "+IntegerToString(g_nSenders)
                 +" sender(s), "+IntegerToString(added)+" new subscription(s)");
      return;
     }

   if(op=="reqpos" || op=="refreshpos" || op=="refresh")
     {
      g_forcePosReport=true;
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+": position table update requested by WebUI");
      return;
     }

   //--- The hub validates OP at the door, so reaching this line means a hub
   //--- a version apart, or a hand-crafted frame. Answer rather than leave
   //--- the ladder running against an op that will never become known.
   g_cmdId=id;
   g_cmdAck="ID="+id+";OK=0;ERR=unknown op "+op;
   SendCfgAck(g_cmdAck);
   g_log.Error("CMD "+id+": unknown op \""+op+"\". Refused.");
  }

void HandleModifyEvent(const int si,const CopierEnv &e)
  {
   CopierPos p;
   if(!CopierPayloadModifyParse(e.payload,p)) return;
   int idx=StopsOvIndex(p.uid,true);
   g_stHasOv[idx]=true;
   g_stOvSl[idx]=p.sl;
   g_stOvTp[idx]=p.tp;
   g_stOvOpn[idx]=p.openPx;
  }

void HandleOpenEvent(const int si,const CopierEnv &e)
  {
   CopierPos p;
   if(!CopierPayloadOpenParse(e.payload,p)) return;
   int base=si*CP_MAX_POSITIONS;
   for(int i=0;i<g_desiredCount[si];i++)
     {
      if(g_desired[base+i].uid==p.uid) { g_desired[base+i]=p; return; }
     }
   if(g_desiredCount[si]>=CP_MAX_POSITIONS) return;
   g_desired[base+g_desiredCount[si]]=p;
   g_desiredCount[si]++;
  }

void HandleCloseEvent(const int si,const CopierEnv &e)
  {
   string uid="";
   if(!CopierKvGet(e.payload,"UID",uid)) return;
   int base=si*CP_MAX_POSITIONS;
   for(int i=0;i<g_desiredCount[si];i++)
     {
      if(g_desired[base+i].uid!=uid) continue;
      for(int k=i;k<g_desiredCount[si]-1;k++) g_desired[base+k]=g_desired[base+k+1];
      g_desiredCount[si]--;
      return;
     }
  }

//--- Account state of the sender. Not used for sizing yet (the MVP is
//--- multiplier/fixed only), but it is what a later equity-relative
//--- sizing mode needs, and it doubles as an extra liveness signal.
//---
//--- The DEBUG line is THROTTLED. Heartbeats arrive once a second by
//--- default, so logging each one is a per-second line forever - measured
//--- at 28 lines in 27 seconds, i.e. ~250 KB/hour. That is the same
//--- unbounded-noise failure CopierOnceLog exists to prevent, and at
//--- LogLevel=3 it buries the open/close lines you actually turned DEBUG
//--- on to see. Once a minute answers "is the link alive, and what is the
//--- sender's equity" perfectly well.
//--- Send a message UP the socket (receiver -> sender).
//---
//--- One place, so the envelope fields that must be identical for every such
//--- message - sid, ssid, seq, ts - cannot drift between the status report and
//--- the latency probes. sid is deliberately the literal "receiver": the
//--- sender must not route an upward message by sender-id.
void CopierSendStatus(const string type,const string payload)
  {
   CopierEnv se;
   se.v=CP_PROTO_V;
   se.sid="receiver";
   se.ssid=(string)CopierAccountLogin();
   se.seq=++g_statusSeq;
   se.ts=CopierServerTime();
   //--- monotonic ms, so the sender can estimate the link from this message
   //--- alone: see the header of CopierPeers.mqh
   se.ms=CopierNowMs();
   se.type=type;
   se.payload=payload;
   string msg=CopierEncodeEnv(se);

   //--- CENTRAL mode goes up as TWO frames on @hub, and that is not a style
   //--- choice - it is the only shape the hub can route.
   //---
   //--- A single frame is the DIRECT channel's convention, where the socket
   //--- carries exactly one stream and needs no topic. To an XPUB it looks
   //--- like a subscription byte, which is how XPUB tells the two apart. So
   //--- the hub read every one of these, matched it against the subscription
   //--- shape, found it was not one, and DROPPED it - with no log line, no
   //--- counter and no trace. Measured on the first live run: the receiver's
   //--- STAT and PONG were being thrown away by the hub, silently.
   if(g_hubOn)
     {
      if(!g_tp.SendUp("@hub",msg))
         g_log.Warn("status send failed errno="+(string)g_tp.LastErrno());
      return;
     }

   if(!g_tp.SendStatus(msg))
      g_log.Warn("status send failed errno="+(string)g_tp.LastErrno());
  }

//--- Announce this node to the hub: REG once, HBT2 afterwards.
//---
//--- The hub learns who exists ONLY from these. It never probes for nodes and
//--- never guesses, so a receiver that does not announce itself is invisible -
//--- and in central mode that means the hub can see every sender and no
//--- receiver, which is exactly backwards from what an operator needs to know.
//---
//--- REG and HBT2 differ in ONE field (NAME) and are otherwise identical. A
//--- heartbeat repeating a name that cannot have changed is bytes for nothing,
//--- every five seconds, from every node.
//---
//--- Neither carries anything a trade depends on. If the hub is down, or drops
//--- every one of these, mirroring is completely unaffected - that is Phase 2's
//--- whole promise.
void HubAnnounce(const bool isReg)
  {
   if(!g_hubOn) return;

   long up=(CopierNowMs()-g_bootMs)/1000;
   CopierEnv e;
   e.v=CP_PROTO_V;
   //--- Same identity convention the receiver's STAT already uses: the NID as
   //--- the routing id, the account as the session id, and the SHARED status
   //--- sequence. One counter for everything this node sends, because they all
   //--- leave by the same socket - a second counter would only make the
   //--- numbers on the wire harder to read.
   e.sid=(string)g_nid;
   e.ssid=(string)CopierAccountLogin();
   e.seq=++g_statusSeq;
   e.ts=CopierServerTime();
   e.ms=CopierNowMs();
   e.type=isReg?CP_T_REG:CP_T_HBT2;
   e.payload=isReg
             ?CopierPayloadReg("receiver",CopierAccountLogin(),
                               CopierTerminalName(),up)
             :CopierPayloadHbt2("receiver",CopierAccountLogin(),
                                CopierTerminalName(),up);
   //--- M4b: the config revision this receiver is RUNNING. Appended here
   //--- rather than added to the shared encoder, because only a node that has
   //--- a config has a revision - a sender has no ini and would send REV=0
   //--- forever for nothing.
   //---
   //--- This one field is what lets the hub tell "behind" from "drifted"
   //--- (§7.3), and it is why it is persisted to disk: a receiver that
   //--- restarted and claimed 0 would be pushed a config it already has,
   //--- every time it restarted.
   e.payload+=CP_SEP_KV+"REV="+(string)g_cfgRev;
   //--- M5b on the dashboard: report the hub-pause state so the operator can
   //--- SEE a paused node without grepping the hub log. Carried on REG and
   //--- HBT2 alike (a REG right after a closeall must not look un-paused),
   //--- and the hub's list refreshes every heartbeat, so a pause/resume
   //--- shows up on the dashboard within one cadence.
   //--- The hub ignores the field from a sender, and an OLD hub ignores it
   //--- entirely - unknown payload fields are skipped by design.
   e.payload+=CP_SEP_KV+"PAUSED="+(g_cmdPaused?"1":"0");
   if(isReg)
      e.payload+=CP_SEP_KV+"INI="+CopierIniEscape(SerializeCurrentConfigToIni());
   //--- Dropped silently on purpose: one lost heartbeat is nothing, and a log
   //--- line per failure would be a line per five seconds on a hub that is
   //--- simply not running yet. The hub's WHO sweep is the recovery path.
   g_tp.SendUp("@hub",CopierEncodeEnv(e));
  }

void HandleHeartbeat(const int si,const CopierEnv &e)
  {
   double eq=CopierKvGetDouble(e.payload,"EQ",0.0);
   int npos=CopierKvGetInt(e.payload,"NPOS",-1);

   //--- The sender's ACCOUNT NUMBER, so the panel can name it. Falls back to
   //--- the routing id for a sender that does not send one, which is still
   //--- better than an unnamed row.
   long acc=CopierKvGetLong(e.payload,"ACC",0);
   string want=(acc>0)?((string)acc):g_sid[si];

   //--- If the name CHANGES - which happens when a sender that does not
   //--- report ACC is first seen under its routing id and then under its real
   //--- account - drop the old entry. Otherwise ONE sender occupies TWO rows:
   //--- one under its port and one under its account, and the stale one sits
   //--- there looking like a second, dead sender forever.
   if(StringLen(g_senderAcc[si])>0 && g_senderAcc[si]!=want)
      g_peers.Forget(g_senderAcc[si]);
   g_senderAcc[si]=want;
   g_peers.Seen(want);
   if(g_onceHbt.ShouldEmit("hbt|"+g_sid[si]))
      g_log.Verbose("hbt "+g_sid[si]+" eq="+DoubleToString(eq,2)
                    +" npos="+(string)npos+" (heartbeat logged at most"
                    +" once per minute)");
  }

//--- returns false when the message must be discarded
bool AcceptSeq(const int si,const CopierEnv &e,const int stream)
  {
   //--- a new session id means the sender restarted: throw away our idea
   //--- of its state and resync from the next snapshot
   if(g_ssidSeen[si]!=e.ssid)
     {
      g_ssidSeen[si]=e.ssid;
      g_lastSeq[si][CP_STREAM_EVENTS]=-1;
      g_lastSeq[si][CP_STREAM_SNAP]=-1;
      g_ready[si]=false;
      g_desiredCount[si]=0;
      g_log.Info("sender "+g_sid[si]+" new session "+e.ssid+" -> resync");
     }
   //--- per-stream watermark: a snapshot must never invalidate an event
   //--- that was emitted before it on the other socket
   if(e.seq<=g_lastSeq[si][stream]) return false;
   g_lastSeq[si][stream]=e.seq;
   return true;
  }

void HandleMessage(const string msg,const int stream)
  {
   CopierEnv e;
   int err=CopierDecodeEnv(msg,e);
   if(err!=CP_ERR_NONE)
     {
      //--- "bad message err=1" was reported and answerable only by reading
      //--- the source. err=1 is also AMBIGUOUS: it means "empty OR longer
      //--- than the limit", two unrelated faults with unrelated fixes, and
      //--- the old line did not even print the length that separates them.
      //---
      //--- Say which, say the size, and show the head of the message: an
      //--- unparseable frame is usually obvious once you can see 60 bytes
      //--- of it (a stray subscription frame, a truncated snapshot, a peer
      //--- speaking a different protocol).
      string why=CopierErrText(err);
      if(err==CP_ERR_TRUNCATED)
        {
         if(StringLen(msg)==0)
            why="EMPTY (zero bytes)";
         else
            why="TOO LONG - "+(string)StringLen(msg)+" bytes against a "
                +(string)CP_MAX_MSG_LEN+" limit. A snapshot this size can"
                +" never be parsed, so that sender's state is NOT being"
                +" applied: raise CP_MAX_MSG_LEN to hold CP_MAX_POSITIONS"
                +" records";
        }
      g_log.Warn("bad message err="+(string)err+" ("+why+")"
                 +" len="+(string)StringLen(msg)
                 +" head=\""+StringSubstr(msg,0,60)+"\"");
      return;
     }

   //--- THE HUB'S OWN MESSAGES, before the per-sender lookup below.
   //---
   //--- That lookup drops anything whose SID is not a configured sender, and
   //--- the hub's SID is "hub" - so EVERY hub-addressed frame would be
   //--- discarded here without a trace. WHO was exempted when it was the only
   //--- such frame; M4b added CFG and M5b added CMD without extending the
   //--- exemption, and BOTH were silently eaten by this lookup - found live
   //--- when the first real CMD never reached the receiver while a wire probe
   //--- showed the hub publishing it correctly, and the config-push half of
   //--- M4b had the same latent break because no real CFG had ever been
   //--- pushed (every CFG test drove the handler directly, not this router).
   //--- Route by SID FIRST: hub control is not per-sender and must not be
   //--- routed as if it were. Hub frames also skip the per-sender sequence
   //--- guard on purpose - each carries its own idempotency key (§5.4), and
   //--- a hub frame is not evidence that any SENDER is alive.
   if(e.sid=="hub")
     {
      if(e.type==CP_T_WHO)
        {
         //--- The hub lost its node table (it restarted) and is asking
         //--- everyone to say who they are. Answering is the entire job -
         //--- and it is why this node subscribed to @all.
         //---
         //--- ONE REG, and the counter is deliberately NOT reset. Resetting
         //--- it would re-arm the REG burst every 60s for as long as the hub
         //--- runs, because the sweep is unconditional. Same reasoning as
         //--- the sender; see the longer note there.
         HubAnnounce(true);
        }
      else if(e.type==CP_T_PONG)
        {
         string pms="",pfrom="",pto="";
         CopierKvGet(e.payload,"MS",pms);
         CopierKvGet(e.payload,"FROM",pfrom);
         CopierKvGet(e.payload,"TO",pto);
         if((pto==(string)g_nid || pto==(string)CopierAccountLogin()) && StringLen(pfrom)>0)
           {
            if(g_peers.PongBack(pfrom,CopierParseLong(pms)))
              {
               if(g_once.ShouldEmit("rtt|"+pfrom))
                  g_log.Info("link to "+pfrom+" measured: "
                             +(string)g_peers.RttFor(pfrom)+" ms round trip");
              }
           }
        }
      else if(e.type==CP_T_CFG) HandleCfg(e);
      else if(e.type==CP_T_CMD) HandleCmd(e);
      else if(g_once.ShouldEmit("hubctl|"+e.type))
         g_log.Info("central channel: hub sent "+e.type
                    +" (no receiver action for it)");
      return;
     }

   int si=SenderIndexById(e.sid);
   if(si<0) return;                       // not one of ours

   g_lastMsgMs[si]=CopierNowMs();
   if(g_firstMsgMs[si]==0) g_firstMsgMs[si]=g_lastMsgMs[si];
   if(g_stale[si])
     {
      g_stale[si]=false;
      g_log.Info("sender "+g_sid[si]+" is back");
     }

   //--- Anything at all from this sender proves it is alive. Before the
   //--- sequence guard, so a dropped sequence number cannot make a live link
   //--- look dead.
   if(StringLen(g_senderAcc[si])>0)
      g_peers.Seen(g_senderAcc[si]);

   //--- PING / PONG carry no state, so they are answered BEFORE the sequence
   //--- guard for the same reason.
   if(e.type==CP_T_PING)
     {
      //--- IN CENTRAL MODE, DO NOT ANSWER.
      //---
      //--- The reply would have to reach the SENDER, and the hub consumes every
      //--- '@' topic rather than routing it - so a PONG sent up the central
      //--- channel dies at the hub. Answering anyway would be traffic that
      //--- cannot arrive, which is worse than silence: it makes the sender's
      //--- peer table look like it is being maintained when it is not.
      //---
      //--- The sender's PING itself is not wasted - it is broadcast for the
      //--- DIRECT receivers, which do answer, and it happens to be forwarded by
      //--- the hub to central ones as ordinary data.
      if(g_hubOn) return;

      string pms="",pfrom="";
      CopierKvGet(e.payload,"MS",pms);
      CopierKvGet(e.payload,"FROM",pfrom);
      //--- address the reply back to whoever asked, so other receivers ignore
      //--- it; FROM names us, so the sender can attribute our echo.
      CopierSendStatus(CP_T_PONG,
                       CopierPayloadPong(CopierParseLong(pms),
                                         (string)CopierAccountLogin(),pfrom));
      return;
     }
   if(e.type==CP_T_PONG)
     {
      string pms="",pfrom="",pto="";
      CopierKvGet(e.payload,"MS",pms);
      CopierKvGet(e.payload,"FROM",pfrom);
      CopierKvGet(e.payload,"TO",pto);
      //--- NAME THE PEER BY `FROM`, NOT BY `TO`.
      //---
      //--- FROM is the SENDER - the one that answered. TO is US, and exists
      //--- only so a reply meant for this receiver is ignored by the others.
      //--- Using TO as the peer name registered this receiver under its OWN
      //--- account number, so the panel listed itself as a second, silent
      //--- "sender" beside the real one - forever.
      if((pto==(string)CopierAccountLogin() || (g_hubOn && pto==(string)g_nid)) && StringLen(pfrom)>0
         && g_peers.PongBack(pfrom,CopierParseLong(pms)))
        {
         //--- first successful measurement: the only line that distinguishes
         //--- "the link is fine" from "both ends answer and nobody records it"
         if(g_once.ShouldEmit("rtt|"+pfrom))
            g_log.Info("link to "+pfrom+" measured: "
                       +(string)g_peers.RttFor(pfrom)+" ms round trip");
        }
      return;
     }

   if(!AcceptSeq(si,e,stream))
     {
      g_dropped[si]++;
      return;
     }

   if(e.type==CP_T_CFG)        HandleCfg(e);
   else if(e.type==CP_T_CMD)   HandleCmd(e);
   else if(e.type==CP_T_SNAP)  HandleSnapshot(si,e);
   else if(e.type==CP_T_OPEN)  HandleOpenEvent(si,e);
   else if(e.type==CP_T_CLOSE) HandleCloseEvent(si,e);
   else if(e.type==CP_T_MODIFY) HandleModifyEvent(si,e);
   else if(e.type==CP_T_HBT)   HandleHeartbeat(si,e);
   else                        g_log.Verbose("ignoring type "+e.type);
  }

//=====================================================================
// Lifecycle
//=====================================================================
int OnInit()
  {
   ResetRuntimeInputsFromInputs();
   //--- One log per instance, or two receivers in one terminal write the same
   //--- file and overwrite each other's history.
   g_log.Init("receiver"+InstanceSuffix(),LogLevel);
   if(!AcquireInstanceLock()) return INIT_FAILED;
   g_seen.SetTtlMs(600000);
   //--- g_backoff carries its own per-key deadline; there is no single TTL
   //--- to set, which is the whole point of it.
   g_unsupported.SetTtlMs(CP_UNSUPPORTED_MS);
   g_onceFail.SetRepeatMs(60000);
   g_onceHbt.SetRepeatMs(60000);
   g_onceHour.SetRepeatMs(60*60*1000);

   //--- risk switches. Every one defaults to off, so this is a no-op unless
   //--- the operator has deliberately configured something.
   CopierRiskLimits rl;
   rl.maxLotsPerPosition=MaxLotsPerPosition;
   rl.maxTotalLots      =MaxTotalLots;
   rl.maxOpenPositions  =MaxOpenPositions;
   rl.dailyLossPct      =DailyLossPct;
   rl.maxDrawdownPct    =MaxDrawdownPct;
   g_risk.Configure(rl);
   //--- Restore the drawdown peak measured in the PREVIOUS run. Without this
   //--- every terminal restart re-based the drawdown to the equity of the
   //--- moment, so the one switch whose job is "stop and look at this" was
   //--- forgiven by the event most likely to follow a bad day. Called AFTER
   //--- Configure so the restored peak is measured against the current limits.
   RiskPeakLoad();
   //--- "remember what we have opened" survives long enough to recognise a
   //--- restore a day later; the dedup ring is a different lifetime.
   //--- NOTE: no `L` suffix on the literals - MQL5 accepts `12L`, MQL4
   //--- does not (error 256, "'L' - undeclared identifier"), and this file
   //--- is compiled by both. 43200000 fits in an int anyway.
   //--- seed the feed-liveness clock so the FIRST comparison is meaningful.
   //--- Leaving it at 0 would make the first read look like "the clock moved"
   //--- and defeat g_srvEverMoved entirely.
   g_srvSeenTime=CopierServerTime();
   g_srvChangedMs=CopierNowMs();
   g_srvEverMoved=false;
   //--- Globals SURVIVE a reinitialise, so without this a fresh attach would
   //--- inherit the previous run's per-symbol timestamps and hold every symbol
   //--- for a minute on arrival - which looks exactly like a broken feed.
   CopierSymbolQuoteReset();
   g_mktClosed.SetTtlMs(CP_MKTCLOSED_MS);
   g_everOpened.SetTtlMs(12*60*60*1000);
   //--- Only has to bridge the gap between our own close and the replacement
   //--- open on the next pass - seconds in practice. Five minutes is generous
   //--- enough to survive a retrying close without letting the exemption
   //--- linger into a genuinely separate event.
   g_reopenExpected.SetTtlMs(5*60*1000);
   //--- A dropped UID is abandoned for the session, effectively: the TTL only
   //--- exists because the ring is fixed-size. Re-deriving it sooner would
   //--- undo the give-up and re-alert on every pass.
   g_fillDropped.SetTtlMs(24*60*60*1000);
   g_permitted.Set(PermittedSymbols);
   //--- The stray "!" was tolerated rather than obeyed literally, so say so:
   //--- the list now behaves the way the operator intended, but they should
   //--- know their spelling was off before they write the next one.
   if(g_permitted.StrayBangs()>0)
      g_log.Warn("PermittedSymbols has "+(string)g_permitted.StrayBangs()
                 +" item(s) with their own '!' - only the FIRST one, at the"
                 +" very front of the whole list, means \"reject these\". The"
                 +" extra ones were ignored, so the list is being read as "
                 +((g_permitted.Active())?"a real filter":"no filter")
                 +". Write (!EURUSD,GBPUSD) rather than (!EURUSD,!GBPUSD).");
   //--- PermittedMagic uses the SAME list class and the same syntax, so it
   //--- gets the same stray-"!" diagnosis. Without this the one list that is
   //--- hardest to eyeball (bare numbers, no symbols to recognise) would be
   //--- the one that fails silently.
   g_permittedMagic.Set(PermittedMagic);
   if(g_permittedMagic.Active())
      g_log.Info("PermittedMagic is filtering new entries by the SENDER's"
                 +" position magic ("+(string)g_permittedMagic.Count()
                 +" magic(s) listed). Existing mirrors are unaffected.");
   if(g_permittedMagic.StrayBangs()>0)
      g_log.Warn("PermittedMagic has "+(string)g_permittedMagic.StrayBangs()
                 +" item(s) with their own '!' - only the FIRST one, at the"
                 +" very front of the whole list, means \"reject these\". The"
                 +" extra ones were ignored. Write (!77889,998877) rather than"
                 +" (!77889,!998877).");
   g_hours.Set(IncludeTradingTimes,DayTradingTimes);
   if(g_hours.Active())
      g_log.Info("trading windows active - new entries only between the"
                 +" configured SERVER times; existing mirrors are unaffected");
   //--- the per-position opt-out list, straight from the input
   g_ignore.SetText(IgnoreUids);
   if(g_ignore.Count()>0)
      g_log.Info("IgnoreUids lists "+(string)g_ignore.Count()
                 +" UID(s) the copier will not open or close");
   //--- Rejected entries are REPORTED, never dropped quietly. A uid the
   //--- operator typed and the copier ignored is the exact failure this list
   //--- exists to prevent, and the two ways it can happen need different fixes:
   //--- a malformed entry is a typo, an overflowing one means the list is long.
   if(g_ignore.BadCount()>0)
      g_log.Warn("IgnoreUids: "+(string)g_ignore.BadCount()+" entr(ies) are not"
                 +" valid uids and were IGNORED: "+g_ignore.BadList()
                 +". A uid is exactly "+IntegerToString(CP_UID_LEN)+" characters"
                 +" from \""+CP_COMMENT_PFX+"\" in the order comment (alphabet"
                 +" "+CP_UID_ALPHA+") - see any \"exec open\" line in this log");
   if(g_ignore.OverCount()>0)
      g_log.Warn("IgnoreUids: "+(string)g_ignore.OverCount()+" more uid(s) were"
                 +" well-formed but did not fit - the list holds at most "
                 +IntegerToString(CP_MAX_IGNORE)+", and the rest were IGNORED."
                 +" Those positions will be managed normally.");

   if(!LoadConfig()) return INIT_FAILED;

   //--- restore UID <-> identifier BEFORE the first converge, so positions
   //--- whose comment was overwritten by a partial close are still known
   string hdr="";
   CopierPos saved[];
   int savedN=0;
   if(CopierStateFile::Load(ReceiverStatePath(),hdr,saved,savedN))
     {
      for(int i=0;i<savedN;i++) g_recKnown.Upsert(saved[i]);
      g_log.Info("restored "+(string)savedN+" known position(s) from state");
     }
   else
     {
      //--- Say so out loud. On MT4 this file is the ONLY durable identity:
      //--- a partial close makes the broker replace the ticket and rewrite
      //--- the comment to "from #<old>", and there is no API to write a
      //--- comment back (OrderClose has no comment parameter, OrderModify
      //--- does not touch comments). A silent absence here is
      //--- indistinguishable from "the file is there and all is well", and
      //--- it is exactly what makes a later "unmanageable order(s)" report
      //--- look like it came from nowhere.
      g_log.Info("no usable "+ReceiverStatePath()+" yet - identity will come"
                 +" from order comments until the first save");
     }

   //--- desired sets: one slice per sender, allocated once, never grown
   ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS);
   ArrayResize(g_scratch,CP_MAX_POSITIONS);

   //--- ONE endpoint per sender now: the sender binds a single socket, so
   //--- there is no separate snapshot address to collect. snap= in the
   //--- config is ignored (noted above).
   //---
   //--- CURVE: this receiver's own keypair comes from the key file, and the
   //--- only key an operator supplies is the SENDER's public key.
   //---
   //--- Regenerating this receiver's keypair (delete the file, restart) is a
   //--- LOCAL operation that touches nothing in copier.ini: serverkey= holds
   //--- the SENDER's public key, which does not change when this side's key
   //--- does. That asymmetry is the reason the client's key can be fully
   //--- automatic while the server's cannot.
   g_myPublicKey="";
   string mySecret="";
   if(UseCurve || (g_hubOn && HubUseCurve))
     {
      CP_KEY_RESULT kr=g_key.Ensure(GetPointer(g_log));
      if(kr==CP_KEY_FAILED)
        {
         g_log.Error("CURVE is on but no CURVE key could be obtained for"
                     +" this receiver. See the lines above for the reason.");
         return INIT_FAILED;
        }
      mySecret=g_key.SecretKey();
      g_myPublicKey=g_key.PublicKey();
      if(StringLen(mySecret)!=CP_KEY_LEN || StringLen(g_myPublicKey)!=CP_KEY_LEN)
        {
         g_log.Error("CURVE is on but the keys loaded from "+g_key.Path()
                     +" are the wrong length. Refusing to start.");
         return INIT_FAILED;
        }
      if(UseCurve) g_key.AnnouncePublic(GetPointer(g_log),"receiver");
     }

   //--- must precede the context creation inside ConnectReceiver / ConnectHub
   g_tp.SetInstanceName(InstanceSuffix());

   //--- M4b: what config revision are we already running? Read BEFORE the
   //--- connect, because the first REG carries it and the hub decides whether
   //--- to push based on the answer.
   {
      string cfgId="";
      CopierCfgRevLoad(cfgId,g_cfgRev);
      g_cfgId=cfgId;
      if(g_cfgRev>0)
         g_log.Info("central mode: running config rev "+(string)g_cfgRev
                    +" (id "+(StringLen(cfgId)>0?cfgId:"?")+")");
   }

   //--- M5b: restore the operational-command state. PAUSED must survive a
   //--- restart - converge runs the moment the first snapshot lands, and a
   //--- silently un-paused receiver would re-open everything the operator
   //--- had just flattened. The last CMD id/ack come back too, so a hub
   //--- retry that outruns a crash gets the same ACK rather than a second
   //--- execution (§5.4 rule 2 across the restart as well).
   CmdStateLoad();
   if(g_cmdPaused)
      g_log.Warn("operational state: PAUSED (from "+CmdStatePath()+") - no"
                 +" new mirrors will be opened until the hub sends RESUME");

   if(g_hubOn)
     {
      //--- ONE endpoint, and deliberately NOT "subscribe to everything".
      //--- Subscribing to the senders this receiver actually mirrors is what
      //--- keeps the hub from delivering every OTHER sender's stream too - the
      //--- whole point of the topic frame.
      //---
      //--- CURVE on this link is HubUseCurve, NOT UseCurve: the hub is the
      //--- CURVE SERVER on its side (§19.1 - it binds the port), so this node
      //--- is a client and holds the HUB's public key, not the sender's.
      bool hubCurveOk=true;
      string activeHubKey="";
      if(HubUseCurve)
        {
         string keySrc="";
         activeHubKey=CopierLoadHubPublicKey("",GetPointer(g_log),keySrc);
         if(StringLen(activeHubKey)!=CP_KEY_LEN)
           {
            g_log.Error("Hub link CURVE is on but no valid "+IntegerToString(CP_KEY_LEN)+"-character Hub public key found."
                        +" Download copier_hub.key from Web Dashboard to MQL\\Files (or Common\\Files).");
            hubCurveOk=false;
           }
         else
           {
            g_log.Info("CURVE: the hub link to "+g_hubEp+" is encrypted (source: "+keySrc+").");
            g_log.Info("  Add THIS node's public key to the hub's curve_clients.txt (or auto-register):");
            g_log.Info("  "+g_myPublicKey);
           }
        }
      if(!hubCurveOk)
        {
         //--- FATAL, like every other central-mode failure: with HubEndpoint
         //--- set, the hub IS this receiver's channel - there is no direct
         //--- one to fall back to. Starting without it would look like a
         //--- running receiver that mirrors nothing.
         g_log.Error("central mode: the hub link was NOT opened - download"
                     +" copier_hub.key from Web Dashboard to MQL\\Files (or Common\\Files) and restart.");
         return INIT_FAILED;
        }
      if(!g_tp.ConnectHub(g_hubEp,HubUseCurve,activeHubKey,
                          g_myPublicKey,mySecret))
        {
         g_log.Error("central mode: cannot open a socket to "+g_hubEp
                     +" errno="+(string)g_tp.LastErrno());
         return INIT_FAILED;
        }
      //--- its own control topic first, then one per mirrored sender
      g_tp.Subscribe("@"+(string)g_nid);
      //--- @all is how the hub asks everyone to re-register after it loses its
      //--- table. A node that does not subscribe to it is unreachable by the
      //--- one message that exists to make it reachable.
      g_tp.Subscribe("@all");
      //--- ...and its own account as a DATA topic, so a sender can re-send a
      //--- missed snapshot to THIS receiver alone.
      //---
      //--- Two topics for one identity, and the '@' is the whole difference:
      //--- '@<nid>' is the hub's channel to us and is consumed by the hub, so
      //--- a sender publishing there reaches nobody. '<nid>' is forwarded byte
      //--- for byte to whoever subscribed to that prefix - us.
      g_tp.Subscribe((string)g_nid);
      for(int i=0;i<g_nSenders;i++)
         g_tp.Subscribe(g_sid[i]);
      g_hubUpMs=CopierNowMs();
      g_bootMs=g_hubUpMs;
      g_peers.Seen(g_hubPeerName);
      //--- Best effort: the socket is IMMEDIATE, so a send made before the TCP
      //--- connection completes is DISCARDED rather than queued. This one may
      //--- well be lost, which is fine - the first few announcements in OnTimer
      //--- are REG too, and the hub repeats WHO while its table is empty.
      HubAnnounce(true);
      g_announceCount=1;
      g_log.Info("central mode: connected to "+g_hubEp+" as NID="
                 +(string)g_nid+", subscribed to "
                 +IntegerToString(g_nSenders+3)+" topic(s)");
     }
   else
     {
      string evEnd[];
      ArrayResize(evEnd,g_nSenders);
      for(int i=0;i<g_nSenders;i++) evEnd[i]=g_epEvents[i];

      if(!g_tp.ConnectReceiver(evEnd,g_nSenders,
                               UseCurve,g_serverKey,g_myPublicKey,mySecret))
        {
         g_log.Error("cannot connect errno="+(string)g_tp.LastErrno());
         return INIT_FAILED;
        }
     }

   //--- the status channel needs no setup of its own: it goes up the socket
   //--- the data already comes down.


   EventSetMillisecondTimer(PollMs);
   g_panel.Init("cprcv",10,20,430);
   //--- list the magics rather than a base: there is no base any more, and
   //--- the actual numbers are what you check against the terminal.
   string mags="";
   for(int i=0;i<g_nSenders;i++)
     {
      if(i>0) mags+=", ";
      mags+=g_sid[i]+"="+(string)g_magic[i];
     }
   //--- Say which MODE, not just how many senders. "0 sender(s)" means two
   //--- completely different things in the two modes: in direct mode it is a
   //--- misconfiguration, in central mode it is a receiver waiting for the hub
   //--- to push its config. Without the mode the line cannot be told apart.
   g_log.Info("receiver up, "+(string)g_nSenders+" sender(s), magic "
              +mags+(g_hubOn?(", mode=CENTRAL, NID "+(string)g_nid
                              +", hub "+g_hubEp)
                            :", mode=DIRECT (inputs)")
              +" build="+CP_BUILD_STAMP);
   if(StatusEnabled)
      g_log.Info("status channel: on, reporting up the data socket once a"
                 +" minute");
   else
      g_log.Info("status channel: off. The sender cannot see this account's"
                 +" state.");
   if(g_risk.Enabled())
      g_log.Info("risk switches active: "+g_risk.Status());
   else
      g_log.Info("risk switches: all off (nothing limits position size, count,"
                 +" total volume, daily loss or drawdown)");

   //--- one-shot startup scan. Cheap, and it is the only thing that will
   //--- ever tell you about orders the copier cannot manage.
   ReportBrokerLimits();
   ReportEntryGates();
   ReportMagicConfig();
   ReportUnreadableOwnOrders();
   ReportOrphanedMirrors();

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();

   //--- remove the panel objects: a removed EA must not leave an unreadable
   //--- rectangle on the chart, and a re-attach would draw a second one
   g_panel.Destroy();

   //--- Record what we are holding before shutting down.
   //---
   //--- The log is otherwise a DIFF (open/close lines), and a diff with a
   //--- gap in it cannot be read. During the first MT4 pilot exactly that
   //--- happened: a genuine divergence and missing history were
   //--- indistinguishable, because the receiver's log had an 11-minute hole
   //--- between restarts. One line at shutdown means every session's log
   //--- ends in a known, checkable state.
   //--- persist before the log line: the state is what lets a restart find
   //--- positions whose comment the terminal has overwritten
   SaveReceiverMap();

   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   string held="";
   int hc=0;
   for(int i=0;i<an;i++)
     {
      string uid=CopierUidFromComment(all[i].cmt);
      if(StringLen(uid)==0)
        {
         CopierPos prev;
         if(g_recKnown.GetByTicket(all[i].ticket,prev)) uid=prev.uid;
        }
      if(StringLen(uid)==0) continue;
      held+=(hc>0?",":"")+uid;
      hc++;
     }
   g_log.Info("receiver stopped reason="+(string)reason+" holding "
              +(string)hc+" copier position(s)"+(hc>0?": "+held:""));

   //--- Force the peak out on the way down, ignoring the once-a-minute
   //--- throttle: a clean shutdown is exactly the moment the in-memory peak is
   //--- about to be lost, and it costs one small file write.
   RiskPeakSave(true);

   g_tp.Close();
   ReleaseInstanceLock();
  }

//--- Probe every sender, and say once when one goes quiet.
//---
//--- The sender's own traffic is frequent enough here (snapshot every 2s,
//--- heartbeat every 1s), so this probe is not strictly required for liveness
//--- on THIS side - but it is what makes the round-trip number exist at all,
//--- and the sender needs our echo for its own panel. One mechanism, both
//--- directions, rather than each side guessing differently.
void CheckPeers()
  {
   long now=CopierNowMs();
   //--- IN CENTRAL MODE, DO NOT PROBE.
   //---
   //--- The probe exists to measure the round trip to a sender. Through the hub
   //--- that is impossible: the reply would have to travel back UP the central
   //--- channel, and the hub CONSUMES every '@' topic rather than routing it.
   //--- So the answer can never arrive.
   //---
   //--- This used to be merely useless - the probe went out as a single frame
   //--- and the hub discarded it without a trace. Once the uplink was fixed to
   //--- two frames it became ACTIVELY BAD: the probe now arrives, is counted as
   //--- control, and earns a PONG from the hub addressed to nobody useful.
   //--- Measured on a four-node hub: 2 PINGs a second of pure noise, half the
   //--- entire control rate.
   //---
   //--- The silence detection below still runs, and that is the part that
   //--- matters here - noticing a sender that has gone quiet is exactly what
   //--- the central channel is for.
   if(!g_hubOn && now-g_lastPingMs>=CP_PING_MS)
     {
      g_lastPingMs=now;
      CopierSendStatus(CP_T_PING,
                       CopierPayloadPing(now,(string)CopierAccountLogin()));
      //--- FROM names us so the sender can attribute the reply, and the
      //--- sender's own PING carries ITS account, which the Seen() at the top
      //--- of HandleMessage already records.
      //---
      //--- RECORD the probe against every peer: PongBack() only accepts an
      //--- echo matching a probe still outstanding, so without this the round
      //--- trip is never measured and the panel sits on "connected" forever
      //--- while both ends answer each other correctly.
      for(int k=0;k<CP_MAX_PEERS;k++)
        {
         string pn=g_peers.NameAt(k);
         if(StringLen(pn)>0) g_peers.ProbeSent(pn,now);
        }
     }

   //--- In Central mode, probe the Hub link directly on its own channel.
   //--- The Hub replies with PONG to @<nid>, measuring the round-trip latency.
   if(g_hubOn && now-g_lastHubPingMs>=CP_PING_MS)
     {
      g_lastHubPingMs=now;
      CopierEnv he;
      he.v=CP_PROTO_V;
      he.sid=(string)g_nid;
      he.ssid=(string)CopierAccountLogin();
      he.seq=++g_statusSeq;
      he.ts=CopierServerTime();
      he.ms=now;
      he.type=CP_T_PING;
      he.payload=CopierPayloadPing(now,(string)g_nid);
      g_tp.SendUp("@hub",CopierEncodeEnv(he));
      g_peers.ProbeSent(g_hubPeerName,now);
     }

   for(int i=0;i<CP_MAX_PEERS;i++)
     {
      string nm=g_peers.NameAt(i);
      if(StringLen(nm)==0) continue;

      long silent=g_peers.SilentAt(i);
      //--- Same three-state predicate the sender uses, so the two EAs cannot
      //--- drift apart on what "this peer is dead" means. A receiver's peers
      //--- are only created once a message arrives, so CONNECTING is rare here
      //--- - but "rare" is not "never", and the last time these two files each
      //--- carried their own copy of a liveness rule, one of them was wrong.
      int  st=g_peers.StateAt(i,CP_PEER_TIMEOUT_MS);
      bool down=(st==CP_PEER_DOWN);

      if(down && !g_peerWasDown[i])
        {
         g_peerWasDown[i]=true;
         string what=(nm==g_hubPeerName)?"hub":"sender";
         g_log.Warn(what+" "+nm+" "
                    +((silent<0)?"has NEVER been heard from"
                                :("has been silent for "
                                  +(string)(silent/1000)+"s"))
                    +" - DISCONNECTED");
         if(now-g_peerAlerted[i]>=CP_ALERT_QUIET_MS)
           {
            g_peerAlerted[i]=now;
            Alert("Copier RECEIVER: "+what+" "+nm+" DISCONNECTED ("
                  +((silent<0)?"never heard from"
                              :((string)(silent/1000)+"s silent"))
                  +"). Existing positions are kept;"
                  +" new entries stop until it returns.");
           }
        }
      else if(!down && g_peerWasDown[i])
        {
         g_peerWasDown[i]=false;
         string what=(nm==g_hubPeerName)?"hub":"sender";
         g_log.Info(what+" "+nm+" is back");
        }
     }
  }

//--- The on-chart panel: what this account is actually holding, and who it is
//--- holding it for.
void UpdatePanel()
  {
   if(!ShowPanel) return;

   //--- Counted from what is really on the account, not from the desired set:
   //--- the question the panel answers is "what do I hold", and a mirror that
   //--- has not been placed yet is not held.
   CopierPos all[];
   int an=CopierReadPositions(all,CP_MAX_POSITIONS);
   int nOpen=0,nPend=0,nOrphan=0,orphShown=0;
   string orphLine[CP_PANEL_ORPHAN_SHOW];
   for(int i=0;i<an;i++)
     {
      bool ours=false;
      for(int k=0;k<g_nSenders;k++)
        {
         if(all[i].magic==g_magic[k]) { ours=true; break; }
        }
      if(ours)
        {
         if(all[i].kind==CP_ORD_PENDING) nPend++; else nOpen++;
         continue;
        }
      //--- Not ours by magic. If it still carries OUR comment tag, it is an
      //--- orphan: real money under a magic no configured sender owns any
      //--- more. Same test as ReportOrphanedMirrors(), run against the array
      //--- this function already read - so the panel count and the startup
      //--- log line can never disagree, and no second pass over the orders
      //--- is paid for on every timer tick.
      if(StringLen(CopierUidFromComment(all[i].cmt))==0) continue;
      nOrphan++;
      if(ShowOrphanedList && orphShown<CP_PANEL_ORPHAN_SHOW)
        {
         orphLine[orphShown]="  "+all[i].sym+"  #"+(string)all[i].ticket
                             +"  magic "+(string)all[i].magic;
         orphShown++;
        }
     }

   //--- Actions queued but not yet executed: the mirrors this account still
   //--- owes the sender. Worth its own line - an empty queue and a queue that
   //--- cannot drain look identical on the position counts alone.
   int qOpen=0;
   double qLots=0.0;
   PendingOpens(qOpen,qLots);

   //--- +1 for the optional RISK row: it is only written when a switch is
   //--- tripped, and leaving it out of the count meant the spacer below it
   //--- vanished exactly when the panel had something important to say.
   int np=g_peers.Count();
   //--- The orphan block only exists when ShowOrphanedList is on. Sizing the
   //--- panel for rows that will not be written would leave a gap at the
   //--- bottom of the background - the panel would look broken rather than
   //--- simply shorter.
   int orphanRows=(ShowOrphanedList?(2+CP_PANEL_ORPHAN_SHOW):0);
   int rows=11+np+orphanRows;
   g_panel.Begin(rows);

   int r=0;
   g_panel.Row(r++,"Copier RECEIVER  -  account "
                   +(string)CopierAccountLogin(),CP_PANEL_TITLE);
   g_panel.Row(r++,"Magic "+(string)((g_nSenders>0)?g_magic[0]:0)
                   +"   "+(string)g_nSenders+" sender(s) configured",
               CP_PANEL_DIM);
   if(g_hubOn)
      g_panel.Row(r++,"Mode       CENTRAL (Hub)   NID "+(string)g_nid,
                  CP_PANEL_OK);
   else
      g_panel.Row(r++,"Mode       DIRECT",
                  CP_PANEL_DIM);
   g_panel.Row(r++,"Managing   open "+IntegerToString(nOpen)
                   +"   pending "+IntegerToString(nPend)
                   +"   total "+IntegerToString(nOpen+nPend),
               CP_PANEL_TEXT);
   g_panel.Row(r++,"Volume     "+DoubleToString(g_ourLots,2)+" lots",
               CP_PANEL_TEXT);
   //--- what the account still OWES the sender. A queue that is not draining
   //--- and a queue that is simply empty look the same in the counts above.
   //--- TWO different kinds of "not open yet", and they are not the same thing:
   //---   queued  - an action is in the queue, waiting its turn at the broker
   //---   held    - a wait gate is deliberately delaying it, so it is NOT
   //---             queued at all and the queue count alone reports zero
   //--- Reporting only the queue said "0 to open" on a receiver that was
   //--- holding ten delayed entries, which reads as "nothing pending" when the
   //--- truth was "everything is pending".
   int    waitTotal=qOpen+g_waitHeld+g_mktHeld;
   double waitLots =qLots+g_waitLots+g_mktHeldLots;
   g_panel.Row(r++,"Waiting    "+IntegerToString(waitTotal)+" to open"
                   +"   ("+IntegerToString(qOpen)+" queued, "
                   +IntegerToString(g_waitHeld)+" delayed, "
                   +IntegerToString(g_mktHeld)+" mkt closed)"
                   +((waitTotal>0)?("   "+DoubleToString(waitLots,2)+" lots"):""),
               (waitTotal>0)?CP_PANEL_WARN:CP_PANEL_DIM);
   g_panel.Row(r++,"Equity "+DoubleToString(CopierAccountEquity(),2)
                   +"   Balance "+DoubleToString(CopierAccountBalance(),2),
               CP_PANEL_TEXT);

   //--- ORPHANS. Positions carrying this copier's own comment tag but sitting
   //--- under a magic no configured sender owns any more - what a reordered
   //--- copier.ini, or a changed MagicBase, leaves behind.
   //---
   //--- They are the worst kind of leftover: the position is real money, it is
   //--- invisible to every loop in this file (all of them select on magic
   //--- first, so nothing will ever close it), and meanwhile the sender's live
   //--- position gets opened again under the new magic - so the account
   //--- quietly ends up holding BOTH.
   //---
   //--- Shown only when ShowOrphanedList is on (default OFF - see the input
   //--- note). The count is always computed and the startup log line always
   //--- fires; this switch controls the chart only.
   if(ShowOrphanedList)
     {
      //--- Reported even at zero, dimmed. A row that appears only on failure
      //--- is indistinguishable from a row that was never wired up; a zero you
      //--- can see is proof the check is running.
      g_panel.Row(r++,"Orphaned   "+IntegerToString(nOrphan)
                      +((nOrphan==1)?" position":" positions")
                      +"   (magic no longer configured)",
                  (nOrphan>0)?CP_PANEL_BAD:CP_PANEL_DIM);
      for(int i=0;i<orphShown;i++)
         g_panel.Row(r++,orphLine[i],CP_PANEL_BAD);
      if(nOrphan>orphShown)
         g_panel.Row(r++,"  ... and "+(string)(nOrphan-orphShown)+" more"
                        +" - see the Experts log",CP_PANEL_BAD);
     }

   g_panel.Row(r++,"Peers connected: "+IntegerToString(np)+((g_hubOn)?"  (incl. hub)":""),
               (np>0)?CP_PANEL_OK:CP_PANEL_BAD);

   for(int i=0;i<np && i<CP_MAX_PEERS;i++)
     {
      string nm=g_peers.NameAt(i);
      if(StringLen(nm)==0) continue;
      long silent=g_peers.SilentAt(i);
      int  st=g_peers.StateAt(i,CP_PEER_TIMEOUT_MS);
      bool down=(st==CP_PEER_DOWN);
      long rtt=g_peers.RttAt(i);

      bool isHub=(nm==g_hubPeerName);
      string line=isHub?("  HUB  "+g_hubEp+"   "):("  "+nm+"   ");
      if(st==CP_PEER_CONNECT)
         line+="connecting...";
      else if(down)
         line+="DISCONNECTED  ("
               +(string)((silent<0)?0:(silent/1000))+"s silent)";
      else if(rtt>=0)
         line+=(string)rtt+" ms round trip";
      else
         line+="connected";

      g_panel.Row(r++,line,
                  (st==CP_PEER_DOWN)?CP_PANEL_BAD
                                    :((st==CP_PEER_CONNECT)?CP_PANEL_DIM
                                                           :CP_PANEL_OK));
     }

   if(g_risk.AnyTripped())
      g_panel.Row(r++,"RISK: "+g_risk.BlockKey(),CP_PANEL_WARN);

   g_panel.Row(r++," ",CP_PANEL_TEXT);
   g_panel.End();
  }

void OnTimer()
  {
   //--- 1) drain the one socket: non-blocking, bounded per tick
   //---
   //--- Both streams arrive together and are told apart by the envelope's
   //--- T= field. The snapshot wants "keep only the newest" semantics, and
   //--- ZMQ_CONFLATE cannot provide them here because it is a PER-SOCKET
   //--- option - on a socket that also carries events it would drop trading
   //--- instructions. So the conflation is done here instead: every SNAP
   //--- except the LAST one in this batch is skipped.
   //---
   //--- That is exactly equivalent to applying them all in order. A snapshot
   //--- is a full state REPLACEMENT and not a delta, so applying S1, S2, S3
   //--- leaves precisely the state S3 alone would leave. Events keep their
   //--- position relative to the snapshot that survives, which is what makes
   //--- the ordering correct rather than merely convenient.
   //--- ONE parse loop for BOTH channels.
   //---
   //--- DrainFrames splits every message into (topic, payload), and a
   //--- single-frame message simply yields an empty topic. The direct channel
   //--- is all single-frame and the central channel is all two-frame, so the
   //--- caller never has to know which it is on - and there is no second parse
   //--- loop to drift out of step with this one.
   //---
   //--- The topics are not used here: routing is by the envelope's SID, on both
   //--- channels, because that is what the whole convergence model is built on.
   //--- The topic only ever decided DELIVERY, and ZMQ has already done that.
   string topics[],msgs[];
   int n=g_tp.DrainFrames(topics,msgs,CP_DRAIN_MAX);
   if(n>=CP_DRAIN_MAX && g_once.ShouldEmit("drainfull"))
      g_log.Warn("drain hit the per-tick bound of "+(string)CP_DRAIN_MAX
                 +" message(s) - there is more waiting, so the EA is falling"
                 +" behind. Lower SnapshotSeconds on the sender or raise"
                 +" PollMs here.");
   if(n>0)
     {
      //--- pass 1: find the last snapshot, so pass 2 can skip the rest
      CopierEnv e;
      int lastSnap=-1;
      for(int i=0;i<n;i++)
        {
         if(CopierDecodeEnv(msgs[i],e)!=CP_ERR_NONE) continue;
         if(e.type==CP_T_SNAP) lastSnap=i;
        }

      //--- pass 2: in arrival order, so an event emitted before the surviving
      //--- snapshot is still applied before it
      for(int i=0;i<n;i++)
        {
         if(CopierDecodeEnv(msgs[i],e)!=CP_ERR_NONE)
           {
            //--- malformed: let HandleMessage report it, in one place
            HandleMessage(msgs[i],CP_STREAM_EVENTS);
            continue;
           }
         if(e.type==CP_T_SNAP)
           {
            if(i!=lastSnap) { g_snapSkipped++; continue; }
            HandleMessage(msgs[i],CP_STREAM_SNAP);
            continue;
           }
         HandleMessage(msgs[i],CP_STREAM_EVENTS);
        }
     }

   //--- 1b) REG/HBT2. The hub's node table is built from these and NOTHING
   //--- else - it never probes for nodes - so this is the only reason this
   //--- receiver appears in the hub's view at all.
   //---
   //--- Sent from here rather than from a timer of its own so that exactly one
   //--- place decides when a node speaks, and it is the same place that already
   //--- knows whether the hub link is up.
   //---
   //--- The first CP_REG_REPEATS announcements are REG, not HBT2: the one sent
   //--- from OnInit can be DISCARDED, because the socket is IMMEDIATE and a
   //--- send made before the TCP connection completes is dropped. A node that
   //--- only ever heartbeats is visible but ANONYMOUS - only REG carries a
   //--- name - and that is exactly what the first live run looked like.
   if(g_hubOn && CopierNowMs()-g_lastHbt2Ms>=CP_HBT2_MS)
     {
      g_lastHbt2Ms=CopierNowMs();
      HubAnnounce(g_announceCount<CP_REG_REPEATS);
      g_announceCount++;
     }

   //--- M4b self-heal: ask the hub for a config if we still have none.
   //---
   //--- A receiver with no copier.ini mirrors NOTHING and says so at startup,
   //--- and it is supposed to wait for the hub to push one. But "wait" has to
   //--- have an end: if the push is lost, or the hub's store was empty when
   //--- this node registered, nothing else will ever make one arrive. The REG
   //--- comparison in §7.3 covers a node that is BEHIND; this covers a node
   //--- that has never been sent anything at all.
   //---
   //--- Every 30 s, and only while the config gate is on (hard-coded on
   //--- since 2026-10-14) - asking for
   //--- something you have already decided not to accept is just noise on
   //--- somebody else's log.
   if(g_hubOn && AcceptConfigPush && g_nSenders<=0
      && CopierNowMs()-g_lastCfgrMs>=30000)
     {
      g_lastCfgrMs=CopierNowMs();
      CopierSendStatus(CP_T_CFGR,"REQ=1;ROLE=receiver;ACC="
                       +(string)CopierAccountLogin()
                       +";REV="+(string)g_cfgRev);
      g_log.Info("central mode: still no config - asked the hub for one (CFGR)");
     }

   //--- 2) stale detection
   long now=CopierNowMs();
   for(int i=0;i<g_nSenders;i++)
     {
      if(g_lastMsgMs[i]==0) continue;        // never heard from it yet
      if(g_stale[i]) continue;
      int sSec=(g_senderCfg[i].staleSeconds>0)?g_senderCfg[i].staleSeconds:StaleSeconds;
      if(now-g_lastMsgMs[i]>(long)sSec*1000)
        {
         g_stale[i]=true;
         g_log.Error("sender "+g_sid[i]+" silent for >"+(string)sSec
                     +"s: new entries stopped, existing positions kept");
        }
     }

   //--- 3) hearing the sender but never getting a usable snapshot?
   for(int i=0;i<g_nSenders;i++)
     {
      if(g_ready[i]) continue;                        // has snapshots
      if(g_lastSnapMs[i]!=0) continue;                // had one, resyncing
      if(g_firstMsgMs[i]==0) continue;                // nothing heard yet
      int sSec=(g_senderCfg[i].staleSeconds>0)?g_senderCfg[i].staleSeconds:StaleSeconds;
      if(now-g_lastMsgMs[i]>(long)sSec*1000) continue;  // covered
      if(now-g_firstMsgMs[i]<10000) continue;         // give it 10s
      if(g_onceNoSnap.ShouldEmit("nosnap|"+g_sid[i]))
         g_log.Error("sender "+g_sid[i]+" is sending events but NO usable"
                     +" SNAPSHOT has arrived - the receiver will not act at"
                     +" all until one does. Check the snap port is reachable,"
                     +" and that nothing is corrupting the snapshot stream"
                     +" (tools/zmq_sniff.py shows what is on the wire).");
     }

   //--- CENTRAL MODE: subscribed, and NOTHING has ever arrived.
   //---
   //--- This is THE failure mode of the hub topology, and without this check it
   //--- is completely silent. The receiver connects, subscribes to every topic
   //--- it was told to, logs that it did, and then sits there looking healthy.
   //--- Nothing errors, because A SUBSCRIPTION THAT MATCHES NOTHING IS NOT AN
   //--- ERROR - ZMQ has no idea you meant something else.
   //---
   //--- The cause is nearly always an ini `id=` that is not the SENDER'S NID:
   //--- the old name or port left in place, which is exactly what an existing
   //--- copier.ini already contains. The topic is the NID, so the subscription
   //--- is to a topic no sender ever publishes on.
   //---
   //--- The check above cannot catch it: that one requires g_firstMsgMs[i]>0,
   //--- i.e. that SOMETHING arrived. Here nothing ever does.
   if(g_hubOn && g_nSenders>0)
     {
      bool anyEver=false;
      for(int i=0;i<g_nSenders;i++)
         if(g_firstMsgMs[i]>0) { anyEver=true; break; }
      if(!anyEver && now-g_hubUpMs>30000 && g_onceNoSnap.ShouldEmit("hubnodata"))
        {
         string ids="";
         for(int i=0;i<g_nSenders;i++)
           {
            if(i>0) ids+=", ";
            ids+=g_sid[i];
           }
         g_log.Error("central mode: subscribed to "+IntegerToString(g_nSenders)
                     +" sender(s) but NOTHING has arrived in 30s. The usual"
                     +" cause is an ini id= that is not the SENDER'S NID."
                     +" Each sender prints its NID in its own startup line as"
                     +" nid=<number>, and THAT NUMBER is the topic - not its old"
                     +" name and not its port. Currently subscribing to: "+ids
                     +". (A subscription that matches nothing is not an error,"
                     +" which is why this is the only place it shows up.)");
        }
     }

   //--- 4) persist the UID <-> identifier map (tiny; every 10 s is plenty and
   //--- keeps the comment-overwritten case recoverable across a restart).
   //---
   //--- No ignore-list refresh here any more. That list is an INPUT now, and
   //--- changing an input re-runs OnInit, which re-parses it - so the polling
   //--- and the file it polled are both gone.
   if(now-g_lastMapSave>10000)
     {
      g_lastMapSave=now;
      SaveReceiverMap();
     }

   //--- 4b) refresh the risk view BEFORE converge, so every sender's opens
   //--- this tick gate against the same exposure numbers
   RefreshRisk();
   if(g_risk.TakeJustTripped())
     {
      //--- ERROR, not a warning: this is the one event that means the
      //--- receiver has deliberately stopped doing its job. The message
      //--- carries the equity, the baseline and the level it tripped at,
      //--- because "down 5%" does not tell anyone where the line is.
      g_log.Error("RISK SWITCH TRIPPED - "+g_risk.TripReason());
      //--- start the hourly clock now, so the repeat line does not land
      //--- immediately on top of this one
      g_lastRiskReport=CopierNowMs();
      if(RiskCloseAllOnTrip) RiskCloseEverything();
     }

   //--- 5) converge every sender, then execute queued actions serially
   //--- reset the held-back tally: it is a per-sweep snapshot, not a running
   //--- total, so an entry that starts moving must stop being counted
   g_waitHeld=0;
   g_waitLots=0.0;
   g_mktHeld=0;
   g_mktHeldLots=0.0;
   ClearWaitItems();

   //--- feed liveness, measured on the clock that ALWAYS moves. See the note
   //--- on g_srvChangedMs: the server clock stopping is the signal, and
   //--- GetTickCount() is the only clock that can detect it.
   {
    long st=CopierServerTime();
    if(st!=g_srvSeenTime)
      {
       g_srvSeenTime=st;
       g_srvChangedMs=now;
       g_srvEverMoved=true;
      }
   }
   for(int i=0;i<g_nSenders;i++) ConvergeSender(i);
   ExecuteQueue();

   //--- 4) report discarded messages once a minute.
   //---
   //--- A non-zero count here is the difference between "the sender sent
   //--- nothing" and "we threw it away", which is exactly the question that
   //--- was unanswerable while the MT4 receiver sat idle for 90 seconds
   //--- with no line in its log explaining why.
   if(now-g_lastDropReport>=60000)
     {
      g_lastDropReport=now;
      for(int i=0;i<g_nSenders;i++)
        {
         if(g_dropped[i]==0) continue;
         g_log.Warn("sender "+g_sid[i]+" "+(string)g_dropped[i]
                    +" message(s) discarded by the sequence guard since the"
                    +" last report (duplicate or reordered)");
         g_dropped[i]=0;
        }
      //--- Superseded snapshots are the conflation working, not a problem,
      //--- so this is INFO and only when it actually happened. It is worth
      //--- reporting because it is the only visible sign that the drain-loop
      //--- conflation is doing anything at all - without it, "one socket
      //--- carrying both streams" and "the snapshot was silently lost" look
      //--- identical from the outside.
      //--- ONCE AN HOUR, not once a minute. This is routine housekeeping and
      //--- it is true almost continuously, so a per-minute line filled the
      //--- log with a fact nobody needs - the exact unbounded-noise failure
      //--- this codebase exists to avoid, reached from the "it's only INFO"
      //--- direction.
      //---
      //--- The counter is NOT reset while suppressed, so the hourly line
      //--- reports the true total since the last report rather than the last
      //--- minute's share.
      if(g_snapSkipped>0 && g_onceHour.ShouldEmit("superseded"))
        {
         g_log.Info((string)g_snapSkipped+" superseded snapshot(s) collapsed"
                    +" in the drain since the last report (only the newest of"
                    +" each batch is applied)");
         g_snapSkipped=0;
        }

      //--- Same treatment for a full action queue: count it, report the total
      //--- once a minute. Deferred actions are re-derived from the next
      //--- snapshot, so this is a throughput observation, not lost work.
      if(g_qDeferred>0)
        {
         g_log.Warn((string)g_qDeferred+" action(s) deferred by a full queue"
                    +" since the last report - they are re-derived from the"
                    +" next snapshot, so nothing is lost, but a sustained"
                    +" count means MaxActionsPerTick is pacing below the"
                    +" sender's activity");
         g_qDeferred=0;
        }
      //--- While a switch is tripped the receiver is DELIBERATELY doing
      //--- nothing, so it must say so - but see the hourly gate below, not
      //--- here: a steady state does not need a per-minute line.
     }

   //--- The risk status on its own, slower clock. Without it, "blocked by
   //--- risk" and "silently broken" are the same log; with it, the line
   //--- appears once an hour and never floods.
   if(g_risk.AnyTripped() && now-g_lastRiskReport>=CP_RISK_REPORT_MS)
     {
      g_lastRiskReport=now;
      g_log.Warn("still blocked by risk - "+g_risk.TripReason()
                 +". Holding "+DoubleToString(g_ourLots,2)+" lots across "
                 +(string)g_ourCount+" position(s)");
     }

   //--- STAT channel. TWO independent cadences share this message:
   //---
   //---  * MONITORING - the equity/lots/risk figures. Once a minute, and only
   //---    when StatusEnabled. Nothing acts on it, so it can be late or lost.
   //---
   //---  * SNAPSHOT RECEIPT - the hash of the last snapshot we ingested, so
   //---    the sender knows whether to re-send to us alone. Governed by
   //---    SyncHeartbeatSeconds, and NOT by StatusEnabled, because it is part
   //---    of the delivery path rather than a report about it.
   //---
   //--- ONE MESSAGE PER SENDER, not one message listing all of them. This
   //--- receiver may mirror several senders and each has its own hash; the
   //--- sender that reads a message must be able to tell whether the receipt
   //--- is about IT. The SID field carries that, and a sender ignores a
   //--- receipt that is not addressed to its own id.
   //---
   //--- The position summary (HELD/LOTS/ORPHAN) shares the SyncHeartbeatSeconds
   //--- cadence - default 1s - so the dashboard can show fresh receiver counts
   //--- without waiting for the slower monitoring report. It is included only
   //--- once per batch, regardless of how many senders are configured.
   //---
   //--- The other monitoring figures (equity/balance/risk) still go out once a
   //--- minute, and only when StatusEnabled. Nothing acts on them, so they can
   //--- be late or lost.
   //---
   //--- The stop-override table is pruned on the same slow cadence as the
   //--- status report: often enough that it never grows past the positions
   //--- actually in play, rarely enough that the sweep costs nothing.
   if(now-g_lastPruneMs>=60000)
     {
      g_lastPruneMs=now;
      StopsPrune(CopierNowMs());
     }

   bool dueStatus =(StatusEnabled && now-g_lastStatusMs>=60000);
   bool dueSync   =(SyncHeartbeatSeconds>0
                    && now-g_lastSyncMs>=(long)SyncHeartbeatSeconds*1000);
   bool dueSummary=(g_forcePosReport || (g_lastSummaryMs==0) || (now-g_lastSummaryMs>=5000));
   bool dueDetail =(g_hubOn && (g_forcePosReport || (g_lastPosDetailMs==0) || (now-g_lastPosDetailMs>=60000)));

   if(dueStatus || dueSync || dueSummary || g_forcePosReport)
     {
      if(dueStatus) g_lastStatusMs=now;
      if(dueSync || g_forcePosReport) g_lastSyncMs=now;
      if(dueSummary) g_lastSummaryMs=now;
      if(dueDetail) g_lastPosDetailMs=now;

      bool putPositionSummary=(dueSummary || dueStatus || g_forcePosReport);
      bool putFigures=dueStatus;
      for(int i=0;i<g_nSenders;i++)
        {
         //--- a receipt is only meaningful for a sender we have actually
         //--- received a snapshot from; "" says "no receipt yet" and is the
         //--- honest answer, not a wrong hash.
         string st="LOGIN="+(string)CopierAccountLogin()
                   +CP_SEP_KV+"SID="+g_sid[i]
                   +CP_SEP_KV+"H="+g_snapHash[i];
         if(putPositionSummary)
           {
            int qOpen=0;
            double qLots=0.0;
            PendingOpens(qOpen,qLots);
            int waitTotal=qOpen+g_waitHeld+g_mktHeld;
            double waitLots=qLots+g_waitLots+g_mktHeldLots;

            st+=CP_SEP_KV+"HELD="+(string)g_ourCount
               +CP_SEP_KV+"LOTS="+DoubleToString(g_ourLots,2)
               +CP_SEP_KV+"ORPHAN="+(string)g_orphanCount
               +CP_SEP_KV+"WAIT="+(string)waitTotal
               +CP_SEP_KV+"WLOTS="+DoubleToString(waitLots,2)
               +CP_SEP_KV+"WQUEUED="+(string)qOpen
               +CP_SEP_KV+"WDELAYED="+(string)g_waitHeld
               +CP_SEP_KV+"WMKT="+(string)g_mktHeld
               +CP_SEP_KV+"EQ="+DoubleToString(CopierAccountEquity(),2)
               +CP_SEP_KV+"BL="+DoubleToString(CopierAccountBalance(),2);

            //--- Detailed position & waiting item lists are transmitted once a minute
            //--- or on-demand when requested by WebUI (g_forcePosReport) in Hub mode
            if(dueDetail && g_hubOn)
              {
               string posEnc=EncodeReceiverPositions();
               string waitEnc=EncodeReceiverWaitList();
               st+=CP_SEP_KV+"POS="+posEnc
                  +CP_SEP_KV+"WAITLIST="+waitEnc;
              }

            putPositionSummary=false;  // once per batch, not per sender
           }
         if(putFigures)
           {
            st+=CP_SEP_KV+"EQ="+DoubleToString(CopierAccountEquity(),2)
               +CP_SEP_KV+"BL="+DoubleToString(CopierAccountBalance(),2)
               +CP_SEP_KV+"NSEND="+(string)g_nSenders
               +CP_SEP_KV+"BLOCKED="+(string)g_riskBlocked
               +CP_SEP_KV+"RISK="+(g_risk.AnyTripped()?g_risk.BlockKey():"ok");
            putFigures=false;            // once per batch, not per sender
           }
         CopierSendStatus(CP_T_STAT,st);
        }
      if(dueStatus) g_riskBlocked=0;     // reported; start the next window
      if(dueDetail) g_forcePosReport=false;
     }

   //--- peers and the panel, last so the figures shown are this pass's
   CheckPeers();
   UpdatePanel();

   g_log.Tick();
  }
//+------------------------------------------------------------------+
