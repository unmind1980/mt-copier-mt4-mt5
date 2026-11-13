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

#import "winmm.dll"
int timeBeginPeriod(uint uPeriod);
int timeEndPeriod(uint uPeriod);
#import

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
#include <Copier/CopierPump.mqh>
#include <Copier/CopierCluster.mqh>

CopierEventPump g_pump;
//--- V3/C4: PONGs still outstanding for the current probe burst. A dual-hub PING
//--- is dual-sent, so both hubs answer; disarming on the first echo pushed the
//--- second one onto the slow timer and inflated its reported RTT. Bounded by
//--- CP_PUMP_BURST_MAX / CP_PUMP_TIMEOUT_MS, so a dead peer cannot wedge it.
int g_pumpPongExpect=0;

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
input string InpMagic        = "";            // InpMagic - blank=Auto (uses SenderPort)

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
   LOT_FIXED      = CP_SIZE_FIXED,        // Fixed - always SenderLotParam
   LOT_EQUITY_RATIO = CP_SIZE_EQUITY_RATIO // Equity Ratio - scaled by account equity
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
input int    InpMarketOpenDelayMinutes    = 5;     // OpenDelayMinutes - open warmup delay (0=off, min)
int          MarketOpenDelayMinutes       = 5;
input int    InpMarketOpenCloseMaxWaitSec = 120;   // CloseMaxWaitSec - max spread wait on close (sec)
int          MarketOpenCloseMaxWaitSec    = 120;
input double InpMaxSpreadMultiplier       = 2.5;   // MaxSpreadMultiplier - wide spread threshold multiplier
double       MaxSpreadMultiplier          = 2.5;

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
input double InpPendingFillGraceSeconds          = 1.5; // PendingFillGraceSec - wait local fill, 0=cancel
double       PendingFillGraceSeconds             = 1.5;

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
input int    InpPollMs               = 5;     // PollMs - timer interval in milliseconds
int          PollMs                  = 5;
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
   double              pendingfillgraceseconds;
  };

CopierSenderSettings g_senderCfg[CP_MAX_SENDERS];
CopierRisk           g_senderRisk[CP_MAX_SENDERS];
CopierList           g_senderPermitted[CP_MAX_SENDERS];
CopierList           g_senderPermittedMagic[CP_MAX_SENDERS];
CopierTradingTimes   g_senderHours[CP_MAX_SENDERS];
CopierIgnore         g_senderIgnore[CP_MAX_SENDERS];

string  g_sid[CP_MAX_SENDERS];
string  g_epEvents[CP_MAX_SENDERS];
string  g_serverKey[CP_MAX_SENDERS];
//--- This receiver's OWN public key, loaded from the key file at startup and
//--- never typed - see CopierCurveKey.mqh. Kept in a global so the log line
//--- and the socket setup use the SAME string; deriving it twice would be
//--- harmless today and a trap the moment anything about it changes.
string  g_myPublicKey="";
string  g_suffix[CP_MAX_SENDERS];
long    g_magic[CP_MAX_SENDERS];
int     g_lotMode[CP_MAX_SENDERS];
double  g_lotParam[CP_MAX_SENDERS];
double  g_senderEquity[CP_MAX_SENDERS];
string  g_senderCurrency[CP_MAX_SENDERS];
long    g_lastSeqGlobal[CP_MAX_SENDERS];
//--- One sequence watermark PER STREAM, not per sender.
//---
//--- The sender numbers both sockets from a single counter, and the
//--- receiver drains snapshots BEFORE events each tick. With one shared
//--- watermark, a snapshot at seq 115 processed first silently invalidated
//--- every buffered event at seq <= 115 - so after any pause the receiver
//--- threw away the entire event backlog and converged from the snapshot
//--- alone. That is why a stalled receiver came back and opened eight
//--- positions at once instead of following them as they happened.
//--- [0] = events stream, [1] = snapshot stream, [2] = heartbeat stream.
long    g_lastSeq[CP_MAX_SENDERS][CP_STREAM_COUNT];
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
bool    g_senderClockOffsetValid[CP_MAX_SENDERS];
string  g_ssidSeen[CP_MAX_SENDERS];
//--- N71-03: Track recently abandoned SSIDs per sender to ignore delayed frames from dead sessions
#define CP_OLD_SSID_MAX 4
string  g_ssidOld[CP_MAX_SENDERS][CP_OLD_SSID_MAX];
int     g_ssidOldHead[CP_MAX_SENDERS];

bool IsAbandonedSsid(const int si,const string ssid)
  {
   if(si<0 || si>=CP_MAX_SENDERS || StringLen(ssid)==0) return false;
   for(int k=0;k<CP_OLD_SSID_MAX;k++)
     {
      if(g_ssidOld[si][k]==ssid) return true;
     }
   return false;
  }

void RecordAbandonedSsid(const int si,const string ssid)
  {
   if(si<0 || si>=CP_MAX_SENDERS || StringLen(ssid)==0) return;
   int slot=g_ssidOldHead[si]%CP_OLD_SSID_MAX;
   g_ssidOld[si][slot]=ssid;
   g_ssidOldHead[si]=(g_ssidOldHead[si]+1)%CP_OLD_SSID_MAX;
  }

void ClearAbandonedSsids(const int si)
  {
   if(si<0 || si>=CP_MAX_SENDERS) return;
   for(int k=0;k<CP_OLD_SSID_MAX;k++) g_ssidOld[si][k]="";
   g_ssidOldHead[si]=0;
  }
long    g_lastMsgMs[CP_MAX_SENDERS];
long    g_firstMsgMs[CP_MAX_SENDERS];   // first message ever heard
long    g_lastSnapMs[CP_MAX_SENDERS];   // last ACCEPTED snapshot
//--- Consecutive snapshots REJECTED by the declared-vs-decoded guard.
//---
//--- Reset the moment one is accepted, so the number answers "how long has
//--- this sender been sending unusable snapshots" rather than "how many have
//--- I ever rejected" - and the count is what turns a silent standstill into
//--- something a human can tell is still going on. See HandleSnapshot.
int     g_snapRejectStreak[CP_MAX_SENDERS];
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
//--- N-04: sized to the POSITION table, not to 512. Every UID that ever carried
//--- a stop change is pinned in this table for as long as the position lives
//--- (`StopsPrune` keeps `g_stHasOv` entries whose UID is still desired), so
//--- 512 was a hard ceiling on "positions that can receive live stop events".
//--- A 513th UID used to have its MODIFY dropped outright and wait for the next
//--- snapshot (up to SnapshotSeconds). The index below (CP_UIDIDX_SLOTS 4096)
//--- is sized for exactly this many entries at 50% load.
#define CP_MAX_STOPS_OV CP_MAX_POSITIONS
string  g_stUid[CP_MAX_STOPS_OV];
bool    g_stHasOv[CP_MAX_STOPS_OV];
double  g_stOvSl[CP_MAX_STOPS_OV];
double  g_stOvTp[CP_MAX_STOPS_OV];
double  g_stOvOpn[CP_MAX_STOPS_OV];
double  g_stOvPprice[CP_MAX_STOPS_OV]; // BUG-02: Pending price override table
double  g_stOvPstop[CP_MAX_STOPS_OV];  // BUG-05: Real-time StopLimit limit price override table
long    g_stOvPexp[CP_MAX_STOPS_OV];   // BUG-05: Real-time pending expiration override table
long    g_stLastMs[CP_MAX_STOPS_OV];
int     g_stCount=0;
//--- Bumped on every change to the override table. QueueModifyIfNeeded() caches
//--- "this position's stop geometry was already computed and nothing that
//--- feeds it has moved", and the override table is one of those inputs, so a
//--- MODIFY event (or the snapshot catching up with one) has to invalidate it.
long    g_stOvEpoch=1;
CopierUidIndex g_stUidIdx; // N70-02: O(1) hash index for g_stUid table

void StopsRebuildUidIndex()
  {
   if(g_stCount>0)
      g_stUidIdx.BuildFromStrings(g_stUid,g_stCount);
   else
      g_stUidIdx.Clear();
  }

//--- Last (ticket -> inputs) seen by QueueModifyIfNeeded, so the per-tick
//--- recomputation can be skipped when nothing changed.
//---
//--- That function runs once per mirrored position per 100 ms tick and is the
//--- most expensive thing in the converge pass: symbol info, the override
//--- table scan, four stop-geometry conversions and two broker-price reads -
//--- all to conclude "no change" on essentially every tick. A direct-mapped
//--- cache keyed on the ticket, with every input compared exactly, keeps the
//--- conclusion and skips the work.
#define CP_STOPSIG_SLOTS 2048
struct CopierStopSig
  {
   long              ticket;
   long              epoch;
   double            v[13]; // BUG-03: Expanded to 13 fields (including local.kind and local.openPx)
  };
CopierStopSig g_stopSig[CP_STOPSIG_SLOTS];
//--- A tripped risk switch is a STEADY STATE, not an event: the receiver is
//--- deliberately doing nothing and will keep doing it. Once an hour is
//--- plenty to notice that in a log; once a minute is 1440 lines a day.
#define CP_RISK_REPORT_MS (60*60*1000)
int     g_snapSkipped=0;             // superseded snapshots collapsed in the drain
int     g_snapDeclFailed=0;          // snapshots rejected due to invalid N= declaration
int     g_qDeferred=0;               // actions deferred by a full queue
//--- N-10: WHY the last PushAction() refused, for the caller that has to answer
//--- with an ACK. The function has seven distinct refusal paths (seen ring,
//--- in-flight, two backoffs, unsupported, already queued, queue full) and the
//--- command ACK used to report every one of them as "queue_full" - so a
//--- duplicate click or a 1-second CLOSE backoff looked like a full queue to
//--- the hub's audit and to the operator.
string  g_pushReject="";
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
bool    g_forceCfgReport=false;      // hub asked for the current config (reqcfg)
long    g_lastPruneMs=0;             // stop-override table sweep
long    g_statusSeq=0;
int     g_riskBlocked=0;             // entries refused by a risk switch since the last STAT
long    g_lastMapSave=0;
bool    g_mapDirty=false;      // an executed action changed what must persist
//--- Last time the idempotency rings were swept. See the note in OnTimer.
long    g_lastSeenPrune=0;
bool    g_stateSaveOk=false;   // announced the identity store once per session
//--- Did OnInit restore a state file? Its UIDs are seeded into g_everOpened,
//--- which is exactly the set the slow-path backfill would otherwise rebuild -
//--- and that backfill costs a 4096-slot ring scan per row, over every row,
//--- on every 30-second revalidation.
bool    g_stateRestored=false;
int     g_nSenders=0;

//--- Direct-mapped magic -> sender index (slot+1, 0 = not cached, -1 = known
//--- miss). Every account scan used to answer "which sender owns this order"
//--- with a linear pass over all senders, for every order, ten times a second:
//--- 100 positions x 100 senders is 10,000 compares a tick. Verified by
//--- comparing g_magic[idx], so a stale or colliding entry falls back to the
//--- scan instead of returning a wrong sender.
#define CP_MAGIC_LOOKUP 256
int     g_magicLookup[CP_MAGIC_LOOKUP];
long    g_magicLookupTag[CP_MAGIC_LOOKUP];

int MagicToSender(const long magic)
  {
   int h=(int)(magic&(CP_MAGIC_LOOKUP-1));
   if(h<0 || h>=CP_MAGIC_LOOKUP) h=0;
   // A86-01: Verify full 64-bit magic tag on lookup cache hit to prevent hash bucket collision
   if(g_magicLookupTag[h]==magic)
     {
      int c=g_magicLookup[h];
      if(c>0 && c<=g_nSenders && g_magic[c-1]==magic) return c-1;
      if(c<0) return -1;                     // verified cached miss for this exact magic
     }
   for(int k=0;k<g_nSenders;k++)
     {
      if(g_magic[k]!=magic) continue;
      g_magicLookup[h]=k+1;
      g_magicLookupTag[h]=magic;
      return k;
     }
   g_magicLookup[h]=-1;
   g_magicLookupTag[h]=magic;
   return -1;
  }

void MagicLookupClear()
  {
   ArrayInitialize(g_magicLookup,0);
   ArrayInitialize(g_magicLookupTag,0);
  }


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

#define CP_MAX_WAIT_ITEMS 128
CopierWaitItem g_waitItems[CP_MAX_WAIT_ITEMS];
int            g_waitItemsCount=0;

// MQL-02: Per-sender wait telemetry buckets to prevent fast-track clearing of other senders' telemetry
int            g_senderWaitHeld[CP_MAX_SENDERS];
double         g_senderWaitLots[CP_MAX_SENDERS];
int            g_senderMktHeld[CP_MAX_SENDERS];
double         g_senderMktHeldLots[CP_MAX_SENDERS];

// MQL-01: Safe sender label accessor preventing negative array index out of bounds
string SenderLabel(const int si)
  {
   if(si>=0 && si<CP_MAX_SENDERS && si<g_nSenders && StringLen(g_sid[si])>0)
      return g_sid[si];
   return "manual";
  }

//--- L2: is this LOCAL ticket still working on this account?
//--- Used by the manual-closed GC, which must not evict an ignore entry while
//--- the position it protects is still open (that is exactly the window in
//--- which the mirror would be re-created).
bool LocalTicketStillOpen(const long ticket)
  {
   if(ticket<=0) return false;
   long resolvedTkt=0;
   bool isPending=false;
   return CopierResolveCloseTicket(ticket, resolvedTkt, isPending);
  }

//--- Pre-allocated scratch buffer for LocalForSender / ConvergeSender (zero ArrayResize)
CopierPos      g_locScratch[CP_MAX_POSITIONS];

void ClearWaitItems(const int si=-1)
  {
   if(si<0)
     {
      //--- O4: release the string fields of every slot we are about to orphan,
      //--- in addition to lowering the count. CopierWaitItem holds four strings;
      //--- dropping only the count kept all of them referenced until the slot
      //--- was overwritten (which, for a table that is allocated once, is never).
      for(int i=0;i<g_waitItemsCount;i++)
        {
         g_waitItems[i].uid="";
         g_waitItems[i].sym="";
         g_waitItems[i].stage="";
         g_waitItems[i].reason="";
        }
      g_waitItemsCount=0;
      return;
     }
   if(si>=g_nSenders) return;
   long targetMagic=g_magic[si];
   int oldCount=g_waitItemsCount;
   int w=0;
   for(int i=0;i<oldCount;i++)
     {
      if(g_waitItems[i].magic==targetMagic) continue; // remove only this sender's items
      if(w!=i) g_waitItems[w]=g_waitItems[i];
      w++;
     }
   //--- O4: clear the vacated tail so the removed rows stop pinning strings
   for(int k=w;k<oldCount;k++)
     {
      g_waitItems[k].uid="";
      g_waitItems[k].sym="";
      g_waitItems[k].stage="";
      g_waitItems[k].reason="";
     }
   g_waitItemsCount=w;
  }

void RecomputeWaitTotals()
  {
   g_waitHeld=0;
   g_waitLots=0.0;
   g_mktHeld=0;
   g_mktHeldLots=0.0;
   for(int s=0;s<g_nSenders;s++)
     {
      g_waitHeld+=g_senderWaitHeld[s];
      g_waitLots+=g_senderWaitLots[s];
      g_mktHeld+=g_senderMktHeld[s];
      g_mktHeldLots+=g_senderMktHeldLots[s];
     }
  }

void AddWaitItem(const string uid,const string sym,const int side,const double lots,const double openPx,const long magic,const string stage,const string reason)
  {
   if(g_waitItemsCount>=CP_MAX_WAIT_ITEMS) return;
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
#define CP_MAX_TOTAL_MAPS (CP_MAX_SENDERS*CP_MAX_SYMBOL_MAP)
string  g_mapFrom[CP_MAX_TOTAL_MAPS];
string  g_mapTo[CP_MAX_TOTAL_MAPS];
int     g_mapSender[CP_MAX_TOTAL_MAPS];
double  g_mapMult[CP_MAX_TOTAL_MAPS];
int     g_nMap=0;

//--- desired-position sets: nSenders * CP_MAX_POSITIONS --------------
CopierPos g_desired[];
int       g_desiredCount[CP_MAX_SENDERS];
CopierPos g_scratch[];        // decode buffer, allocated once

//--- action queue ---------------------------------------------------
//--- CP_ACT_* kinds, struct CopierAction and the "does the seen-ring apply?" rule live in
//--- CopierDefs.mqh so the self-test can reach them.
//--- The action queue is a FIXED array with a moving head, not a shifting one.
//---
//--- It used to be contiguous from index 0 and ShiftQueue() moved the whole
//--- live region down by one struct per executed action. CopierAction carries
//--- four strings (uid, sym, key, and the key's suffix), so at the 256-entry
//--- bound that was ~256 struct assignments per action - several thousand per
//--- tick while a burst drains, all of it spent moving data that does not
//--- change. Advancing g_qHead is one integer increment.
//---
//--- Live entries are ALWAYS g_q[g_qHead .. g_qHead+g_qn-1]. Never index g_q
//--- directly: use g_q[g_qHead+i]. When the tail reaches the end of the array
//--- the live region is slid back to 0 by CompactQueue(), which costs one
//--- O(n) pass per CP_MAX_ACTIONS/2 dequeues instead of one per dequeue.
CopierAction g_q[CP_MAX_ACTIONS];
int    g_qHead=0;      // index of the OLDEST live action
int    g_qn=0;         // number of live actions, contiguous from g_qHead

//--- P1: a drain pass that makes NO progress must not be repeated every tick.
//---
//--- The queue loop is bounded by `skipped<=g_qn`, i.e. by the WHOLE queue, so a
//--- queue in which every action is held (market shut) is walked end to end on
//--- every timer tick - 200 times a second, all weekend, re-deriving the same
//--- answer. Each pass costs a per-symbol freshness evaluation per action.
//--- Measured on a 4-core VPS: 100 held actions = ~6% of one core, continuously,
//--- for nothing.
//---
//--- So a zero-progress pass arms a retry deadline. The periodic drain checks it;
//--- the event-driven drains (a trade event arrived, a snapshot changed the
//--- desired set) never do, and PushAction() clears it outright, because those
//--- are exactly the moments the answer can change.
long   g_qRetryAtMs=0;      // periodic drain may run again at this monotonic ms
long   g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
int    g_qSpinPasses=0;     // consecutive zero-progress passes, for the panel

//--- P3: ONE cadence for the account scan and the reconcile.
//---
//--- `ConvergeSender` re-derives "desired minus actual" from scratch and, to do
//--- it, walks the whole account position list once per sender. It was called on
//--- EVERY timer tick (PollMs, 5 ms), i.e. 200 times a second, to catch snapshots
//--- that arrive every 15 seconds - and `RefreshRisk`, which scans the account
//--- once, ran on the same tick because converge consumes its output.
//---
//--- Both now run when something can have changed (a snapshot landed, a trade
//--- event arrived, an action executed, the config was reloaded) plus on a slow
//--- sweep. The sweep is the SAFETY NET, not an optimisation: if a hook is ever
//--- missed, the next sweep re-derives everything from scratch, so the worst case
//--- is a delay - never a divergence.
//---
//--- 0 restores the old every-tick behaviour. Deliberately NOT an ini key: the
//--- ini is a protocol artifact synced by the hub, and this is a local pacing
//--- decision.
input int InpConvergeSweepMs = 250;   // ConvergeSweepMs - 0 = reconcile every tick (legacy)
int    g_convergeSweepMs=250;
long   g_lastConvergeSweepMs=0;
bool   g_convergeDirty[CP_MAX_SENDERS];
bool   g_convergeDirtyAll=true;       // first tick must converge

//--- Per-pass verdict caches: one for "this symbol's feed is stale", one for
//--- "this symbol is inside its trading session". Reset at the top of each pass.
CopierSymVerdictCache g_staleVerdict;
CopierSymVerdictCache g_sessVerdict;

//--- Cached wrappers. The cache key carries the SELECTOR (the stall threshold),
//--- so a future caller with a different threshold cannot read another one's
//--- verdict. A miss falls through to the real predicate.
bool SymStaleCached(const string sym)
  {
   bool v=false;
   if(g_staleVerdict.Get(sym,CP_SYM_STALL_MS,v)) return v;
   v=CopierSymbolFeedStale(sym,CP_SYM_STALL_MS);
   g_staleVerdict.Put(sym,CP_SYM_STALL_MS,v);
   return v;
  }

bool SymInSessionCached(const string sym)
  {
   bool v=false;
   if(g_sessVerdict.Get(sym,0,v)) return v;
   v=CopierInTradingSession(sym);
   g_sessVerdict.Put(sym,0,v);
   return v;
  }
long   g_gateCalls=0;       // per-symbol freshness evaluations (diagnostic)

CopierTransport g_tp;
CopierLog       g_log;
CopierSeenRing  g_seen;

//--- Receive buffers for the per-tick drain, allocated ONCE.
//---
//--- These used to be `string topics[],msgs[]` declared inside the tick: the
//--- transport resized them to CP_DRAIN_MAX and shrank them back on every
//--- pass, so a 10 Hz loop did 20 heap operations a second to hold two or
//--- three frames. As file-level arrays the transport takes the static path
//--- (no ArrayResize at all) and only the first `n` entries are ever read -
//--- the count returned by DrainFrames is the ONLY valid length, never
//--- ArraySize().
string          g_drainTopics[CP_DRAIN_MAX];
string          g_drainMsgs[CP_DRAIN_MAX];
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
long            SenderTimeToOurs(const int si,const long senderTime);
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
string          g_connectedEps[CP_MAX_CLUSTER_HUBS];
int             g_connectedEpCount=0;
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
int             g_hbtSinceReg=0;        // N-06: heartbeats since the last maintenance REG
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
bool            g_cmdCloseAllActive=false; // true while closeall is actively queueing/draining
string          g_cmdCloseAllId="";     // command ID for active closeall
bool            g_riskCloseAllPending=false; // true while risk close-all is queueing/draining
CopierSeenRing  g_inflight;             // NH-04: in-flight 1s suppression for asyncMode
CopierAction    g_sweepFailed[CP_MAX_ACTIONS]; // NM-11: file-global sweep array
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
string           g_singleHubRole="hub:primary"; // P1-4: auto-adapted role in single endpoint mode
long             g_lastHubPingMs=0;
long             g_lastPingMs=0;
//--- Edge-triggered: see the note on the sender's copy. A repeating popup
//--- teaches people to dismiss the channel without reading it.
bool             g_peerWasDown[CP_MAX_PEERS];
long             g_peerAlerted[CP_MAX_PEERS];   // when we last popped up
string           g_lastTrackedName[CP_MAX_PEERS];// names last bound to each slot
//--- The account number each sender reported, so the panel can name it even
//--- before the first heartbeat arrives.
string           g_senderAcc[CP_MAX_SENDERS];
#define CP_PEER_TIMEOUT_MS 15000
#define CP_PING_MS          5000
//--- One popup per outage: see the note on the sender's copy.
#define CP_ALERT_QUIET_MS  (5*60*1000)
CopierTradingTimes g_hours;  // IncludeTradingTimes / DayTradingTimes, server time
CopierSeenRing  g_fillDropped; // UIDs given up on - sticky, so it is not
                               // re-derived and re-alerted every pass
CopierManualClosedRing g_manualClosed; // Manually closed positions by operator; prevents converge from re-opening
//--- L2: how long a ticket-keyed ignore entry survives when the position is
//--- still open locally. It exists to stop the mirror being re-created right
//--- after the operator closed it; once the sender has also dropped it the
//--- desired-set check collects the entry long before this expires. The TTL is
//--- only the backstop for entries whose broker comment was mangled and which
//--- therefore have no UID to match on.
#define CP_MANUAL_CLOSED_TTL_MS (15*60*1000)
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
//--- The same split, restricted to the positions this copier owns (magic
//--- matches a configured sender). The panel asks "what am I managing", and
//--- an unrelated EA's position is not part of the answer - the account-wide
//--- numbers above are what the broker's order limit is measured against.
int             g_ourPositions=0;
int             g_ourPending=0;
//--- Keys that failed and then failed AGAIN. Parked far longer than the
//--- normal two-second retry, because a broker refusing the same order
//--- repeatedly is not a transient condition, and retrying it every two
//--- seconds is how an account gets throttled or blocked.
long            g_lastRealizedMs=0;      // CopierRealizedToday walks history
long            g_riskDay=0;             // server day the baseline belongs to
double          g_riskDayStartEquity=0.0;
double          g_riskDayStartBalance=0.0;
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
CopierPos       g_scanScratch[CP_MAX_POSITIONS]; // Global scratch for position sweeps (avoids 400KB stack frame)

//--- Track sender's peak/initial lots per UID for proportional partial-close in FIXED lot mode
struct CopierUidPeakLots
  {
   string uid;
   double peakLots;
  };
CopierUidPeakLots g_uidPeakLots[CP_MAX_POSITIONS];
int               g_uidPeakLotsCount=0;

//--- Direct-mapped cache: uid -> slot+1, verified by string compare.
//---
//--- GetOrUpdateSenderPeakLots() is called once per record while applying a
//--- snapshot, and it used to walk the whole peak table: at 2048 records that
//--- is ~2 million string compares per snapshot, for a lookup whose answer is
//--- almost always the same slot as the previous pass. A stale index cannot
//--- give a wrong answer because the uid is compared before it is trusted.
#define CP_PEAK_LOOKUP 4096
int g_peakLookup[CP_PEAK_LOOKUP];

// MQL-10: Uniformly use CopierHash32 for peak lookup hash slots
int PeakFind(const string uid)
  {
   if(StringLen(uid)==0) return -1;
   int h=(int)(CopierHash32(uid)&(CP_PEAK_LOOKUP-1));
   int c=g_peakLookup[h];
   if(c>0 && c<=g_uidPeakLotsCount && g_uidPeakLots[c-1].uid==uid) return c-1;
   for(int i=0;i<g_uidPeakLotsCount;i++)
     {
      if(g_uidPeakLots[i].uid!=uid) continue;
      g_peakLookup[h]=i+1;
      return i;
     }
   return -1;
  }

void PruneSenderPeakLots()
  {
   if(g_uidPeakLotsCount<=0) return;
   static bool s_isAlive[CP_MAX_POSITIONS];
   ArrayInitialize(s_isAlive,false);

   //--- DEF-61-04: Mark active UIDs in O(Desired + Acct) time via direct-mapped PeakFind
   //--- instead of O(N * S * D) nested brute-force loop.
   for(int s=0;s<g_nSenders;s++)
     {
      int base=s*CP_MAX_POSITIONS;
      for(int d=0;d<g_desiredCount[s];d++)
        {
         int p=PeakFind(g_desired[base+d].uid);
         if(p>=0 && p<g_uidPeakLotsCount && p<CP_MAX_POSITIONS) s_isAlive[p]=true;
        }
     }
   for(int k=0;k<g_acctAllPosCount;k++)
     {
      int p=PeakFind(g_acctAllPos[k].uid);
      if(p>=0 && p<g_uidPeakLotsCount && p<CP_MAX_POSITIONS) s_isAlive[p]=true;
     }

   //--- Compact active entries in single pass
   int oldPeakCount=g_uidPeakLotsCount;
   int writeIdx=0;
   for(int i=0;i<oldPeakCount;i++)
     {
      if(s_isAlive[i])
        {
         if(writeIdx!=i) g_uidPeakLots[writeIdx]=g_uidPeakLots[i];
         writeIdx++;
        }
     }
   //--- O4: clear the vacated tail, otherwise every pruned UID string stays
   //--- referenced by the array slot it used to occupy
   for(int k=writeIdx;k<oldPeakCount;k++) g_uidPeakLots[k].uid="";
   g_uidPeakLotsCount=writeIdx;
   //--- the compaction moved rows, so every cached index is suspect
   ArrayInitialize(g_peakLookup,0);
   // MQL-OPT-01: Rebuild hash index immediately after compaction so subsequent lookups remain O(1)
   for(int k=0; k<writeIdx; k++)
     {
      int h=(int)(CopierHash32(g_uidPeakLots[k].uid)&(CP_PEAK_LOOKUP-1));
      g_peakLookup[h]=k+1;
     }
  }

double GetOrUpdateSenderPeakLots(const string uid,const double curLots)
  {
   int i=PeakFind(uid);
   if(i>=0)
     {
      if(curLots>g_uidPeakLots[i].peakLots) g_uidPeakLots[i].peakLots=curLots;
      return g_uidPeakLots[i].peakLots;
     }
   if(g_uidPeakLotsCount>=CP_MAX_POSITIONS)
     {
      PruneSenderPeakLots();
     }
   if(g_uidPeakLotsCount<CP_MAX_POSITIONS)
     {
      int n=g_uidPeakLotsCount++;
      g_uidPeakLots[n].uid=uid;
      g_uidPeakLots[n].peakLots=curLots;
      g_peakLookup[(int)(CopierHash32(uid)&(CP_PEAK_LOOKUP-1))]=n+1;
      return curLots;
     }
   return curLots;
  }

void ForgetSenderPeakLots(const string uid)
  {
   int i=PeakFind(uid);
   if(i<0) return;
   int last=g_uidPeakLotsCount-1;
   string moved=(i!=last)?g_uidPeakLots[last].uid:"";
   g_uidPeakLots[i]=g_uidPeakLots[last];
   g_uidPeakLots[last].uid="";
   g_uidPeakLots[last].peakLots=0.0;
   g_uidPeakLotsCount--;
   //--- both the forgotten uid and the one that moved into its slot have a
   //--- cached index that is now wrong
   g_peakLookup[(int)(CopierHash32(uid)&(CP_PEAK_LOOKUP-1))]=0;
   if(StringLen(moved)>0)
      g_peakLookup[(int)(CopierHash32(moved)&(CP_PEAK_LOOKUP-1))]=0;
  }

CopierSeenRing  g_mktClosed;
#define CP_MKTCLOSED_MS 60000

//=====================================================================
// Unified authoritative Market Closed check for all actions (OPEN/CLOSE/MODIFY)
//=====================================================================
bool SymbolMarketClosed(const string sym)
  {
   if(StringLen(sym)==0) return false;
   // 1. Broker explicit rejection cache (MT4 132 / MT5 10018)
   if(g_mktClosed.Has(sym)) return true;
   // 2. Official trading session schedule (crypto 24/7 is open, forex weekend is closed)
   if(!SymInSessionCached(sym)) return true;
   // 3. Feed freshness: quote stream halted for > 60s
   if(SymStaleCached(sym)) return true;
   return false;
  }

#define CP_SPREAD_TRACK_SLOTS 256
string g_spreadSym[CP_SPREAD_TRACK_SLOTS];
double g_spreadMin[CP_SPREAD_TRACK_SLOTS];

double GetSymbolMinSpread(const string sym)
  {
   if(StringLen(sym)==0) return 0.0;
   uint h=(uint)(CopierHash32(sym)&(CP_SPREAD_TRACK_SLOTS-1));
   for(int i=0;i<CP_SPREAD_TRACK_SLOTS;i++)
     {
      int s=(int)((h+i)&(CP_SPREAD_TRACK_SLOTS-1));
      if(g_spreadSym[s]==sym) return g_spreadMin[s];
      if(StringLen(g_spreadSym[s])==0) break;
     }
   return 0.0;
  }

void TrackSymbolSpread(const string sym,const double curSpread,const bool inWarmup=false)
  {
   if(StringLen(sym)==0 || curSpread<=0.0) return;
   uint h=(uint)(CopierHash32(sym)&(CP_SPREAD_TRACK_SLOTS-1));
   for(int i=0;i<CP_SPREAD_TRACK_SLOTS;i++)
     {
      int s=(int)((h+i)&(CP_SPREAD_TRACK_SLOTS-1));
      if(g_spreadSym[s]==sym)
        {
         // ISSUE-02: If currently in warmup, only allow lowering the min spread, never initialize from warmup
         if(g_spreadMin[s]>0.0)
           {
            if(curSpread<g_spreadMin[s]) g_spreadMin[s]=curSpread;
           }
         else if(!inWarmup)
           {
            g_spreadMin[s]=curSpread;
           }
         return;
        }
      if(StringLen(g_spreadSym[s])==0)
        {
         g_spreadSym[s]=sym;
         g_spreadMin[s]=inWarmup ? 0.0 : curSpread;
         return;
        }
     }
  }

bool SymbolInOpenWarmup(const string sym,int &elapsedSecs)
  {
   elapsedSecs=0;
   if(MarketOpenDelayMinutes<=0) return false;
   int secs=CopierSecondsSinceSessionOpen(sym);
   if(secs<0 || secs>=MarketOpenDelayMinutes*60) return false;

   long now=CopierServerTime();
   MqlDateTime dt;
   TimeToStruct((datetime)now,dt);
   int secOfDay=dt.hour*3600 + dt.min*60 + dt.sec;
   int dow=dt.day_of_week;
   int prevDow=(dow+6)%7;

   int activeIdx=-1;
   long activeFs=0;
   long prevTodayEnd=-1;
   long prevTodayFs=0;
   for(int si0=0;si0<8;si0++)
     {
      datetime pf=0,pt=0;
      if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)dow,si0,pf,pt)) break;
      long fs=0,todayEnd=0,nextTail=0;
      if(!CopierExtractSessionSpan(pf,pt,fs,todayEnd,nextTail)) continue;
      if(secOfDay>=fs && secOfDay<=todayEnd)
        {
         activeIdx=si0;
         activeFs=fs;
         break;
        }
      prevTodayFs=fs;
      prevTodayEnd=todayEnd;
     }

   if(activeIdx>=0)
     {
      // Same-day session following a break (e.g. lunch break 12:00->13:00):
      // only continuous if previous session ended within 60s of this session's open.
      if(prevTodayEnd>=0)
        {
         if((activeFs-prevTodayEnd)<=60 && (secOfDay-prevTodayFs)>=MarketOpenDelayMinutes*60)
            return false;
        }
      else if(activeFs<=60)
        {
         // First session of day starting at 00:00 (..00:01): continuous with yesterday only
         // if yesterday's final session reached midnight (>=23:59 == 86340s) AND total
         // elapsed open span across midnight has already exceeded the warmup window.
         long prevLastFs=0, prevMaxEnd=-1;
         for(int si1=0;si1<8;si1++)
           {
            datetime pf=0,pt=0;
            if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)prevDow,si1,pf,pt)) break;
            long fs=0,todayEnd=0,nextTail=0;
            if(!CopierExtractSessionSpan(pf,pt,fs,todayEnd,nextTail)) continue;
            if(todayEnd>=prevMaxEnd)
              {
               prevMaxEnd=todayEnd;
               prevLastFs=fs;
              }
           }
         if(prevMaxEnd>=86340)
           {
            long crossMidnightElapsed=secOfDay+(86400-prevLastFs);
            if(crossMidnightElapsed>=MarketOpenDelayMinutes*60)
               return false;
           }
        }
     }

   elapsedSecs=secs;
   return true;
  }

void SampleSpreadIfUnique(const string sym,string &sampled[],int &nSampled,const int cap)
  {
   if(StringLen(sym)==0 || nSampled>=cap) return;
   for(int j=0;j<nSampled;j++)
      if(sampled[j]==sym) return;
   sampled[nSampled++]=sym;
   int el=0;
   if(SymInSessionCached(sym) && !SymStaleCached(sym) && !SymbolInOpenWarmup(sym,el))
     {
      double sp=CopierGetSpreadPoints(sym);
      if(sp>0.0) TrackSymbolSpread(sym,sp,false);
     }
  }

bool CopierTradeAllowed()
  {
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
#ifdef __MQL5__
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!CopierIsHedgingAccount()) return false;
#else
   if(!IsTradeAllowed()) return false;
#endif
   return true;
  }

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
CopierSeenRing  g_fillGraceRing;
                             // UIDs currently in pending-fill grace window:
                             // when sender fills, receiver waits up to
                             // PendingFillGraceSeconds for its own pending order
                             // to fill naturally before cancelling and re-opening.
CopierSeenRing  g_emgSlApplied;
                             // UIDs whose local SL was temporarily initialized from
                             // EmergencySLPips and has not yet converged to sender's real SL.

//=====================================================================
// Symbol map (flattened)
//=====================================================================
void MapAdd(const int si,const string from,const string to)
  {
   string cleanFrom=CopierTrim(from);
   string cleanTo=CopierTrim(to);
   double mult=1.0;
   int multIdx=StringFind(cleanTo,"*");
   if(multIdx<0) multIdx=StringFind(cleanTo,":");
   if(multIdx>0)
     {
      string mStr=CopierTrim(StringSubstr(cleanTo,multIdx+1));
      cleanTo=CopierTrim(StringSubstr(cleanTo,0,multIdx));
      int slashIdx=StringFind(mStr,"/");
      if(slashIdx<0) slashIdx=StringFind(mStr,":");
      if(slashIdx>0)
        {
         double num=StringToDouble(StringSubstr(mStr,0,slashIdx));
         double den=StringToDouble(StringSubstr(mStr,slashIdx+1));
         mult=(den>0.0)?(num/den):1.0;
        }
      else
        {
         mult=StringToDouble(mStr);
        }
      if(mult<=0.0) mult=1.0;
     }

   for(int i=0;i<g_nMap;i++)
     {
      //--- (si,cleanFrom) is the key: two senders may map the same symbol
      //--- differently, and that is deliberate.
      if(g_mapSender[i]==si && g_mapFrom[i]==cleanFrom)
        {
         g_mapTo[i]=cleanTo;
         g_mapMult[i]=mult;
         return;
        }
     }
   if(g_nMap>=CP_MAX_TOTAL_MAPS)
     {
      //--- The table is FIXED (CP_MAX_TOTAL_MAPS = senders x per-sender
      //--- limit), so this is a real ceiling and not a transient. Dropping the
      //--- row silently would leave a symbol routed under its own name, which
      //--- usually "works" and hides the misconfiguration until a trade lands
      //--- on the wrong instrument - the same class of failure the ini loader
      //--- was just taught to shout about.
      if(g_once.ShouldEmit("mapfull"))
         g_log.Error("symbol map is FULL ("+(string)CP_MAX_TOTAL_MAPS
                     +" entries): mapping "+from+" -> "+to+" was DROPPED, so"
                     +" that symbol will be resolved by name instead. Raise"
                     +" CP_MAX_SYMBOL_MAP or trim the per-sender maps.");
      return;
     }
   g_mapFrom[g_nMap]=cleanFrom;
   g_mapTo[g_nMap]=cleanTo;
   g_mapSender[g_nMap]=si;
   g_mapMult[g_nMap]=mult;
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
   for(int i=0;i<g_nMap;i++)
     {
      g_mapFrom[i]="";
      g_mapTo[i]="";
      g_mapMult[i]=1.0;
     }
   g_nMap=0;
  }

double GetSymbolMultiplier(const int si,const string sym)
  {
   for(int i=0;i<g_nMap;i++)
     {
      if(g_mapSender[i]==si && g_mapFrom[i]==sym)
         return g_mapMult[i];
     }
   for(int i=0;i<g_nMap;i++)
     {
      if(g_mapSender[i]==si && g_mapTo[i]==sym)
         return g_mapMult[i];
     }
   return 1.0;
  }

double GetSymbolMultiplierForPair(const int si,const string fromSym,const string toSym)
  {
   for(int i=0;i<g_nMap;i++)
     {
      if(g_mapSender[i]==si && g_mapFrom[i]==fromSym && g_mapTo[i]==toSym)
         return g_mapMult[i];
     }
   if(StringLen(fromSym)>0)
     {
      for(int i=0;i<g_nMap;i++)
        {
         if(g_mapSender[i]==si && g_mapFrom[i]==fromSym)
            return g_mapMult[i];
        }
     }
   return GetSymbolMultiplier(si,toSym);
  }

string MapSymbol(const int si,const string sym,const string suffix)
  {
   for(int i=0;i<g_nMap;i++)
     {
      if(g_mapSender[i]==si && g_mapFrom[i]==sym) return g_mapTo[i];
     }
   if(StringLen(suffix)>0)
     {
      // INC-01: Try direct concatenation first (e.g. suffix="m" -> "EURUSDm"),
      // then dotted fallback if suffix didn't already begin with dot.
      string cand1=sym+suffix;
      if(CopierSymbolExists(cand1)) return cand1;
      if(StringSubstr(suffix,0,1)!=".")
        {
         string cand2=sym+"."+suffix;
         if(CopierSymbolExists(cand2)) return cand2;
        }
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
   InvalidateIniHash();
   ResetRuntimeInputsFromInputs();
   g_nSenders=1;

   //--- Same rule as the hub path: g_desired is indexed
   //--- si*CP_MAX_POSITIONS+i, so its size IS the sender count. Direct
   //--- mode never re-loads its config after OnInit today, but the resize
   //--- is one line and makes the invariant local rather than depending on
   //--- which caller ran first.
   if(ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS)<0)
     {
      g_log.Error("out of memory resizing g_desired");
      return false;
     }

   //--- reset all senders' stream state. Globals SURVIVE a reinitialisation,
   //--- so a stale watermark here would make the receiver discard the first
   //--- messages from a sender it has only just been told about, or converge
   //--- on stale desired positions from a previous sender configuration.
   for(int s=0; s<CP_MAX_SENDERS; s++)
     {
      g_lastSeq[s][CP_STREAM_EVENTS]=-1;
      g_lastSeq[s][CP_STREAM_SNAP]=-1;
      g_lastSeq[s][CP_STREAM_HBT]=-1;
      g_ssidSeen[s]="";
      ClearAbandonedSsids(s);
      g_lastMsgMs[s]=0;
      g_firstMsgMs[s]=0;
      g_lastSnapMs[s]=0;
      g_snapHash[s]="";
      g_stale[s]=false;
      g_ready[s]=false;
      g_desiredCount[s]=0;
      g_senderClockKnown[s]=false;
      g_senderClockOffset[s]=0;
      g_senderClockOffsetValid[s]=false;
      g_snapRejectStreak[s]=0;
      g_dropped[s]=0;
      g_senderEquity[s]=0.0;
      g_senderCurrency[s]="";
      g_senderAcc[s]="";
      g_lastSeqGlobal[s]=0;
     }

   //--- Start from an empty symbol map on every load - see MapClear.
   MapClear();
   //--- the magic -> sender cache is derived from the config, so it goes with it
   MagicLookupClear();

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
   g_serverKey[0]=CopierTrim(SenderServerKey);
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
#ifndef __MQL5__
   if(Magic > 2147483647 || Magic < 0)
      g_magic[0] = (long)(Magic & 0x7FFFFFFF);
   else
      g_magic[0] = Magic;
#else
   g_magic[0] = Magic;
#endif

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

   double gs=PendingFillGraceSeconds;
   if(gs>300.0) { gs=300.0; PendingFillGraceSeconds=300.0; }
   g_senderCfg[0].pendingfillgraceseconds=gs;
   long ringTtl=60000;
   if(gs>0.0)
     {
      long reqTtl=(long)(gs*1000.0)+30000;
      if(reqTtl>ringTtl) ringTtl=reqTtl;
     }
   g_fillGraceRing.SetTtlMs(ringTtl);

   g_lastFullScanMs=0;
   g_posCacheCount=0;

   g_log.Info("configured from EA inputs: one sender ("+g_sid[0]
              +"), magic "+(string)g_magic[0]+", endpoint "+g_epEvents[0]);
   ClearQueue();
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
      Magic = CopierParseLong(mStr);
     }

   DeviationPoints                  = MathMax(0, InpDeviationPoints);
   EmergencySLPips                  = InpEmergencySLPips;
   EmergencyTPPips                  = InpEmergencyTPPips;
   MarketOpenDelayMinutes           = MathMax(0, InpMarketOpenDelayMinutes);
   MarketOpenCloseMaxWaitSec        = MathMax(0, InpMarketOpenCloseMaxWaitSec);
   MaxSpreadMultiplier             = MathMax(1.0, InpMaxSpreadMultiplier);
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
   PendingFillGraceSeconds          = InpPendingFillGraceSeconds;
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
   g_convergeSweepMs                = InpConvergeSweepMs;
   if(g_convergeSweepMs<0) g_convergeSweepMs=0;
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
      DeviationPoints = MathMax(0, ini.GetInt("common","deviationpoints",DeviationPoints));
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
   if(ini.Has("common","pendingfillgraceseconds"))
      PendingFillGraceSeconds = ini.GetDouble("common","pendingfillgraceseconds",PendingFillGraceSeconds);
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
     {
      bool newShow = ini.GetBool("common","showpanel",ShowPanel);
      if(ShowPanel && !newShow) g_panel.Destroy();
      else if(!ShowPanel && newShow) g_panel.Init("cprcv",10,20,430);
      ShowPanel = newShow;
     }
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
   if(!g_hubOn && g_nSenders>0)
      g_senderHours[0].Set(IncludeTradingTimes,DayTradingTimes);
   g_ignore.SetText(IgnoreUids);

   if(LogLevel != oldLogLevel)
      g_log.Init("receiver"+InstanceSuffix(),LogLevel);
   if(PollMs != oldPollMs && PollMs > 0)
     {
      EventKillTimer();
      int p=PollMs;
      if(p<1) p=1;
      if(p>5000) p=5000;
      if(!EventSetMillisecondTimer(p))
        {
         g_log.Error("ApplyCommonConfig: failed to set timer for "+(string)p+"ms, falling back to 100ms");
         EventSetMillisecondTimer(100);
        }
     }
   g_stOvEpoch++; // Invalidate stop-geometry cache on config change
  }

void InitSenderSettings(const int si, const CopierIni &ini, const string sec)
  {
   if(si < 0 || si >= CP_MAX_SENDERS) return;

   g_senderCfg[si].deviationPoints                  = MathMax(0, ini.GetInt(sec, "deviationpoints", DeviationPoints));
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
   g_senderCfg[si].pendingfillgraceseconds          = ini.GetDouble(sec, "pendingfillgraceseconds", PendingFillGraceSeconds);
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
   g_stOvEpoch++; // Invalidate stop-geometry cache on sender config change
  }

void PendingOpensForSender(const int si, int &cnt, double &lots)
  {
   cnt = 0;
   lots = 0.0;
   for(int i = 0; i < g_qn; i++)
     {
      if(g_q[g_qHead+i].senderIdx == si && g_q[g_qHead+i].kind == CP_ACT_OPEN)
        {
         cnt++;
         lots += g_q[g_qHead+i].lots;
        }
     }
  }

//--- The config's content hash, and whether the cached one is still good.
//---
//--- Serialising the whole config is the expensive half of answering "what am
//--- I running" - at 100 senders it builds a ~100 KB string - and REG needs
//--- only the hash. Caching it here means a REG costs one string append; the
//--- cache is invalidated by BOTH config load paths, and recomputed lazily on
//--- first use, so it can never be stale with respect to a load.
string g_iniHash="";
bool   g_iniHashOk=false;

void InvalidateIniHash() { g_iniHashOk=false; }

string CurrentIniHash()
  {
   if(!g_iniHashOk)
     {
      g_iniHash=CopierCfgHash(SerializeCurrentConfigToIni());
      g_iniHashOk=true;
     }
   return g_iniHash;
  }

string SerializeCurrentConfigToIni()
  {
   //--- Linear accumulation, N-07. This function emits ~126 lines per sender and
   //--- `out +=` copies the WHOLE string each time: at 100 senders the output is
   //--- ~270 KB and the copying worked out to several megabytes per call - on the
   //--- thread that also has to answer snapshots and send orders. Every line now
   //--- goes straight into the builder (which flushes at 4 KB), so each append is
   //--- bounded by one line.
   //---
   //--- The OUTPUT IS BYTE-IDENTICAL: same literals, same order, just handed to the
   //--- builder instead of a growing accumulator. That matters because this text is
   //--- what `IH=` hashes - a single byte of drift would look like "the node's
   //--- config changed" to the hub on every heartbeat.
   CopierStrBuilder sb;
   sb.Add("; copier.ini (active current settings)\n");
   sb.Add("[common]\n");
   sb.Add("deviationpoints=" + (string)DeviationPoints + "\n");
   sb.Add("emergencyslpips=" + DoubleToString(EmergencySLPips, 1) + "\n");
   sb.Add("emergencytppips=" + DoubleToString(EmergencyTPPips, 1) + "\n");
   sb.Add("reopenclosedmirrors=" + (ReopenClosedMirrors ? "1" : "0") + "\n");
   sb.Add("dedupduplicates=" + (DedupDuplicates ? "1" : "0") + "\n");
   sb.Add("ignorenewentrysignals=" + (IgnoreNewEntrySignals ? "1" : "0") + "\n");
   sb.Add("ignoreallexitsignals=" + (IgnoreAllExitSignals ? "1" : "0") + "\n");
   sb.Add("ignoreuids=" + IgnoreUids + "\n");
   sb.Add("nobuy=" + (NoBuy ? "1" : "0") + "\n");
   sb.Add("nosell=" + (NoSell ? "1" : "0") + "\n");
   sb.Add("permittedsymbols=" + PermittedSymbols + "\n");
   sb.Add("permittedmagic=" + PermittedMagic + "\n");
   sb.Add("minsenderlotsize=" + DoubleToString(MinSenderLotSize, 2) + "\n");
   sb.Add("maxsenderlotsize=" + DoubleToString(MaxSenderLotSize, 2) + "\n");
   sb.Add("checkforexistingposition=" + (string)((int)CheckForExistingPosition) + "\n");
   sb.Add("requirepositionfillwithinseconds=" + (string)RequirePositionFillWithinSeconds + "\n");
   sb.Add("requirepositionfillwithinminutes=" + (string)RequirePositionFillWithinMinutes + "\n");
   sb.Add("requirepositionfillwithinhours=" + (string)RequirePositionFillWithinHours + "\n");
   sb.Add("fillwithinminutesbar=" + (string)FillWithinMinutesBar + "\n");
   sb.Add("pendingfillgraceseconds=" + DoubleToString(PendingFillGraceSeconds, 1) + "\n");
   sb.Add("waitforseconds=" + (string)WaitForSeconds + "\n");
   sb.Add("waitforminutes=" + (string)WaitForMinutes + "\n");
   sb.Add("waitforhours=" + (string)WaitForHours + "\n");
   sb.Add("waitforprofitpips=" + DoubleToString(WaitForProfitPips, 1) + "\n");
   sb.Add("waitforminutesbar=" + (string)WaitForMinutesBar + "\n");
   sb.Add("includetradingtimes=" + IncludeTradingTimes + "\n");
   sb.Add("daytradingtimes=" + DayTradingTimes + "\n");
   sb.Add("inverttrades=" + (InvertTrades ? "1" : "0") + "\n");
   sb.Add("mirrorstops=" + (MirrorStops ? "1" : "0") + "\n");
   sb.Add("stopsthrottleseconds=" + (string)StopsThrottleSeconds + "\n");
   sb.Add("maxlotsperposition=" + DoubleToString(MaxLotsPerPosition, 2) + "\n");
   sb.Add("maxtotallots=" + DoubleToString(MaxTotalLots, 2) + "\n");
   sb.Add("maxopenpositions=" + (string)MaxOpenPositions + "\n");
   sb.Add("dailylosspct=" + DoubleToString(DailyLossPct, 2) + "\n");
   sb.Add("maxdrawdownpct=" + DoubleToString(MaxDrawdownPct, 2) + "\n");
   sb.Add("riskcloseallontrip=" + (RiskCloseAllOnTrip ? "1" : "0") + "\n");
   sb.Add("pollms=" + (string)PollMs + "\n");
   sb.Add("staleseconds=" + (string)StaleSeconds + "\n");
   sb.Add("maxactionspertick=" + (string)MaxActionsPerTick + "\n");
   sb.Add("loglevel=" + (string)LogLevel + "\n");
   sb.Add("statusenabled=" + (StatusEnabled ? "1" : "0") + "\n");
   sb.Add("syncheartbeatseconds=" + (string)SyncHeartbeatSeconds + "\n");
   sb.Add("showpanel=" + (ShowPanel ? "1" : "0") + "\n");
   sb.Add("showorphanedlist=" + (ShowOrphanedList ? "1" : "0") + "\n");

   if(g_nSenders > 0)
     {
      for(int i = 0; i < g_nSenders; i++)
        {
         sb.Add("\n[sender" + (string)i + "]\n");
         sb.Add("id=" + g_sid[i] + "\n");
         sb.Add("magic=" + (string)g_magic[i] + "\n");
         sb.Add("lotmode=" + CopierLotModeKey(g_lotMode[i]) + "\n");
         sb.Add("lotparam=" + DoubleToString(g_lotParam[i], 4) + "\n");
         if(StringLen(g_suffix[i]) > 0)
            sb.Add("suffix=" + g_suffix[i] + "\n");
         for(int m = 0; m < g_nMap; m++)
           {
            if(g_mapSender[m] == i)
              {
               string line = "symbol." + g_mapFrom[m] + "=" + g_mapTo[m];
               if(g_mapMult[m] != 1.0)
                  line += "*" + DoubleToString(g_mapMult[m], 4);
               sb.Add(line + "\n");
              }
           }
         sb.Add("deviationpoints=" + (string)g_senderCfg[i].deviationPoints + "\n");
         sb.Add("emergencyslpips=" + DoubleToString(g_senderCfg[i].emergencySLPips, 1) + "\n");
         sb.Add("emergencytppips=" + DoubleToString(g_senderCfg[i].emergencyTPPips, 1) + "\n");
         sb.Add("reopenclosedmirrors=" + (g_senderCfg[i].reopenclosedmirrors ? "1" : "0") + "\n");
         sb.Add("dedupduplicates=" + (g_senderCfg[i].dedupduplicates ? "1" : "0") + "\n");
         sb.Add("ignorenewentrysignals=" + (g_senderCfg[i].ignorenewentrysignals ? "1" : "0") + "\n");
         sb.Add("ignoreallexitsignals=" + (g_senderCfg[i].ignoreallexitsignals ? "1" : "0") + "\n");
         sb.Add("ignoreuids=" + g_senderCfg[i].ignoreuids + "\n");
         sb.Add("nobuy=" + (g_senderCfg[i].nobuy ? "1" : "0") + "\n");
         sb.Add("nosell=" + (g_senderCfg[i].nosell ? "1" : "0") + "\n");
         sb.Add("permittedsymbols=" + g_senderCfg[i].permittedsymbols + "\n");
         sb.Add("permittedmagic=" + g_senderCfg[i].permittedmagic + "\n");
         sb.Add("minsenderlotsize=" + DoubleToString(g_senderCfg[i].minsenderlotsize, 2) + "\n");
         sb.Add("maxsenderlotsize=" + DoubleToString(g_senderCfg[i].maxsenderlotsize, 2) + "\n");
         sb.Add("checkforexistingposition=" + (string)((int)g_senderCfg[i].checkforexistingposition) + "\n");
         sb.Add("requirepositionfillwithinseconds=" + (string)g_senderCfg[i].requirepositionfillwithinseconds + "\n");
         sb.Add("requirepositionfillwithinminutes=" + (string)g_senderCfg[i].requirepositionfillwithinminutes + "\n");
         sb.Add("requirepositionfillwithinhours=" + (string)g_senderCfg[i].requirepositionfillwithinhours + "\n");
         sb.Add("fillwithinminutesbar=" + (string)g_senderCfg[i].fillwithinminutesbar + "\n");
         sb.Add("pendingfillgraceseconds=" + DoubleToString(g_senderCfg[i].pendingfillgraceseconds, 1) + "\n");
         sb.Add("waitforseconds=" + (string)g_senderCfg[i].waitforseconds + "\n");
         sb.Add("waitforminutes=" + (string)g_senderCfg[i].waitforminutes + "\n");
         sb.Add("waitforhours=" + (string)g_senderCfg[i].waitforhours + "\n");
         sb.Add("waitforprofitpips=" + DoubleToString(g_senderCfg[i].waitforprofitpips, 1) + "\n");
         sb.Add("waitforminutesbar=" + (string)g_senderCfg[i].waitforminutesbar + "\n");
         sb.Add("includetradingtimes=" + g_senderCfg[i].includetradingtimes + "\n");
         sb.Add("daytradingtimes=" + g_senderCfg[i].daytradingtimes + "\n");
         sb.Add("inverttrades=" + (g_senderCfg[i].inverttrades ? "1" : "0") + "\n");
         sb.Add("mirrorstops=" + (g_senderCfg[i].mirrorstops ? "1" : "0") + "\n");
         sb.Add("stopsthrottleseconds=" + (string)g_senderCfg[i].stopsThrottleSeconds + "\n");
         sb.Add("maxlotsperposition=" + DoubleToString(g_senderCfg[i].maxLotsPerPosition, 2) + "\n");
         sb.Add("maxtotallots=" + DoubleToString(g_senderCfg[i].maxTotalLots, 2) + "\n");
         sb.Add("maxopenpositions=" + (string)g_senderCfg[i].maxOpenPositions + "\n");
         sb.Add("staleseconds=" + (string)g_senderCfg[i].staleSeconds + "\n");
        }
     }

   return sb.Result();
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
   e.gts = (long)TimeGMT();
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
   InvalidateIniHash();
   g_hubOn=true;
   g_nid=CopierNid(CopierAccountLogin());
   bool forceSingle=(StringLen(HubEndpoint)>0 && StringSubstr(HubEndpoint,0,1)=="!");
   string effectiveEp=forceSingle ? StringSubstr(HubEndpoint,1) : HubEndpoint;
   if(forceSingle)
     {
      FileDelete(CP_CLUSTER_STATE_FILE);
      g_log.Info("central channel: force single endpoint requested ('!'), cleared cluster cache "+CP_CLUSTER_STATE_FILE);
     }
   string eps[CP_MAX_CLUSTER_HUBS];
   int nEp=CopierParseEndpoints(effectiveEp,eps,CP_MAX_CLUSTER_HUBS);
   if(nEp==1 && !forceSingle)
     {
      CopierClusterState cs;
      if(CopierClusterCache::Load(cs))
        {
         string cachedTarget="";
         if(eps[0]==cs.primary && StringLen(cs.standby)>0) cachedTarget=cs.standby;
         else if(eps[0]==cs.standby && StringLen(cs.primary)>0) cachedTarget=cs.primary;
         if(StringLen(cachedTarget)>0 && cachedTarget!=eps[0])
           {
            eps[1]=cachedTarget;
            nEp=2;
            g_log.Info("central channel: augmented dual endpoints from "+CP_CLUSTER_STATE_FILE+" -> added "+cachedTarget);
           }
        }
     }
   g_connectedEpCount=nEp;
   g_hubEp="";
   for(int k=0;k<nEp;k++)
     {
      g_connectedEps[k]=eps[k];
      g_hubEp+=(k>0?";":"")+eps[k];
     }

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

   //--- Pass 1: Pre-validation without modifying global state.
   //--- Ensures atomic rollback if any sender section is invalid.
   int candidateMax=ini.SenderDeclaredMax();
   int candidateCount=ini.SenderCount();
   if(candidateCount>CP_MAX_SENDERS) candidateCount=CP_MAX_SENDERS;
   for(int i=0;i<candidateCount;i++)
     {
      string sec="sender"+(string)i;
      string sid=ini.Get(sec,"id","");
      if(StringLen(sid)==0)
        {
         g_log.Error("central mode: "+sec+" has no id=. It must be the SENDER'S"
                     +" NID - the number that sender prints as nid= in its"
                     +" startup line. Without it there is no topic to subscribe"
                     +" to, and this sender would be mirrored by nobody. Reload aborted.");
         return false;
        }
      bool pinned=false;
      long mg=CopierResolveMagic(ini.Get(sec,"magic",""),pinned);
      if(mg<0)
        {
         g_log.Error("central mode: sender "+sid+" has no magic= in "
                     +CP_INI_PATH+". Every sender MUST pin its magic - it is how"
                     +" this receiver finds that sender's positions, so a guess"
                     +" would orphan real orders. Reload aborted.");
         return false;
        }
     }

   //--- Pass 2: Commit verified configuration
   g_lastFullScanMs=0;
   g_posCacheCount=0;

   //--- BUG-02: Snapshot previous sender stream state and desired positions BEFORE
   //--- modifying g_nSenders or resizing g_desired, so senders do not lose their
   //--- mirror sync, readiness, sequence numbers or abandoned SSIDs during hot reload.
   int oldSenderCount = g_nSenders;
   string oldSid[CP_MAX_SENDERS];
   long oldMagic[CP_MAX_SENDERS];
   long oldLastSeq[CP_MAX_SENDERS][CP_STREAM_COUNT];
   long oldLastSeqGlobal[CP_MAX_SENDERS];
   string oldSsidSeen[CP_MAX_SENDERS];
   string oldSsidOld[CP_MAX_SENDERS][CP_OLD_SSID_MAX];
   int oldSsidOldHead[CP_MAX_SENDERS];
   int oldDesiredCount[CP_MAX_SENDERS];
   bool oldReady[CP_MAX_SENDERS];
   long oldLastMsgMs[CP_MAX_SENDERS];
   long oldFirstMsgMs[CP_MAX_SENDERS];
   long oldLastSnapMs[CP_MAX_SENDERS];
   string oldSnapHash[CP_MAX_SENDERS];
   bool oldStale[CP_MAX_SENDERS];
   bool oldClockKnown[CP_MAX_SENDERS];
   long oldClockOffset[CP_MAX_SENDERS];
   bool oldClockValid[CP_MAX_SENDERS];
   int oldRejectStreak[CP_MAX_SENDERS];
   int oldDropped[CP_MAX_SENDERS];
   double oldSenderEquity[CP_MAX_SENDERS];
   string oldSenderCurrency[CP_MAX_SENDERS];
   string oldSenderAcc[CP_MAX_SENDERS];

   ArrayInitialize(oldMagic,0);
   ArrayInitialize(oldLastSeq,-1);
   ArrayInitialize(oldLastSeqGlobal,0);
   ArrayInitialize(oldSsidOldHead,0);
   ArrayInitialize(oldDesiredCount,0);
   ArrayInitialize(oldReady,false);
   ArrayInitialize(oldLastMsgMs,0);
   ArrayInitialize(oldFirstMsgMs,0);
   ArrayInitialize(oldLastSnapMs,0);
   ArrayInitialize(oldStale,false);
   ArrayInitialize(oldClockKnown,false);
   ArrayInitialize(oldClockOffset,0);
   ArrayInitialize(oldClockValid,false);
   ArrayInitialize(oldRejectStreak,0);
   ArrayInitialize(oldDropped,0);
   ArrayInitialize(oldSenderEquity,0.0);
   for(int z=0;z<CP_MAX_SENDERS;z++)
     {
      oldSid[z]="";
      oldSsidSeen[z]="";
      oldSnapHash[z]="";
      oldSenderCurrency[z]="";
      oldSenderAcc[z]="";
      for(int k=0;k<CP_OLD_SSID_MAX;k++) oldSsidOld[z][k]="";
     }

   CopierPos oldDesiredScratch[];
   if(oldSenderCount>0)
     {
      ArrayResize(oldDesiredScratch, ArraySize(g_desired));
      for(int s=0; s<oldSenderCount && s<CP_MAX_SENDERS; s++)
        {
         oldSid[s]=g_sid[s];
         oldMagic[s]=g_magic[s];
         oldLastSeq[s][0]=g_lastSeq[s][0];
         oldLastSeq[s][1]=g_lastSeq[s][1];
         oldLastSeq[s][2]=g_lastSeq[s][2];
         oldLastSeqGlobal[s]=g_lastSeqGlobal[s];
         oldSsidSeen[s]=g_ssidSeen[s];
         for(int k=0;k<CP_OLD_SSID_MAX;k++) oldSsidOld[s][k]=g_ssidOld[s][k];
         oldSsidOldHead[s]=g_ssidOldHead[s];
         oldDesiredCount[s]=g_desiredCount[s];
         oldReady[s]=g_ready[s];
         oldLastMsgMs[s]=g_lastMsgMs[s];
         oldFirstMsgMs[s]=g_firstMsgMs[s];
         oldLastSnapMs[s]=g_lastSnapMs[s];
         oldSnapHash[s]=g_snapHash[s];
         oldStale[s]=g_stale[s];
         oldClockKnown[s]=g_senderClockKnown[s];
         oldClockOffset[s]=g_senderClockOffset[s];
         oldClockValid[s]=g_senderClockOffsetValid[s];
         oldRejectStreak[s]=g_snapRejectStreak[s];
         oldDropped[s]=g_dropped[s];
         oldSenderEquity[s]=g_senderEquity[s];
         oldSenderCurrency[s]=g_senderCurrency[s];
         oldSenderAcc[s]=g_senderAcc[s];

         int sbase = s * CP_MAX_POSITIONS;
         for(int d=0; d<oldDesiredCount[s]; d++)
            oldDesiredScratch[sbase + d] = g_desired[sbase + d];
        }
     }

   ResetRuntimeInputsFromInputs();
   ApplyCommonConfig(ini);

   //--- Start from an empty symbol map on every load - see MapClear. A CFG
   //--- push re-runs this whole function, and without the clear the old
   //--- rows stay underneath the new ones.
   MapClear();

   //--- How many senders the file DECLARES, and how many this build can take.
   //--- Two numbers, reported separately, because they used to be one and the
   //--- difference was invisible: SenderCount() stops at the first gap AND at
   //--- CP_MAX_SENDERS, so a file that declared sender0..sender99 on a build
   //--- holding 16 loaded sixteen of them and said nothing about the other 84.
   //--- "I configured 30 senders and only some appear" was unanswerable.
   int declaredMax=candidateMax;
   g_nSenders=candidateCount;
   if(declaredMax>=CP_MAX_SENDERS)
     {
      //--- ERROR: the operator's intent cannot be honoured at all. This is the
      //--- one message that makes the ceiling discoverable from the outside.
      g_log.Error("central mode: "+CP_INI_PATH+" declares up to [sender"
                  +(string)declaredMax+"], but this build supports "
                  +(string)CP_MAX_SENDERS+" sender(s). Sections sender0..sender"
                  +(string)(CP_MAX_SENDERS-1)+" were loaded; sender"
                  +(string)CP_MAX_SENDERS+" onward were NOT. Raise"
                  +" CP_MAX_SENDERS, or split this receiver."
                  +" (The ceiling is the same one that bounds how many senders"
                  +" DIRECT mode can mirror - the terminal's chart limit.)");
     }
   else if(declaredMax>=0 && declaredMax+1>g_nSenders)
     {
      //--- A gap: numbering must be consecutive from sender0, because position
      //--- in the file is a sender's identity. Reported, not silently collapsed.
      g_log.Error("central mode: "+CP_INI_PATH+" numbers senders with a gap -"
                  +" the highest section is [sender"+(string)declaredMax+"]"
                  +" but only "+(string)g_nSenders+" consecutive section(s)"
                  +" from sender0 are present. Sender numbering must be"
                  +" consecutive (sender0, sender1, ...); sections after the"
                  +" first missing index are ignored.");
     }
   //--- Same resize as the no-ini branch above: a CFG push re-runs this
   //--- whole function, and the count can go from N to M in either
   //--- direction. g_desired is indexed as si*CP_MAX_POSITIONS + i, so its
   //--- size IS the sender count - re-reading the ini without resizing it
   //--- is the crash the bootstrap path hits first.
   //---
   //--- Resize only when the size actually changes: at 100 senders the array
   //--- is 204,800 CopierPos (~30 MB), and ArrayResize reallocates and copies
   //--- the whole thing. A reload that does not change the sender count - the
   //--- common case, since most edits touch one sender's settings - would
   //--- otherwise pay a 30 MB memcpy for nothing.
   {
    int want=MathMax(1,g_nSenders)*CP_MAX_POSITIONS;
    if(ArraySize(g_desired)!=want)
      {
       if(ArrayResize(g_desired,want)<0)
         {
          g_log.Error("out of memory resizing g_desired to "+(string)want);
          return false;
         }
      }
   }
   //--- the magic -> sender cache is derived from the config, so it goes with it
   MagicLookupClear();
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
      //--- cleared, NOT read - see the note above
      g_epEvents[i] ="";
      g_serverKey[i]="";
      g_suffix[i]   =ini.Get(sec,"suffix","");

      //--- magic= is REQUIRED, exactly as in the direct path. There is no
      //--- fallback: a guessed magic orphans whatever is already open under the
      //--- real one. The hub knows every sender's NID, so it can always write a
      //--- correct value here.
      //--- `pinned` is an out-parameter of CopierResolveMagic reporting
      //--- whether magic= was present in the ini. Nothing is decided from it
      //--- here: a missing magic already aborted the reload in pass 1 above,
      //--- so every sender that reaches this line is pinned by construction.
      bool pinned=false;
      g_magic[i]=CopierResolveMagic(ini.Get(sec,"magic",""),pinned);

      bool lotOk=false;
      g_lotMode[i] =CopierLotModeFromText(ini.Get(sec,"lotmode","multiplier"),
                                          lotOk);
      if(!lotOk)
         g_log.Warn("sender "+g_sid[i]+": lotmode=\""
                    +ini.Get(sec,"lotmode","")+"\" is not recognised - falling"
                    +" back to multiplier. Use off / multiplier / fixed, or the"
                    +" codes 2 / 0 / 1.");
      g_lotParam[i]=ini.GetDouble(sec,"lotparam",1.0);

      int secStart=0,secLen=0;
      if(ini.SectionRange(sec,secStart,secLen)>=0)
        {
         for(int k=secStart;k<secStart+secLen;k++)
           {
            string key=ini.KeyAt(k);
            if(StringFind(key,"symbol.")!=0) continue;
            MapAdd(i,StringSubstr(key,StringLen("symbol.")),ini.ValAt(k));
           }
        }

      //--- BUG-01: Match against previous configuration. If sender ID and magic
      //--- are identical, preserve stream sequence, desired positions and readiness.
      int prevIdx = -1;
      for(int s=0; s<oldSenderCount && s<CP_MAX_SENDERS; s++)
        {
         if(oldSid[s]==g_sid[i] && oldMagic[s]==g_magic[i] && StringLen(g_sid[i])>0)
           {
            prevIdx = s;
            break;
           }
        }

      if(prevIdx >= 0)
        {
         g_lastSeq[i][0] = oldLastSeq[prevIdx][0];
         g_lastSeq[i][1] = oldLastSeq[prevIdx][1];
         g_lastSeq[i][2] = oldLastSeq[prevIdx][2];
         g_lastSeqGlobal[i] = oldLastSeqGlobal[prevIdx];
         g_ssidSeen[i]   = oldSsidSeen[prevIdx];
         g_desiredCount[i]= oldDesiredCount[prevIdx];
         g_ready[i]      = oldReady[prevIdx];
         g_lastMsgMs[i]  = oldLastMsgMs[prevIdx];
         g_firstMsgMs[i] = oldFirstMsgMs[prevIdx];
         g_lastSnapMs[i] = oldLastSnapMs[prevIdx];
         g_snapHash[i]   = oldSnapHash[prevIdx];
         g_stale[i]      = oldStale[prevIdx];
         g_senderClockKnown[i]       = oldClockKnown[prevIdx];
         g_senderClockOffset[i]      = oldClockOffset[prevIdx];
         g_senderClockOffsetValid[i] = oldClockValid[prevIdx];
         g_snapRejectStreak[i]       = oldRejectStreak[prevIdx];
         g_dropped[i]    = oldDropped[prevIdx];
         g_senderEquity[i]   = oldSenderEquity[prevIdx];
         g_senderCurrency[i] = oldSenderCurrency[prevIdx];
         g_senderAcc[i]      = oldSenderAcc[prevIdx];

         if(prevIdx != i)
           {
            for(int k=0; k<CP_OLD_SSID_MAX; k++)
               g_ssidOld[i][k] = oldSsidOld[prevIdx][k];
            g_ssidOldHead[i] = oldSsidOldHead[prevIdx];
           }

         if(oldDesiredCount[prevIdx] > 0)
           {
            int srcBase = prevIdx * CP_MAX_POSITIONS;
            int dstBase = i * CP_MAX_POSITIONS;
            for(int d=0; d<oldDesiredCount[prevIdx]; d++)
               g_desired[dstBase + d] = oldDesiredScratch[srcBase + d];
           }
        }
      else
        {
         //--- reset this sender's stream state. Globals SURVIVE a reinitialisation,
         //--- so a stale watermark here would make the receiver discard the first
         //--- messages from a sender it has only just been told about.
         g_lastSeq[i][CP_STREAM_EVENTS]=-1;
         g_lastSeq[i][CP_STREAM_SNAP]=-1;
         g_lastSeq[i][CP_STREAM_HBT]=-1;
         g_lastSeqGlobal[i]=0;
         g_ssidSeen[i]="";
         ClearAbandonedSsids(i);
         g_lastMsgMs[i]=0;
         g_firstMsgMs[i]=0;
         g_lastSnapMs[i]=0;
         g_snapHash[i]="";
         g_stale[i]=false;
         g_ready[i]=false;
         g_desiredCount[i]=0;
         g_senderClockKnown[i]=false;
         g_senderClockOffset[i]=0;
         g_senderClockOffsetValid[i]=false;
         g_snapRejectStreak[i]=0;
         g_dropped[i]=0;
         g_senderEquity[i]=0.0;
         g_senderCurrency[i]="";
         g_senderAcc[i]="";
        }

      InitSenderSettings(i, ini, sec);
     }
   ArrayResize(oldDesiredScratch, 0);

   double maxGraceSec=0.0;
   for(int i=0;i<g_nSenders;i++)
     {
      double gs=g_senderCfg[i].pendingfillgraceseconds;
      if(gs>300.0) { gs=300.0; g_senderCfg[i].pendingfillgraceseconds=300.0; }
      if(gs>maxGraceSec) maxGraceSec=gs;
     }
   long ringTtl=60000;
   if(maxGraceSec>0.0)
     {
      long reqTtl=(long)(maxGraceSec*1000.0)+30000;
      if(reqTtl>ringTtl) ringTtl=reqTtl;
     }
   g_fillGraceRing.SetTtlMs(ringTtl);

   g_log.Info("central mode: "+IntegerToString(g_nSenders)+" sender(s) from "
              +CP_INI_PATH+" - subscribing to each sender's NID, plus control"
              +" for this account (NID "+(string)g_nid+")");
   //--- F-03: Do NOT call ClearQueue() here. During hot-reloading (HandleCfg / reload),
   //--- ClearQueueExceptRiskReducing() must preserve in-flight CLOSE/TRIM actions.
   //--- The queue is explicitly initialized in OnInit().
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
   if(g_recKnown.GetByTicket(p.ticket,prev))
     {
      // R6-D1-01: Guard against recycled tickets
      if(prev.openTime==p.openTime || prev.openTime<=0 || p.openTime<=0)
         return prev.uid;
     }

   long from=CopierMt4FromTicket(p.cmt);
   if(from>0)
     {
      if(g_recKnown.GetByTicket(from,prev)) return prev.uid;
#ifndef __MQL5__
      long curFrom=from;
      long seen[32];
      ArrayInitialize(seen,0);
      int nSeen=0;
      int hops=0;
      for(;hops<32;hops++)
        {
         // BUG-06: Guard against 32-bit signed int overflow when casting from-ticket to MT4 OrderSelect
         if(curFrom<=0 || (ulong)curFrom>0xFFFFFFFF || !OrderSelect((int)(uint)curFrom,SELECT_BY_TICKET,MODE_HISTORY)) break;
         // R5-D2-01: Check if root ticket carries original copier UID in comment
         string histUid=CopierUidFromComment(OrderComment());
         if(StringLen(histUid)>0) return histUid;
         long prevFrom=CopierMt4FromTicket(OrderComment());
         if(prevFrom<=0) break;
         if(g_recKnown.GetByTicket(prevFrom,prev)) return prev.uid;
         bool dup=false;
         for(int s=0;s<nSeen;s++) { if(seen[s]==prevFrom) { dup=true; break; } }
         if(dup) break;
         if(nSeen<32) seen[nSeen++]=prevFrom;
         curFrom=prevFrom;
        }
      // R47-16: Only warn if the loop actually exhausted all 32 hops without resolving
      if(hops>=32 && g_once.ShouldEmit("recvfromhops|"+(string)p.ticket))
         g_log.Warn("MT4 partial-close 'from #' chain exceeded 32 hops for ticket "+(string)p.ticket);
#endif
     }

   return "";
  }

int LocalForSender(const int si,const CopierPos &all[],const int n)
  {
   int m=0;
   for(int i=0;i<n;i++)
     {
      if(all[i].magic!=g_magic[si]) continue;

      string uid=all[i].uid;
      if(StringLen(uid)==0) uid=ResolveUid(all[i]);
      if(StringLen(uid)==0) continue;

      if(m>=CP_MAX_POSITIONS) break;
      g_locScratch[m]=all[i];
      g_locScratch[m].uid=uid;
      m++;
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
   if(h==INVALID_HANDLE || FileSize(h)==0)
     {
      if(h!=INVALID_HANDLE) FileClose(h);
      // D-03: Fallback to .tmp successor if target file is missing or corrupted 0-byte
      string tmpPath=RiskPeakPath()+".tmp";
      h=FileOpen(tmpPath,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h==INVALID_HANDLE) return;
     }
   double peak=0.0;
   long savedDay=0;
   double savedDayEquity=0.0;
   double savedDayBalance=0.0;
   while(!FileIsEnding(h))
     {
      string line=CopierTrim(FileReadString(h));
      if(StringLen(line)==0) continue;
      string v="";
      if(CopierKvGet(line,"PEAK",v)) peak=StringToDouble(v);
      if(CopierKvGet(line,"DAY",v)) savedDay=CopierParseLong(v);
      if(CopierKvGet(line,"DAY_EQUITY",v)) savedDayEquity=StringToDouble(v);
      if(CopierKvGet(line,"DAY_BALANCE",v)) savedDayBalance=StringToDouble(v);
     }
   FileClose(h);
   long currentDay=CopierServerDayStart();
   if(savedDay==currentDay && savedDayEquity>0.0)
     {
      g_riskDay=savedDay;
      g_riskDayStartEquity=savedDayEquity;
      g_riskDayStartBalance=(savedDayBalance>0.0)?savedDayBalance:savedDayEquity;
      g_risk.SetDayStartEquity(savedDayEquity);
      g_log.Info("day start equity baseline restored from "+RiskPeakPath()+": "+DoubleToString(savedDayEquity,2));
     }
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
//--- R7-D4-02: Two-phase atomic write to prevent 0-byte truncation on crash
void RiskPeakSave(const bool force)
  {
   double peak=g_risk.PeakEquity();
   if(peak<=0.0) return;
   long now=CopierNowMs();
   if(!force && now-g_lastPeakSave<60000) return;
   g_lastPeakSave=now;
   string targetPath=RiskPeakPath();
   string tmpPath=targetPath+".tmp";
   int h=FileOpen(tmpPath,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
     {
      if(g_once.ShouldEmit("peaksave"))
         g_log.Warn("cannot write "+tmpPath+" - the drawdown peak will"
                    +" NOT survive a restart (reported at most once per 10 min)");
      return;
     }
   FileWrite(h,"V=1");
   FileWrite(h,"PEAK="+DoubleToString(peak,2));
   if(g_riskDay>0 && g_riskDayStartEquity>0.0)
     {
      FileWrite(h,"DAY="+(string)g_riskDay);
      FileWrite(h,"DAY_EQUITY="+DoubleToString(g_riskDayStartEquity,2));
      FileWrite(h,"DAY_BALANCE="+DoubleToString(g_riskDayStartBalance,2));
     }
   FileFlush(h);
   FileClose(h);

   int rh=FileOpen(tmpPath,FILE_READ|FILE_TXT|FILE_ANSI);
   int wh=FileOpen(targetPath,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   bool copyOk=false;
   if(rh!=INVALID_HANDLE && wh!=INVALID_HANDLE)
     {
      while(!FileIsEnding(rh)) FileWriteString(wh,FileReadString(rh)+"\r\n");
      copyOk=true;
     }
   if(rh!=INVALID_HANDLE) FileClose(rh);
   if(wh!=INVALID_HANDLE) FileClose(wh);
   // D-03: Only delete tmp if copy succeeded, preserving backup if write failed
   if(copyOk) FileDelete(tmpPath);
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
   // R47-21: Verify atomic acquisition against concurrent chart startup races
   if(GetLockChartId(name)!=myChart)
     {
      g_log.Error("Failed to acquire lock "+name+": concurrent instance claimed lock first. Refusing to start.");
      return false;
     }
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
   // N83-02 & N84-02: Persist operator manually closed UIDs and sender identity
   int mcCount=g_manualClosed.Count();
   for(int i=0;i<mcCount;i++)
     {
      string mUid=g_manualClosed.GetUid(i);
      long mTicket=g_manualClosed.GetTicket(i);
      string mSid=g_manualClosed.GetSid(i);
      if(StringLen(mUid)>0 || mTicket>0)
         body+="\nMC="+mUid+"|"+(string)mTicket+"|"+mSid;
     }
   CopierIniWriteAll(CmdStatePath(),body);
  }

void CmdStateLoad()
  {
   g_cmdPaused=false; g_cmdId=""; g_cmdAck="";
   g_manualClosed.Clear();
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
      if(CopierKvGet(line,"MC",v))
        {
         int sep=StringFind(v,"|");
         if(sep>=0)
           {
            string uid=StringSubstr(v,0,sep);
            string rem=StringSubstr(v,sep+1);
            int sep2=StringFind(rem,"|");
            long ticket=0;
            string sid="";
            if(sep2>=0)
              {
               ticket=CopierParseLong(StringSubstr(rem,0,sep2));
               sid=StringSubstr(rem,sep2+1);
              }
            else
              {
               ticket=CopierParseLong(rem);
              }
            if(StringLen(uid)>0 || ticket>0)
               g_manualClosed.Add(uid,ticket,sid);
           }
         else if(StringLen(v)>0)
           {
            g_manualClosed.Add(v,0,"");
           }
        }
     }
  }

void SaveReceiverMap()
  {
   //--- Never save from a cache nobody has filled. OnDeinit runs this, and so
   //--- did the first timer tick before the order was fixed: an empty
   //--- g_acctAllPos means "not scanned", not "the account is flat", and
   //--- writing it out both clears g_recKnown and overwrites the durable
   //--- identity file with N=0.
   if(!g_acctScanned) return;

   //--- Reuse the account positions resolved during RefreshRisk to avoid
   //--- redundant terminal scans and string parsing every 10 seconds.
   g_saveScratch.Clear();

   for(int i=0;i<g_acctAllPosCount;i++)
     {
      int si=MagicToSender(g_acctAllPos[i].magic);
      if(si<0) continue;                        // not ours

      string uid=g_acctAllPos[i].uid;
      if(StringLen(uid)==0) uid=ResolveUid(g_acctAllPos[i]);
      if(StringLen(uid)==0) continue;           // unmanageable; reported elsewhere

      CopierPos p=g_acctAllPos[i];
      p.uid=uid;
      //--- InsertEmpty, not Upsert: the account scan yields one row per
      //--- position, so there is nothing to look up. Upsert() starts with a
      //--- 2048-slot Find(uid), which made this rebuild O(rows x 2048) - the
      //--- table is cleared first, so no row can already be present.
      g_saveScratch.InsertEmpty(p);
     }

   //--- Write-amplification guard: check if the position table has changed compared to g_recKnown
   bool mapChanged = (g_saveScratch.Count() != g_recKnown.Count());
   if(!mapChanged)
     {
      for(int i=0;i<g_acctAllPosCount;i++)
        {
         if(StringLen(g_acctAllPos[i].uid)==0) continue;
         CopierPos prev;
         if(!g_recKnown.GetByTicket(g_acctAllPos[i].ticket,prev) || prev.uid!=g_acctAllPos[i].uid)
           {
            mapChanged=true;
            break;
           }
        }
     }
   if(!mapChanged && g_stateSaveOk) return; // Unchanged: avoid disk write amplification!

   CopierPos dense[];
   int dn=g_saveScratch.CopyTo(dense);
   if(!CopierStateFile::Save(ReceiverStatePath(),"N="+(string)dn,dense,dn))
     {
      g_stateSaveOk=false; // F03: Ensure retry occurs on next pass if disk save fails
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
   else
     {
      g_recKnown.CopyFrom(g_saveScratch); // Update in-memory durable shadow ONLY after confirmed disk save
      if(!g_stateSaveOk)
        {
         //--- Once per session, so a pilot can tell the durability mechanism
         //--- is actually live rather than merely present in the source.
         g_stateSaveOk=true;
         g_log.Info("identity store "+ReceiverStatePath()+" written ("
                    +(string)dn+" position(s))");
        }
     }
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
   int an=CopierReadPositions(g_scanScratch,CP_MAX_POSITIONS);
   int bad=0;
   for(int i=0;i<an;i++)
     {
      int si=-1;
      for(int k=0;k<g_nSenders;k++)
        {
         if(g_scanScratch[i].magic==g_magic[k]) { si=k; break; }
        }
      if(si<0) continue;                                     // not ours
      //--- an unreadable comment is EXPECTED after a partial close (MT5
      //--- overwrites it, MT4 replaces the ticket). It is only a problem if
      //--- none of the three sources can name the position - then nothing
      //--- will ever match it, and it can never be closed.
      if(StringLen(ResolveUid(g_scanScratch[i]))>0) continue;

      bad++;
      g_log.Error("order "+g_scanScratch[i].sym+" ticket="+(string)g_scanScratch[i].ticket
                  +" magic="+(string)g_scanScratch[i].magic+" ("+g_sid[si]+")"
                  +" carries our magic but its comment yields no UID"
                  +" [comment=\""+g_scanScratch[i].cmt+"\"]"
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
   int an=CopierReadPositions(g_scanScratch,CP_MAX_POSITIONS);
   int bad=0;
   for(int i=0;i<an;i++)
     {
      //--- only positions WE tagged. Another EA may legitimately use any
      //--- magic, and none of those are ours to comment on.
      string uid=CopierUidFromComment(g_scanScratch[i].cmt);
      if(StringLen(uid)==0) continue;

      bool owned=false;
      for(int k=0;k<g_nSenders;k++)
        {
         if(g_scanScratch[i].magic==g_magic[k]) { owned=true; break; }
        }
      if(owned) continue;

      bad++;
      g_log.Error("ORPHAN: "+g_scanScratch[i].sym+" ticket="+(string)g_scanScratch[i].ticket
                  +" uid="+uid+" magic="+(string)g_scanScratch[i].magic
                  +" - it carries this copier's comment tag but no sender is"
                  +" configured with that magic (a reordered copier.ini or a"
                  +" changed MagicBase moves a sender onto a new one)."
                  +" Nothing will manage or close it. To adopt it, add"
                  +" magic="+(string)g_scanScratch[i].magic+" to that sender's section;"
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
                 +" pending + open order(s) combined while the copier's table holds "
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

#include <Copier/RecvExecute.mqh>   // Action queue: PushAction, queue maintenance, backoff and ExecuteQueue.

#include <Copier/RecvReconcile.mqh>   // Lot sizing, partial-close trim, stop/target modify, account position scan and STAT encoders.

#include <Copier/RecvRisk.mqh>   // RefreshRisk and the risk close-all path.

#include <Copier/RecvConverge.mqh>   // Sender clock mapping, exposure counting and ConvergeSender.

//=====================================================================
// Message handling
//=====================================================================
int SenderIndexById(const string sid)
  {
   for(int i=0;i<g_nSenders;i++) { if(g_sid[i]==sid) return i; }
   return -1;
  }

void LearnSenderClock(const int si,const long ts)
  {
   if(ts<=0) return;
   long off=(long)CopierServerTime()-ts;
   bool first=!g_senderClockKnown[si];
   g_senderClockKnown[si]=true;
   g_senderClockOffset[si]=off;
   g_senderClockOffsetValid[si]=g_srvEverMoved;

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

void HandleSnapshot(const int si,const CopierEnv &e)
  {
   int n=CopierDecodeSnapshot(e.payload,g_scratch,CP_MAX_POSITIONS);

   // F-04: Validate snapshot integrity, N declaration, H= checksum and decoded record count
   string valErr="";
   if(!CopierValidateSnapshot(e.payload,n,CP_MAX_POSITIONS,valErr))
     {
      g_snapDeclFailed++;
      g_snapRejectStreak[si]++;
      if(g_snapRejectStreak[si]==1 || g_once.ShouldEmit("snapval|"+g_sid[si]))
         g_log.Error("CRITICAL: snapshot from sender "+g_sid[si]+" validation failed ("+valErr+"); rejected to prevent false close-all.");
      return;
     }

   //--- accepted: the streak only measures CONSECUTIVE failures
   g_snapRejectStreak[si]=0;
   g_lastSnapMs[si]=CopierNowMs();
   // P2-25 fix: learn sender clock offset ONLY after payload integrity and records are fully validated
   LearnSenderClock(si,e.ts);

   //--- Store this sender's receipt hash once validated.
   g_snapHash[si]=CopierSnapshotHash(e.payload);

   string nStr="";
   int sent=n;
   if(CopierKvGet(e.payload,"N",nStr)) sent=(int)CopierParseLong(nStr);

   //--- A sender can hold more than our table. Decode caps at
   //--- CP_MAX_POSITIONS and drops the remainder SILENTLY - the worst
   //--- possible outcome, because the receiver then believes it holds the
   //--- full picture while mirroring only part of it. The divergence does
   //--- not show up as an error anywhere else: nothing is missing locally,
   //--- it was never known about.
   //---
   //--- So compare the sender's own count against what we actually took and
   //--- say so. Rate-limited because it is true on every snapshot.
   if(sent>n && g_once.ShouldEmit("overflow|"+g_sid[si]))
     {
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
   int prevCount=g_desiredCount[si];
   //--- N-03: carry each UID's peak lots from the row being replaced.
   //---
   //--- This is the per-row replacement for the global peak table, which had ONE
   //--- 2048-row budget shared by every sender: two senders holding 1200 positions
   //--- each overflowed it, and `PruneSenderPeakLots` cannot free a UID that is
   //--- still desired - so the last ~350 UIDs were stored with peak == current
   //--- lots. FIXED sizing scales a partial close by lots/peak, so with peak
   //--- pinned to the current volume the ratio never fell below 1 and a sender
   //--- trim silently stopped shrinking the mirror.
   //---
   //--- Building the index over the PREVIOUS slice costs one pass per snapshot
   //--- (the same O(n) a hash build already costs elsewhere) and makes the lookup
   //--- O(1) instead of a scan per record.
   //--- BUG-01 Fix: build index of existing g_desired rows before mutating.
   //--- Phase 1: compute carry & initLots into g_scratch without touching g_desired.
   //--- In-place mutation during lookup would corrupt the array that g_desIdx probes.
   if(prevCount>0) g_desIdx.Build(g_desired,base,prevCount);
   for(int i=0;i<n;i++)
     {
      double carry=0.0;
      if(prevCount>0)
        {
         int prevRow=g_desIdx.Find(g_desired,g_scratch[i].uid);
         if(prevRow>=base && prevRow<base+prevCount) carry=g_desired[prevRow].initLots;
        }
      //--- Two tiers on purpose:
      //---   the ROW is the primary source (per-sender capacity, cannot be
      //---   evicted while it is live), and
      //---   the TABLE is the fallback for the one case a row cannot answer -
      //---   the first snapshot after `ClearDesired()` (sender restart or new
      //---   SSID), where the previous peak still exists in the table and is
      //---   what keeps a position that was already trimmed before the restart
      //---   from being re-scaled to its original size.
      if(carry<=0.0) carry=GetOrUpdateSenderPeakLots(g_scratch[i].uid,g_scratch[i].lots);
      g_scratch[i].initLots=CopierNextInitLots(carry,g_scratch[i].lots);
     }
   //--- Phase 2: apply new records to g_desired now that index lookups are complete
   for(int i=0;i<n;i++)
     {
      g_desired[base+i]=g_scratch[i];
     }
   //--- C4: release the rows this snapshot shrank past. CopierPos carries three
   //--- strings; leaving them behind kept up to 2048 UID/symbol/comment references
   //--- alive per sender for the life of the terminal, and every shrink of a large
   //--- book leaked another batch.
   //--- C4 / ISSUE-11: Cleanly zero-initialize the rows this snapshot shrank past,
   //--- releasing string references and clearing numerical fields (tickets, prices, lots, types).
   CopierPos emptyPos;
   for(int i=n;i<prevCount && i<CP_MAX_POSITIONS;i++)
     {
      g_desired[base+i]=emptyPos;
     }
   g_desiredCount[si]=n;
   g_ready[si]=true;
   if(g_stale[si])
     {
      g_stale[si]=false;
      g_log.Info("sender "+g_sid[si]+" snapshot received -> stale cleared, mirror active");
     }
   //--- P3: the desired set just changed - reconcile on the very next tick.
   g_convergeDirty[si]=true;
  }

void StopsForget(const string uid)
  {
   for(int i=0;i<g_stCount;i++)
     {
      if(g_stUid[i]==uid)
        {
         int last=g_stCount-1;
         if(i!=last)
           {
            g_stUid[i]=g_stUid[last];
            g_stHasOv[i]=g_stHasOv[last];
            g_stOvSl[i]=g_stOvSl[last];
            g_stOvTp[i]=g_stOvTp[last];
            g_stOvOpn[i]=g_stOvOpn[last];
            g_stOvPprice[i]=g_stOvPprice[last];
            g_stOvPstop[i]=g_stOvPstop[last];
            g_stOvPexp[i]=g_stOvPexp[last];
            g_stLastMs[i]=g_stLastMs[last];
           }
         g_stCount--;
         g_stUid[g_stCount]="";
         g_stHasOv[g_stCount]=false;
         g_stOvEpoch++;                 // the effective override set changed
         StopsRebuildUidIndex();
         return;
        }
     }
  }

//--- index of `uid` in the stop-override table, appending on demand.
//--- The table is FIXED at CP_MAX_STOPS_OV (no ArrayResize), so a full table
//--- is a real state and returns -1: every caller MUST check before indexing.
int StopsOvIndex(const string uid,const bool create)
  {
   // N70-02: O(1) hash lookup via g_stUidIdx replaces linear array scan on hot path
   if(g_stCount>0)
     {
      int found=g_stUidIdx.FindInStrings(g_stUid,uid);
      if(found>=0 && found<g_stCount && g_stUid[found]==uid) return found;
     }
   if(!create) return -1;
   if(g_stCount>=CP_MAX_STOPS_OV)
     {
      StopsPrune(CopierNowMs());
     }
   if(g_stCount>=CP_MAX_STOPS_OV) return -1;
   int n=g_stCount;
   g_stUid[n]=uid;
   g_stHasOv[n]=false;
   g_stOvSl[n]=0.0;
   g_stOvTp[n]=0.0;
   g_stOvOpn[n]=0.0;
   g_stOvPprice[n]=0.0;
   g_stOvPstop[n]=0.0;
   g_stOvPexp[n]=0;
   //--- -1, not 0, for "never pushed". CopierNowMs() is a millisecond counter
   //--- that starts at zero when the terminal does, so a stop change in the
   //--- first second after attach would stamp a real 0 and read back as
   //--- "never" - which silently disables the throttle for the next change.
   g_stLastMs[n]=-1;
   g_stCount++;
   //--- N-04: index the row we just added instead of rebuilding the table
   if(!g_stUidIdx.InsertString(g_stUid,n))
      StopsRebuildUidIndex();   // probe table full / hash clash: full rebuild is the fallback
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
   PruneSenderPeakLots();

   int maxThrottle=StopsThrottleSeconds;
   for(int s=0;s<g_nSenders;s++)
     {
      if(g_senderCfg[s].stopsThrottleSeconds>maxThrottle)
         maxThrottle=g_senderCfg[s].stopsThrottleSeconds;
     }
   long keep=(long)maxThrottle*1000;

   //--- M2 & N70-02 fix: Pre-mark active override UIDs in true O(Desired + Acct) time using
   //--- O(1) g_stUidIdx hash probe instead of O(Overrides * (Senders*Desired + Acct)) string scans.
   static bool s_isOvAlive[CP_MAX_STOPS_OV];
   ArrayInitialize(s_isOvAlive,false);
   if(g_stCount>0)
     {
      for(int s=0;s<g_nSenders;s++)
        {
         int base=s*CP_MAX_POSITIONS;
         for(int d=0;d<g_desiredCount[s];d++)
           {
            int idx=g_stUidIdx.FindInStrings(g_stUid,g_desired[base+d].uid);
            if(idx>=0 && idx<g_stCount) s_isOvAlive[idx]=true;
           }
        }
      for(int k=0;k<g_acctAllPosCount;k++)
        {
         int idx=g_stUidIdx.FindInStrings(g_stUid,g_acctAllPos[k].uid);
         if(idx>=0 && idx<g_stCount) s_isOvAlive[idx]=true;
        }
     }

   int pruned=0;
   for(int i=g_stCount-1;i>=0;i--)
     {
      if(g_stHasOv[i])
        {
         if(s_isOvAlive[i]) continue;
        }
      else
        {
         if(g_stLastMs[i]>=0 && now-g_stLastMs[i]<keep) continue;
        }
      int last=g_stCount-1;
      if(i!=last)
        {
         g_stUid[i]=g_stUid[last];
         g_stHasOv[i]=g_stHasOv[last];
         g_stOvSl[i]=g_stOvSl[last];
         g_stOvTp[i]=g_stOvTp[last];
         g_stOvOpn[i]=g_stOvOpn[last];
         g_stOvPprice[i]=g_stOvPprice[last];
         g_stOvPstop[i]=g_stOvPstop[last];
         g_stOvPexp[i]=g_stOvPexp[last];
         g_stLastMs[i]=g_stLastMs[last];
        }
      g_stCount--;
      //--- M-03: the slot at the old tail is outside the table now. Leaving the
      //--- uid there keeps an MQL string reference alive for the life of the
      //--- array; PruneSenderPeakLots and CopierPosTable::PruneTo already clear
      //--- theirs for exactly this reason.
      g_stUid[g_stCount]="";
      g_stHasOv[g_stCount]=false;
      pruned++;
      g_stOvEpoch++;                   // the effective override set changed
     }
   if(pruned>0) StopsRebuildUidIndex();
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
#include <Copier/RecvHubCtl.mqh>   // Hub control plane: CFG apply/ack, TOPOLOGY, CMD.

void HandleModifyEvent(const int si,const CopierEnv &e)
  {
   CopierPos p;
   if(!CopierPayloadModifyParse(e.payload,p)) return;
   int idx=StopsOvIndex(p.uid,true);
   //--- fixed table, so a full one must be tolerated rather than indexed at -1
   if(idx<0)
     {
      if(g_once.ShouldEmit("stopsovfull"))
         g_log.Warn("stop-override table is full ("+(string)CP_MAX_STOPS_OV
                    +" UIDs); this MODIFY for "+p.uid+" is dropped and the"
                    +" stop will follow the next snapshot instead, which"
                    +" carries the same levels (slower, not lost).");
      return;
     }
   g_stHasOv[idx]=true;
   g_stOvSl[idx]=p.sl;
   g_stOvTp[idx]=p.tp;
   g_stOvOpn[idx]=p.openPx;
   g_stOvPprice[idx]=p.pprice; // BUG-02 & N70-03: Protected in override table only, preventing self-cancelling ppriceCaughtUp
   g_stOvPstop[idx]=p.pstop;   // BUG-05: Real-time StopLimit limit price override
   g_stOvPexp[idx]=p.pexpire;  // BUG-05: Real-time pending expiration override
   g_stOvEpoch++;                          // invalidates the stop-geometry cache
   g_convergeDirty[si]=true;
  }

void HandleOpenEvent(const int si,const CopierEnv &e)
  {
   CopierPos p;
   if(!CopierPayloadOpenParse(e.payload,p)) return;
   int base=si*CP_MAX_POSITIONS;
   for(int i=0;i<g_desiredCount[si];i++)
     {
      if(g_desired[base+i].uid!=p.uid) continue;
      //--- N-03: an OPEN for a UID we already hold is a re-open (same UID, new
      //--- ticket). Keep the peak or the next partial close stops scaling.
      double il=g_desired[base+i].initLots;
      if(il<=0.0) il=g_desired[base+i].lots;
      p.initLots=CopierNextInitLots(il,p.lots);
      g_desired[base+i]=p;
      g_convergeDirty[si]=true;
      return;
     }
   if(g_desiredCount[si]>=CP_MAX_POSITIONS)
     {
      if(g_once.ShouldEmit("desiredfull|"+(string)si))
         g_log.Error("desired positions table is full ("+(string)CP_MAX_POSITIONS
                    +"); open event dropped for "+p.uid);
      return;
     }
   p.initLots=(p.lots>0.0)?p.lots:0.0;    // N-03: first sight is the baseline
   GetOrUpdateSenderPeakLots(p.uid,p.initLots);
   g_desired[base+g_desiredCount[si]]=p;
   g_desiredCount[si]++;
   g_convergeDirty[si]=true;
  }

void HandleCloseEvent(const int si,const CopierEnv &e)
  {
   string uid="";
   if(!CopierKvGet(e.payload,"UID",uid)) return;
   // R47-07: Peak lots & stops cleanup deferred to ConvergeSender once action is queued
   int base=si*CP_MAX_POSITIONS;
   for(int i=0;i<g_desiredCount[si];i++)
     {
      if(g_desired[base+i].uid!=uid) continue;
      for(int k=i;k<g_desiredCount[si]-1;k++) g_desired[base+k]=g_desired[base+k+1];
      g_desired[base+g_desiredCount[si]-1].uid="";
      g_desired[base+g_desiredCount[si]-1].sym="";
      g_desired[base+g_desiredCount[si]-1].cmt="";
      g_desired[base+g_desiredCount[si]-1].ticket=0;
      g_desired[base+g_desiredCount[si]-1].initLots=0.0;
      g_desiredCount[si]--;
      g_convergeDirty[si]=true;
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
   se.gts=(long)TimeGMT();
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
        {
         if(g_once.ShouldEmit("statfail"))
            g_log.Warn("status send failed errno="+(string)g_tp.LastErrno());
        }
      return;
     }

   if(!g_tp.SendStatus(msg))
     {
      if(g_once.ShouldEmit("statfail"))
         g_log.Warn("status send failed errno="+(string)g_tp.LastErrno());
     }
  }

//--- Announce this node to the hub: REG once, HBT2 afterwards.
//---
//--- The hub learns who exists ONLY from these. It never probes for nodes and
//--- never guesses, so a receiver that does not announce itself is invisible -
//--- and in central mode that means the hub can see every sender and no
//--- receiver, which is exactly backwards from what an operator needs to know.
//---
//--- REG and HBT2 share the node payload builder path. HBT2 intentionally
//--- carries NAME so that if Hub restarts and misses initial REG, identity
//--- is promptly recovered without requiring node re-registration.
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
   e.gts=(long)TimeGMT();
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
   long rtt=g_peers.RttFor(g_hubPeerName);
   if(rtt<0) rtt=g_peers.RttFor("hub:primary");
   if(rtt<0) rtt=g_peers.RttFor("hub:standby");
   if(rtt>=0) e.payload+=CP_SEP_KV+"PING="+(string)rtt;
   //--- The WHOLE USED TO RIDE HERE. Every REG answered the hub's 60-second
   //--- sweep with the entire escaped config - ~110 KB per receiver per minute
   //--- forever at 100 senders - to answer one yes/no question. It now carries
   //--- 32 bytes of content hash instead, and the hub pulls the full config
   //--- (reqcfg) only when that hash differs from what it holds or when it has
   //--- nothing on record. The full text still goes out on CFGREPORT, i.e.
   //--- whenever the config actually changed.
   if(isReg)
      e.payload+=CP_SEP_KV+"IH="+CurrentIniHash();

   //--- N73-06: re-assert control channel subscriptions on every announce, so a
   //--- socket rebuild (ConnectHub / a hub that came back after a restart) picks
   //--- them up on the next heartbeat instead of waiting for a reattach.
   //--- N-01: Subscribe() is idempotent now - it only sends 0x01 when this socket
   //--- has not already seen one for that prefix. The old unconditional send made
   //--- XPUB's per-prefix reference count grow by ~3 every 5 s, which meant
   //--- Unsubscribe could never cancel it (removing a sender left its stream
   //--- arriving for the life of the socket).
   g_tp.Subscribe("@"+(string)g_nid);
   long rawAcc=CopierAccountLogin();
   if(rawAcc!=g_nid) g_tp.Subscribe("@"+(string)rawAcc);
   g_tp.Subscribe("@all");

   //--- Dropped silently on purpose: one lost heartbeat is nothing, and a log
   //--- line per failure would be a line per five seconds on a hub that is
   //--- simply not running yet. The hub's WHO sweep is the recovery path.
   g_tp.SendUp("@hub",CopierEncodeEnv(e));
  }

void HandleHeartbeat(const int si,const CopierEnv &e)
  {
   // BUG-85-01: Learn sender clock from periodic heartbeats to maintain active offset calibration
   LearnSenderClock(si,e.ts);
   double eq=CopierKvGetDouble(e.payload,"EQ",0.0);
   if(eq>0.0) g_senderEquity[si]=eq;
   string sCcy=CopierKvGetString(e.payload,"CCY","");
   if(StringLen(sCcy)>0) g_senderCurrency[si]=sCcy;
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
bool AcceptSeq(const int si,const CopierEnv &e,const int stream,const string topic)
  {
   //--- a new session id means the sender restarted: throw away our idea
   //--- of its state and resync from the next snapshot.
   //--- Security guard (F-02 & N49-07): If an event carries a new SSID, allow resync if
   //--- the event arrived on the sender's authentic data topic (or direct mode), avoiding false SECURITY discards.
   if(g_ssidSeen[si]!=e.ssid)
     {
      //--- N71-03: Ignore packets carrying an old, already-abandoned session SSID (delayed arrival from standby hub)
      if(IsAbandonedSsid(si,e.ssid))
        {
         if(g_once.ShouldEmit("oldssid|"+g_sid[si]+"|"+e.ssid))
            g_log.Warn("sender "+g_sid[si]+" packet carries abandoned old SSID '"+e.ssid+"' vs active '"+g_ssidSeen[si]+"' - DISCARDED");
         return false;
        }

      if(stream==CP_STREAM_EVENTS && StringLen(g_ssidSeen[si])>0)
        {
         if(g_hubOn && topic!=g_sid[si] && topic!=g_senderAcc[si] && topic!=(string)g_nid)
           {
            g_log.Warn("SECURITY F-02: sender "+g_sid[si]+" event carries unexpected SSID '"+e.ssid+"' vs '"+g_ssidSeen[si]+"' on topic '"+topic+"' - DISCARDED");
            return false;
           }
        }
      if(StringLen(g_ssidSeen[si])>0)
        {
         RecordAbandonedSsid(si,g_ssidSeen[si]);
        }
      g_ssidSeen[si]=e.ssid;
      g_lastSeq[si][CP_STREAM_EVENTS]=-1;
      g_lastSeq[si][CP_STREAM_SNAP]=-1;
      g_lastSeq[si][CP_STREAM_HBT]=-1;
      g_lastSeqGlobal[si]=0;
      g_ready[si]=false;
      int prevDesired=g_desiredCount[si];
      g_desiredCount[si]=0;
      g_lastSnapMs[si]=0;
      g_snapHash[si]=""; // H5 fix: Clear cached snapshot receipt so STAT sends H="" to trigger immediate bootstrap
      int base=si*CP_MAX_POSITIONS;
      for(int d=0;d<prevDesired;d++)
        {
         if(StringLen(g_desired[base+d].uid)>0)
           {
            StopsForget(g_desired[base+d].uid);
            g_desired[base+d].uid="";
            g_desired[base+d].sym="";
            g_desired[base+d].cmt="";
            g_desired[base+d].ticket=0;
            g_desired[base+d].initLots=0.0;
           }
        }
      g_stOvEpoch++;
      g_snapRejectStreak[si]=0; // NM-14: Clear reject streak on sender restart so failure diagnosis is not biased by prior session
      g_log.Info("sender "+g_sid[si]+" new session "+e.ssid+" -> resync");
     }
   //--- A SNAPSHOT MUST NEVER BE OLDER THAN AN EVENT ALREADY APPLIED.
   //---
   //--- The per-stream watermark below cannot see that on its own: it
   //--- compares a snapshot only with earlier snapshots and an event only
   //--- with earlier events, so a SNAP at seq 90 arriving after an EVENT at
   //--- seq 100 passes the SNAP watermark - nothing was ever seen on that
   //--- stream - and then REPLACES the desired set with the state as it was
   //--- BEFORE that event. Converge reads the freshly opened mirror as "no
   //--- longer desired" and closes it, and the next snapshot opens it again.
   //--- Each round trip costs the spread and the slippage; if the re-open is
   //--- refused by margin or by the risk gate, the position is gone while
   //--- the sender still holds it - an exposure split nothing reports.
   //---
   //--- Two hubs make that arrival order ordinary rather than exotic: each
   //--- delivers its own copy of every frame, and the two links are not
   //--- obliged to preserve the same relative order.
   //---
   //--- The test is ONE-DIRECTIONAL on purpose, and is NOT "reject anything
   //--- below the highest seq seen". One watermark shared by all three
   //--- streams was tried and reverted - see the note on g_lastSeq - because
   //--- a snapshot that overtook the event backlog discarded events that had
   //--- not been applied yet. Here only a SNAPSHOT is checked, and only
   //--- against the EVENT watermark, so no event can ever be dropped by it.
   //---
   //--- It cannot starve the snapshot stream either. The sender numbers a
   //--- frame from one counter when the frame is BUILT, so a snapshot is
   //--- always numbered after the events that precede it: the next periodic
   //--- broadcast carries a seq above anything applied here, and a targeted
   //--- repair is numbered afresh by EmitToNode. Only a snapshot emitted
   //--- BEFORE an event we have already acted on is discarded, and that
   //--- snapshot is stale by definition.
   if(stream==CP_STREAM_SNAP && g_lastSeq[si][CP_STREAM_EVENTS]>=0
      && (long)(e.seq - g_lastSeq[si][CP_STREAM_EVENTS])<0)
     {
      if(g_once.ShouldEmit("stalesnap|"+g_sid[si]))
         g_log.Verbose("discarded snapshot seq="+(string)e.seq+" from sender "
                       +g_sid[si]+": event seq="
                       +(string)g_lastSeq[si][CP_STREAM_EVENTS]
                       +" is already applied, so this snapshot predates it");
      return false;
     }
   // P1-NET-01: An incremental event older than the latest authoritative snapshot is obsolete
   if(stream==CP_STREAM_EVENTS && g_lastSeq[si][CP_STREAM_SNAP]>=0
      && (long)(e.seq - g_lastSeq[si][CP_STREAM_SNAP])<0)
     {
      return false;
     }
   //--- per-stream watermark: a snapshot must never invalidate an event
   //--- that was emitted before it on the other socket
   if((long)(e.seq - g_lastSeq[si][stream])<=0) return false;
   // R12-B04: Sender sequence is global across all streams.
   // Track drops against sender's global high watermark rather than stream watermark to avoid false alarms on stream interleaving.
   long globalGap = (e.seq - g_lastSeqGlobal[si]) - 1;
   if(g_lastSeqGlobal[si] > 0 && globalGap > 0)
     {
      if(g_once.ShouldEmit("net_gap|"+g_sid[si]))
         g_log.Warn("NETWORK DROP: sender "+g_sid[si]+
                    " lost "+(string)globalGap+" frame(s) [expected "+
                    (string)(g_lastSeqGlobal[si]+1)+".."+(string)(e.seq-1)+
                    ", got "+(string)e.seq+"]");
     }
   if(e.seq > g_lastSeqGlobal[si]) g_lastSeqGlobal[si] = e.seq;
   g_lastSeq[si][stream]=e.seq;
   return true;
  }

bool RouteMessage(const string topic,const CopierEnv &e,const int stream)
  {
   //--- F-01: Control frames claiming to be from "hub" must arrive strictly on control channels (@all, @nid, @acc)
   if(e.sid=="hub")
     {
      // NL-06: Apply F-01 unconditionally so direct mode cannot be injected with spoofed SID=hub on data topics
      if(StringLen(topic)==0 || StringSubstr(topic,0,1)!="@")
        {
         g_log.Warn("SECURITY F-01: frame claiming SID=hub received on non-control topic '"+topic+"' - DISCARDED");
         return false;
        }
      if(e.type==CP_T_WHO)
        {
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
            if(g_connectedEpCount<=1 && StringSubstr(pfrom,0,4)=="hub:")
              {
               if(pfrom!=g_singleHubRole)
                 {
                  g_peers.Forget(g_singleHubRole);
                  g_singleHubRole=pfrom;
                 }
              }
            if(g_peers.PongBack(pfrom,CopierParseLong(pms)))
              {
               // V3/C4: disarm only after every expected echo has landed
               if(g_pumpPongExpect>0) g_pumpPongExpect--;
               if(g_pumpPongExpect<=0) g_pump.Disarm();
               if(g_once.ShouldEmit("rtt|"+pfrom))
                  g_log.Info("link to "+pfrom+" measured: "
                             +(string)g_peers.RttFor(pfrom)+" ms round trip");
              }
           }
        }
      else if(e.type==CP_T_TOPOLOGY) HandleTopology(e);
      else if(e.type==CP_T_CFG) HandleCfg(e);
      else if(e.type==CP_T_CMD) HandleCmd(e);
      else if(g_once.ShouldEmit("hubctl|"+e.type))
         g_log.Info("central channel: hub sent "+e.type
                    +" (no receiver action for it)");
      return false;
     }

   //--- Control channels (@all, @nid, @acc) are strictly reserved for SID=hub (D5-02)
   if(StringSubstr(topic,0,1)=="@")
     {
      g_log.Warn("SECURITY: non-hub SID '"+e.sid+"' attempted transmission on control topic '"+topic+"' - DISCARDED");
      return false;
     }

   //--- F-02 & N49-14: Targeted repair topic (<myNid>) is strictly for SNAP frames from other senders.
   //--- In self-copy mode, sender NID equals my NID; do not drop legitimate self-copy events.
   if(g_hubOn && (topic==(string)g_nid || topic==(string)CopierAccountLogin())
      && e.sid!=(string)g_nid && e.sid!=(string)CopierAccountLogin())
     {
      if(e.type!=CP_T_SNAP)
        {
         g_log.Warn("SECURITY F-02: non-SNAP type '"+e.type+"' from SID "+e.sid+" on targeted repair topic '"+topic+"' - DISCARDED");
         return false;
        }
     }

   int si=SenderIndexById(e.sid);
   if(si<0) return false;                       // not one of ours

   g_lastMsgMs[si]=CopierNowMs();
   if(g_firstMsgMs[si]==0) g_firstMsgMs[si]=g_lastMsgMs[si];

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
   if(g_hubOn) return false;

      string pms="",pfrom="";
      CopierKvGet(e.payload,"MS",pms);
      CopierKvGet(e.payload,"FROM",pfrom);
      //--- address the reply back to whoever asked, so other receivers ignore
      //--- it; FROM names us, so the sender can attribute our echo.
      CopierSendStatus(CP_T_PONG,
                       CopierPayloadPong(CopierParseLong(pms),
                                         (string)CopierAccountLogin(),pfrom));
      return false;
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
         // V3/C4: disarm only after every expected echo has landed
         if(g_pumpPongExpect>0) g_pumpPongExpect--;
         if(g_pumpPongExpect<=0) g_pump.Disarm();
         //--- first successful measurement: the only line that distinguishes
         //--- "the link is fine" from "both ends answer and nobody records it"
         if(g_once.ShouldEmit("rtt|"+pfrom))
            g_log.Info("link to "+pfrom+" measured: "
                       +(string)g_peers.RttFor(pfrom)+" ms round trip");
        }
      return false;
     }

   // ISSUE-03 / N-07 & H-02: Security check MUST run BEFORE AcceptSeq!
   // An unauthorized CFG/CMD frame on a data topic must not advance the sequence watermark
   // before being rejected, which would cause subsequent legitimate trade events to be dropped.
   if(e.type==CP_T_CFG || e.type==CP_T_CMD)
     {
      g_log.Warn("SECURITY: rejected "+e.type+" frame from data stream / sender "+g_sid[si]+"; control frames only accepted from @hub");
      return false;
     }

   int effectiveStream=(e.type==CP_T_HBT)?CP_STREAM_HBT:stream;
   if(!AcceptSeq(si,e,effectiveStream,topic))
     {
      g_dropped[si]++;
      return false;
     }
   if(e.type==CP_T_SNAP)       HandleSnapshot(si,e);
   else if(e.type==CP_T_OPEN)  HandleOpenEvent(si,e);
   else if(e.type==CP_T_CLOSE) HandleCloseEvent(si,e);
   else if(e.type==CP_T_MODIFY) HandleModifyEvent(si,e);
   else if(e.type==CP_T_HBT)   HandleHeartbeat(si,e);
   else                        g_log.Verbose("ignoring type "+e.type);
   return true;
  }

void HandleMessage(const string topic,const string msg,const int stream)
  {
   CopierEnv e;
   int err=CopierDecodeEnv(msg,e);
   if(err!=CP_ERR_NONE)
     {
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
   RouteMessage(topic,e,stream);
  }

//=====================================================================
// Lifecycle
//=====================================================================
int OnInit()
  {
   ResetRuntimeInputsFromInputs();
   CopierSymInfoReset(); // BUG-04: flush symbol specifications cache on init
   //--- One log per instance, or two receivers in one terminal write the same
   //--- file and overwrite each other's history.
   g_log.Init("receiver"+InstanceSuffix(),LogLevel);
#ifdef __MQL5__
   for(int cWait=0; cWait<20 && (!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN)<=0); cWait++)
      CopierWaitMs(100);
   if(CopierIsNettingAccount())
     {
      g_log.Error("CRITICAL: this terminal is running on a NETTING account."
                  +" Netting accounts merge multiple positions per symbol and"
                  +" overwrite order comments, breaking the one-UID-one-position"
                  +" invariant and causing an infinite trade loop."
                  +" The copier requires a HEDGING account.");
      Alert("Copier RECEIVER: Cannot run on a NETTING account. Hedging account required.");
      return INIT_FAILED;
     }
   if(CopierAccountMode()<0)
      g_log.Warn("Account not connected during init; hedging mode verification deferred to runtime.");
#endif
   if(!AcquireInstanceLock()) return INIT_FAILED;
   // R12-B03: Seed PRNG with salted entropy to avoid lock-step reconnect SYN storms across receiver fleet
   MathSrand((int)(CopierNowMs() ^ (long)TimeLocal() ^ (long)CopierAccountLogin() ^ (long)g_nid));
   g_seen.SetTtlMs(600000);
   g_inflight.SetTtlMs(5000); // R17-A07: 5-second in-flight window preventing async duplicate dispatch
   g_inflight.Clear();
   g_backoff.Clear();
   g_emgSlApplied.SetTtlMs(24*60*60*1000);
   g_emgSlApplied.Clear();
   g_unsupported.SetTtlMs(CP_UNSUPPORTED_MS);
   g_onceFail.SetRepeatMs(60000);
   g_onceHbt.SetRepeatMs(60000);
   g_onceHour.SetRepeatMs(60*60*1000);
   // MQL-02: Reset stop override tables on re-init so parameter changes don't inherit stale in-memory overrides.
   // Legitimate persisted overrides are restored cleanly by LoadStates() below.
   for(int i=0;i<g_stCount;i++) g_stUid[i]="";
   g_stCount=0;
   ArrayInitialize(g_stHasOv,false);
   ArrayInitialize(g_stLastMs,0);
   g_stOvEpoch++;
   StopsRebuildUidIndex();
   ZeroMemory(g_stopSig);

   //--- Reset position scan, cache and hash index globals so hot reload doesn't inherit stale state
   g_acctAllPosCount=0;
   g_acctScanned=false;
   g_posCacheCount=0;
   g_lastOrdersTotal=-1;
   g_lastFullScanMs=0;
   g_locIdx.Clear();
   g_desIdx.Clear();
   g_qCloseIdx.Clear();
   ArrayInitialize(s_posCacheTkSlot,0);
   ArrayInitialize(s_posCacheTkHash,0);
   g_waitHeld=0;
   g_waitLots=0.0;
   g_mktHeld=0;
   g_mktHeldLots=0.0;
   g_riskBlocked=0;
   g_snapSkipped=0;
   g_snapDeclFailed=0;
   g_qDeferred=0;
   g_pushReject="";

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
   //--- N-11: 7 days, not 12 hours. This ring is what makes `ReopenClosedMirrors
   //--- = false` mean "the operator closed it, leave it closed"; the TTL exists
   //--- only because the ring is fixed-size. At 12 h a Friday-evening manual
   //--- close had expired by Monday, so the same UID (sender still holding it)
   //--- looked like a FIRST open and was mirrored back.
   g_everOpened.SetTtlMs(CP_EVEROPENED_TTL_MS);
   //--- Only has to bridge the gap between our own close and the replacement
   //--- open on the next pass - seconds in practice. Five minutes is generous
   //--- enough to survive a retrying close without letting the exemption
   //--- linger into a genuinely separate event.
   g_reopenExpected.SetTtlMs(5*60*1000);
   g_fillGraceRing.SetTtlMs(60000);
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
   g_recKnown.Clear(); // DEF-11-01: clear in-memory table before restoring so stale ghost entries don't persist across hot reload
   if(CopierStateFile::Load(ReceiverStatePath(),hdr,saved,savedN))
     {
      g_stateRestored=true;
      for(int i=0;i<savedN;i++) g_recKnown.Upsert(saved[i]);
      //--- Seed "ever opened" from the same file. These are exactly the
      //--- mirrors this receiver opened and still holds, which is what the
      //--- per-tick Add() used to cover - and doing it here costs one pass at
      //--- startup instead of 300 ring writes every tick.
      for(int i=0;i<savedN;i++)
        {
         if(StringLen(saved[i].uid)!=CP_UID_LEN) continue;
         for(int k=0;k<g_nSenders;k++)
           {
            if(saved[i].magic!=g_magic[k]) continue;
            g_everOpened.Add(g_sid[k]+":"+(string)CP_ACT_OPEN+":"+saved[i].uid);
            break;
           }
        }
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
   if(ArrayResize(g_desired,g_nSenders*CP_MAX_POSITIONS)<0 ||
      ArrayResize(g_scratch,CP_MAX_POSITIONS)<0)
     {
      g_log.Error("out of memory allocating desired position arrays in OnInit");
      return INIT_FAILED;
     }

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
      if(kr==CP_KEY_REPLACED)
        {
         g_log.Error("CRITICAL: Receiver CURVE key was corrupt/replaced with a fresh keypair! "
                     +"All upstream Senders and Hubs will reject this receiver until updated. Refusing to start automatically.");
         Alert("Copier RECEIVER: CURVE key regenerated! Senders/Hub must be updated with the new public key.");
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

   g_bootMs=CopierNowMs();
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
      //--- N57-01: also subscribe to the RAW account number.
      //---
      //--- CopierNid() truncates accounts >= 1e9 (10 digits) modulo 1e9 to keep
      //--- the mirror magic inside 32 bits. The hub, however, addresses control
      //--- topics by the account it received in REG - the RAW one, because
      //--- CopierPayloadReg() reports CopierAccountLogin(). For a 9-digit
      //--- account the two strings are identical and this line changes nothing;
      //--- for a 10-digit account it is the difference between working and
      //--- being unreachable while still showing "online" in the dashboard.
      long rawAcc=CopierAccountLogin();
      if(rawAcc!=g_nid) g_tp.Subscribe("@"+(string)rawAcc);
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
      //--- F-04: also subscribe to rawAcc as a DATA topic for targeted snapshot repair from senders
      if(rawAcc!=g_nid) g_tp.Subscribe((string)rawAcc);
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
      int extraTopics=(rawAcc!=g_nid)?1:0;
      g_log.Info("central mode: connected to "+g_hubEp+" as NID="
                 +(string)g_nid+", subscribed to "
                 +IntegerToString(g_nSenders+3+extraTopics)+" topic(s)");
     }
   else
     {
      string evEnd[];
      ArrayResize(evEnd,g_nSenders);
      for(int i=0;i<g_nSenders;i++) evEnd[i]=g_epEvents[i];

      if(UseCurve)
        {
         string trimmedKey=CopierTrim(SenderServerKey);
         if(StringLen(trimmedKey)==0)
           {
            g_log.Error("Direct mode: UseCurve is true but SenderServerKey is empty. Set SenderServerKey to sender's 40-character public key.");
            return INIT_FAILED;
           }
         if(StringLen(trimmedKey)!=CP_KEY_LEN)
           {
            g_log.Error("Direct mode: SenderServerKey must be exactly "+IntegerToString(CP_KEY_LEN)+" characters (got "+IntegerToString(StringLen(trimmedKey))+"). Check for extra spaces or truncated paste.");
            return INIT_FAILED;
           }
         for(int k=0;k<g_nSenders && k<CP_MAX_SENDERS;k++)
           {
            if(StringLen(g_serverKey[k])==0) g_serverKey[k]=trimmedKey;
           }
        }

      if(!g_tp.ConnectReceiver(evEnd,g_nSenders,
                               UseCurve,g_serverKey,g_myPublicKey,mySecret))
        {
         g_log.Error("cannot connect errno="+(string)g_tp.LastErrno());
         return INIT_FAILED;
        }
     }

   ClearQueue(); // F-03: explicitly initialize queue on startup

   //--- the status channel needs no setup of its own: it goes up the socket
   //--- the data already comes down.


   timeBeginPeriod(1);
   int effectivePollMs=PollMs;
   if(effectivePollMs<1) effectivePollMs=1;
   if(effectivePollMs>5000) effectivePollMs=5000;
   if(!EventSetMillisecondTimer(effectivePollMs))
     {
      g_log.Error("EventSetMillisecondTimer("+(string)effectivePollMs+") failed");
      return INIT_FAILED;
     }
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

   ClearQueue();
   g_pump.Init();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_pump.Disarm();
   EventKillTimer();
   timeEndPeriod(1);
   ClearQueue();

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

   int an=CopierReadPositions(g_scanScratch,CP_MAX_POSITIONS);
   string held="";
   int hc=0;
   for(int i=0;i<an;i++)
     {
      string uid=CopierUidFromComment(g_scanScratch[i].cmt);
      if(StringLen(uid)==0)
        {
         CopierPos prev;
         if(g_recKnown.GetByTicket(g_scanScratch[i].ticket,prev)) uid=prev.uid;
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

   //--- Flush position scan, cache, hash index, idempotency and memory buffers so hot reload doesn't inherit stale state
   g_acctAllPosCount=0;
   g_acctScanned=false;
   g_posCacheCount=0;
   g_lastOrdersTotal=-1;
   g_lastFullScanMs=0;
   g_recKnown.Clear();
   g_locIdx.Clear();
   g_desIdx.Clear();
   g_qCloseIdx.Clear();
   ArrayInitialize(s_posCacheTkSlot,0);
   ArrayInitialize(s_posCacheTkHash,0);
   ZeroMemory(g_stopSig);
   g_seen.Clear();
   g_inflight.Clear();
   g_unsupported.Clear();
   g_fillGraceRing.Clear();
   g_mktClosed.Clear();
   g_manualClosed.Clear();
   g_backoff.Clear();
   for(int i=0;i<CP_MAX_ACTIONS;i++)
     {
      g_sweepFailed[i].uid="";
      g_sweepFailed[i].sym="";
      g_sweepFailed[i].key="";
      g_sweepFailed[i].ticket=0;
     }
   for(int i=0;i<CP_MAX_POSITIONS;i++)
     {
      g_rawScratch[i].uid=""; g_rawScratch[i].sym=""; g_rawScratch[i].cmt="";
      g_scanScratch[i].uid=""; g_scanScratch[i].sym=""; g_scanScratch[i].cmt="";
      g_locScratch[i].uid=""; g_locScratch[i].sym=""; g_locScratch[i].cmt="";
      g_acctAllPos[i].uid=""; g_acctAllPos[i].sym=""; g_acctAllPos[i].cmt="";
      g_posCache[i].uid=""; g_posCache[i].cmt="";
      g_posCacheNext[i].uid=""; g_posCacheNext[i].cmt="";
     }
   ArrayFree(g_desired);
   ArrayFree(g_scratch);
   g_saveScratch.Clear();
   g_peers.Clear();
   g_permitted.Clear();
   g_permittedMagic.Clear();
   g_hours.Clear();
   g_ignore.Clear();
   g_once.Clear();
   g_onceHbt.Clear();
   g_onceNoSnap.Clear();
   g_onceFail.Clear();
   g_onceHour.Clear();
   g_log.Close();
  }

//--- Probe every sender, and say once when one goes quiet.
//---
//--- The sender's own traffic is frequent enough here (snapshot every 2s,
//--- heartbeat every 1s), so this probe is not strictly required for liveness
//--- on THIS side - but it is what makes the round-trip number exist at all,
//--- and the sender needs our echo for its own panel. One mechanism, both
//--- directions, rather than each side guessing differently.
void CheckPeersPing(const long now)
  {
   bool armedRound=false;
   if(!g_hubOn && now-g_lastPingMs>=CP_PING_MS)
     {
      g_lastPingMs=now;
      g_pumpPongExpect=0;
      armedRound=true;
      CopierSendStatus(CP_T_PING,
                       CopierPayloadPing(now,(string)CopierAccountLogin()));
      for(int k=0;k<CP_MAX_PEERS;k++)
        {
         string pn=g_peers.NameAt(k);
         if(StringLen(pn)>0)
           {
            if(IsHubPeerName(pn)) continue; // M1: Do not overwrite hub peer probe timestamps from direct ping
            g_peers.ProbeSentAt(k,now);
            g_pumpPongExpect++;
           }
        }
     }

   if(g_hubOn && now-g_lastHubPingMs>=CP_PING_MS)
     {
      g_lastHubPingMs=now;
      if(!armedRound)
        {
         g_pumpPongExpect=0;
         armedRound=true;
        }
      CopierEnv he;
      he.v=CP_PROTO_V;
      he.sid=(string)g_nid;
      he.ssid=(string)CopierAccountLogin();
      he.seq=++g_statusSeq;
      he.ts=CopierServerTime();
      he.ms=now;
      he.gts=(long)TimeGMT();
      he.type=CP_T_PING;
      he.payload=CopierPayloadPing(now,(string)g_nid);
      g_tp.SendUp("@hub",CopierEncodeEnv(he));
      if(g_connectedEpCount>1)
        {
         g_peers.ProbeSent("hub:primary",now);
         g_peers.ProbeSent("hub:standby",now);
         g_peers.Forget(g_hubPeerName); // Clean up standalone placeholder
         g_pumpPongExpect+=2;           // dual-sent: both hubs answer
        }
      else
        {
         g_peers.ProbeSent(g_singleHubRole,now);
         g_peers.Forget(g_hubPeerName); // Clean up standalone placeholder
         g_pumpPongExpect+=1;
        }
     }
   if(armedRound && g_pumpPongExpect>0)
      g_pump.ArmFast(); // Bounded micro burst sized to the echos this round expects
  }

//--- F-09: accurately recognize hub peers whether standalone "hub" or HA "hub:primary" / "hub:standby"
bool IsHubPeerName(const string nm)
  {
   return (nm==g_hubPeerName || StringSubstr(nm,0,4)=="hub:");
  }

void CheckPeersLiveness(const long now)
  {
   for(int i=0;i<CP_MAX_PEERS;i++)
     {
      string nm=g_peers.NameAt(i);
      if(StringLen(nm)==0)
        {
         g_lastTrackedName[i]="";
         g_peerWasDown[i]=false;
         g_peerAlerted[i]=0;
         continue;
        }

      if(g_lastTrackedName[i]!=nm)
        {
         g_lastTrackedName[i]=nm;
         g_peerWasDown[i]=false;
         g_peerAlerted[i]=0;
        }

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
         string what=IsHubPeerName(nm)?"hub":"sender";
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
         string what=IsHubPeerName(nm)?"hub":"sender";
         g_log.Info(what+" "+nm+" is back");
        }
     }
  }

//--- The on-chart panel: what this account is actually holding, and who it is
//--- holding it for.
void UpdatePanel()
  {
   if(!ShowPanel) return;

   //--- Throttle GUI panel redraws to at most once per 1.5 seconds (1500ms).
   //--- Redrawing heavy on-chart objects at 10 Hz burns massive Windows GDI CPU for nothing.
   long now=CopierNowMs();
   if(now-g_lastPanelRenderMs<1500) return;
   g_lastPanelRenderMs=now;

   //--- Directly reuse the figures already computed during RefreshRisk!
   //--- ZERO terminal scans and ZERO comment string parsing!
   //---
   //--- "Managing" means the positions this copier owns, not everything on
   //--- the account: another EA's trades are not ours to manage and counting
   //--- them made the panel disagree with the volume line below it.
   int nOpen=g_ourPositions;
   int nPend=g_ourPending;
   int nOrphan=g_orphanCount;
   int orphShown=0;
   string orphLine[CP_PANEL_ORPHAN_SHOW];

   if(ShowOrphanedList && nOrphan>0)
     {
      for(int i=0;i<g_acctAllPosCount && orphShown<CP_PANEL_ORPHAN_SHOW;i++)
        {
         if(g_posCache[i].isOrphan)
           {
            orphLine[orphShown]="  "+g_acctAllPos[i].sym+"  #"+(string)g_acctAllPos[i].ticket
                                +"  magic "+(string)g_acctAllPos[i].magic;
            orphShown++;
           }
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
   int np=0;
   int nTotal=0;
   for(int i=0;i<CP_MAX_PEERS;i++)
     {
      string pnm=g_peers.NameAt(i);
      if(StringLen(pnm)==0) continue;
      if(pnm==g_hubPeerName) continue; // skip standalone generic "hub" placeholder
      nTotal++;
      if(IsHubPeerName(pnm))
        {
         if(g_hubOn && g_peers.StateAt(i,CP_PEER_TIMEOUT_MS)==CP_PEER_UP) np++;
         continue;
        }
      if(g_peers.StateAt(i,CP_PEER_TIMEOUT_MS)==CP_PEER_UP) np++;
     }
   //--- The orphan block only exists when ShowOrphanedList is on. Sizing the
   //--- panel for rows that will not be written would leave a gap at the
   //--- bottom of the background - the panel would look broken rather than
   //--- simply shorter.
   //--- N78-02: Calculate exact orphan rows drawn instead of overestimating to prevent dead gaps.
   int orphanRows=(ShowOrphanedList ? (1 + orphShown + ((nOrphan > orphShown) ? 1 : 0)) : 0);
   //--- Detail rows for the first few peers; the rest get ONE summary line
   //--- instead of being dropped off the bottom of the panel.
   //--- BUG-03: Cap display rows by total displayable peers nTotal so down/hub peers are not hidden.
   int peerShow=(nTotal>CP_PANEL_PEER_SHOW)?CP_PANEL_PEER_SHOW:nTotal;
   int peerMore=(nTotal>peerShow)?1:0;
   int riskRow=g_risk.AnyTripped()?1:0;
   int queueRow=(g_qn>0)?1:0;
   //--- N78-02: Base rows is 9 plus dynamic Queue line when queue > 0.
   int rows=9+queueRow+riskRow+peerShow+peerMore+orphanRows;
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

   //--- P1: the queue's own state, and whether the periodic drain is backing
   //--- off. A queue that cannot drain is not an error - the market is shut - but
   //--- it used to be re-walked 200 times a second to discover that, forever.
   //--- Showing the backoff makes both the state and the fix visible instead of
   //--- leaving "my EA burns a core at the weekend" to be diagnosed from scratch.
   if(g_qn>0)
     {
      long nowQ=CopierNowMs();
      bool spinning=(!CopierQueueMayDrain(nowQ,g_qRetryAtMs));
      int waitMs=(int)(g_qRetryAtMs-nowQ);
      if(waitMs<0) waitMs=0;
      string qstatus = "   draining";
      if(spinning)
        {
         if(g_qBackoffMs>=900000)
            qstatus="   held (market closed, awaits reopen)";
         else
            qstatus="   held, retry in "+CopierQueueBackoffText(waitMs);
        }
      g_panel.Row(r++,"Queue      "+IntegerToString(g_qn)+" action(s)"+qstatus,
                  spinning?CP_PANEL_WARN:CP_PANEL_TEXT);
     }

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

   int shown=0;
   for(int i=0;i<CP_MAX_PEERS && shown<peerShow;i++)
     {
      string nm=g_peers.NameAt(i);
      if(StringLen(nm)==0) continue;
      // Hide the standalone generic "hub" placeholder as hub responds with hub:primary / hub:standby
      if(nm==g_hubPeerName) continue;
      shown++;
      long silent=g_peers.SilentAt(i);
      int  st=g_peers.StateAt(i,CP_PEER_TIMEOUT_MS);
      bool down=(st==CP_PEER_DOWN);
      long rtt=g_peers.RttAt(i);

      bool isHub=(nm==g_hubPeerName || StringSubstr(nm,0,4)=="hub:");

      string line="";
      if(isHub)
        {
         string hubLabel="  HUB  ";
         string epShown=g_hubEp;
         if(nm=="hub:primary")
           {
            hubLabel=(g_connectedEpCount>1)?"  HUB1 ":"  HUB  ";
            if(g_connectedEpCount>0) epShown=g_connectedEps[0];
           }
         else if(nm=="hub:standby")
           {
            hubLabel="  HUB2 ";
            if(g_connectedEpCount>1) epShown=g_connectedEps[1];
           }
         line=hubLabel+epShown+"   ";
        }
      else
         line="  "+nm+"   ";
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

   //--- The rest, named as a count rather than vanished: the panel is a
   //--- rectangle and 100 peer rows do not fit on any chart.
   if(peerMore)
      g_panel.Row(r++,"  ... and "+(string)(nTotal-peerShow)+" more peer(s)"
                      +" - the hub dashboard lists every one",
                  CP_PANEL_DIM);

   if(g_risk.AnyTripped())
      g_panel.Row(r++,"RISK: "+g_risk.BlockKey(),CP_PANEL_WARN);

   g_panel.Row(r++," ",CP_PANEL_TEXT);
   g_panel.End();
  }

bool IsTopicForReceiver(const string topic,const string envSid)
  {
   if(!g_hubOn) return true;
   return CopierIsTopicTarget(topic,(string)g_nid,(string)CopierAccountLogin(),g_sid,g_nSenders,envSid);
  }

void OnTimer()
  {
   // R11-A05: Atomic reentrancy guard for OnTimer against nested OnChartEvent / pump triggers
   static bool s_inTimer=false;
   if(s_inTimer) return;
   s_inTimer=true;

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
   //---
   //--- The buffers are file-level statics (g_drainTopics / g_drainMsgs), so
   //--- the drain does no allocation at all. `n` is the ONLY valid length -
   //--- the arrays are CP_DRAIN_MAX long forever, and their tails hold frames
   //--- from previous ticks.
   int n=g_tp.DrainFrames(g_drainTopics,g_drainMsgs,CP_DRAIN_MAX);
   long now=CopierNowMs();

#ifdef __MQL5__
   static long lastConnCheck=0;
   if(now-lastConnCheck>=1000)
     {
      lastConnCheck=now;
      if(CopierIsConnected() && CopierIsNettingAccount())
        {
         g_log.Error("CRITICAL: Terminal connected to a NETTING account at runtime! Netting accounts violate one-UID-one-position invariant. Emergency disarming receiver.");
         Alert("Copier RECEIVER: NETTING account detected at runtime! Emergency STOP.");
         ExpertRemove();
         s_inTimer=false;
         return;
        }
     }
#endif
   CheckPeersPing(now);
   if(n>=CP_DRAIN_MAX && g_once.ShouldEmit("drainfull"))
      g_log.Warn("drain hit the per-tick bound of "+(string)CP_DRAIN_MAX
                 +" message(s) - there is more waiting, so the EA is falling"
                 +" behind. Lower SnapshotSeconds on the sender or raise"
                 +" PollMs here.");
   if(n>0)
     {
      //--- Conflate snapshots PER SENDER (e.sid) in arrival order in O(N) time:
      //--- Step 1: Decode each message ONCE into pre-allocated scratch arrays
      //--- Step 2: Backward pass records the latest SNAP for each sender
      //--- Step 3: Forward pass executes messages, skipping superseded SNAPs
      static CopierEnv s_envs[CP_DRAIN_MAX];
      static int       s_errs[CP_DRAIN_MAX];
      static bool      s_isLatestSnap[CP_DRAIN_MAX];

      for(int i=0;i<n;i++)
        {
         s_errs[i]=CopierDecodeEnv(g_drainMsgs[i],s_envs[i]);
         string esid=(s_errs[i]==CP_ERR_NONE ? s_envs[i].sid : "");
         if(!IsTopicForReceiver(g_drainTopics[i],esid))
           {
            s_errs[i]=-999; // Discard: prefix collision from ZMQ SUB filter
            continue;
           }
         s_isLatestSnap[i]=false;
        }

      // HA-02, N67-04 & N68-03: Conflate snapshots PER SENDER by selecting the snapshot with the MAXIMAL SEQ
      // within the current session, immune to multi-hub arrival jitter (older Standby snapshot arriving after newer Primary snapshot).
      // Sized to CP_DRAIN_MAX (256) matching maximum drain frames per tick.
      // s_seenSnapHash provides O(1) integer pre-check before string comparison, avoiding O(N^2) CPU overhead.
      static string s_seenSnapSid[CP_DRAIN_MAX];
      static uint   s_seenSnapHash[CP_DRAIN_MAX];
      static string s_bestSnapSsid[CP_DRAIN_MAX];
      static long   s_bestSnapSeq[CP_DRAIN_MAX];
      static int    s_bestSnapIdx[CP_DRAIN_MAX];
      int snapSendersCount=0;

      for(int i=0;i<n;i++)
        {
         if(s_errs[i]==CP_ERR_NONE && s_envs[i].type==CP_T_SNAP)
           {
            // N71-03: Skip snapshots from abandoned old sessions during drain conflation
            int si_check=-1;
            for(int k=0;k<g_nSenders;k++) if(g_sid[k]==s_envs[i].sid) { si_check=k; break; }
            if(si_check>=0 && IsAbandonedSsid(si_check,s_envs[i].ssid)) continue;

            int slot=-1;
            uint hSid=(uint)CopierHash32(s_envs[i].sid);
            for(int s=0;s<snapSendersCount;s++)
              {
               if(s_seenSnapHash[s]==hSid && s_seenSnapSid[s]==s_envs[i].sid) { slot=s; break; }
              }
            if(slot<0)
              {
               if(snapSendersCount<CP_DRAIN_MAX)
                 {
                  slot=snapSendersCount++;
                  s_seenSnapSid[slot]=s_envs[i].sid;
                  s_seenSnapHash[slot]=hSid;
                  s_bestSnapSsid[slot]=s_envs[i].ssid;
                  s_bestSnapSeq[slot]=s_envs[i].seq;
                  s_bestSnapIdx[slot]=i;
                 }
              }
            else
              {
               // M-01 fix: if current active session matches, prioritize active session
               int si_match=-1;
               for(int k=0;k<g_nSenders;k++) if(g_sid[k]==s_envs[i].sid) { si_match=k; break; }
               string activeSsid=(si_match>=0 ? g_ssidSeen[si_match] : "");

               if(s_envs[i].ssid==s_bestSnapSsid[slot])
                 {
                  if(s_envs[i].seq>s_bestSnapSeq[slot])
                    {
                     s_bestSnapSeq[slot]=s_envs[i].seq;
                     s_bestSnapIdx[slot]=i;
                    }
                 }
               else if(StringLen(activeSsid)>0 && s_envs[i].ssid==activeSsid)
                 {
                  // Incoming matches our active session; candidate does not -> keep active
                  s_bestSnapSsid[slot]=s_envs[i].ssid;
                  s_bestSnapSeq[slot]=s_envs[i].seq;
                  s_bestSnapIdx[slot]=i;
                 }
               else if(StringLen(activeSsid)>0 && s_bestSnapSsid[slot]==activeSsid)
                 {
                  // Candidate already matches active session -> ignore foreign session
                 }
               else if(s_envs[i].seq>s_bestSnapSeq[slot])
                 {
                  s_bestSnapSsid[slot]=s_envs[i].ssid;
                  s_bestSnapSeq[slot]=s_envs[i].seq;
                  s_bestSnapIdx[slot]=i;
                 }
              }
           }
        }
      for(int s=0;s<snapSendersCount;s++)
        {
         int bi=s_bestSnapIdx[s];
         if(bi>=0 && bi<n) s_isLatestSnap[bi]=true;
        }

      bool hasFastAction=false;
      bool fastSender[CP_MAX_SENDERS];
      ArrayInitialize(fastSender,false);
      for(int i=0;i<n;i++)
        {
         if(s_errs[i]==-999) continue;
         if(s_errs[i]!=CP_ERR_NONE)
           {
            HandleMessage(g_drainTopics[i],g_drainMsgs[i],CP_STREAM_EVENTS);
            continue;
           }
         if(s_envs[i].type==CP_T_SNAP)
           {
            if(!s_isLatestSnap[i])
              {
               g_snapSkipped++;
               continue;
              }
            RouteMessage(g_drainTopics[i],s_envs[i],CP_STREAM_SNAP);
            continue;
           }
         if(s_envs[i].type==CP_T_OPEN || s_envs[i].type==CP_T_CLOSE || s_envs[i].type==CP_T_MODIFY)
           {
            if(RouteMessage(g_drainTopics[i],s_envs[i],CP_STREAM_EVENTS))
              {
               hasFastAction=true;
               int fsi=SenderIndexById(s_envs[i].sid);
               if(fsi>=0 && fsi<CP_MAX_SENDERS) fastSender[fsi]=true;
              }
            continue;
           }
         RouteMessage(g_drainTopics[i],s_envs[i],CP_STREAM_EVENTS);
        }

      //--- Fast-Track: If any trade event arrived, converge active senders and execute immediately!
      //--- N49-08 & MQL-02: Only converge senders that actually received trade events in this batch.
      //--- Per-sender wait buckets are updated in ConvergeSender(i) without clearing other senders' telemetry.
      if(hasFastAction)
        {
         g_pump.ArmFast(); // Bounded micro burst to execute queue on high-priority chart pump
         RefreshRisk();    // R47-06: Update account position risk counts before fast-track converge & execute
         static int s_fastRrStart=0;
         if(g_nSenders>0)
           {
            int start=s_fastRrStart%g_nSenders;
            for(int off=0;off<g_nSenders;off++)
              {
               int i=(start+off)%g_nSenders;
               if(fastSender[i] && !g_stale[i] && g_ready[i]) ConvergeSender(i);
              }
            s_fastRrStart=(start+1)%g_nSenders;
           }
         ExecuteQueue();
         // BUG-01 (Report 2): Only clear dirty flags for senders that actually converged in this fast batch
         bool anyRemainingDirty=false;
         for(int k=0; k<g_nSenders; k++)
           {
            if(fastSender[k]) g_convergeDirty[k]=false;
            else if(g_convergeDirty[k]) anyRemainingDirty=true;
           }
         if(!anyRemainingDirty)
           {
            g_convergeDirtyAll = false;
            g_lastConvergeSweepMs = now; // Stave off immediate redundant slow-lane sweep only when all senders clean
           }
        }

      // N67-04 & N68-03: Clear string references on static conflate table to prevent dead string retention
      for(int sc=0;sc<snapSendersCount;sc++)
        {
         s_seenSnapSid[sc]="";
         s_seenSnapHash[sc]=0;
         s_bestSnapSsid[sc]="";
        }
      // D6-02: Clear decoded envelope strings to release multi-megabyte snapshot payload buffers
      for(int ec=0;ec<n;ec++)
        {
         s_envs[ec].payload="";
         s_envs[ec].sid="";
         s_envs[ec].ssid="";
         s_envs[ec].type="";
        }
     }

   //--- Background retry for closeall / risk-close if queue was full during initial batch
   //--- Step-ladder retry: 1s -> 3s -> 10s -> 30s to prevent constant 1s background churn while ensuring exit completion
   static long s_lastCloseAllRetryMs=0;
   static int  s_closeAllPasses=0;
   if(!g_cmdCloseAllActive && !g_riskCloseAllPending)
     {
      s_closeAllPasses=0;
     }
   else
     {
      long closeAllInterval = (s_closeAllPasses<=1) ? 1000 : ((s_closeAllPasses==2) ? 3000 : ((s_closeAllPasses==3) ? 10000 : 30000));
      if(now-s_lastCloseAllRetryMs>=closeAllInterval)
        {
         s_lastCloseAllRetryMs=now;
         s_closeAllPasses++;
         int closeFailed=0, closeTotal=0;
         int cn=CloseAllOurs("",closeFailed,closeTotal);
         ExecuteQueue();
         // BUG-03 & R4-D4-02: Deactivate closeall/risk-close when all matching actionable positions are confirmed closed
         if(closeTotal==0 && closeFailed==0)
           {
            s_closeAllPasses=0;
            if(g_cmdCloseAllActive && StringLen(g_cmdCloseAllId)>0)
              {
               SendCfgAck("ID="+g_cmdCloseAllId+";OK=1;REV="+(string)g_cfgRev);
               g_cmdCloseAllId="";
              }
            g_cmdCloseAllActive=false;
            g_riskCloseAllPending=false;
           }
        }
     }

   //=================================================================
   // 2) SLOW LANE (100ms interval):
   //    Periodic maintenance, full account reconciliation, and UI.
   //=================================================================
   static long s_lastSlowMs=0;
   if(now-s_lastSlowMs<100) { s_inTimer=false; return; }
   s_lastSlowMs=now;

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
      //--- N-06: one maintenance REG a minute after the opening burst. See the
      //--- note on CP_REG_REFRESH_HBTS: the double-send only reaches both hubs
      //--- while both pipes are writable, and this counter is already saturated
      //--- by then, so without this the second hub could stay blind to the node.
      bool wantReg=(g_announceCount<CP_REG_REPEATS);
      if(!wantReg)
        {
         g_hbtSinceReg++;
         if(g_hbtSinceReg>=CP_REG_REFRESH_HBTS) { g_hbtSinceReg=0; wantReg=true; }
        }
      else
         g_hbtSinceReg=0;
      HubAnnounce(wantReg);
      g_announceCount++;
      //--- O4: saturate instead of counting forever. Nothing reads this beyond
      //--- the CP_REG_REPEATS threshold, and an unbounded counter is a latent
      //--- overflow on a terminal that runs for months.
      if(g_announceCount>CP_REG_REPEATS) g_announceCount=CP_REG_REPEATS;
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

   //--- 4) refresh the risk view BEFORE converge, so every sender's opens
   //--- this tick gate against the same exposure numbers
   //---
   //--- It also has to run BEFORE the state save below. SaveReceiverMap()
   //--- consumes g_acctAllPos, and on the first tick that cache is empty -
   //--- saving then would rebuild g_recKnown from nothing and overwrite the
   //--- state file with N=0, throwing away the identity map OnInit had just
   //--- restored from disk.
   //--- P3: ONE cadence for the scan and the reconcile, decided here.
   //---
   //--- `doConverge` is true on the sweep, or when anything marked itself dirty
   //--- (snapshot landed, action executed, config reloaded). `drainDue` forces a
   //--- scan as well, because the queue's risk re-check reads the counters this
   //--- scan produces - so the drain never runs on numbers from a previous pass.
   long nowMs=CopierNowMs();
   bool dirtyAny=g_convergeDirtyAll;
   if(!dirtyAny)
     {
      for(int di=0;di<g_nSenders;di++)
        {
         if(g_convergeDirty[di]) { dirtyAny=true; break; }
        }
     }
   bool doConverge=CopierConvergeDue(nowMs,g_lastConvergeSweepMs,dirtyAny,g_convergeSweepMs);
   bool drainDue=(g_qn>0 && CopierQueueMayDrain(nowMs,g_qRetryAtMs));
   bool didScan=(doConverge || drainDue);
   if(doConverge) g_lastConvergeSweepMs=nowMs;

   if(didScan)
     {
      RefreshRisk();
      static long s_lastSpreadScanMs=0;
      if(nowMs-s_lastSpreadScanMs>=2000)
        {
         s_lastSpreadScanMs=nowMs;
         string sampled[128];
         int nSampled=0;
         for(int i=0;i<g_acctAllPosCount && nSampled<128;i++)
            SampleSpreadIfUnique(g_acctAllPos[i].sym,sampled,nSampled,128);
         for(int si=0;si<g_nSenders && nSampled<128;si++)
           {
            if(!g_ready[si]) continue;
            int base=si*CP_MAX_POSITIONS;
            for(int i=0;i<g_desiredCount[si] && nSampled<128;i++)
               SampleSpreadIfUnique(MapSymbol(si,g_desired[base+i].sym,g_suffix[si]),sampled,nSampled,128);
           }
         for(int c=0;c<nSampled;c++) sampled[c]="";
        }
     }
   if(didScan && g_risk.TakeJustTripped())
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

   //--- 4b) persist the UID <-> identifier map. Two triggers:
   //---   - a scheduled pass every 10 s, which keeps the comment-overwritten
   //---     case recoverable across a restart without per-tick writes;
   //---   - g_mapDirty, set by any executed OPEN/TRIM/CLOSE, which flushes on
   //---     the next tick. The file is rebuilt from the account scan, so the
   //---     save only lands one tick after RefreshRisk has seen the change -
   //---     that is the whole point: a crash right after an open must not
   //---     leave the new mirror out of the file that seeds g_everOpened.
   //---
   //--- No ignore-list refresh here any more. That list is an INPUT now, and
   //--- changing an input re-runs OnInit, which re-parses it - so the polling
   //--- and the file it polled are both gone.
   //--- P3: SaveReceiverMap() rebuilds the file from g_acctAllPos, so it may only
   //--- run on a tick that actually scanned. g_mapDirty stays set until then, so
   //--- the flush lands within one sweep instead of on the next tick - which is
   //--- still far inside the crash window this exists to close.
   if(didScan && (now-g_lastMapSave>=250) && (g_mapDirty || now-g_lastMapSave>10000))
     {
      g_lastMapSave=now;
      g_mapDirty=false;
      SaveReceiverMap();
     }

   //--- 4c) sweep the idempotency rings once a minute.
   //---
   //--- An entry that merely EXPIRED still occupies its slot, and the cheap
   //--- "the ring is empty, nothing to clear" exit depends on the occupied
   //--- count being truthful. Without this sweep the count would only ever
   //--- grow and that exit would never be taken again.
   if(now-g_lastSeenPrune>=60000)
     {
      g_lastSeenPrune=now;
      g_seen.PruneExpired();
      g_everOpened.PruneExpired();
      g_reopenExpected.PruneExpired();
      g_fillGraceRing.PruneExpired();
      g_unsupported.PruneExpired();
      g_mktClosed.PruneExpired();
      g_fillDropped.PruneExpired();
      g_inflight.PruneExpired(); // N49-05: Sweep expired in-flight entries to prevent ring slot accumulation
     }

   //--- 5) converge every sender, then execute queued actions serially
   //--- reset the held-back tally: it is a per-sweep snapshot, not a running
   //--- total, so an entry that starts moving must stop being counted
   //--- P3: these tallies are rebuilt BY the converge pass, so they may only be
   //--- zeroed on a tick that runs it - otherwise the wait list would be cleared
   //--- and never repopulated, and the dashboard would report zero waiting orders
   //--- on a receiver that is holding ten.
   if(doConverge)
     {
      g_waitHeld=0;
      g_waitLots=0.0;
      g_mktHeld=0;
      g_mktHeldLots=0.0;
      ArrayInitialize(g_senderWaitHeld,0);
      ArrayInitialize(g_senderWaitLots,0.0);
      ArrayInitialize(g_senderMktHeld,0);
      ArrayInitialize(g_senderMktHeldLots,0.0);
      ClearWaitItems(-1);
     }

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
       // BUG-85-01: Update sender clock offset validity once our server clock advances
       for(int s=0;s<g_nSenders;s++)
         {
          if(g_senderClockKnown[s]) g_senderClockOffsetValid[s]=true;
         }
      }
   }
   if(doConverge)
     {
      //--- clear BEFORE the pass: anything that marks itself dirty during it must
      //--- survive to the next tick
      g_convergeDirtyAll=false;
      for(int i=0;i<g_nSenders;i++) g_convergeDirty[i]=false;
      static int s_sweepRrStart=0;
      if(g_nSenders>0)
        {
         int rrStart=(s_sweepRrStart % g_nSenders + g_nSenders) % g_nSenders;
         s_sweepRrStart=(rrStart+1) % g_nSenders;
         for(int k=0;k<g_nSenders;k++)
           {
            int i=(rrStart+k) % g_nSenders;
            ConvergeSender(i);
           }
        }
     }
   //--- Periodic check for market reopened or unblocked exit actions on held queue (every 5s)
   //--- BUG-01: Removed g_qBackoffMs >= 900000 gate so unblocked exit actions or reopened markets
   //--- wake the queue immediately even when backoff is intermediate (10s, 60s, 300s).
   static long s_lastMktRecheckMs=0;
   if(g_qRetryAtMs>0 && g_qn>0 && now-s_lastMktRecheckMs>=5000)
     {
      s_lastMktRecheckMs=now;
      if(CopierTradeAllowed())
        {
         bool wake=false;
         string wokeReason="";
         for(int i=0;i<g_qn;i++)
           {
            int idx=g_qHead+i;
            int k=g_q[idx].kind;
            string s=g_q[idx].sym;
            string boKey = ActionBackoffKey(g_q[idx]);
            if(k==CP_ACT_CLOSE || k==CP_ACT_TRIM || k==CP_ACT_DEDUP)
              {
               if(!g_backoff.BlockedExit(boKey))
                 {
                  wake=true;
                  wokeReason="unblocked exit action on "+s;
                  break;
                 }
              }
            else if(k==CP_ACT_MODIFY)
              {
               if(!g_backoff.BlockedModify(boKey))
                 {
                  wake=true;
                  wokeReason="unblocked modify action on "+s;
                  break;
                 }
              }
            else
              {
               int dummyWarmup=0;
               bool isBlocked = g_backoff.Blocked(boKey);
               if(!g_cmdPaused && !isBlocked && !SymbolMarketClosed(s) && !SymbolInOpenWarmup(s, dummyWarmup) && g_qBackoffMs >= 60000)
                 {
                  wake=true;
                  wokeReason="market reopened for "+s;
                  break;
                 }
              }
           }
         if(wake)
           {
            g_log.Info("OnTimer: "+wokeReason+"; waking action queue immediately");
            g_qRetryAtMs=0;
            g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
            g_qSpinPasses=0;
           }
        }
     }

   //--- P1: the PERIODIC drain respects the backoff armed by a zero-progress
   //--- pass. The event-driven drains (a trade event arrived, a snapshot changed
   //--- the desired set) deliberately do not, and PushAction() clears the
   //--- deadline outright - those are the moments the answer can change.
   if(g_qn>0 && CopierQueueMayDrain(CopierNowMs(),g_qRetryAtMs)) ExecuteQueue();

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

   //--- The pull half of the IH= scheme. The hub asked for the full config
   //--- (because our hash did not match what it held, or it had just restarted
   //--- and holds nothing); CFGREPORT is the answer, and it is the same message
   //--- a CFG apply already sends, so the hub's store is correct whichever door
   //--- it arrives by. Handled here rather than inline in HandleCmd so the
   //--- command is answered immediately and the heavy serialisation happens on
   //--- the next tick, not inside the command dispatch.
   if(g_forceCfgReport)
     {
      g_forceCfgReport=false;
      SendCurrentConfigReport();
     }

   bool dueStatus =(StatusEnabled && now-g_lastStatusMs>=60000);
   bool dueSync   =(SyncHeartbeatSeconds>0
                    && now-g_lastSyncMs>=(long)SyncHeartbeatSeconds*1000);
   bool dueSummary=(g_forcePosReport || (g_lastSummaryMs==0) || (now-g_lastSummaryMs>=5000));
   bool dueDetail =(g_hubOn && (g_forcePosReport || (g_lastPosDetailMs==0) || (now-g_lastPosDetailMs>=60000)));

   // NM-04: Include dueDetail in transmission gate
   if(dueStatus || dueSync || dueSummary || dueDetail || g_forcePosReport)
     {
      if(dueStatus) g_lastStatusMs=now;
      if(dueSync || g_forcePosReport) g_lastSyncMs=now;
      if(dueSummary) g_lastSummaryMs=now;
      if(dueDetail) g_lastPosDetailMs=now;

      //--- N56-14: dueDetail MUST imply putPositionSummary.
      //---
      //--- The detail block (POS / WAITLIST) lives INSIDE `if(putPositionSummary)`,
      //--- but g_lastPosDetailMs is advanced OUTSIDE it (just above). So any tick
      //--- where dueDetail is true while dueSummary and dueStatus are both false
      //--- advances the 60s timer and then skips the block: the position table is
      //--- never transmitted, and the dashboard shows "0 orders" next to a
      //--- perfectly correct HELD=43 - until the next miss.
      //---
      //--- This is exactly what was observed: two receivers, both HELD=43, both
      //--- positions_detail empty, on BOTH hubs. A manual reqpos filled it
      //--- immediately (43 rows), which is what ruled out parsing and transport
      //--- and pointed here. Including dueDetail makes the gate match the block
      //--- it guards, and costs one extra summary frame per minute.
      // BUG-13 & MQL-01: Re-scan live account positions BEFORE assembling summary HELD/LOTS and POS detail
      if(g_forcePosReport) RefreshRisk();
      bool putPositionSummary=(dueSummary || dueStatus || dueDetail || g_forcePosReport);
      bool putFigures=dueStatus;

      //--- B5/P4: ONE batched STAT per tick, not one per sender.
      //---
      //--- Every frame pays the same fixed cost on the hub (envelope decode,
      //--- ~20 key lookups, the state lock, receipt de-duplication) no matter how
      //--- much it carries. With N senders that cost was paid N times a second to
      //--- deliver 8 bytes each; the pairs now ride together as
      //--- `RH=<sid>:<h>,<sid>:<h>,...` and the hub splits them back into the same
      //--- per-sender RCPT unicasts.
      //---
      //--- The summary block (HELD/LOTS/POS/WAITLIST/...) is emitted exactly once,
      //--- on the FIRST frame, exactly as `putPositionSummary=false` used to do -
      //--- so the heavy fields are still parsed by the hub once per minute, not once
      //--- per sender.
      //---
      //--- The first pair is ALSO repeated as `SID=`/`H=` so that a hub which
      //--- predates this change still receives one valid receipt per receiver
      //--- instead of none.
      if(g_nSenders>0)
        {
         //--- build the once-per-batch suffix up front
         string tail="";
         if(putPositionSummary)
           {
            int qOpen=0;
            double qLots=0.0;
            PendingOpens(qOpen,qLots);
            int waitTotal=qOpen+g_waitHeld+g_mktHeld;
            double waitLots=qLots+g_waitLots+g_mktHeldLots;

            tail+=CP_SEP_KV+"HELD="+(string)g_ourCount
                 +CP_SEP_KV+"LOTS="+CopierFmtDouble(g_ourLots,CP_DIGITS_LOTS)
                 +CP_SEP_KV+"ORPHAN="+(string)g_orphanCount
                 +CP_SEP_KV+"WAIT="+(string)waitTotal
                 +CP_SEP_KV+"WLOTS="+CopierFmtDouble(waitLots,CP_DIGITS_LOTS)
                 +CP_SEP_KV+"WQUEUED="+(string)qOpen
                 +CP_SEP_KV+"WDELAYED="+(string)g_waitHeld
                 +CP_SEP_KV+"WMKT="+(string)g_mktHeld
                 +CP_SEP_KV+"EQ="+DoubleToString(CopierAccountEquity(),2)
                 +CP_SEP_KV+"BL="+DoubleToString(CopierAccountBalance(),2);

            long rtt=g_peers.RttFor(g_hubPeerName);
            if(rtt<0) rtt=g_peers.RttFor("hub:primary");
            if(rtt<0) rtt=g_peers.RttFor("hub:standby");
            if(rtt>=0) tail+=CP_SEP_KV+"PING="+(string)rtt;

            //--- Detailed position & waiting item lists are transmitted once a minute
            //--- or on-demand when requested by WebUI (g_forcePosReport) in Hub mode
            if(dueDetail && g_hubOn)
              {
               string posEnc=EncodeReceiverPositions();
               string waitEnc=EncodeReceiverWaitList();
               tail+=CP_SEP_KV+"POS="+posEnc
                    +CP_SEP_KV+"WAITLIST="+waitEnc;
              }
            putPositionSummary=false;
           }
         if(putFigures)
           {
            tail+=CP_SEP_KV+"NSEND="+(string)g_nSenders
                 +CP_SEP_KV+"BLOCKED="+(string)g_riskBlocked
                 +CP_SEP_KV+"RISK="+(g_risk.AnyTripped()?g_risk.BlockKey():"ok");
            putFigures=false;
           }

         int idx=0;
         bool firstChunk=true;
         while(idx<g_nSenders)
           {
            int startIdx=idx;
            string rh="";
            while(idx<g_nSenders)
              {
               //--- a receipt is only meaningful for a sender we have actually
               //--- received a snapshot from; "" says "no receipt yet" and is the
               //--- honest answer, not a wrong hash.
               string pair=g_sid[idx]+":"+g_snapHash[idx];
               if(StringLen(rh)>0 && StringLen(rh)+1+StringLen(pair)>CP_STAT_RH_CHUNK) break;
               if(StringLen(rh)>0) rh+=",";
               rh+=pair;
               idx++;
              }
            string st="LOGIN="+(string)CopierAccountLogin()+CP_SEP_KV+"RH="+rh;
            //--- EVERY chunk repeats its first pair as `SID=`/`H=`, not just the
            //--- first one. A hub that predates `RH=` only understands that form,
            //--- and a mixed-version window (rolling upgrade, or a Primary/Standby
            //--- pair at different builds) must not silently lose every sender but
            //--- the first chunk's. With CP_STAT_RH_CHUNK sized for the full
            //--- configuration there is normally exactly one chunk, so this is
            //--- belt-and-braces rather than the common path.
            st+=CP_SEP_KV+"SID="+g_sid[startIdx]
               +CP_SEP_KV+"H="+g_snapHash[startIdx];
            if(firstChunk)
              {
               st+=tail;
               firstChunk=false;
              }
            CopierSendStatus(CP_T_STAT,st);
            if(idx<=startIdx) break;   // defensive: an oversized single pair must not spin
           }
        }
      if(g_nSenders==0 && g_hubOn && putPositionSummary)
        {
         string st="LOGIN="+(string)CopierAccountLogin()
                   +CP_SEP_KV+"SID=-"
                   +CP_SEP_KV+"H=";
         int qOpen=0;
         double qLots=0.0;
         PendingOpens(qOpen,qLots);
         int waitTotal=qOpen+g_waitHeld+g_mktHeld;
         double waitLots=qLots+g_waitLots+g_mktHeldLots;

         st+=CP_SEP_KV+"HELD="+(string)g_ourCount
            +CP_SEP_KV+"LOTS="+CopierFmtDouble(g_ourLots,CP_DIGITS_LOTS)
            +CP_SEP_KV+"ORPHAN="+(string)g_orphanCount
            +CP_SEP_KV+"WAIT="+(string)waitTotal
            +CP_SEP_KV+"WLOTS="+CopierFmtDouble(waitLots,CP_DIGITS_LOTS)
            +CP_SEP_KV+"WQUEUED="+(string)qOpen
            +CP_SEP_KV+"WDELAYED="+(string)g_waitHeld
            +CP_SEP_KV+"WMKT="+(string)g_mktHeld
            +CP_SEP_KV+"EQ="+DoubleToString(CopierAccountEquity(),2)
            +CP_SEP_KV+"BL="+DoubleToString(CopierAccountBalance(),2);

         long rtt=g_peers.RttFor(g_hubPeerName);
         if(rtt<0) rtt=g_peers.RttFor("hub:primary");
         if(rtt<0) rtt=g_peers.RttFor("hub:standby");
         if(rtt>=0) st+=CP_SEP_KV+"PING="+(string)rtt;

         if(dueDetail)
           {
            string posEnc=EncodeReceiverPositions();
            string waitEnc=EncodeReceiverWaitList();
            st+=CP_SEP_KV+"POS="+posEnc
               +CP_SEP_KV+"WAITLIST="+waitEnc;
           }
         if(putFigures)
           {
            st+=CP_SEP_KV+"NSEND=0"
               +CP_SEP_KV+"BLOCKED="+(string)g_riskBlocked
               +CP_SEP_KV+"RISK="+(g_risk.AnyTripped()?g_risk.BlockKey():"ok");
           }
         CopierSendStatus(CP_T_STAT,st);
        }
      if(dueStatus) g_riskBlocked=0;     // reported; start the next window
      if(dueDetail) g_forcePosReport=false;
     }

   //--- Panel update and peer liveness check in slow lane
   UpdatePanel();
   CheckPeersLiveness(now);

   //--- F-18: the uplink socket is stuck mid-multipart, so every send is being
   //--- refused until it can be closed. That is an uplink outage, not a warning:
   //--- the hub is not receiving anything from this node.
   if(g_tp.FramingCorrupted() && g_once.ShouldEmit("framing_corrupt"))
      g_log.Error("uplink socket is stuck mid-multipart (a frame could not be"
                  +" terminated). Uplink frames are being refused until the socket"
                  +" becomes writable again; if this line persists, restart the EA.");

   g_log.Tick();
   s_inTimer=false;
  }

void OnTick()
  {
   int dummyW=0;
   bool inW=SymbolInOpenWarmup(_Symbol,dummyW);
   double sp=CopierGetSpreadPoints(_Symbol);
   if(sp>0.0) TrackSymbolSpread(_Symbol,sp,inW);

   // BUG-01: Wake up immediately from queue backoff upon receiving a fresh tick
   // if any queued action is an unblocked exit action, or if any queued symbol is verified open.
   if(g_qRetryAtMs>0 && g_qn>0 && CopierTradeAllowed())
     {
      bool wake=false;
      string wokeReason="";
      for(int i=0;i<g_qn;i++)
        {
         int idx=g_qHead+i;
         int k=g_q[idx].kind;
         string s=g_q[idx].sym;
         string boKey = ActionBackoffKey(g_q[idx]);
         if(k==CP_ACT_CLOSE || k==CP_ACT_TRIM || k==CP_ACT_DEDUP)
           {
            if(!g_backoff.BlockedExit(boKey))
              {
               wake=true;
               wokeReason="unblocked exit action on "+s;
               break;
              }
           }
         else if(k==CP_ACT_MODIFY)
           {
            if(!g_backoff.BlockedModify(boKey))
              {
               wake=true;
               wokeReason="unblocked modify action on "+s;
               break;
              }
           }
         else
           {
            int dummyWarmup=0;
            bool isBlocked = g_backoff.Blocked(boKey);
            if(!g_cmdPaused && !isBlocked && !SymbolMarketClosed(s) && !SymbolInOpenWarmup(s, dummyWarmup) && g_qBackoffMs >= 60000)
              {
               wake=true;
               wokeReason="market reopened for "+s;
               break;
              }
           }
        }
      if(wake)
        {
         g_log.Info("OnTick: "+wokeReason+"; waking action queue immediately");
         g_qRetryAtMs=0;
         g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
         g_qSpinPasses=0;
        }
     }
  }

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(g_pump.OnEvent(id))
     {
      OnTimer();
      // Bounded re-trigger: only pump if armed, within 15ms limit, and under burst cap
      if(g_pump.IsActive())
         g_pump.Trigger();
     }
  }
//+------------------------------------------------------------------+
