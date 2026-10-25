//+------------------------------------------------------------------+
//|                                                  CopierSender.mq4 |
//| MT4 / MT5 Trade Copier - SENDER (signal source)                   |
//|                                                                   |
//| Runs on the account you want to copy FROM. It is a pure observer: |
//| it never places, modifies or closes anything. Because of that it  |
//| can be run on an investor (read-only) password.                   |
//|                                                                   |
//| It publishes two streams over ZeroMQ:                             |
//|   * events   - OPEN / CLOSE, sent the moment they are detected     |
//|   * snapshot - the full set of open positions, every N seconds     |
//| The snapshot is what makes the system self-healing: a receiver    |
//| that missed an event converges within one snapshot period.        |
//|                                                                   |
//| The same source file is compiled as .mq4 (MT4) and .mq5 (MT5).    |
//| Everything platform specific lives in CopierModel.mqh.            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Trade copier sender: publishes positions over ZeroMQ."

#import "winmm.dll"
int timeBeginPeriod(uint uPeriod);
int timeEndPeriod(uint uPeriod);
#import

#include <Copier/CopierDefs.mqh>
#include <Copier/CopierCodec.mqh>
#include <Copier/CopierLog.mqh>
#include <Copier/CopierState.mqh>
#include <Copier/CopierFilter.mqh>
#include <Copier/CopierModel.mqh>
#include <Copier/CopierTransport.mqh>
#include <Copier/CopierPeers.mqh>
#include <Copier/CopierPanel.mqh>
#include <Copier/CopierCurveKey.mqh>
#include <Copier/CopierPump.mqh>

CopierEventPump g_pump;

//--- identity / transport -------------------------------------------
//--- NOTE every comment below STARTS WITH THE VARIABLE NAME.
//--- MetaTrader's input dialog shows the comment INSTEAD of the variable
//--- name whenever one is present, so a comment that does not name its
//--- input leaves the operator reading a list of anonymous descriptions.
#ifdef __MQL5__
input group "--- Connectivity & Mode ---"
#else
input string _g_conn_ = ""; // --- Connectivity & Mode ---
#endif
//--- The CENTRAL CHANNEL (Tier 2). Leave empty for the normal direct setup.
//---
//--- Fill it in to ALSO publish through a central hub, for receivers that are
//--- spread across machines and cannot each be pointed at this one. Both
//--- channels run at once: the direct one keeps working exactly as before, so
//--- nothing that already mirrors this sender is affected.
//---
//--- On the central channel this sender is identified by its ACCOUNT NUMBER,
//--- not by its port - and the account number is what the receiver puts in its
//--- ini as `id=`. The NID in the startup line below is that value.
input string HubEndpoint     = "";          // HubEndpoint - e.g. 10.8.0.1:6000; empty = direct only
input string BindAddress     = "*";         // BindAddress - "*" = all NICs, or one IP like 10.0.0.5
input string EventsPort      = "";          // EventsPort - blank=Auto; or manual 1024-49151

int          g_effectivePort = 5555;
bool         g_isAutoPort    = true;

int EffectivePort(bool &isAuto,string &errDesc)
  {
   errDesc = "";
   string pStr = CopierTrim(EventsPort);
   if(StringLen(pStr) == 0 || pStr == "0")
     {
      isAuto = true;
      long acc = CopierAccountLogin();
      return (int)(5000 + (MathAbs(acc) % 1000));
     }

   // 严格纯数字检查
   for(int i = 0; i < StringLen(pStr); i++)
     {
      ushort c = StringGetCharacter(pStr, i);
      if(c < '0' || c > '9')
        {
         errDesc = "EventsPort contains invalid characters (must be digits only, or blank for Auto).";
         return 0;
        }
     }

   long p = CopierParseLong(pStr);
   if(p < 1024 || p > 49151)
     {
      errDesc = "EventsPort (" + (string)p + ") out of range. Suggested port range: 1024-49151.";
      return 0;
     }

   isAuto = false;
   return (int)p;
  }

//--- The sender's identity IS its port; there is no separate name.
//---
//--- A port cannot be bound twice on one machine, so it is already unique
//--- among the senders there - and both ends can derive the same string from
//--- it without anyone keeping two fields in step. That removes an input and
//--- removes a whole failure mode: a SenderId that does not match the
//--- receiver's is IGNORED silently, so a typo looks exactly like "nothing is
//--- being sent".
//---
//--- NOTE two senders on DIFFERENT hosts may legitimately use the same port,
//--- and would then share an id. On a multi-host setup give them different
//--- ports, or use copier.ini, which still accepts an explicit id= per sender.
string SenderId() { return (string)g_effectivePort; }

//--- security (ZMQ CURVE) -------------------------------------------
//---
//--- UseCurve is now the WHOLE of this side's configuration.
//---
//--- There used to be a CurveSecretKey input here, filled in by pasting a
//--- line out of CopierKeygen's output. It is gone, and its absence is the
//--- point: a 40-character secret copied by hand can be truncated, wrapped
//--- or given a trailing space, and a malformed CURVE key does not fail -
//--- it simply never completes a handshake, with nothing in any log saying
//--- why. The keypair is now generated on first start into
//--- MQL\Files\copier_curve.key and reused from then on.
//---
//--- The key can be checked against the other end at any time:
//---   the EA prints the PUBLIC key in the Experts log at every start, and
//---   that line is what goes into each receiver's SenderServerKey input.
//---
//--- To ROTATE this sender's key: stop the EA, delete copier_curve.key,
//--- start the EA again, and copy the new PUBLIC key to the receivers.
//--- Deleting the file is the whole procedure - there is no input to clear
//--- and no script to re-run.
input bool   UseCurve        = false;       // UseCurve - turn Curve encryption on (key is automatic)

//--- CURVE on the HUB link, which is a SEPARATE decision from UseCurve.
//---
//--- The roles are inverted, and that is the whole reason for a second
//--- switch. On the direct channel this sender is the CURVE SERVER, so the
//--- receivers hold ITS public key. On the hub link the HUB is the server
//--- (§19.1 - it is the one binding the port), so this node is a CLIENT: it
//--- needs the hub's public key in HubPublicKey, and the hub needs THIS
//--- node's public key in its curve_clients.txt allow-list.
//---
//--- Keeping them separate means a deployment can run the direct channel in
//--- plaintext and the hub link encrypted (or the other way round) without
//--- dragging a keypair into a link that does not use one.
//---
//--- The keypair itself is the same file either way (MQL\Files\
//--- copier_curve.key) - one terminal, one identity. It is generated on
//--- first use and the PUBLIC half is printed in the log at every start;
//--- that printed line is what goes into the hub's allow-list.
//--- DEFAULT TRUE since 2026-10-15, by the owner's call, for the same reason
//--- the write gates above were hard-wired on: every session from here on is
//--- a test session that needs the hub link encrypted.
//---
//--- CURVE on the HUB link is hard-wired ON. The Hub public key is resolved
//--- automatically from copier_hub.key in MQL\Files or Terminal\Common\Files
//--- (downloaded from the Web Dashboard). Neither HubUseCurve nor HubPublicKey
//--- requires user input in the EA dialog.
const bool   HubUseCurve      = true;       // Hub link CURVE encryption permanently enabled

//--- cadence --------------------------------------------------------
//--- SnapshotSeconds is the BASELINE full-state push interval, not the only
//--- time a snapshot goes out: a receiver whose receipt says it is behind gets
//--- the last snapshot re-sent to it directly (see SnapRepairMaybe).
//---
//--- It was 2 and is now 10 because the periodic broadcast is what costs the
//--- bandwidth - ~380 KB per push, per sender, forever. With 100 receivers at
//--- 2s that is ~1.5 TB/day of downlink for a state that changes far less
//--- often than that.
//---
//--- WHAT THIS COSTS, STATED PLAINLY: SL/TP changes ride the snapshot (MODIFY
//--- is deliberately unimplemented), so their propagation latency is bounded
//--- by this number. At 2 it was <= 2s; at 10 it is <= 10s. The receipt
//--- mechanism does NOT reduce it - a receipt can only report what was SENT,
//--- so it detects a LOST snapshot, never a change that has not been sent yet.
//--- If stop latency matters more than the bandwidth here, either lower this
//--- (2 restores the old behaviour) or add an event-driven push on content
//--- change, which is a separate decision and not part of this change.
#ifdef __MQL5__
input group "--- Cadence & Performance ---"
#else
input string _g_cadence_ = ""; // --- Cadence & Performance ---
#endif
input int    SnapshotSeconds = 15;          // SnapshotSeconds - baseline push interval; 0=off
input int    HeartbeatSeconds= 5;   // HeartbeatSeconds - account state interval (default 5s)
input int    PollMs          = 5;           // PollMs - timer interval in milliseconds

#ifdef __MQL5__
input group "--- Filters ---"
#else
input string _g_filters_ = ""; // --- Filters ---
#endif
input string IncludeSymbols  = "";          // IncludeSymbols - blank = all; ! prefix excludes
input string IncludeMagicNumbers = "";   // IncludeMagicNumbers - blank=all; "0"=manual trades

#ifdef __MQL5__
input group "--- Sizing Hint ---"
#else
input string _g_sizing_ = ""; // --- Sizing Hint ---
#endif
input double FixedLotSize    = 0.0;   // FixedLotSize - >0: send this size, not the real one
input double LotSizeMultiplier = 0.0;   // LotSizeMultiplier - lots x this (if FixedLotSize=0)

#ifdef __MQL5__
input group "--- System ---"
#else
input string _g_system_ = ""; // --- System ---
#endif
input int    LogLevel        = 2;           // LogLevel - 0=err 1=warn 2=info 3=debug

//--- STAT channel (optional) ----------------------------------------
//--- Status arrives UP the same socket the data goes down, so there is no
//--- endpoint to configure. XPUB/XSUB are bidirectional where PUB/SUB are
//--- not; see the header of CopierTransport.mqh.
//--- Nothing here feeds back into trading - it exists so this side can see
//--- what the receiving account actually holds.
input bool   StatusEnabled   = true;        // StatusEnabled - log what each receiver reports
input bool   ShowPanel       = true;        // ShowPanel - draw the status panel on the chart

//=====================================================================
// Globals. Every container here is fixed-size - see CopierState.mqh.
//=====================================================================
CopierTransport  g_tp;
CopierLog        g_log;
CopierOnceLog    g_once;      // for conditions that stay true on every tick
CopierPosTable   g_prev;      // positions seen last tick (also the UID lookup)
CopierPosTable   g_cur;       // scratch for this tick

//--- This sender's CURVE keypair, loaded from (or generated into)
//--- MQL\Files\copier_curve.key. Only touched when UseCurve is on - see
//--- the note in CopierCurveKey.mqh for why it is a file at all.
CopierCurveKey   g_key;

string           g_ssid="";
long             g_seq=0;

//--- CENTRAL CHANNEL state.
//---
//--- g_nid is the identity on that channel: the account number reduced to at
//--- most 9 digits (see CopierNid). It is BOTH the SID this sender puts on the
//--- wire AND the ZMQ topic that carries its data - one value, two uses, and
//--- the receiver subscribes to it straight out of its own ini.
long             g_nid=0;
bool             g_hubOn=false;
//--- HubEndpoint, NORMALISED once. "10.8.0.1:6000" is what people type; the
//--- scheme is what ZMQ needs. Normalising in one place means the log, the
//--- panel and the connect all agree on what was actually dialled - and a
//--- scheme-less endpoint never reaches the socket.
string           g_hubEp="";
string           g_hubPeerName="hub";       // the name g_peers files the hub under
//--- Shared with the receiver's PermittedSymbols: one implementation of the
//--- "CSV, leading ! means exclude" rule, so the two ends cannot drift into
//--- disagreeing about what "!EURUSD" means.
CopierList       g_symFilter;
CopierList       g_magicFilter;

long             g_lastSnapMs=0;
long             g_lastHbtMs=0;
long             g_fillSnapshotDueMs=0; // 500ms buffered snapshot deadline after pending fill
long             g_lastPanelRenderMs=0;

//--- Pre-allocated static scratch buffers for BuildCurrent (ZERO ArrayResize in hot loop)
CopierPos        g_rawScratch[CP_MAX_POSITIONS];
CopierPos        g_curScratch[CP_MAX_POSITIONS];
int              g_prevSlotScratch[CP_MAX_POSITIONS];
//--- Per-tick "was this slot seen / did this row change" markers, as
//--- GENERATION STAMPS rather than booleans.
//---
//--- The booleans they replaced were local and had to be ArrayInitialize'd
//--- every tick: 2 x 2048 bytes of memset at 10 Hz, for an answer that can be
//--- "stale by construction". A stamp array is written only when something is
//--- actually seen, and the test is a single compare against the current tick
//--- number. No clearing, no construction, no stack frame.
//---
//--- g_stampGen starts at 1 and is bumped BEFORE use, so a slot whose stamp
//--- still reads 0 (untouched since load) can never match the current tick.
//--- It would take ~2.1 billion ticks - decades at 10 Hz - to wrap.
int              g_slotStamp[CP_MAX_POSITIONS];   // index: slot in g_prev
int              g_rowStamp[CP_MAX_POSITIONS];    // index: row in this tick
int              g_slotMissCount[CP_MAX_POSITIONS];// consecutive ticks slot was missing from scan
double           g_openLots[CP_MAX_POSITIONS];    // initial lots at position opening
int              g_stampGen=1;

//--- SNAPSHOT RECEIPT (slice A: observe; slice B: repair).
//---
//--- g_snapHash is the receipt of the snapshot we last SENT - the value a
//--- receiver echoes back when it has ingested that exact state. A mismatch
//--- means "this receiver is behind". See doc/SNAPSHOT-DEMAND-PLAN.md.
string           g_snapHash="";
string           g_latestSnapHash="";
#define CP_RECENT_HASH_COUNT 4
string           g_recentSnapHashes[CP_RECENT_HASH_COUNT];
long             g_recentSnapHashTime[CP_RECENT_HASH_COUNT];
int              g_recentSnapHashHead=0;

void NoteRecentSnapHash(const string h)
  {
   if(StringLen(h)==0) return;
   long now=CopierNowMs();
   for(int i=0;i<CP_RECENT_HASH_COUNT;i++)
     {
      if(g_recentSnapHashes[i]==h)
        {
         g_recentSnapHashTime[i]=now;
         return;
        }
     }
   g_recentSnapHashes[g_recentSnapHashHead]=h;
   g_recentSnapHashTime[g_recentSnapHashHead]=now;
   g_recentSnapHashHead=(g_recentSnapHashHead+1)%CP_RECENT_HASH_COUNT;
  }

bool IsRecentSnapHash(const string h)
  {
   if(StringLen(h)==0) return false;
   if(h==g_snapHash || h==g_latestSnapHash) return true;
   long now=CopierNowMs();
   long ttlMs=MathMax(15000,(long)SnapshotSeconds*1000+5000);
   for(int i=0;i<CP_RECENT_HASH_COUNT;i++)
     {
      if(g_recentSnapHashes[i]==h && (now-g_recentSnapHashTime[i]<=ttlMs)) return true;
     }
   return false;
  }
//--- The exact bytes of the last BROADCAST snapshot, kept so a repair can
//--- re-send what the receiver actually missed.
//---
//--- Re-building a fresh snapshot at repair time is the obvious thing and it
//--- is WRONG: if the content has changed since the broadcast, the fresh one
//--- carries a new hash, g_snapHash moves, and every OTHER receiver - whose
//--- receipt was perfectly correct - suddenly looks behind too. One lagging
//--- receiver would then drag a repair out of all of them, turning a targeted
//--- fix into N full-size sends. Re-sending the SAME bytes cannot do that: the
//--- hash does not move, so only the receiver that was actually behind is
//--- affected. Content changes are the periodic broadcast's job, not this one.
string           g_snapPayload="";
string           g_latestSnapPayload="";
//--- Receive buffers for the per-tick drains, allocated ONCE.
//---
//--- Both drain paths used to declare their arrays inside OnTimer, so the
//--- transport resized them to CP_DRAIN_MAX and shrank them back every tick -
//--- two heap operations ten times a second, forever, to carry a handful of
//--- frames. As file-level arrays the transport takes its static path (no
//--- ArrayResize at all). The returned count is the ONLY valid length; the
//--- tails keep frames from previous ticks and must never be read.
string           g_drainStatus[CP_DRAIN_MAX];   // direct channel: XPUB status/PONG
string           g_drainTopics[CP_DRAIN_MAX];   // central channel: topic frame
string           g_drainMsgs[CP_DRAIN_MAX];     // central channel: payload frame

//--- Per-peer count of CONSECUTIVE heartbeats that reported a stale receipt.
//--- Keyed the same way the peer table is (by the name the peer reports).
//---
//--- 64, not 16: in CENTRAL mode ONE sender serves every receiver in the
//--- fleet, so the number of distinct receipt senders is the number of
//--- receivers, not the number of links. At 16 the table filled on any real
//--- deployment, and the overflow used to alias onto slot 0 (see
//--- SnapStaleIndex). Each slot is a string plus five 8-byte counters, so 64
//--- of them is a few KB - cheap insurance against a silent wrong answer.
//--- Same ceiling again: one entry per receiver that can report a receipt.
//--- It must be >= CP_MAX_PEERS, or a peer can be tracked for liveness and
//--- NOT tracked for snapshot repair - which is exactly the silent split this
//--- family of constants kept producing. 64 was already over the old peer
//--- ceiling of 16; both are 100 now.
#define CP_MAX_STALE_PEERS 100
string           g_snapStaleWho[CP_MAX_STALE_PEERS];
int              g_snapStaleN[CP_MAX_STALE_PEERS];
//--- Slice B timing, parallel to the arrays above.
//---
//---   g_snapStaleMs  - when the current stale run STARTED. The debounce is
//---                    measured from here, not from the last heartbeat, so a
//---                    slow reporter is not made to wait longer than a fast
//---                    one for the same evidence.
//---   g_snapRcptMs   - when this peer last reported anything, used to measure
//---                    its cadence. A receiver's SyncHeartbeatSeconds is NOT
//---                    on the wire and does not need to be: the sender can
//---                    see the interval directly, which is also the honest
//---                    measurement (it includes the link).
//---   g_snapIntMs    - the last measured interval, smoothed by halving.
//---   g_snapRepairMs - when we last re-sent to this peer, for the rate limit.
long             g_snapStaleMs[CP_MAX_STALE_PEERS];
long             g_snapRcptMs[CP_MAX_STALE_PEERS];
long             g_snapIntMs[CP_MAX_STALE_PEERS];
long             g_snapRepairMs[CP_MAX_STALE_PEERS];
bool             g_snapIsHub[CP_MAX_STALE_PEERS];
int              g_snapStaleCount=0;

//--- peers, latency probes and the on-chart panel -------------------
CopierPeerTable  g_peers;              // receivers we have heard from
CopierPanel      g_panel;
long             g_lastPingMs=0;
long             g_lastHubPingMs=0;     // the hub is probed on its own channel
//--- REG/HBT2 cadence. The hub learns this node exists ONLY from REG, so the
//--- startup REG being dropped - which it can be, because the socket is opened
//--- with IMMEDIATE and a send before the connection completes is discarded -
//--- would leave this node invisible until it restarted. The hub's WHO sweep
//--- is what recovers from that; these two are what make it rare.
long             g_lastHbt2Ms=0;
int              g_announceCount=0;     // first CP_REG_REPEATS are REG, then HBT2
                                        // NOT reset on a WHO reply - the sweep runs
                                        // every 60s forever, so re-arming here would
                                        // mean never settling (measured: 19 REG where
                                        // 3 is correct). See the WHO branch in OnTimer.
long             g_bootMs=0;            // for UP=, the node's own uptime
//--- Edge-triggered disconnect alerts. Without the latch the Alert would fire
//--- on every timer tick while a peer is down, which is worse than no alert at
//--- all: a wall of popups is something people learn to dismiss without
//--- reading, and then they miss the one that mattered.
bool             g_peerWasDown[CP_MAX_PEERS];
long             g_peerAlerted[CP_MAX_PEERS];   // when we last popped up
string           g_lastTrackedName[CP_MAX_PEERS];// names last bound to each slot
#define CP_PEER_TIMEOUT_MS 15000       // silence beyond this = disconnected
#define CP_PING_MS          5000       // probe cadence (5s for responsive measurement)
//--- After an alert for a peer, stay quiet about that peer for a while. One
//--- popup per outage is useful; one per flap cycle is not, and a flapping
//--- link is exactly when an operator most needs the popup to still mean
//--- something.
#define CP_ALERT_QUIET_MS  (5*60*1000)
bool             g_stateDirty=false;

//=====================================================================
// Helpers
//=====================================================================
string StatePath() { return "copier_sender_"+(string)CopierAccountLogin()+".st"; }

bool SymbolAllowed(const string sym) { return g_symFilter.Allows(sym); }

bool MagicAllowed(const long magic)
  {
   return g_magicFilter.AllowsLong(magic);
  }

//--- apply the optional broadcast-size override before sending
double BroadcastLots(const double actual,const double initLots=0.0)
  {
   if(FixedLotSize>0.0)
     {
      //--- Scale partial closes proportionally so receiver trims mirror sender
      if(initLots>0.0 && actual<initLots)
        {
         double scaled=NormalizeDouble(FixedLotSize*(actual/initLots),CP_DIGITS_LOTS);
         return (scaled>0.0)?scaled:0.01;
        }
      return FixedLotSize;
     }
   if(LotSizeMultiplier>0.0) return NormalizeDouble(actual*LotSizeMultiplier,CP_DIGITS_LOTS);
   return actual;
  }

//--- Announce this node to the hub: REG once, HBT2 afterwards.
//---
//--- The hub learns who exists ONLY from these. It never probes for nodes and
//--- never guesses, so a node that does not announce itself is invisible - and
//--- "invisible" is indistinguishable from "not running" on the far side.
//---
//--- REG and HBT2 differ in ONE field (NAME) and are otherwise identical, which
//--- is why they share a builder path. A heartbeat repeating a name that cannot
//--- have changed is bytes for nothing, every five seconds, from every node.
//---
//--- Neither message carries anything a trade depends on. If the hub is down,
//--- or drops every one of these, trading is completely unaffected - that is
//--- Phase 2's whole promise, and it is worth keeping it that way.
void HubAnnounce(const bool isReg)
  {
   if(!g_hubOn) return;

   long up=(CopierNowMs()-g_bootMs)/1000;
   CopierEnv e;
   e.v=CP_PROTO_V;
   e.sid=(string)g_nid;
   e.ssid=g_ssid;
   e.seq=++g_seq;
   e.ts=CopierServerTime();
   e.ms=CopierNowMs();
   e.type=isReg?CP_T_REG:CP_T_HBT2;
   e.payload=isReg
             ?CopierPayloadReg("sender",CopierAccountLogin(),
                               CopierTerminalName(),up)
             :CopierPayloadHbt2("sender",CopierAccountLogin(),
                                CopierTerminalName(),up);

   long rtt=g_peers.RttFor(g_hubPeerName);
   if(rtt>=0) e.payload+=CP_SEP_KV+"PING="+(string)rtt;

   //--- Dropped silently on purpose. Losing one heartbeat is nothing, and a
   //--- log line per failure would be a line per five seconds on a hub that is
   //--- simply not running yet. The hub's own WHO sweep is the recovery path.
   g_tp.SendUp("@hub",CopierEncodeEnv(e));
  }

//--- `centralToo` is for the ONE message that is not for hub-connected peers.
//---
//--- The peer probe asks "are you there, and how far away". A receiver behind
//--- the hub cannot answer it: the reply would have to come back up the central
//--- channel, and the hub CONSUMES every '@' topic rather than routing it. So
//--- publishing it through the hub is not merely useless - the hub fans it out
//--- to EVERY subscriber, so one wasted message becomes N, and N grows with the
//--- deployment.
//---
//--- Everything else (events, snapshots, heartbeats) is genuinely for both
//--- channels and keeps the default.
void Emit(const string type,const string payload,const bool snapshot,
          const bool centralToo=true)
  {
   CopierEnv e;
   e.v=CP_PROTO_V;
   e.ssid=g_ssid;
   e.seq=++g_seq;              // ONE sequence, shared by both channels - below
   e.ts=CopierServerTime();
   //--- monotonic ms, so the receiver can estimate the link without any extra
   //--- message: see the header of CopierPeers.mqh
   e.ms=CopierNowMs();
   e.type=type;
   e.payload=payload;

   //--- DIRECT channel: identity is the PORT, one frame.
   //--- Only encode and send if direct socket is bound and ready.
   if(g_tp.HasDirectSubscribers())
     {
      e.sid=SenderId();
      bool ok=g_tp.Send(CopierEncodeEnv(e));
      if(!ok && !snapshot)
         g_log.Warn("send failed type="+type+" errno="+(string)g_tp.LastErrno());
     }

   //--- CENTRAL channel: identity is the NID, two frames [NID, envelope].
   //---
   //--- Encoded SEPARATELY rather than editing SID inside the string above.
   //--- A substring edit is faster and is wrong the day a payload happens to
   //--- contain the same text - and a half-rewritten envelope is not a class
   //--- of bug worth risking to save one string build at a few messages a
   //--- second. Each channel is then a complete message in its own right.
   //---
   //--- The SEQ is SHARED on purpose: the two channels carry different SIDs,
   //--- so a receiver's per-SID watermark never sees both, and sharing it
   //--- means one trade has the same sequence number in both logs - which is
   //--- exactly what makes comparing them useful.
   if(g_hubOn && centralToo)
     {
      e.sid=(string)g_nid;
      if(!g_tp.SendUp((string)g_nid,CopierEncodeEnv(e)) && !snapshot)
         g_log.Warn("hub send failed type="+type+" errno="
                    +(string)g_tp.LastErrno());
     }
  }

//--- Send one envelope to ONE node, by its NID, through the hub.
//---
//--- The topic is the TARGET'S NID, with no '@'. That prefix matters and is
//--- the opposite of what the design document first assumed:
//---
//---   '@<nid>'  is the HUB's own channel to a node. A node that publishes on
//---             one is not routing anything - the hub CONSUMES every
//---             '@'-prefixed message as control addressed to itself, and the
//---             payload is never forwarded. Only the hub can originate on it
//---             (PONG, WHO). Measured: tools/hub_stat_path_test.py.
//---   '<nid>'   is a DATA topic, forwarded byte for byte to whoever
//---             subscribed to that prefix.
//---
//--- So a receiver subscribes to its OWN nid (CopierReceiver, central setup)
//--- and this is what reaches it - and only it. No new namespace: the same
//--- account number is already the sender's data topic, the receiver's ini
//--- `id=`, and the hub's node identity.
//---
//--- Only meaningful with a hub. In direct mode the socket is XPUB and the
//--- peer subscribed to "", so there is no way to address one of several.
void EmitToNode(const long nid,const string type,const string payload)
  {
   if(!g_hubOn) return;

   CopierEnv e;
   e.v=CP_PROTO_V;
   e.ssid=g_ssid;
   e.seq=++g_seq;
   e.ts=CopierServerTime();
   e.ms=CopierNowMs();
   e.type=type;
   e.payload=payload;
   e.sid=(string)g_nid;

   if(!g_tp.SendUp((string)nid,CopierEncodeEnv(e)))
      g_log.Warn("targeted send to NID "+IntegerToString(nid)
                 +" failed errno="+(string)g_tp.LastErrno());
  }

void EmitOpen(const CopierPos &p)
  {
   CopierPos q=p;
   q.lots=BroadcastLots(p.lots,p.lots);
   Emit(CP_T_OPEN,CopierPayloadOpen(q),false);
  }

void EmitClose(const CopierPos &p)
  {
   int slot=g_prev.Find(p.uid);
   double initLots=(slot>=0)?g_openLots[slot]:p.lots;
   double bLots=BroadcastLots(p.lots,initLots);
   Emit(CP_T_CLOSE,CopierPayloadClose(p.uid,p.ticket,bLots,0.0),false);
  }

//=====================================================================
// Scan + UID assignment
//=====================================================================
int BuildCurrent()
  {
   //--- Pass readComment=false: skip reading comments for all orders indiscriminately.
   //--- Sender only ever needs comment on MT4 for newly appeared tickets to check "from #".
   //--- Writes directly into pre-allocated static g_rawScratch, zero ArrayResize.
   int rn=CopierReadPositions(g_rawScratch,CP_MAX_POSITIONS,false);
   int n=0;

   //--- Rebuild ticket index only when table mutations actually occurred.
   //--- In steady state (99.9% of ticks), positions do not change, so the hash
   //--- index stays valid across ticks without re-zeroing 2048 integers.
   if(!g_prev.IsTicketIndexValid()) g_prev.RebuildTicketIndex();

   for(int i=0;i<rn;i++)
     {
      CopierPos p=g_rawScratch[i];
      if(!SymbolAllowed(p.sym)) continue;
      if(!MagicAllowed(p.magic)) continue;

      //--- 1) identity carried over from the previous tick (ticket match)
      string uid="";
      int slot=-1;
      CopierPos q;
      int idx=g_prev.FindByTicket(p.ticket);
      if(idx>=0 && g_prev.At(idx,q))
        {
         uid=q.uid;
         slot=idx;
        }

      //--- 2) MT4 partial close: broker re-opens the remainder under a
      //---    new ticket with "from #<old>" in the comment. Inherit.
      //---    Selectively read comment ONLY for this new ticket!
      if(StringLen(uid)==0)
        {
#ifndef __MQL5__
         string cmt="";
         if(OrderSelect((int)p.ticket,SELECT_BY_TICKET)) cmt=OrderComment();
         long from=CopierMt4FromTicket(cmt);
         if(from>0)
           {
            int j=g_prev.FindByTicket(from);
            if(j>=0 && g_prev.At(j,q))
              {
               uid=q.uid;
               slot=j;
              }
            else
              {
               long curFrom=from;
               for(int hops=0;hops<5;hops++)
                 {
                  if(!OrderSelect((int)curFrom,SELECT_BY_TICKET,MODE_HISTORY)) break;
                  long prevFrom=CopierMt4FromTicket(OrderComment());
                  if(prevFrom<=0) break;
                  j=g_prev.FindByTicket(prevFrom);
                  if(j>=0 && g_prev.At(j,q))
                    {
                     uid=q.uid;
                     slot=j;
                     break;
                    }
                  curFrom=prevFrom;
                 }
               if(StringLen(uid)==0 && g_once.ShouldEmit("fromhops|"+(string)p.ticket))
                  g_log.Warn("MT4 partial-close 'from #' chain exceeded 5 hops for ticket "+(string)p.ticket+"; minting fresh UID");
              }
           }
#endif
        }

      //--- 3) genuinely new
      //---
      //--- REFUSE to mint an identity we cannot store. A new UID only becomes
      //--- durable when the row reaches g_prev at the end of the tick; if the
      //--- table is full that never happens, so next tick this same position
      //--- looks new again, gets ANOTHER UID, and the receiver is told about a
      //--- different "new" position every 100 ms. Skipping it here is the
      //--- honest answer: the position is not tracked, and that is reported
      //--- once rather than as a stream of phantom opens.
      if(StringLen(uid)==0)
        {
         if(g_prev.IsFull())
           {
            if(g_once.ShouldEmit("prevfull"))
               g_log.Error("position table is full ("+(string)CP_MAX_POSITIONS
                          +" entries) - NEW positions are NOT being tracked or"
                          +" broadcast. Close something, or raise"
                          +" CP_MAX_POSITIONS. Reported at most once per 10 min.");
            continue;
           }
         uid=CopierNewUid();
         slot=-1;
        }

      p.uid=uid;
      if(n>=CP_MAX_POSITIONS) break;
      g_curScratch[n]=p;
      g_prevSlotScratch[n]=slot;
      n++;
     }
   return n;
  }

//=====================================================================
// Lifecycle
//=====================================================================
int OnInit()
  {
   string portErr = "";
   g_effectivePort = EffectivePort(g_isAutoPort, portErr);
   if(StringLen(portErr) > 0)
     {
      Alert("[CopierSender] " + portErr);
      Print("[CopierSender] ERROR: " + portErr);
      return INIT_PARAMETERS_INCORRECT;
     }
   MathSrand((int)(CopierNowMs()%2147483647)+(int)CopierAccountLogin());
   g_log.Init("sender_"+SenderId(),LogLevel);

   g_symFilter.Set(IncludeSymbols);
   g_magicFilter.Set(IncludeMagicNumbers);
   if(g_magicFilter.StrayBangs()>0)
      g_log.Warn("IncludeMagicNumbers: '!' on individual item was stripped. A leading '!' excludes the whole list.");

   g_hubOn=false;
   g_prev.Clear();
   ArrayInitialize(g_openLots,0.0);
   ArrayInitialize(g_slotMissCount,0);

   //--- restore UID<->ticket mapping so a restart does not re-announce
   //--- positions that are already open (which would double them up)
   string hdr="";
   CopierPos saved[];
   double savedOpenLots[];
   int savedCount=0;
   if(CopierStateFile::Load(StatePath(),hdr,saved,savedCount,savedOpenLots))
     {
      for(int i=0;i<savedCount;i++)
        {
         if(!SymbolAllowed(saved[i].sym) || !MagicAllowed(saved[i].magic))
           {
            // M-04: Warn about filtered historical positions so operator is aware of possible receiver orphans
            g_log.Warn("state restore: ignoring position ticket "+(string)saved[i].ticket+" ("+saved[i].sym+") - disallowed by current filter; receivers may hold orphan mirrors if closed while excluded");
            continue;
           }
         int s=g_prev.Upsert(saved[i]);
         if(s>=0) g_openLots[s]=(i<ArraySize(savedOpenLots) && savedOpenLots[i]>0.0)?savedOpenLots[i]:saved[i].lots;
        }
      g_log.Info("restored "+(string)savedCount+" position(s) from state ("+StatePath()+")");
     }
   else if(CopierStateFile::Load("copier_sender_"+SenderId()+".st",hdr,saved,savedCount,savedOpenLots))
     {
      for(int i=0;i<savedCount;i++)
        {
         if(!SymbolAllowed(saved[i].sym) || !MagicAllowed(saved[i].magic))
           {
            g_log.Warn("state restore: ignoring position ticket "+(string)saved[i].ticket+" ("+saved[i].sym+") - disallowed by current filter; receivers may hold orphan mirrors if closed while excluded");
            continue;
           }
         int s=g_prev.Upsert(saved[i]);
         if(s>=0) g_openLots[s]=(i<ArraySize(savedOpenLots) && savedOpenLots[i]>0.0)?savedOpenLots[i]:saved[i].lots;
        }
      g_log.Info("restored "+(string)savedCount+" position(s) from legacy state (copier_sender_"+SenderId()+".st)");
     }
   else
     {
      g_log.Info("no usable state file; starting fresh");
     }

   g_ssid="";
   for(int i=0;i<6;i++) g_ssid+=StringSubstr(CP_UID_ALPHA,MathRand()%32,1);
   g_seq=0;

   //--- CURVE key. Loaded or generated BEFORE the bind, because the bind is
   //--- what installs the key on the socket - a failure here must not leave a
   //--- half-configured server listening.
   //---
   //--- The whole point of doing this here rather than asking for an input:
   //--- there is nothing to paste, nothing to mistype, and the public key the
   //--- receivers need is printed at every start whether anything changed or
   //--- not. A failing Ensure() is FATAL when UseCurve is on: binding a CURVE
   //--- server without a key cannot work, and starting anyway would produce
   //--- exactly the silent-never-connects symptom this design exists to kill.
   string curveSecret="",curvePublic="";
   if(UseCurve || (StringLen(HubEndpoint) > 0 && HubUseCurve))
     {
      CP_KEY_RESULT kr=g_key.Ensure(GetPointer(g_log));
      if(kr==CP_KEY_FAILED)
        {
         g_log.Error("CURVE is on but no CURVE key could be obtained."
                     +" See the lines above for the reason.");
         return INIT_FAILED;
        }
      curveSecret=g_key.SecretKey();
      curvePublic=g_key.PublicKey();
      if(StringLen(curveSecret)!=CP_KEY_LEN || StringLen(curvePublic)!=CP_KEY_LEN)
        {
         g_log.Error("CURVE is on but this node's key is not"
                     +" "+IntegerToString(CP_KEY_LEN)+" characters after"
                     +" loading "+g_key.Path()+". Refusing to start.");
         return INIT_FAILED;
        }
      if(UseCurve) g_key.AnnouncePublic(GetPointer(g_log),"sender");
     }

   if(!g_tp.BindSender(BindAddress,g_effectivePort,UseCurve,curveSecret))
     {
      int err=g_tp.LastErrno();
      g_log.Error("cannot bind "+(string)g_effectivePort
                  +" errno="+(string)err);
      if(g_isAutoPort)
        {
         Alert("[CopierSender] AutoPort "+(string)g_effectivePort
               +" is already in use or unavailable (errno="+(string)err
               +")! Please configure an explicit port in EventsPort (1024-49151).");
        }
      else
        {
         Alert("[CopierSender] Port "+(string)g_effectivePort
               +" cannot be bound (errno="+(string)err
               +")! Check if port is in use.");
        }
      return INIT_FAILED;
     }

   //--- the status channel needs no setup of its own: it arrives on the
   //--- socket the data already leaves by.

   //--- CENTRAL CHANNEL. The m_sub socket has been unused since this EA was
   //--- written (Emit() goes out of m_pub, and so does everything else), so
   //--- the hub link costs no resource that is already spoken for.
   //---
   //--- A failure here is NOT fatal: the direct channel is unaffected and
   //--- still carries every position. It is reported loudly because a receiver
   //--- mirroring this sender through the hub would otherwise simply never
   //--- hear anything, with nothing on this side saying why.
   //---
   //--- CURVE on this link is HubUseCurve, NOT UseCurve - see the input
   //--- block. The hub is the CURVE server on its side, so the roles are the
   //--- opposite of the direct channel's.
   g_nid=CopierNid(CopierAccountLogin());
   g_hubEp=CopierNormalizeEndpoint(HubEndpoint);   // bare IP:port gains tcp://
   //--- Uptime starts here, not at the top of OnInit: everything before this is
   //--- file loading and validation, and reporting it as "up" would claim a
   //--- node is serving before it has bound anything.
   g_bootMs=CopierNowMs();
   //--- CURVE on the hub link: the hub is the SERVER here, so this node is
   //--- the client and needs the hub's public key. A missing or malformed
   //--- one is reported and the hub link is left OFF - never connected in
   //--- the clear as a fallback, which is the failure mode that would look
   //--- like success.
   bool hubCurveOk=true;
   string activeHubKey="";
   if(HubUseCurve)
     {
      string keySrc="";
      activeHubKey=CopierLoadHubPublicKey("",GetPointer(g_log),keySrc);
      if(StringLen(activeHubKey)!=CP_KEY_LEN)
        {
         g_log.Error("Hub link CURVE is on but no valid "+IntegerToString(CP_KEY_LEN)+"-character Hub public key found."
                     +" Download copier_hub.key from Web Dashboard to MQL\\Files (or Common\\Files)."
                     +" Hub link NOT opened.");
         hubCurveOk=false;
        }
      else
        {
         g_log.Info("CURVE: the hub link to "+g_hubEp+" is encrypted (source: "+keySrc+").");
         g_log.Info("  Add THIS node's public key to the hub's curve_clients.txt (or auto-register):");
         g_log.Info("  "+curvePublic);
        }
     }
   if(StringLen(g_hubEp)>0 && hubCurveOk)
     {
      if(!g_tp.ConnectHub(g_hubEp,HubUseCurve,activeHubKey,curvePublic,curveSecret))
        {
         g_log.Error("central channel: cannot open a socket to "+g_hubEp
                     +" errno="+(string)g_tp.LastErrno()
                     +". The direct channel is unaffected, but nothing will"
                     +" reach receivers that mirror this sender through a hub.");
        }
      else
        {
         g_hubOn=true;
         g_tp.Subscribe("@"+(string)g_nid);
         //--- @all is how the hub asks everyone to re-register when it has lost
         //--- its table. A node that does not subscribe to it is unreachable by
         //--- the one message that exists to make it reachable.
         g_tp.Subscribe("@all");
         //--- Best effort. The socket is IMMEDIATE, so a send made before the
         //--- TCP connection completes is DISCARDED rather than queued - this
         //--- one may well be lost. That is fine and by design: the first few
         //--- announcements in OnTimer are REG too, and the hub repeats WHO
         //--- while its table is empty.
         HubAnnounce(true);
         g_announceCount=1;
         g_log.Info("central channel: connected to "+g_hubEp+" as NID="
                    +(string)g_nid+" (account "+(string)CopierAccountLogin()
                    +") - the hub must be running, and a receiver mirroring"
                    +" this sender through it needs id="+(string)g_nid
                    +" in its copier.ini");
        }
     }
   else
      g_log.Info("central channel: off - direct only. Set HubEndpoint to also"
                 +" publish through a central hub. (This sender's NID would be "
                 +(string)g_nid+", which is what a hub-mode receiver would use"
                 +" as id=.)");

   timeBeginPeriod(1);
   int effectivePollMs=PollMs;
   if(effectivePollMs<1) effectivePollMs=1;
   if(effectivePollMs>5000) effectivePollMs=5000;
   if(!EventSetMillisecondTimer(effectivePollMs))
     {
      g_log.Error("EventSetMillisecondTimer("+(string)effectivePollMs+") failed");
      return INIT_FAILED;
     }
   g_panel.Init("cpsnd",10,20,430);
   RebuildSnapshotPayload();
   g_pump.Init();
   g_log.Info("sender "+SenderId()+" listening on port "+(string)g_effectivePort
              +(g_isAutoPort ? " (AutoPort active)" : " (manual port)")
              +" (one socket, both streams) ssid="+g_ssid
              +" nid="+(string)g_nid
              +" build="+CP_BUILD_STAMP);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_pump.Disarm();
   EventKillTimer();
   timeEndPeriod(1);

   //--- remove the panel objects. Leaving them behind means a removed EA
   //--- leaves an unreadable rectangle on the chart forever, and the next
   //--- attach draws a second one on top.
   g_panel.Destroy();

   //--- same reasoning as the receiver: end every session's log with the
   //--- set we were broadcasting, so the log can be read as a state rather
   //--- than a diff with holes in it
   CopierPos dense[];
   int slots[];
   int dn=g_prev.CopyToWithSlots(dense,slots);
   string held="";
   for(int i=0;i<dn;i++) held+=(i>0?",":"")+dense[i].uid;
   g_log.Info("sender stopped reason="+(string)reason+" holding "
              +(string)dn+" position(s)"+(dn>0?": "+held:""));

   //--- Persist state on shutdown so any unflushed mutations are not lost
   //--- across an EA restart or chart timeframe change.
   if(g_stateDirty)
     {
      g_stateDirty=false;
      string hdr="SEQ="+(string)g_seq+";SSID="+g_ssid;
      double openLotsDense[];
      ArrayResize(openLotsDense,dn);
      for(int i=0;i<dn;i++) openLotsDense[i]=(slots[i]>=0)?g_openLots[slots[i]]:dense[i].lots;
      CopierStateFile::Save(StatePath(),hdr,dense,dn,openLotsDense);
     }

   g_tp.Close();          // sockets first, then context (LINGER=0 already set)
  }

//--- Say once when a peer goes quiet, and once when it comes back.
//---
//--- The Alert is EDGE-TRIGGERED: it fires on the transition into "down", not
//--- on every tick while down. A popup that repeats every 100 ms is something
//--- people learn to dismiss without reading, which is worse than no alert -
//--- it trains the operator to ignore the channel that carries the real news.
//---
//--- A probe is REQUIRED, not optional: the receiver's own traffic is a STAT
//--- once a minute, which is far slower than the 15s timeout - so without this
//--- every peer flaps and the operator gets a popup per cycle.
void CheckPeers()
  {
   long now=CopierNowMs();
   if(now-g_lastPingMs>=CP_PING_MS)
     {
      g_lastPingMs=now;
      //--- broadcast: every receiver answers, and each echo names its sender
      //--- so the replies can be told apart. A few dozen bytes every 2s next
      //--- to a snapshot every 2s is nothing.
      //--- DIRECT ONLY (the last argument). A hub-connected receiver cannot
      //--- answer this probe, and the hub would fan it out to every subscriber.
      Emit(CP_T_PING,CopierPayloadPing(now,(string)CopierAccountLogin()),
           false,false);
      //--- RECORD the probe against every peer. Without this the outstanding
      //--- number stays 0, PongBack() refuses every echo it gets (it only
      //--- accepts one matching a probe still outstanding), and the round trip
      //--- is never measured - the panel sits on "connected" forever while
      //--- both ends are dutifully answering each other.
      //--- by INDEX, not by name: the table is being walked here, and
      //--- ProbeSent(name) scans the table again - quadratic at 100 peers.
      for(int k=0;k<CP_MAX_PEERS;k++)
        {
         string pn=g_peers.NameAt(k);
         if(StringLen(pn)>0) g_peers.ProbeSentAt(k,now);
        }
      g_pump.ArmFast(); // Bounded micro burst to catch immediate local PONG
     }

   //--- The HUB is probed on its own channel.
   //---
   //--- Emit() cannot reach it: that goes out of m_pub, and the hub is a
   //--- different socket with different framing. Same idea, different pipe -
   //--- and it has to be separate, because "is the hub reachable" is a
   //--- different question from "are the direct receivers reachable", and the
   //--- panel needs to answer both.
   //---
   //--- Without this the sender would have no way to tell a working hub link
   //--- from a silently broken one: ZMQ connect() succeeds immediately whether
   //--- or not anything is listening at the other end.
   if(g_hubOn && now-g_lastHubPingMs>=CP_PING_MS)
     {
      g_lastHubPingMs=now;
      CopierEnv he;
      he.v=CP_PROTO_V;
      he.sid=(string)g_nid;
      he.ssid=g_ssid;
      he.seq=++g_seq;
      he.ts=CopierServerTime();
      he.ms=now;
      he.type=CP_T_PING;
      he.payload=CopierPayloadPing(now,(string)g_nid);
      g_tp.SendUp("@hub",CopierEncodeEnv(he));
      g_peers.ProbeSent(g_hubPeerName,now);
      g_pump.ArmFast(); // Bounded micro burst to catch immediate local PONG
     }

   //--- REG/HBT2. The hub's node table is built from these and NOTHING else -
   //--- it never probes for nodes - so this is the only reason this sender is
   //--- visible on the far side at all.
   //---
   //--- The first CP_REG_REPEATS announcements are REG, not HBT2. The one sent
   //--- from OnInit can be DISCARDED - the socket is IMMEDIATE, so a send made
   //--- before the TCP connection completes is dropped - and a node that only
   //--- ever heartbeats is visible but ANONYMOUS, because only REG carries a
   //--- name. Measured, not theorised: that is exactly what the first live run
   //--- of this feature looked like.
   if(g_hubOn && now-g_lastHbt2Ms>=CP_HBT2_MS)
     {
      g_lastHbt2Ms=now;
      HubAnnounce(g_announceCount<CP_REG_REPEATS);
      g_announceCount++;
     }

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

      //--- A newly assigned or evicted slot occupant: reset edge-trigger state
      //--- so a freshly connected node never inherits a stale "down" state and
      //--- falsely logs that it is "back".
      if(g_lastTrackedName[i]!=nm)
        {
         g_lastTrackedName[i]=nm;
         g_peerWasDown[i]=false;
         g_peerAlerted[i]=0;
        }

      long silent=g_peers.SilentAt(i);
      //--- Three states, not two. A peer we have only just met is CONNECTING,
      //--- not down: its first probe is still in flight, and reporting that as
      //--- DISCONNECTED meant every hub link announced itself as broken for the
      //--- second before the first PONG came back.
      int  st=g_peers.StateAt(i,CP_PEER_TIMEOUT_MS);
      bool down=(st==CP_PEER_DOWN);

      //--- silent<0 means NEVER HEARD FROM, which is not "silent for 0s" - and
      //--- that is exactly what it used to print, because -1/1000 is 0 in
      //--- integer division. "silent for 0s - DISCONNECTED" reads like a bug in
      //--- the check rather than a peer that has never answered.
      //---
      //--- The hub is a peer like any other here, but calling it a "receiver"
      //--- would be wrong and would make the count above look off by one.
      string what=(nm==g_hubPeerName)?"hub":"receiver";
      string how =(silent<0)?"has NEVER been heard from"
                            :("has been silent for "+(string)(silent/1000)+"s");

      if(down && !g_peerWasDown[i])
        {
         g_peerWasDown[i]=true;
         g_log.Warn(what+" "+nm+" "+how+" - DISCONNECTED");
         //--- ONE popup per outage. The log always gets the line; the popup
         //--- only if we have not already shouted about this peer recently -
         //--- a flapping link would otherwise fire a popup every few seconds
         //--- and train the operator to dismiss them unread.
         if(now-g_peerAlerted[i]>=CP_ALERT_QUIET_MS)
           {
            g_peerAlerted[i]=now;
            Alert("Copier SENDER: "+what+" "+nm+" DISCONNECTED ("+how+")");
           }
        }
      else if(!down && g_peerWasDown[i])
        {
         g_peerWasDown[i]=false;
         g_log.Info(what+" "+nm+" is back");
        }
     }
  }

//--- SNAPSHOT RECEIPT tracking (slice A: observe; slice B: repair) -----
//---
//--- A receiver echoes, in its heartbeat, the hash of the last snapshot it
//--- ingested. Comparing it with g_snapHash answers exactly one question:
//--- "has this receiver seen the state I am sending now?"
//---
//--- A receiver that reports "" has no receipt at all. That is an older build
//--- OR one that has never received a snapshot; both are reported separately
//--- from a genuine mismatch, because they mean different things.
//---
//--- WHY A DEBOUNCE IS NOT OPTIONAL
//---
//--- A receipt is necessarily a little behind by construction: the sender
//--- stamps a new hash the instant it SENDS, while the receiver can only echo
//--- what it has INGESTED. So every time the content changes there is a short
//--- window - the link plus the receiver's poll - during which an honest,
//--- perfectly healthy receiver reports the previous hash. Repairing on the
//--- first mismatch would fire on that window every time the state changed,
//--- which is exactly the traffic this whole design exists to remove.
//---
//--- The debounce therefore asks "is this still true a moment later", and the
//--- moment is measured against the receiver's OWN cadence: two heartbeats
//--- when it reports quickly (<= 2s apart), one when it already reports slowly
//--- enough that waiting for a second would only add delay. That is the rule
//--- agreed for Q4 in doc/SNAPSHOT-DEMAND-PLAN.md.
void SnapTrack(const string who,const string reported,const bool isFromHub=false)
  {
   if(StringLen(who)==0) return;

   long now=CopierNowMs();
   int idx=SnapStaleIndex(who);
   if(idx>=0) g_snapIsHub[idx]=isFromHub;
   //--- Table full: this peer is past CP_MAX_STALE_PEERS distinct receipt
   //--- senders. Skipping the tracking is a degradation, not a failure - the
   //--- periodic SnapshotSeconds broadcast still reaches it. Tracking it in
   //--- somebody else's slot would be a WRONG answer for both peers, which is
   //--- strictly worse than an untracked one.
   if(idx<0)
     {
      if(g_once.ShouldEmit("snapstale|full"))
         g_log.Warn("receipt tracking table is full ("+(string)CP_MAX_STALE_PEERS
                    +" peers); receipt "+(string)who+" is not tracked, so no"
                    +" targeted repair for it - it still gets the periodic"
                    +" SnapshotSeconds broadcast. Raise CP_MAX_STALE_PEERS if"
                    +" this persists.");
      return;
     }

   //--- cadence, measured from the receipts themselves. Smoothed by halving
   //--- so one delayed heartbeat does not redefine "slow" for the next window.
   if(g_snapRcptMs[idx]>0)
     {
      long iv=now-g_snapRcptMs[idx];
      if(iv>0)
        {
         if(g_snapIntMs[idx]<=0) g_snapIntMs[idx]=iv;
         else                    g_snapIntMs[idx]=(g_snapIntMs[idx]+iv)/2;
        }
     }
   g_snapRcptMs[idx]=now;

   string activeHash=(StringLen(g_snapHash)>0)?g_snapHash:g_latestSnapHash;

   if(StringLen(reported)==0)
     {
      //--- A receiver that reports "" has no snapshot yet (newly attached node).
      //--- If we have a snapshot ready, bootstrap it immediately on first contact
      //--- without waiting for the SnapshotSeconds periodic broadcast clock.
      if(StringLen(activeHash)==0 || StringLen(g_snapPayload)==0) return;
      if(g_once.ShouldEmit("snaph|none|"+who))
         g_log.Info("receiver "+who+" reports NO snapshot receipt yet"
                    +" (bootstrapping snapshot on first contact)");
      SnapRepairMaybe(who,idx,now,true);
      return;
     }

   if(StringLen(activeHash)==0) return;      // we have not sent one yet

   if(!IsRecentSnapHash(reported))
     {
      if(g_snapStaleN[idx]==0) g_snapStaleMs[idx]=now;
      g_snapStaleN[idx]=g_snapStaleN[idx]+1;
      //--- Log the FIRST observation of a stale window and then every 10th,
      //--- not every heartbeat: a stuck receiver would otherwise write a line
      //--- per second forever. The count in the line says how long it has run.
      if(g_snapStaleN[idx]==1 || (g_snapStaleN[idx]%10)==0)
         g_log.Warn("receiver "+who+" is BEHIND: it reports H="+reported
                    +" but the current snapshot is H="+activeHash
                    +" (stale for "+IntegerToString(g_snapStaleN[idx])
                    +" heartbeat(s))");
      SnapRepairMaybe(who,idx,now,false);
      return;
     }

   //--- in step again - clear the run, and say so once when it matters.
   //--- "it caught up" is worth one line precisely BECAUSE the stale run
   //--- was logged: an operator seeing a BEHIND line needs to see it end.
   if(g_snapStaleN[idx]>1)
      g_log.Info("receiver "+who+" is back IN STEP (was behind for "
                 +IntegerToString(g_snapStaleN[idx])+" heartbeat(s))");
   g_snapStaleN[idx]=0;
   g_snapStaleMs[idx]=0;
  }

//--- Should this stale run become a repair yet?
//---
//--- TWO gates, and both have to pass. The debounce asks "is this a real
//--- gap or just the send/ingest window"; the rate limit asks "have we already
//--- tried recently". Without the second, a receiver that is behind for a
//--- reason re-sending cannot fix - a broken socket, a rejected subscription -
//--- would be fed a full snapshot on every heartbeat forever, which is the
//--- original traffic problem with the blame moved.
//---
//--- `isBootstrap` is true when a newly connected receiver reports H="" - it
//--- bypasses the debounce so the new receiver receives the snapshot on its
//--- very first heartbeat (<1s) rather than waiting for SnapshotSeconds.
void SnapRepairMaybe(const string who,const int idx,const long now,const bool isBootstrap=false)
  {
   if(!isBootstrap)
     {
      long est=g_snapIntMs[idx];
      if(est<=0) est=2000;                          // no measurement yet
      long waitMs=(est<=2000)? 2*est : est;

      if(now-g_snapStaleMs[idx]<waitMs) return;
     }

   //--- Q5: at most one repair per receiver per SnapshotSeconds. When
   //--- SnapshotSeconds is 0 the periodic broadcast is off, so repairs are the
   //--- only way state moves - the floor keeps that from becoming a flood.
   //--- In bootstrap mode, we enforce only a 1s floor so newly attached peers
   //--- get their snapshot within 1s even if a prior repair was recently emitted.
   long floorSec = isBootstrap ? 1 : ((SnapshotSeconds>0)? SnapshotSeconds : 1);
   if(g_snapRepairMs[idx]>0 && now-g_snapRepairMs[idx]<floorSec*1000) return;

   if(StringLen(g_snapPayload)==0) return;       // nothing sent yet

   long staleFor=now-g_snapStaleMs[idx];
   g_snapRepairMs[idx]=now;
   g_snapStaleN[idx]=0;                          // fresh evidence for the next one
   g_snapStaleMs[idx]=now;

   bool toHub=(g_hubOn && g_snapIsHub[idx]);
   if(toHub)
     {
      long rnid=CopierNid(CopierParseLong(who));
      EmitToNode(rnid,CP_T_SNAP,g_snapPayload);
      NoteRecentSnapHash(g_latestSnapHash);
      if(isBootstrap)
         g_log.Info("bootstrapped snapshot to new receiver "+who+" (NID "
                    +IntegerToString(rnid)+") on first contact");
      else
         g_log.Warn("re-sent the snapshot to receiver "+who+" (NID "
                    +IntegerToString(rnid)+") - it had been behind for "
                    +IntegerToString(staleFor)+"ms");
     }
   else
     {
      //--- DIRECT mode cannot address one peer: the socket is XPUB, which
      //--- fans out by subscription prefix, and a direct receiver subscribes
      //--- to "" - everything. So the repair is a broadcast. That is the right
      //--- trade here rather than a gap, because direct mode is one sender to
      //--- one receiver in every deployment this is used for.
      Emit(CP_T_SNAP,g_snapPayload,true);
      // L-06: Keep g_snapHash aligned with the actual cached payload re-emitted
      g_snapHash=CopierSnapshotHash(g_snapPayload);
      NoteRecentSnapHash(g_snapHash);
      g_lastSnapMs=now;
      if(isBootstrap)
         g_log.Info("bootstrapped snapshot for new receiver "+who+" (direct channel)");
      else
         g_log.Warn("re-sent the snapshot for "+who+" (behind for "
                    +IntegerToString(staleFor)+"ms) - broadcast, because the"
                    +" direct channel cannot address a single receiver");
     }
  }

//--- index of `who` in the stale-run arrays. Fixed capacity since the
//--- zero-allocation pass. When full, evicts the longest-silent slot
//--- (oldest g_snapRcptMs) so long-running deployments never permanently
//--- saturate their targeted-repair capacity.
int SnapStaleIndex(const string who)
  {
   for(int i=0;i<g_snapStaleCount;i++)
      if(g_snapStaleWho[i]==who) return i;

   int n=0;
   if(g_snapStaleCount<CP_MAX_STALE_PEERS)
     {
      n=g_snapStaleCount;
      g_snapStaleCount++;
     }
   else
     {
      //--- Table full: reuse the slot whose receipt is oldest (longest silent).
      int oldest=0;
      for(int i=1;i<CP_MAX_STALE_PEERS;i++)
        {
         if(g_snapRcptMs[i]<g_snapRcptMs[oldest]) oldest=i;
        }
      n=oldest;
     }

   g_snapStaleWho[n]=who;
   g_snapStaleN[n]=0;
   g_snapStaleMs[n]=0;
   g_snapRcptMs[n]=0;
   g_snapIntMs[n]=0;
   g_snapRepairMs[n]=0;
   g_snapIsHub[n]=false;
   return n;
  }

//--- Does a receipt naming `id` belong to THIS sender?
//---
//--- TWO ids, because the two topologies address this sender differently, and
//--- getting that wrong makes a valid receipt look like somebody else's:
//---
//---   DIRECT  - a receiver knows the sender by its PORT, from its own
//---             SenderPort input. That is what SenderId() returns.
//---   CENTRAL - a receiver knows it by the ACCOUNT NUMBER it put in
//---             copier.ini as id=, which is g_nid (and is also the ZMQ topic
//---             its data arrives on).
//---
//--- So in central mode a receiver reports `SID=252033316` while SenderId() is
//--- `5555`. Accepting only the port - which this did at first - silently
//--- discarded every central-mode receipt, and would have kept doing so even
//--- once the relay made them arrive. The symptom is identical to the relay
//--- not working, which is exactly the kind of bug that costs an afternoon.
//---
//--- An EMPTY id is accepted: an older peer sends none, and such a peer has
//--- only one sender to be talking about.
bool SenderAnswersTo(const string id)
  {
   if(StringLen(id)==0) return true;
   if(id==SenderId()) return true;
   if(id==(string)g_nid) return true;
   return false;
  }

//--- The on-chart panel. Cheap enough to redraw on the timer: it rewrites the
//--- text of objects that already exist rather than creating anything.
void UpdatePanel()
  {
   if(!ShowPanel) { return; }

   //--- Throttle GUI panel redraws to at most once per 1.5 seconds (1500ms).
   //--- Redrawing heavy on-chart objects at 10 Hz burns massive Windows GDI CPU for nothing.
   long now=CopierNowMs();
   if(now-g_lastPanelRenderMs<1500) return;
   g_lastPanelRenderMs=now;

   int npos=0,nord=0;
   double lots=0.0;
   g_prev.Summary(npos,nord,lots);

   int np=g_peers.Count();
   //--- header, listening, CHANNEL, active, volume, balance, connected + one
   //--- per receiver + a spacer. Keep this in step with the Row() calls below
   //--- or the last line silently disappears off the background.
   //---
   //--- At 100 receivers that is 100 rows, which is more than any chart can
   //--- show, so the per-receiver detail is capped and the remainder is one
   //--- summary line. Same rule as the receiver's panel, and for the same
   //--- reason: a truncated list that does not SAY it is truncated is the
   //--- failure mode, not the truncation.
   int peerShow=(np>CP_PANEL_PEER_SHOW)?CP_PANEL_PEER_SHOW:np;
   int peerMore=(np>peerShow)?1:0;
   int rows=8+peerShow+peerMore;
   if(rows<9) rows=9;

   g_panel.Begin(rows);
   int r=0;
   g_panel.Row(r++,"Copier SENDER  -  account "
                   +(string)CopierAccountLogin(),CP_PANEL_TITLE);
   g_panel.Row(r++,"Listening  "+(string)BindAddress+":"+(string)g_effectivePort
                   +"   id "+(string)g_effectivePort+(g_isAutoPort ? " [Auto]" : ""),CP_PANEL_DIM);
   //--- WHICH CHANNELS ARE LIVE. Both rows of information D14 asked for are
   //--- kept: the direct side below is unchanged, and the central side is
   //--- added here plus as a row in the peer list (the hub is a peer like any
   //--- other, it just is not a receiver).
   if(g_hubOn)
      g_panel.Row(r++,"Channel    direct + central   NID "+(string)g_nid,
                  CP_PANEL_OK);
   else
      g_panel.Row(r++,"Channel    direct only   (NID would be "
                      +(string)g_nid+")",CP_PANEL_DIM);
   g_panel.Row(r++,"Active   positions "+IntegerToString(npos)
                   +"   pending orders "+IntegerToString(nord)
                   +"   total "+IntegerToString(npos+nord),
               CP_PANEL_TEXT);
   g_panel.Row(r++,"Volume   "+DoubleToString(lots,2)+" lots",
               CP_PANEL_TEXT);
   g_panel.Row(r++,"Balance  "+DoubleToString(CopierAccountBalance(),2)
                   +"   Equity "+DoubleToString(CopierAccountEquity(),2),
               CP_PANEL_TEXT);
   g_panel.Row(r++,"Receivers connected: "+IntegerToString(np)
                   +((g_hubOn)?"  (incl. hub)":""),
               (np>0)?CP_PANEL_OK:CP_PANEL_WARN);

   int shown=0;
   for(int i=0;i<CP_MAX_PEERS && shown<peerShow;i++)
     {
      string nm=g_peers.NameAt(i);
      if(StringLen(nm)==0) continue;
      shown++;
      long silent=g_peers.SilentAt(i);
      int  st=g_peers.StateAt(i,CP_PEER_TIMEOUT_MS);
      bool down=(st==CP_PEER_DOWN);
      long rtt=g_peers.RttAt(i);

      //--- the hub is filed in the same table because it IS a peer - but it
      //--- is not a receiver, and showing it as one would make the count above
      //--- read "2 receivers" when one of them is infrastructure.
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

      string note=g_peers.NoteAt(i);
      if(StringLen(note)>0 && note!="ok") line+="   risk="+note;

      g_panel.Row(r++,line,
                  (st==CP_PEER_DOWN)?CP_PANEL_BAD
                                    :((st==CP_PEER_CONNECT)?CP_PANEL_DIM
                                                           :CP_PANEL_OK));
     }

   if(peerMore)
      g_panel.Row(r++,"  ... and "+(string)(np-peerShow)+" more receiver(s)"
                      +" - the hub dashboard lists every one",
                  CP_PANEL_DIM);

   g_panel.Row(r++," ",CP_PANEL_TEXT);
   g_panel.End();
  }

void RebuildSnapshotPayload()
  {
   static CopierPos dense[];
   static int slots[];
   int dn=g_prev.CopyToWithSlots(dense,slots);
   for(int i=0;i<dn;i++)
     {
      int slot=slots[i];
      double initLots=(slot>=0)?g_openLots[slot]:dense[i].lots;
      dense[i].lots=BroadcastLots(dense[i].lots,initLots);
     }
   g_latestSnapPayload=CopierEncodeSnapshot(dense,dn);
   g_latestSnapHash=CopierSnapshotHash(g_latestSnapPayload);
   if(StringLen(g_snapPayload)==0 || StringLen(g_snapHash)==0 || SnapshotSeconds<=0)
     {
      g_snapPayload=g_latestSnapPayload;
      g_snapHash=g_latestSnapHash;
     }
   NoteRecentSnapHash(g_latestSnapHash);
  }

void BroadcastSnapshot(const long now)
  {
   g_lastSnapMs=now;
   RebuildSnapshotPayload();
   g_snapPayload=g_latestSnapPayload;
   g_snapHash=g_latestSnapHash;
   NoteRecentSnapHash(g_snapHash);
   Emit(CP_T_SNAP,g_snapPayload,true);
  }

void HandleSenderStat(const CopierEnv &se)
  {
   //--- The snapshot receipt is read BEFORE the StatusEnabled gate, and
   //--- deliberately. That switch governs MONITORING - the equity/lots/risk
   //--- figures on the panel - and an operator who turns monitoring off
   //--- must not thereby disable the delivery mechanism. They are
   //--- unrelated concerns that happen to share a message.
   {
    string sh="",swho="",ssid="";
    CopierKvGet(se.payload,"H",sh);
    CopierKvGet(se.payload,"LOGIN",swho);
    CopierKvGet(se.payload,"SID",ssid);
    if(SenderAnswersTo(ssid))
       SnapTrack(swho,sh,false);
   }

   if(!StatusEnabled) return;

   string login="",eq="",bl="",held="",lots="",nsend="",blocked="",risk="";
   CopierKvGet(se.payload,"LOGIN",login);
   CopierKvGet(se.payload,"EQ",eq);
   CopierKvGet(se.payload,"BL",bl);
   CopierKvGet(se.payload,"HELD",held);
   CopierKvGet(se.payload,"LOTS",lots);
   CopierKvGet(se.payload,"NSEND",nsend);
   CopierKvGet(se.payload,"BLOCKED",blocked);
   CopierKvGet(se.payload,"RISK",risk);

   if(StringLen(login)>0)
      g_peers.Seen(login);

   string rk=risk;
   if(StringLen(rk)==0 && StringLen(nsend)>0) rk="ok";
   if(StringLen(login)>0 && StringLen(rk)>0)
     {
      g_peers.SetNote(login,rk);
      if(g_once.ShouldEmit("stat|"+login+"|"+rk))
         g_log.Info("receiver "+login+" status: equity="+eq+" balance="+bl
                    +" held="+held+" position(s) lots="+lots
                    +" senders="+nsend+" risk="+rk
                    +" blocked="+blocked+" since the last report");
     }
  }

void OnTimer()
  {
   long now=CopierNowMs();
#ifdef __MQL5__
   if(g_tradeDirty)
     {
      g_tradeDirty=false;
     }
#endif

   //--- 0) Fast-path: drain incoming PONG and status BEFORE scanning positions
   int sn=g_tp.DrainStatus(g_drainStatus,CP_DRAIN_MAX);
   for(int i=0;i<sn;i++)
     {
      CopierEnv se;
      if(CopierDecodeEnv(g_drainStatus[i],se)!=CP_ERR_NONE) continue;
      if(se.type==CP_T_PONG)
        {
         string pms="",pfrom="";
         CopierKvGet(se.payload,"MS",pms);
         CopierKvGet(se.payload,"FROM",pfrom);
         if(StringLen(pfrom)>0 && g_peers.PongBack(pfrom,CopierParseLong(pms)))
           {
            g_pump.Disarm(); // Echo arrived -> cancel fast pump immediately
            if(g_once.ShouldEmit("rtt|"+pfrom))
               g_log.Info("link to "+pfrom+" measured: "
                          +(string)g_peers.RttFor(pfrom)+" ms round trip");
           }
         continue;
        }
      if(se.type==CP_T_PING)
        {
         string pms="",pfrom="";
         CopierKvGet(se.payload,"MS",pms);
         CopierKvGet(se.payload,"FROM",pfrom);
         if(StringLen(pfrom)>0)
           {
            g_peers.Seen(pfrom);
            Emit(CP_T_PONG,
                 CopierPayloadPong(CopierParseLong(pms),
                                   (string)CopierAccountLogin(),pfrom),
                 false);
           }
         continue;
        }
      // M-03: Process STAT frames arriving in first drain pass rather than silently discarding
      if(se.type==CP_T_STAT)
        {
         HandleSenderStat(se);
         continue;
        }
     }

   if(g_hubOn)
     {
      int hn=g_tp.DrainFrames(g_drainTopics,g_drainMsgs,CP_DRAIN_MAX);
      for(int i=0;i<hn;i++)
        {
         string t=g_drainTopics[i];
         if(StringLen(t)>0)
           {
            string myNid=(string)g_nid;
            string myAcc=(string)CopierAccountLogin();
            if(t!="@all" && t!="@"+myNid && t!="@"+myAcc) continue;
           }
         CopierEnv he;
         if(CopierDecodeEnv(g_drainMsgs[i],he)!=CP_ERR_NONE) continue;

         if(he.type==CP_T_PONG)
           {
            string hms="",hfrom="",hto="";
            CopierKvGet(he.payload,"MS",hms);
            CopierKvGet(he.payload,"FROM",hfrom);
            CopierKvGet(he.payload,"TO",hto);
            if(StringLen(hto)>0 && hto!=(string)g_nid && hto!=(string)CopierAccountLogin()) continue;
            if(StringLen(hfrom)>0 && g_peers.PongBack(hfrom,CopierParseLong(hms)))
              {
               g_pump.Disarm(); // Echo arrived -> cancel fast pump immediately
              }
            continue;
           }
         if(he.type==CP_T_WHO)
           {
            HubAnnounce(true);
            continue;
           }
        }
     }

   //--- 1) scan and reconcile against what we saw last tick (zero ArrayResize)
   int n=BuildCurrent();

   //--- New generation: the two stamp arrays are NOT cleared - a slot or row
   //--- that nothing writes this tick simply keeps an older generation and
   //--- therefore reads as "not seen" / "unchanged".
   g_stampGen++;

   //--- Track which slots in g_prev are still alive this tick, and which rows
   //--- changed. Generation stamps instead of ArrayInitialize'd bool arrays.

   //--- 2) emit opens for new UIDs, or check stop/volume/kind changes for existing slots
   for(int i=0;i<n;i++)
     {
      int slot=g_prevSlotScratch[i];
      if(slot<0)
        {
         //--- NEW POSITION: slot < 0 means no match in previous tick
         EmitOpen(g_curScratch[i]);
         //--- log our own ticket alongside the UID: the receiver writes
         //--- both into its order comment, so the two logs line up and you
         //--- can go straight to the matching order in either terminal.
         //--- A pending entry says so, and gives its trigger price - "open"
         //--- alone cannot tell a working order from a filled one.
         string what=(g_curScratch[i].kind==CP_ORD_PENDING)
                     ?(" place-pending type="+(string)g_curScratch[i].ptype
                       +" trigger="+DoubleToString(g_curScratch[i].pprice,5))
                     :" market";
         g_log.Info("open "+g_curScratch[i].uid+" tkt="+(string)g_curScratch[i].ticket+" "
                    +g_curScratch[i].sym+" side="+(string)g_curScratch[i].side
                    +what
                    +" lots="+DoubleToString(g_curScratch[i].lots,2)
                    +" sl="+((g_curScratch[i].sl>0.0)?DoubleToString(g_curScratch[i].sl,5):"none")
                    +" tp="+((g_curScratch[i].tp>0.0)?DoubleToString(g_curScratch[i].tp,5):"none"));
         g_stateDirty=true;
        }
      else
        {
         g_slotStamp[slot]=g_stampGen;
         g_slotMissCount[slot]=0;
         bool stopsDiff=false, lotsDiff=false, kindDiff=false, otherDiff=false;
         double prevLots=0.0;
         int prevKind=0;
         long prevTicket=0;

         //--- Fast numeric check directly against m_p[slot]: ZERO struct copies,
         //--- ZERO string allocations on 99.9% of steady-state ticks (B11).
         if(g_prev.CheckSlot(slot,stopsDiff,lotsDiff,kindDiff,otherDiff,
                             prevLots,prevKind,prevTicket,g_curScratch[i]))
           {
            if(stopsDiff || lotsDiff || kindDiff || otherDiff) g_rowStamp[i]=g_stampGen;
            if(otherDiff) g_stateDirty=true;

            //--- STOPS CHANGED: compare directly by slot, 0 string lookups!
            if(stopsDiff)
              {
               g_stateDirty=true;
               g_log.Info("stops "+g_curScratch[i].uid+" "+g_curScratch[i].sym
                          +" side="+(string)g_curScratch[i].side
                          +" entry="+DoubleToString(g_curScratch[i].openPx,5)
                          +" sl="+((g_curScratch[i].sl>0.0)?DoubleToString(g_curScratch[i].sl,5):"none")
                          +" tp="+((g_curScratch[i].tp>0.0)?DoubleToString(g_curScratch[i].tp,5):"none"));
               Emit(CP_T_MODIFY,
                    CopierPayloadModify(g_curScratch[i].uid,g_curScratch[i].openPx,
                                        g_curScratch[i].sl,g_curScratch[i].tp),false);
              }

            //--- VOLUME DRIFT (partial close we do not model in the MVP)
            if(lotsDiff)
              {
               g_stateDirty=true;
               if(g_once.ShouldEmit("vol|"+g_curScratch[i].uid))
                  g_log.Info("partial close on "+g_curScratch[i].uid+" "+g_curScratch[i].sym
                             +" "+DoubleToString(prevLots,2)+" -> "+DoubleToString(g_curScratch[i].lots,2)
                             +" (UID carried across the ticket change; the snapshot"
                             +" now carries the smaller volume)");
              }

            //--- PENDING ORDER FILLING / KIND CHANGED
            if(kindDiff)
              {
               g_stateDirty=true;
               g_log.Info("uid "+g_curScratch[i].uid+" "+g_curScratch[i].sym+" moved: kind "
                          +(string)prevKind+" -> "+(string)g_curScratch[i].kind+", ticket "
                          +(string)prevTicket+" -> "+(string)g_curScratch[i].ticket
                          +" (a pending filling looks like this once; a repeat does not)");
               //--- When a pending order fills into a market position, buffer a 0.5s (500ms)
               //--- debounce before pushing the snapshot, giving receivers time to fill naturally.
               if(prevKind==CP_ORD_PENDING && g_curScratch[i].kind==CP_ORD_MARKET)
                 {
                  if(g_fillSnapshotDueMs==0)
                    {
                     g_fillSnapshotDueMs=now+500;
                     g_log.Info("uid "+g_curScratch[i].uid+" pending filled; scheduled buffered snapshot in 500ms");
                    }
                 }
              }
           }
        }
     }

   //--- 3) emit closes for anything that vanished (slot valid but not stamped this tick, 0 string lookups)
   for(int k=0;k<CP_MAX_POSITIONS;k++)
     {
      if(g_slotStamp[k]==g_stampGen)
        {
         g_slotMissCount[k]=0;
         continue;
        }
      CopierPos q;
      if(!g_prev.At(k,q)) continue;
      g_slotMissCount[k]++;
      if(g_slotMissCount[k]<2 && !CopierIsTicketClosedInHistory(q.ticket)) continue; // instant 0ms close when confirmed in history
      g_slotMissCount[k]=0;
      EmitClose(q);
      g_log.Info("close "+q.uid+" tkt="+(string)q.ticket+" "+q.sym);
      g_stateDirty=true;
      g_prev.RemoveAt(k);
      g_openLots[k]=0.0;
     }

   //--- 5) roll the window forward in-place: update modified slots, insert new
   for(int i=0;i<n;i++)
     {
      if(g_prevSlotScratch[i]>=0)
        {
         //--- Steady-state (99.9%): no numeric difference -> NO-OP!
         //--- Zero struct copies and m_tkValid is preserved.
         if(g_rowStamp[i]==g_stampGen) g_prev.UpdateNumericAt(g_prevSlotScratch[i],g_curScratch[i]);
        }
      else
        {
         //--- The return value matters. -1 means the row did not land, so the
         //--- OPEN emitted above has no counterpart in g_prev: next tick this
         //--- position reads as brand new again. BuildCurrent() refuses to
         //--- allocate a UID when the table is full, so this should be
         //--- unreachable - it is checked anyway because "silently dropped
         //--- row" is exactly the failure mode that costs a trade.
         int newSlot=g_prev.InsertEmpty(g_curScratch[i]);
         if(newSlot>=0)
           {
            g_openLots[newSlot]=g_curScratch[i].lots;
           }
         else if(g_once.ShouldEmit("prevfull"))
           {
            g_log.Error("could not store "+g_curScratch[i].uid+" in the position"
                       +" table ("+(string)CP_MAX_POSITIONS+" full) - it will be"
                       +" re-announced as a new position on the next scan."
                       +" Reported at most once per 10 min.");
           }
        }
     }

   //--- 6) snapshot
   bool dueSnap=(SnapshotSeconds>0 && now-g_lastSnapMs>=(long)SnapshotSeconds*1000);
   //--- If a pending order just filled into a market position, give the receiver
   //--- the full 500ms debounce before pushing the snapshot. Even if the routine
   //--- 15s timer happens to elapse during this window, defer it until the
   //--- buffer expires so the receiver is not rushed into an early cancel.
   if(g_fillSnapshotDueMs>0)
     {
      if(now>=g_fillSnapshotDueMs)
        {
         dueSnap=true;
         g_fillSnapshotDueMs=0;
         g_log.Info("buffered snapshot fired after pending fill (0.5s buffer elapsed)");
        }
      else
        {
         dueSnap=false; // defer routine snapshot until 500ms buffer completes
        }
     }

   //--- When positions changed (open/close/modify/drift), immediately refresh the cached
   //--- snapshot payload so any targeted repair or bootstrap emitted before
   //--- the next routine 15s broadcast always carries the true current state.
   //--- Avoid rebuilding twice in the same tick if BroadcastSnapshot is about to run.
   if(g_stateDirty && g_fillSnapshotDueMs==0 && !dueSnap)
     {
      RebuildSnapshotPayload();
     }

   if(dueSnap)
     {
      BroadcastSnapshot(now);
     }

   //--- 7) heartbeat with account state (needed for equity-relative sizing)
   if(HeartbeatSeconds>0 && now-g_lastHbtMs>=(long)HeartbeatSeconds*1000)
     {
      g_lastHbtMs=now;
      double bal=CopierAccountBalance();
      double eq=CopierAccountEquity();
      Emit(CP_T_HBT,CopierPayloadHeartbeat(bal,eq,0.0,0.0,g_prev.Count(),
                                           CopierAccountLogin()),false);
     }

   //--- 8) persist UID map only when it actually changed
   if(g_stateDirty)
     {
      g_stateDirty=false;
      CopierPos dense[];
      int slots[];
      int dn=g_prev.CopyToWithSlots(dense,slots);
      string hdr="SEQ="+(string)g_seq+";SSID="+g_ssid;
      double openLotsDense[];
      ArrayResize(openLotsDense,dn);
      for(int i=0;i<dn;i++) openLotsDense[i]=(slots[i]>=0)?g_openLots[slots[i]]:dense[i].lots;
      if(!CopierStateFile::Save(StatePath(),hdr,dense,dn,openLotsDense))
        {
         g_stateDirty=true;
         //--- rate-limited: on a busy account this can fire on most scans,
         //--- and an unreadable log is worse than no log at all
         if(g_once.ShouldEmit("statesave"))
            g_log.Warn("cannot write "+StatePath()+" - a restart will"
                       +" re-announce open positions as new (reported at most"
                       +" once per 10 min)");
        }
     }

   //--- 9) receiver status, arriving on the same socket the data leaves by.
   //---
   //--- DRAINED UNCONDITIONALLY, even when logging is off: an XPUB that is
   //--- never read grows its receive queue until it starts dropping, and a
   //--- sender that quietly discards what its receivers report is a worse
   //--- failure than a verbose one.
   int sn2=g_tp.DrainStatus(g_drainStatus,CP_DRAIN_MAX);
   for(int i=0;i<sn2;i++)
     {
      //--- subscription bytes arrive here too - that is how XPUB works - so
      //--- every message is DECODED rather than assumed to be status.
      CopierEnv se;
      if(CopierDecodeEnv(g_drainStatus[i],se)!=CP_ERR_NONE) continue;

      if(se.type==CP_T_PONG)
        {
         string pms="",pfrom="";
         CopierKvGet(se.payload,"MS",pms);
         CopierKvGet(se.payload,"FROM",pfrom);
         if(StringLen(pfrom)>0 && g_peers.PongBack(pfrom,CopierParseLong(pms)))
           {
            if(g_once.ShouldEmit("rtt|"+pfrom))
               g_log.Info("link to "+pfrom+" measured: "
                          +(string)g_peers.RttFor(pfrom)+" ms round trip");
           }
         continue;
        }

      if(se.type==CP_T_PING)
        {
         string pms="",pfrom="";
         CopierKvGet(se.payload,"MS",pms);
         CopierKvGet(se.payload,"FROM",pfrom);
         if(StringLen(pfrom)>0)
           {
            g_peers.Seen(pfrom);
            Emit(CP_T_PONG,
                 CopierPayloadPong(CopierParseLong(pms),
                                   (string)CopierAccountLogin(),pfrom),
                 false);
           }
         continue;
        }

      if(se.type==CP_T_STAT)
        {
         HandleSenderStat(se);
         continue;
        }
     }

   //--- 9b) the CENTRAL channel's DOWN path.
   //---
   //--- Two-frame messages, unlike everything above - which is why this uses
   //--- DrainFrames rather than DrainStatus. Both are needed: the direct
   //--- receivers still answer on m_pub, the hub answers on m_sub.
   //---
   //--- Phase 1 has almost nothing to act on here. The point today is that
   //--- these ARRIVE at all, which is what proves the subscription prefix and
   //--- the two-frame framing actually work end to end. A hub that is
   //--- unreachable shows up as the hub row going DISCONNECTED on the panel,
   //--- not as silence in the log.
   if(g_hubOn)
     {
      int hn=g_tp.DrainFrames(g_drainTopics,g_drainMsgs,CP_DRAIN_MAX);
      for(int i=0;i<hn;i++)
        {
         string t=g_drainTopics[i];
         if(StringLen(t)>0)
           {
            string myNid=(string)g_nid;
            string myAcc=(string)CopierAccountLogin();
            if(t!="@all" && t!="@"+myNid && t!="@"+myAcc) continue;
           }
         CopierEnv he;
         if(CopierDecodeEnv(g_drainMsgs[i],he)!=CP_ERR_NONE) continue;

         if(he.type==CP_T_PONG)
           {
            string hms="",hfrom="",hto="";
            CopierKvGet(he.payload,"MS",hms);
            CopierKvGet(he.payload,"FROM",hfrom);
            CopierKvGet(he.payload,"TO",hto);
            if(StringLen(hto)>0 && hto!=(string)g_nid && hto!=(string)CopierAccountLogin()) continue;
            if(StringLen(hfrom)>0 && g_peers.PongBack(hfrom,CopierParseLong(hms)))
              {
               g_pump.Disarm(); // Echo arrived -> cancel fast pump immediately
              }
            continue;
           }
         //--- WHO: the hub has lost its node table - it restarted, and the
         //--- table is in memory only - and is asking everyone to say who they
         //--- are. Answering is the entire job, and it is why this node
         //--- subscribed to @all.
         if(he.type==CP_T_WHO)
           {
            //--- Answer with ONE REG. The counter is deliberately NOT reset.
            //---
            //--- Resetting it looks like a safety net - "if this answer is
            //--- lost, the next few heartbeats are REG as well" - but the WHO
            //--- sweep is unconditional and runs every 60s forever, so the
            //--- counter would be re-armed every minute and the node would
            //--- never settle into HBT2. MEASURED on a live 5-minute run: 19
            //--- REG from a node whose steady state should be 3, and REG is
            //--- the EXPENSIVE message (it carries NAME, and the hub logs
            //--- every one).
            //---
            //--- The safety net is unnecessary anyway. A lost REG is recovered
            //--- by the NEXT WHO, which arrives whether or not anyone answers -
            //--- that is the entire reason the sweep exists.
            HubAnnounce(true);
            continue;
           }

         //--- SNAPSHOT RECEIPT, relayed back by the hub.
         //---
         //--- In central mode the receiver's STAT stops AT THE HUB and is not
         //--- forwarded (D13, doc/CENTRAL-HUB-PLAN.md) - the hub keeps the
         //--- receiver's monitoring figures, which belong to whoever watches
         //--- receivers. The delivery receipt is the one part that has to
         //--- reach the sender, because only the sender can act on it, so the
         //--- hub extracts it and relays it here.
         //---
         //--- This is a SEPARATE T from STAT on purpose. A relayed receipt
         //--- carries no equity, lots or risk state, so running the STAT path
         //--- on it would print a receiver-status line full of empty numbers.
         //--- Different message, different path, no shared assumptions.
         if(he.type==CP_T_RCPT)
           {
            string rwho="",rh="",rsid="";
            CopierKvGet(he.payload,"LOGIN",rwho);
            CopierKvGet(he.payload,"H",rh);
            CopierKvGet(he.payload,"SID",rsid);
            if(SenderAnswersTo(rsid))
               SnapTrack(rwho,rh,true);
            continue;
           }

         //--- anything else from the hub is control. Phase 2 has no command
         //--- that CHANGES anything - the write path (CFG/ACK/CFGR) is Phase 3,
         //--- the highest-risk step, deliberately last - so there is nothing to
         //--- obey yet. Logged once per type so a future CFG does not look like
         //--- it vanished.
         if(g_once.ShouldEmit("hubctl|"+he.type))
            g_log.Info("central channel: hub sent "+he.type
                       +" (nothing to do for it yet - Phase 2 is read-only)");
        }
     }

   //--- 9) peers and the panel. Panel update BEFORE CheckPeers so GDI rendering never blocks/delays PING round-trip
   UpdatePanel();
   CheckPeers();

   g_log.Tick();
  }

#ifdef __MQL5__
bool g_tradeDirty=false;
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD ||
      trans.type==TRADE_TRANSACTION_POSITION ||
      trans.type==TRADE_TRANSACTION_ORDER_ADD ||
      trans.type==TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type==TRADE_TRANSACTION_HISTORY_ADD)
     {
      // NM-06: Set dirty flag and pulse high-priority pump instead of re-entering full OnTimer 6-7 times
      g_tradeDirty=true;
      g_pump.Trigger();
     }
  }
#endif

void OnTick()
  {
   // Pure event & timer driven: zero dependency on symbol tick data.
   // Eliminates CPU spikes during high-volatility tick bursts.
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
