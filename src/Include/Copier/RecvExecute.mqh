//+------------------------------------------------------------------+
//| RecvExecute.mqh                                                  |
//| Part of CopierReceiver.mq4 - not a standalone header.            |
//+------------------------------------------------------------------+
//--- Action queue: PushAction, queue maintenance, backoff and ExecuteQueue.
//--- Included at a fixed point inside CopierReceiver.mq4 and relies on
//--- the globals, inputs and helpers declared above that point. Moved
//--- verbatim out of the EA; do not include it from anywhere else.
#ifndef __COPIER_RECVEXECUTE_MQH__
#define __COPIER_RECVEXECUTE_MQH__

//=====================================================================
// Action queue
//=====================================================================
bool ActionQueued(const int si,const int kind,const string uid,const string keyExtra="")
  {
   string expectedKey=(StringLen(keyExtra)>0)?(SenderLabel(si)+":"+(string)kind+":"+uid+keyExtra):"";
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[g_qHead+i].senderIdx==si && g_q[g_qHead+i].kind==kind
         && g_q[g_qHead+i].uid==uid)
        {
         // P2-20: If keyExtra distinguishes sub-actions (e.g. TRIM target lots, specific sl/tp), compare key
         if(StringLen(keyExtra)==0 || g_q[g_qHead+i].key==expectedKey) return true;
        }
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
                const long pexpire=0,const double openPx=0.0)
  {
   //--- keyExtra distinguishes actions that share a kind and a UID but are
   //--- genuinely different, e.g. two successive partial closes to two
   //--- different target volumes, or two successive stop changes
   string sname=(si>=0 && si<CP_MAX_SENDERS && StringLen(g_sid[si])>0) ? g_sid[si] : "manual";
   string key=sname+":"+(string)kind+":"+uid+keyExtra;
   g_pushReject="";
   //--- an idempotent state assignment is guarded by the state comparison
   //--- on every converge pass, NOT by the "already done" ring - see
   //--- CopierSeenRingApplies() for the pilot failure this caused
   if(CopierSeenRingApplies(kind) && g_seen.Has(key)) { g_pushReject="already_done"; return false; }
   if(g_inflight.Has(key)) { g_pushReject="in_flight"; return false; } // NH-04: in-flight suppression for async execution
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
   //--- CLOSE, TRIM, and DEDUP actions are risk-reducing exit operations.
   //--- They use BlockedExit() with a progressive 60s-capped ladder (1s -> 3s -> 10s -> 30s -> 60s max),
   //--- protecting capital promptly without ever flooding the broker at 1 request/sec on persistent refusals.
   if(kind==CP_ACT_CLOSE || kind==CP_ACT_TRIM || kind==CP_ACT_DEDUP)
     {
      // SenderIdx < 0 (manual/orphan close re-queues) are held and paced inside ExecuteQueue
      if(si>=0 && g_backoff.BlockedExit(key)) { g_pushReject="retry_backoff"; return false; }
     }
   else if(kind==CP_ACT_MODIFY)
     {
      //--- ISSUE-05 / N-04: MODIFY actions lock backoff to position ticket with 30s-capped BlockedModify ladder.
      //--- Otherwise micro-price changes in trailing stops generate fresh keys, or rejected stops park for 24 hours.
      string boKey = (ticket!=0) ? (sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)ticket) : key;
      if(g_backoff.BlockedModify(boKey)) { g_pushReject="retry_backoff"; return false; }
     }
   else
     {
      if(g_backoff.Blocked(key)) { g_pushReject="retry_backoff"; return false; }
     }
   //--- and a longer park for something this platform cannot place at all,
   //--- for the same reason - the key keeps it from touching anything else.
   if(g_unsupported.Has(key)) { g_pushReject="unsupported"; return false; }
   // DEF-B01 & DEF-B05: If a full CLOSE or DEDUP is being queued, cancel any pending OPEN or MODIFY in the queue for this UID
   if(kind==CP_ACT_CLOSE || kind==CP_ACT_DEDUP)
     {
      bool openCancelled=false;
      for(int qi=0; qi<g_qn; qi++)
        {
         int qidx=g_qHead+qi;
         if(g_q[qidx].uid==uid && g_q[qidx].senderIdx==si)
           {
            if(g_q[qidx].kind==CP_ACT_OPEN)
              {
               g_q[qidx].kind=CP_ACT_NONE;
               openCancelled=true;
              }
            else if(g_q[qidx].kind==CP_ACT_MODIFY || g_q[qidx].kind==CP_ACT_TRIM)
              {
               g_q[qidx].kind=CP_ACT_NONE;
              }
           }
        }
      if(openCancelled && ticket<=0)
        {
         // Open was cancelled in queue before ever reaching the broker
         // and no local ticket was supplied; close is already satisfied.
         g_pushReject="open_cancelled_in_queue";
         return false;
        }
     }
   // D1-M02: Suppress MODIFY and TRIM if a full CLOSE or DEDUP action is already queued for this position
   if(kind==CP_ACT_MODIFY || kind==CP_ACT_TRIM)
     {
      if(ActionQueued(si,CP_ACT_CLOSE,uid) || ActionQueued(si,CP_ACT_DEDUP,uid))
        {
         g_pushReject="close_already_queued";
         return false;
        }
     }
   // R12-A01: In-place coalescing for CP_ACT_TRIM:
   if(kind==CP_ACT_TRIM)
     {
      for(int qi=0; qi<g_qn; qi++)
        {
         int qidx=g_qHead+qi;
         if(g_q[qidx].senderIdx==si && g_q[qidx].kind==CP_ACT_TRIM && g_q[qidx].uid==uid)
           {
            g_q[qidx].lots   = lots;
            g_q[qidx].ticket = ticket;
            g_q[qidx].key    = key;
            g_qRetryAtMs     = 0;
            return true;
           }
        }
     }
   // R10-A04: In-place coalescing for CP_ACT_MODIFY:
   // If a MODIFY action for this sender and UID is already queued, coalesce it in place
   // with the latest requested sl/tp/pprice/pstop/pexpire rather than creating queue duplicate storms.
   if(kind==CP_ACT_MODIFY)
     {
      for(int qi=0; qi<g_qn; qi++)
        {
         int qidx=g_qHead+qi;
         if(g_q[qidx].senderIdx==si && g_q[qidx].kind==CP_ACT_MODIFY && g_q[qidx].uid==uid)
           {
            g_q[qidx].sl      = sl;
            g_q[qidx].tp      = tp;
            g_q[qidx].pprice  = pprice;
            g_q[qidx].pstop   = pstop;
            g_q[qidx].pexpire = pexpire;
            g_q[qidx].key     = key;
            g_qRetryAtMs      = 0;
            return true;
           }
        }
     }
   if(ActionQueued(si,kind,uid,keyExtra))
     {
      // BUG-01: If an exit action (CLOSE/TRIM/DEDUP) is already in the queue, do not leave it
      // frozen under an existing queue backoff (which could be up to 15m~1h) if exit backoff has cleared!
      if(kind==CP_ACT_CLOSE || kind==CP_ACT_TRIM || kind==CP_ACT_DEDUP)
        {
         if(!g_backoff.BlockedExit(key))
           {
            g_qRetryAtMs=0;
            g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
            g_qSpinPasses=0;
           }
        }
      g_pushReject="already_queued";
      return false;
     }
   if(g_qHead+g_qn>=CP_MAX_ACTIONS)
     {
      //--- the tail hit the end of the array: reclaim the dead prefix first,
      //--- then re-check. Compaction is the ONLY O(n) pass left on this path
      //--- and it happens once per CP_MAX_ACTIONS/2 dequeues.
      CompactQueue();
     }
   if(g_qHead+g_qn>=CP_MAX_ACTIONS)
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
      g_pushReject="queue_full";
      return false;
     }
   int t=g_qHead+g_qn;
   g_q[t].senderIdx=si;
   g_q[t].kind=kind;
   g_q[t].uid=uid;
   g_q[t].sym=sym;
   g_q[t].side=side;
   g_q[t].lots=lots;
   g_q[t].ticket=ticket;
   g_q[t].senderTicket=senderTicket;
   //--- every field is written on every push. g_q is a fixed array of
   //--- structs and slots are reused, so a field left unset would silently
   //--- inherit the previous occupant's value.
   g_q[t].sl=sl;
   g_q[t].tp=tp;
   g_q[t].ordKind=ordKind;
   g_q[t].ptype=ptype;
   g_q[t].pprice=pprice;
   g_q[t].pstop=pstop;
   g_q[t].pexpire=pexpire;
   g_q[t].openPx=openPx;
   g_q[t].key=key;
   g_qn++;
   //--- P1: something new to do - never let a backoff armed by an earlier
   //--- zero-progress pass delay it.
   g_qRetryAtMs=0;
   g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
   g_qSpinPasses=0;
   return true;
  }

//--- Slide the live region back to index 0. The only O(n) operation on the
//--- queue, and only when the tail runs out of room - i.e. once per
//--- CP_MAX_ACTIONS/2 executed actions, not once per action.
void CompactQueue()
  {
   if(g_qHead<=0) return;
   int oldHead=g_qHead;
   for(int i=0;i<g_qn;i++) g_q[i]=g_q[oldHead+i];
   // M7 & D6: Clear string references on vacated tail slots to prevent dead string retention
   for(int k=g_qn;k<oldHead+g_qn;k++)
     {
      g_q[k].uid="";
      g_q[k].sym="";
      g_q[k].key="";
     }
   g_qHead=0;
  }

void ShiftQueue()
  {
   if(g_qn<=0) return;
   //--- release the strings the slot held: with a moving head the slot is not
   //--- overwritten until the next compaction, so leaving them referenced
   //--- would keep up to CP_MAX_ACTIONS dead actions alive in memory
   g_q[g_qHead].uid="";
   g_q[g_qHead].sym="";
   g_q[g_qHead].key="";
   g_qHead++;
   g_qn--;
   if(g_qn<=0) g_qHead=0;              // empty: reset so the array is reusable
  }

void ClearQueue()
  {
   //--- P1: an emptied queue has nothing to back off from. Without this, a
   //--- reload could leave a deadline armed for a queue that no longer exists.
   g_qRetryAtMs=0;
   g_qBackoffMs=CP_Q_BACKOFF_MIN_MS;
   g_qSpinPasses=0;
   for(int i=0;i<CP_MAX_ACTIONS;i++)
     {
      g_q[i].uid="";
      g_q[i].sym="";
      g_q[i].key="";
      g_q[i].ticket=0;
      g_q[i].senderTicket=0;
      g_q[i].lots=0.0;
      g_q[i].kind=0;
      g_q[i].senderIdx=-1;
     }
   g_qn=0;
   g_qHead=0;
  }

// NM-10: Clear queue on config reload while preserving risk-reducing actions (CLOSE/TRIM/DEDUP/MODIFY)
void ClearQueueExceptRiskReducing()
  {
   int w=0;
   for(int i=0;i<g_qn;i++)
     {
      int idx=g_qHead+i;
      CopierAction a=g_q[idx];
      if(a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP || a.kind==CP_ACT_MODIFY)
        {
         if(w!=i) g_q[g_qHead+w]=a;
         w++;
        }
      else
        {
         g_q[idx].uid="";
         g_q[idx].sym="";
         g_q[idx].key="";
        }
     }
   //--- M7 fix: clear string references on vacated tail slots to prevent dead string retention
   for(int k=w;k<g_qn;k++)
     {
      int idx=g_qHead+k;
      g_q[idx].uid="";
      g_q[idx].sym="";
      g_q[idx].key="";
     }
   g_qn=w;
   if(g_qn<=0) g_qHead=0;
  }

// M2 & L5: Remap preserved queue actions' senderIdx from old configuration to new indices.
//--- L5: a CP_ACT_MODIFY whose sender disappeared is dropped rather than kept with
//--- senderIdx == -1. Risk-reducing exits (CLOSE/TRIM/DEDUP) must survive a reload -
//--- they are the only path that can still flatten the position - but a stop update
//--- has no meaning without its sender, and keeping it only produced a bogus
//--- "action in queue for sender index -1 out of bounds" error on every dequeue.
void RemapQueueSenders(const string &beforeSid[],const int beforeN)
  {
   int w=0;
   for(int i=0;i<g_qn;i++)
     {
      int idx=g_qHead+i;
      CopierAction a=g_q[idx];
      int oldSi=a.senderIdx;
      int newSi=oldSi;
      if(oldSi>=0 && oldSi<beforeN)
        {
         string oldSid=beforeSid[oldSi];
         newSi=-1;
         for(int j=0;j<g_nSenders;j++)
           {
            if(g_sid[j]==oldSid) { newSi=j; break; }
           }
        }
      else if(oldSi>=beforeN)
        {
         newSi=-1;
        }
      a.senderIdx=newSi;
      if(newSi<0 && a.kind==CP_ACT_MODIFY)
        {
         g_q[idx].uid="";
         g_q[idx].sym="";
         g_q[idx].key="";
         continue;                       // compacted away, not merely skipped
        }
      if(w!=i) g_q[g_qHead+w]=a;
      w++;
     }
   for(int k=w;k<g_qn;k++)
     {
      int idx=g_qHead+k;
      g_q[idx].uid="";
      g_q[idx].sym="";
      g_q[idx].key="";
     }
   g_qn=w;
   if(g_qn<=0) g_qHead=0;
  }

double PipSize(const CopierSymInfo &si)
  {
   //--- the digits-based pip rule used to live here; it is now the single
   //--- definition in CopierModel.mqh that every caller shares
   return CopierPipOf(si);
  }

//--- Move the head of the queue to the back.
//--- Used to step past an action that must not be sent right now without
//--- dropping it: converge would re-derive an OPEN anyway, but a CLOSE has no
//--- other source, so nothing may be silently discarded here.
void RotateQueue()
  {
   if(g_qn<2) return;
   if(g_qHead+g_qn>=CP_MAX_ACTIONS) CompactQueue();
   //--- H2 fix: If queue is completely full (g_qn == CP_MAX_ACTIONS), rotate in-place
   //--- by shifting elements left and moving head to the tail, preventing head-of-line blocking.
   if(g_qHead+g_qn>=CP_MAX_ACTIONS)
     {
      CopierAction headAct=g_q[0];
      for(int k=0;k<g_qn-1;k++) g_q[k]=g_q[k+1];
      g_q[g_qn-1]=headAct;
      g_qHead=0;
      return;
     }
   //--- head to tail in ONE assignment: the live region [H, H+Q-1] becomes
   //--- [H+1, H+Q], which is the same Q entries with the head last.
   g_q[g_qHead+g_qn]=g_q[g_qHead];
   g_q[g_qHead].uid="";
   g_q[g_qHead].sym="";
   g_q[g_qHead].key="";
   g_qHead++;
  }

// MQL-01: Action backoff key consistency. MODIFY actions with ticket!=0 are keyed
// by `#t<ticket>` to prevent micro stop adjustments from bypassing backoff.
string ActionBackoffKey(const CopierAction &a)
  {
   if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
     {
      string sname=SenderLabel(a.senderIdx);
      return sname+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket;
     }
   return a.key;
  }

void ExecuteQueue()
  {
   int done=0;
   int skipped=0;
   //--- P3: same rule as ConvergeSender - one pass, verdicts reused inside it.
   g_staleVerdict.Reset();
   g_sessVerdict.Reset();
   int sAddedCount[CP_MAX_SENDERS];
   double sAddedLots[CP_MAX_SENDERS];
   int sHeldBase[CP_MAX_SENDERS];
   double sHeldBaseLots[CP_MAX_SENDERS];
   bool sHeldBaseKnown[CP_MAX_SENDERS];
   ArrayInitialize(sAddedCount,0);
   ArrayInitialize(sAddedLots,0.0);
   ArrayInitialize(sHeldBase,0);
   ArrayInitialize(sHeldBaseLots,0.0);
   ArrayInitialize(sHeldBaseKnown,false);
#ifdef __MQL5__
   double initialFreeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
#else
   double initialFreeMargin=AccountFreeMargin();
#endif
   double drainedReqMargin=0.0;
   double freedMarginEst=0.0;

   //--- Assess if this is a Batch Close or Batch Modify operation (e.g. Martingale/Grid basket exit, or closeall, or >8 queued)
   int closeCount=0;
   int modifyCount=0;
   for(int qi=0; qi<g_qn; qi++)
     {
      int qk=g_q[g_qHead+qi].kind;
      if(qk==CP_ACT_CLOSE || qk==CP_ACT_TRIM || qk==CP_ACT_DEDUP)
         closeCount++;
      else if(qk==CP_ACT_MODIFY)
         modifyCount++;
     }
   // R14-A09/D06: Prioritize risk-reducing exits ahead of pending/new opens in the same tick
   // while preserving FIFO ordering inside exits and inside opens/modifies.
   if(closeCount>0 && closeCount<g_qn)
     {
      int exitDest=0;
      for(int qi=0; qi<g_qn; qi++)
        {
         int qk=g_q[g_qHead+qi].kind;
         if(qk==CP_ACT_CLOSE || qk==CP_ACT_TRIM || qk==CP_ACT_DEDUP)
           {
            if(qi>exitDest)
              {
               CopierAction exitAct=g_q[g_qHead+qi];
               for(int sh=qi; sh>exitDest; sh--)
                  g_q[g_qHead+sh]=g_q[g_qHead+sh-1];
               g_q[g_qHead+exitDest]=exitAct;
              }
            exitDest++;
           }
        }
     }
   bool isEmergencyExit=(g_cmdCloseAllActive || g_riskCloseAllPending);
   bool isBatchClose=(isEmergencyExit || closeCount>=8);
   bool isBatchModify=(modifyCount>=8);
   // M-10: Cap batch operations to 64 actions per tick to avoid freezing event loop on huge backlogs
   int maxActions=((isBatchClose || isBatchModify) ? 64 : MaxActionsPerTick);

   int sweepCount=0;
   int asyncBatchCount=0;
   int mktClosedHeld=0;

   //--- PRE-FLIGHT CHECK: Is trading permitted at this terminal/account?
   //--- Protects against flood-penalties on read-only (investor) accounts or toggled AutoTrading.
   if(!CopierTradeAllowed())
     {
      if(g_once.ShouldEmit("trade_dis_global"))
         g_log.Warn("Trading is disabled at this terminal (AutoTrading button is off, account is read-only / investor mode, or broker disabled trading). Holding all "+(string)g_qn+" queued action(s).");
      CopierQueueNotePass(CopierNowMs(),g_qn,0,g_qBackoffMs,g_qRetryAtMs,g_qSpinPasses,false);
      return;
     }

   //--- N72-05 & P1-01: Global feed stall check BEFORE entering the queue loop.
   //--- If server clock is stalled, check if queue has risk-reducing actions (CLOSE/TRIM).
   //--- If queue has ONLY opens/modifies, hold entire queue up-front to eliminate 65,000 struct copies/tick.
   //--- If queue contains CLOSE/TRIM, proceed into loop so exit orders can be dispatched to broker.
   bool globalStall = (!g_srvEverMoved || CopierNowMs()-g_srvChangedMs>CP_FEED_STALL_MS);
   if(globalStall && closeCount==0)
     {
      if(g_once.ShouldEmit("qstallglobal"))
         g_log.Warn("no quotes for "
                    +(string)((CopierNowMs()-g_srvChangedMs)/1000)+"s -"
                    +" holding ENTIRE queue ("+(string)g_qn+" action(s))."
                    +" Market is closed or feed is down; nothing can be priced from a stale clock.");
      CopierQueueNotePass(CopierNowMs(),g_qn,0,g_qBackoffMs,g_qRetryAtMs,g_qSpinPasses,true);
      return;
     }

   //--- `skipped` bounds a full rotation, so a queue in which EVERY action is
   //--- blocked does not spin through itself ten times a second.
   while(g_qn>0 && done<maxActions && skipped<g_qn)
     {
      CopierAction a=g_q[g_qHead];
      if(a.kind<=CP_ACT_NONE)
        {
         ShiftQueue();
         continue;
        }
      int err=0;
      bool ok=false;
      bool asyncMode=false;

      if(a.senderIdx<0 || a.senderIdx>=g_nSenders)
        {
         // MQL-01 & H3: Allow risk-reducing exit actions (CLOSE/TRIM/DEDUP) on orphaned/removed senders (si == -1)
         if(a.senderIdx==-1 && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP))
           {
            // Allowed: manual/orphan single close action from WebUI, or preserved trim from reloaded sender
           }
         else
           {
            g_log.Error("action in queue for sender index "+(string)a.senderIdx+" out of bounds (nSenders="+(string)g_nSenders+"); dropping action "+a.uid);
            ShiftQueue();
            continue;
           }
        }

      // Paced execution for orphan / manual close actions waiting on backoff
      if(a.senderIdx<0 && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP))
        {
         if(g_backoff.BlockedExit(a.key))
           {
            RotateQueue();
            skipped++;
            continue;
           }
        }

      //--- P1-01 & N74-03: During a global quote stall, hold OPEN actions while permitting
      //--- risk-reducing exit actions (CLOSE/TRIM/DEDUP) to attempt execution.
      if(globalStall && a.kind!=CP_ACT_CLOSE && a.kind!=CP_ACT_TRIM && a.kind!=CP_ACT_DEDUP)
        {
         RotateQueue();
         skipped++;
         mktClosedHeld++;
         continue;
        }

      //--- UNIFIED MARKET CLOSED CHECK (Session, Broker 132/10018, or Stale Feed)
      //--- ISSUE-01 / N-01: Risk-reducing exit actions (CLOSE/TRIM/DEDUP) are NEVER held
      //--- by local quote staleness or session estimates; let the broker execute them.
      if(a.kind!=CP_ACT_CLOSE && a.kind!=CP_ACT_TRIM && a.kind!=CP_ACT_DEDUP && SymbolMarketClosed(a.sym))
        {
         if(g_once.ShouldEmit("qclosed|"+a.sym))
            g_log.Info("market for "+a.sym+" is closed - holding queued action "
                       +a.uid+" (kind="+(string)a.kind+"); it will execute when the market reopens");
         RotateQueue();
         skipped++;
         mktClosedHeld++;
         continue;
        }

      //--- MARKET OPEN WARMUP & SPREAD PROTECTION (Solution A)
      int warmupElapsed=0;
      if(SymbolInOpenWarmup(a.sym, warmupElapsed))
        {
         double curSp = CopierGetSpreadPoints(a.sym);
         TrackSymbolSpread(a.sym, curSp, true);

         if(a.kind==CP_ACT_OPEN)
           {
            if(g_once.ShouldEmit("warmup_open|"+a.sym))
               g_log.Info("market open warmup active for "+a.sym+" ("
                          +IntegerToString(MarketOpenDelayMinutes*60 - warmupElapsed)+"s remaining) - holding queued OPEN");
            RotateQueue();
            skipped++;
            continue;
           }
         else if(a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP)
           {
            // D-04: If risk close-all is pending or emergency close active, never hold exit actions due to spread!
            if(!g_riskCloseAllPending && !g_cmdCloseAllActive && !g_risk.AnyTripped())
              {
               double minSp = GetSymbolMinSpread(a.sym);
               bool isWide = (minSp>0.0 && curSp > minSp * MaxSpreadMultiplier);
               if(isWide && warmupElapsed < MarketOpenCloseMaxWaitSec)
                 {
                  if(g_once.ShouldEmit("warmup_close|"+a.sym))
                     g_log.Info("wide spread ("+DoubleToString(curSp,1)+" vs normal "+DoubleToString(minSp,1)
                                +") on "+a.sym+" during market open - holding CLOSE (timeout in "
                                +IntegerToString(MarketOpenCloseMaxWaitSec - warmupElapsed)+"s)");
                  RotateQueue();
                  skipped++;
                  continue;
                 }
              }
           }
         // Note: a.kind == CP_ACT_MODIFY does NOT cross spread; it proceeds immediately to protect stops!
        }

      //--- R13: Respect trading hours window when executing queued OPEN actions
      if(a.kind==CP_ACT_OPEN)
        {
         bool hoursOk=true;
         if(a.senderIdx>=0 && a.senderIdx<g_nSenders && g_senderHours[a.senderIdx].Active())
            hoursOk=g_senderHours[a.senderIdx].Allows(CopierServerTime());
         else if(g_hours.Active())
            hoursOk=g_hours.Allows(CopierServerTime());
         if(!hoursOk)
           {
            if(g_once.ShouldEmit("hours_open|"+(string)a.senderIdx))
               g_log.Info("outside trading hours window - holding queued OPEN "+a.uid);
            RotateQueue();
            skipped++;
            continue;
           }
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
         // A86-03: Freshness & desire verification before draining queued OPEN.
         // If sender is unready, silent/stale, or has already closed/cancelled the trade, drop stale OPEN.
         int asi=a.senderIdx;
         if(asi>=0 && asi<g_nSenders)
           {
            if(!g_ready[asi] || g_stale[asi])
              {
               if(g_once.ShouldEmit("drainstale|"+g_sid[asi]+"|"+a.uid))
                  g_log.Warn("queued open "+a.uid+" "+a.sym+" dropped: sender "+g_sid[asi]
                             +" is not ready or stale. Next snapshot will re-derive if still desired.");
               ShiftQueue();
               continue;
              }
            int base=asi*CP_MAX_POSITIONS;
            bool stillDesired=false;
            for(int d=0; d<g_desiredCount[asi]; d++)
              {
               if(g_desired[base+d].uid==a.uid)
                 {
                  // N87-04: Verify side, order kind (market vs pending), and that lots haven't been reduced
                  int expectedSide = g_senderCfg[asi].inverttrades ? -g_desired[base+d].side : g_desired[base+d].side;
                  if(expectedSide==a.side && g_desired[base+d].kind==a.ordKind)
                    {
                     // Check target lots: if sender trimmed volume while queued, drop stale oversized OPEN
                     double targetLots = ComputeTargetLotsForMirror(asi, g_desired[base+d], a.sym);
                     if(targetLots > 0.0 && a.lots > targetLots + CP_LOT_EPS)
                       {
                        if(g_once.ShouldEmit("draintrimmed|"+g_sid[asi]+"|"+a.uid))
                           g_log.Info("queued open "+a.uid+" "+a.sym+" dropped: sender trimmed volume while queued ("
                                      +DoubleToString(a.lots,2)+" -> "+DoubleToString(targetLots,2)+"); will re-derive.");
                        break; // stillDesired remains false -> dropped and re-derived next tick
                       }
                     stillDesired=true;
                    }
                  break;
                 }
              }
            if(!stillDesired)
              {
               if(g_once.ShouldEmit("drainundesired|"+g_sid[asi]+"|"+a.uid))
                  g_log.Info("queued open "+a.uid+" "+a.sym+" dropped: sender "+g_sid[asi]
                             +" no longer holds matching position (closed, flipped, changed kind, or trimmed).");
               ShiftQueue();
               continue;
              }
           }

         // R47-05: Defend against unpopulated account positions before initial scan completes
         if(!g_acctScanned)
           {
            ShiftQueue();
            continue;
           }
         string why="";
         if(!g_risk.AllowOpen(a.lots,g_ourPositions,g_ourLots,g_ourPending,0.0,why))
           {
            g_riskBlocked++;
            if(g_once.ShouldEmit("drainrisk|"+a.uid))
               g_log.Warn("queued open "+a.uid+" "+a.sym+" dropped by the"
                          +" account risk gate after its wait: "+why
                          +". It is re-derived from the next snapshot and"
                          +" re-gated, so nothing is lost if the risk state"
                          +" frees (reported at most once per 10 min).");
            ShiftQueue();
            continue;
           }
        if(a.senderIdx>=0 && a.senderIdx<g_nSenders)
          {
           int si=a.senderIdx;
           if(!sHeldBaseKnown[si])
             {
              sHeldBase[si]=LocalForSender(si,g_acctAllPos,g_acctAllPosCount);
              sHeldBaseLots[si]=0.0;
              for(int k=0;k<sHeldBase[si];k++) sHeldBaseLots[si]+=g_locScratch[k].lots;
              sHeldBaseKnown[si]=true;
             }
           int sHeldCount=MathMax(0,sHeldBase[si]+sAddedCount[si]);
           double sHeldLots=MathMax(0.0,sHeldBaseLots[si]+sAddedLots[si]);
           string sWhy="";
           if(!g_senderRisk[si].AllowOpen(a.lots,sHeldCount,sHeldLots,
                                           0,0.0,sWhy))
              {
               g_riskBlocked++;
               if(g_once.ShouldEmit("drainsrisk|"+g_sid[a.senderIdx]+"|"+a.uid))
                  g_log.Warn("queued open "+a.uid+" "+a.sym+" dropped by"
                             +" sender "+g_sid[a.senderIdx]+"'s risk gate"
                             +" after its wait: "+sWhy+". Re-derived from the"
                             +" next snapshot and re-gated (reported at most"
                             +" once per 10 min).");
               ShiftQueue();
               continue;
              }
           }
        }

      double reqMargin=0.0;
      double preExitFree=0.0;
      double closedLots=a.lots;
      bool checkMargin=(a.kind==CP_ACT_OPEN);
      if(checkMargin && a.ordKind==CP_ORD_PENDING)
        {
#ifdef __MQL5__
         ENUM_SYMBOL_CALC_MODE pCalcMode=(ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(a.sym,SYMBOL_TRADE_CALC_MODE);
         checkMargin=(pCalcMode==SYMBOL_CALC_MODE_FUTURES || pCalcMode==SYMBOL_CALC_MODE_EXCH_FUTURES || pCalcMode==SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS);
#else
         checkMargin=(MarketInfo(a.sym,MODE_PROFITCALCMODE)==2);
#endif
        }
      if(checkMargin)
        {
         // Pre-trade Margin Validation (D2-02)
         bool marginOk=true;
#ifdef __MQL5__
         ENUM_ORDER_TYPE otype=(a.side==CP_SIDE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         double checkPx=(a.side==CP_SIDE_BUY)?SymbolInfoDouble(a.sym,SYMBOL_ASK):SymbolInfoDouble(a.sym,SYMBOL_BID);
         if(OrderCalcMargin(otype,a.sym,a.lots,checkPx,reqMargin))
           {
            // R6-D3-01: Check if this trade hedges an existing position on a hedging account
            if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
              {
               double hedgedMargin=SymbolInfoDouble(a.sym,SYMBOL_MARGIN_HEDGED);
               if(hedgedMargin>=0.0 && PositionSelect(a.sym))
                 {
                  ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                  if((a.side==CP_SIDE_BUY && ptype==POSITION_TYPE_SELL) || (a.side==CP_SIDE_SELL && ptype==POSITION_TYPE_BUY))
                    {
                     double posLots=PositionGetDouble(POSITION_VOLUME);
                     if(a.lots<=posLots) reqMargin=hedgedMargin*a.lots;
                    }
                 }
              }
           }
         else
           {
            // R6-D4-03 & R7-D3-01 & D-04: Fallback calculation if OrderCalcMargin fails, converting margin currency to account currency
            double cs=SymbolInfoDouble(a.sym,SYMBOL_TRADE_CONTRACT_SIZE);
            long lev=AccountInfoInteger(ACCOUNT_LEVERAGE);
            ENUM_SYMBOL_CALC_MODE calcMode=(ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(a.sym,SYMBOL_TRADE_CALC_MODE);
            bool noLev=(calcMode==SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE);
            if(cs>0.0 && (lev>0 || noLev))
              {
               string marginCcy=SymbolInfoString(a.sym,SYMBOL_CURRENCY_MARGIN);
               if(StringLen(marginCcy)==0) marginCcy=SymbolInfoString(a.sym,SYMBOL_CURRENCY_BASE);
               string accCcy=CopierAccountCurrency();
               string sfx=(a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS)?g_suffix[a.senderIdx]:"";
               double crossRate=(marginCcy==accCcy)?1.0:CopierGetCurrencyCrossRate(marginCcy,accCcy,sfx);
               bool needsPrice = (calcMode!=SYMBOL_CALC_MODE_FOREX && !noLev);
               double nominal = (needsPrice && checkPx>0.0) ? (a.lots*cs*checkPx) : (a.lots*cs);
               double effLev = noLev ? 1.0 : (double)lev;
               if(marginCcy!=accCcy && crossRate<=0.0)
                  marginOk=false;
               else if(crossRate>0.0)
                  reqMargin=(nominal/effLev)*crossRate;
               else if(checkPx>0.0)
                  reqMargin=nominal/effLev;
               else
                  reqMargin=0.0;
              }
            else
               reqMargin=0.0;
           }
         // R6-D4-04: Prevent double-counting previously drained margin
         double curFree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double effectiveFree=MathMin(curFree,initialFreeMargin+freedMarginEst-drainedReqMargin);
         if(effectiveFree < reqMargin) marginOk=false;
#else
         int cmd=(a.side==CP_SIDE_BUY)?OP_BUY:OP_SELL;
         double curFree=AccountFreeMargin();
         double fmCheck=AccountFreeMarginCheck(a.sym,cmd,a.lots);
         if(curFree>fmCheck && fmCheck>0.0)
            reqMargin=curFree-fmCheck;
         else
           {
            double oneLotMargin=MarketInfo(a.sym,MODE_MARGINREQUIRED);
            if(oneLotMargin>0.0) reqMargin=oneLotMargin*a.lots;
           }
         if(reqMargin<0.0) reqMargin=0.0;
         double effectiveFree=MathMin(curFree,initialFreeMargin+freedMarginEst-drainedReqMargin);
         if(fmCheck<=0.0 || (effectiveFree < reqMargin))
            marginOk=false;
#endif
         // R11-D04 & R12-D02: Check projected margin level against broker stop-out level with mode awareness
         double curMargin=0.0;
         double curEquity=CopierAccountEquity();
         double soLevel=0.0;
         bool isMoneyMode=false;
#ifdef __MQL5__
         curMargin=AccountInfoDouble(ACCOUNT_MARGIN);
         soLevel=AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
         isMoneyMode=(AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)==1);
#else
         curMargin=AccountMargin();
         soLevel=AccountStopoutLevel();
         isMoneyMode=(AccountStopoutMode()==1);
#endif
         double projMargin = MathMax(0.0, curMargin + drainedReqMargin + reqMargin - freedMarginEst);
         if(curEquity <= 0.0)
           {
            marginOk=false;
           }
         else if(projMargin > 0.0)
           {
            if(isMoneyMode)
              {
               double freeAfter = curEquity - projMargin;
               if(freeAfter <= soLevel + 50.0) marginOk=false;
              }
            else
              {
               double projLevel = (curEquity / projMargin) * 100.0;
               double minSafe = (soLevel > 0.0) ? (soLevel + 20.0) : 100.0;
               if(projLevel <= minSafe) marginOk=false;
              }
           }
         if(!marginOk)
           {
            if(g_once.ShouldEmit("nomargin|"+a.key))
               g_log.Warn("insufficient free margin to open "+a.uid+" "+a.sym+" ("
                          +DoubleToString(a.lots,2)+" lots) - skipping open to prevent broker rejection");
            // Park briefly (2s) without climbing 24h exponential backoff.
            // Must be the action's OWN key (it carries the ordKind suffix), or
            // PushAction's Blocked() never matches and converge re-queues it
            // on every pass.
            g_backoff.Park(a.key,2000);
            ShiftQueue();
            continue;
           }

         CopierSymInfo si;
         if(!CopierGetSymbolInfo(a.sym,si))
           {
            if(g_once.ShouldEmit("unknownsym|"+a.sym))
               g_log.Warn("unknown symbol "+a.sym+", dropping "
                          +a.uid+" (reported at most once per 10 min)");
            // P2-23 fix: do not add to seen ring so transient symbol unreadiness does not permanently drop mirror for 10 min
            ShiftQueue();
            done++;
            continue;
           }
         int rawDev = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].deviationPoints:DeviationPoints;
         int dev = CopierScaleDeviationPoints(a.sym, rawDev);
         double emSL = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].emergencySLPips:EmergencySLPips;
         double emTP = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].emergencyTPPips:EmergencyTPPips;
         bool usedEmSl=false;

         if(a.ordKind==CP_ORD_PENDING)
           {
            //--- a working order, not a market entry.
            double pendSl=a.sl;
            double pendTp=a.tp;
            double anchorPx=(a.pstop>0.0)?a.pstop:a.pprice;
            double pipSize=CopierPipOf(si);
            if(pendSl<=0.0 && emSL>0.0 && anchorPx>0.0)
              {
               double rawSl=(a.side==CP_SIDE_BUY)?(anchorPx-emSL*pipSize):(anchorPx+emSL*pipSize);
               pendSl=NormalizeDouble(rawSl,si.digits);
               usedEmSl=(pendSl>0.0);
              }
            if(pendTp<=0.0 && emTP>0.0 && anchorPx>0.0)
              {
               double rawTp=(a.side==CP_SIDE_BUY)?(anchorPx+emTP*pipSize):(anchorPx-emTP*pipSize);
               pendTp=NormalizeDouble(rawTp,si.digits);
              }

            bool clamped=false;
            if(pendSl>0.0 && anchorPx>0.0)
               pendSl=CopierFitStopAt(pendSl,a.side,true,anchorPx,si,clamped);
            if(usedEmSl && pendSl<=0.0) usedEmSl=false;
            if(pendTp>0.0 && anchorPx>0.0)
               pendTp=CopierFitStopAt(pendTp,a.side,false,anchorPx,si,clamped);

            CopierPos pp;
            pp.uid     =a.uid;
            pp.sym     =a.sym;
            pp.cmt     ="";
            pp.side    =a.side;
            pp.lots    =a.lots;
            pp.openPx  =a.pprice;
            pp.sl      =pendSl;
            pp.tp      =pendTp;
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
         //--- R58-01: emergency stops only - a.sl/a.tp are NOT used here.
         //---
         //--- For a market entry a.sl is the sender's absolute price in the
         //--- sender's book. Carrying it across brokers can put the stop on the
         //--- wrong side of our fill (rejected, or an instant stop-out when it is
         //--- far away), and under InvertTrades it points the wrong way at all.
         //--- The converge pass re-stops the position through CopierMirrorStop,
         //--- which re-anchors by DISTANCE against the real fill.
         double sl=0.0,tp=0.0;
         if(emSL>0.0)
           {
            int e2=0;
            sl=CopierEmergencySl(a.sym,a.side,0.0,emSL,si,e2);
            if(sl>0.0) usedEmSl=true;
            if(e2!=0 && g_once.ShouldEmit("em_sl_fail|"+a.sym))
               g_log.Warn("NL-02: EmergencySL configured but could not be computed for "+a.sym+" (err="+(string)e2+") - opening without SL");
           }
         if(emTP>0.0)
           {
            int e2=0;
            tp=CopierEmergencyTp(a.sym,a.side,0.0,emTP,si,e2);
            if(e2!=0 && g_once.ShouldEmit("em_tp_fail|"+a.sym))
               g_log.Warn("NL-02: EmergencyTP configured but could not be computed for "+a.sym+" (err="+(string)e2+") - opening without TP");
           }
         //--- the comment carries the UID (functional identity) and the
         //--- sender's ticket (so the two orders can be matched by eye)
         ok=CopierOpenMarket(a.sym,a.side,a.lots,sl,tp,
                             CopierCommentForUid(a.uid,a.senderTicket),
                             g_magic[a.senderIdx],dev,err);
           }
         if(ok && usedEmSl) g_emgSlApplied.Add(a.uid);
        }
      else if(a.kind==CP_ACT_MODIFY)
        {
         //--- NOTE this branch must come before the CLOSE fallback below.
         //--- Without it a MODIFY would fall through to
         //--- CopierClosePosition() and CLOSE the position it was only
         //--- meant to re-stop - the most expensive possible misroute here.
         if(a.ordKind==CP_ORD_PENDING)
            ok=CopierModifyPendingOrder(a.ticket,a.sym,a.pprice,a.sl,a.tp,a.pstop,(datetime)a.pexpire,err);
         else
            ok=CopierModifyStops(a.ticket,a.sym,a.sl,a.tp,err);
         if(ok) g_emgSlApplied.Forget(a.uid);
        }
      else
        {
         closedLots=a.lots;
         preExitFree=0.0;
         int rawDev = (a.senderIdx>=0 && a.senderIdx<g_nSenders)?g_senderCfg[a.senderIdx].deviationPoints:DeviationPoints;
         int dev = CopierScaleDeviationPoints(a.sym, rawDev);
         // NH-03: Exit Slippage Buffer is applied ONLY to emergency exits or true bulk martingale/grid exits (>=8 actions),
         // preventing routine 2-action closes from suffering 100 points (10 pips) slippage.
         // R12-D03: Exit operations (CLOSE, TRIM, DEDUP) are pure risk-reduction operations.
         // Grant generous slippage (at least 300 points) to prevent unclosable lockout on gap opens
         if(a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP)
            dev = MathMax(dev, CopierScaleDeviationPoints(a.sym, 300));

#ifdef __MQL5__
         asyncMode = isBatchClose && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP);
         if(asyncMode)
           {
            asyncBatchCount++;
            if((asyncBatchCount % 10) == 0)
              {
               // OPT-01: Token-Bucket Pacing: 20ms pause every 10 orders to protect broker rate limit
               CopierWaitMs(20);
              }
           }
         double prefetchedPx = 0.0;
#else
         asyncMode = false;
         double prefetchedPx = 0.0;
         if(isBatchClose && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP))
           {
            int ordType = (a.side==CP_SIDE_BUY)?OP_BUY:OP_SELL;
            prefetchedPx = (ordType==OP_BUY)?MarketInfo(a.sym,MODE_BID):MarketInfo(a.sym,MODE_ASK);
           }
#endif
         if((a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP || a.kind==CP_ACT_TRIM) && a.ordKind==CP_ORD_MARKET)
           {
#ifdef __MQL5__
            preExitFree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
#else
            preExitFree=AccountFreeMargin();
#endif
           }

         if(a.kind==CP_ACT_TRIM)
            ok=CopierClosePartial(a.ticket,a.lots,a.sym,a.side,
                                  (a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS ? g_magic[a.senderIdx] : 0),
                                  CopierCommentForUid(a.uid,a.senderTicket),
                                  dev,err,closedLots);
         else
            ok=CopierClosePosition(a.ticket,dev,err,asyncMode,prefetchedPx,a.ordKind);
        }

      //--- L2 retry budget: hoisted above both branches so the orphan-close
      //--- re-queue below can read it. Stays 1 for every failure mode that does
      //--- not climb the ladder.
      int fails=1;

      if(ok)
        {
         //--- record the SAME key PushAction tested, or the dedup silently
         //--- stops working for TRIMs (whose key carries the target volume)
         //--- ...but NOT for MODIFY, which is idempotent - see
         //--- CopierSeenRingApplies()
         //--- H-01 & NH-04: In asyncMode, broker confirmation is pending.
         //--- Park in 1s g_inflight instead of 10m g_seen to suppress duplicate re-triggers while avoiding lockouts.
         bool trimComplete=(a.kind!=CP_ACT_TRIM || closedLots>=a.lots-CP_LOT_EPS);
#ifdef __MQL5__
         if(asyncMode) g_inflight.Add(a.key);
         else if(CopierSeenRingApplies(a.kind) && trimComplete) g_seen.Add(a.key);
#else
         if(CopierSeenRingApplies(a.kind) && trimComplete) g_seen.Add(a.key);
#endif

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
           {
            drainedReqMargin+=reqMargin;
            g_ourCount++;
            g_ourLots+=a.lots;
            //--- F-10: keep granular order/position counters aligned on successful OPEN
            if(a.ordKind==CP_ORD_PENDING) { g_ourPending++; g_acctOrders++; }
            else                          { g_ourPositions++; g_acctPositions++; }
            if(a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS)
              {
               sAddedCount[a.senderIdx]++;
               sAddedLots[a.senderIdx]+=a.lots;
               g_everOpened.Add(g_sid[a.senderIdx]+":"+(string)CP_ACT_OPEN+":"
                                +a.uid);
               //--- Consumed: the expected re-open has now landed. Clear it so a
               //--- subsequent manual close within the 5-minute TTL is not
               //--- mistakenly re-opened under ReopenClosedMirrors=false.
               g_reopenExpected.Forget(g_sid[a.senderIdx]+":"+a.uid);
              }
           }
         else if(a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP)
           {
            ForgetSenderPeakLots(a.uid);
            StopsForget(a.uid);
            // MQL-07: In asyncMode (OrderSendAsync), broker execution is unconfirmed; do NOT deduct risk counters in this tick
            if(!asyncMode)
              {
               if(a.ordKind==CP_ORD_MARKET)
                 {
                  if(a.senderIdx>=0)
                    {
                     if(g_ourPositions>0) g_ourPositions--;
                     if(g_ourCount>0) g_ourCount--;
                     g_ourLots=MathMax(0.0,g_ourLots-a.lots);
                    }
                  else
                    {
                     // C3: Immediate deduction for manual/orphan position closed via WebUI
                     if(g_orphanCount>0) g_orphanCount--;
                    }
                  if(g_acctPositions>0) g_acctPositions--;
                  if(a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS)
                    {
                     //--- Note: sAddedCount/sAddedLots are per-tick net delta adjustments. If an existing
                     //--- position is closed before an open lands in the same tick, these may become negative;
                     //--- they are safely floored at 0 via MathMax at the risk gate (line 2809).
                     sAddedCount[a.senderIdx]--;
                     sAddedLots[a.senderIdx]-=a.lots;
                    }
                 }
               else if(a.ordKind==CP_ORD_PENDING)
                 {
                  // N49-10: Pending order deletion reduces pending count and total count/lots
                  if(a.senderIdx>=0)
                    {
                     if(g_ourPending>0) g_ourPending--;
                     if(g_ourCount>0) g_ourCount--;
                     g_ourLots=MathMax(0.0,g_ourLots-a.lots);
                    }
                  else
                    {
                     if(g_orphanCount>0) g_orphanCount--;
                    }
                  if(g_acctOrders>0) g_acctOrders--;
                  if(a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS)
                    {
                     sAddedCount[a.senderIdx]--;
                     sAddedLots[a.senderIdx]-=a.lots;
                    }
                 }
              }
           }
         else if(a.kind==CP_ACT_TRIM)
           {
            if(a.ordKind==CP_ORD_MARKET)
              {
               g_ourLots=MathMax(0.0,g_ourLots-closedLots);
               if(a.senderIdx>=0 && a.senderIdx<CP_MAX_SENDERS)
                 {
                  sAddedLots[a.senderIdx]-=closedLots;
                 }
              }
           }
         if((a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP || a.kind==CP_ACT_TRIM) && !asyncMode && a.ordKind==CP_ORD_MARKET)
           {
#ifdef __MQL5__
            double postExitFree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
#else
            double postExitFree=AccountFreeMargin();
#endif
            if(postExitFree>preExitFree) freedMarginEst+=(postExitFree-preExitFree);
           }
         //--- An executed action just changed what the identity file holds:
         //--- OPEN created a mirror, TRIM moved MT4's remainder onto a new
         //--- ticket, CLOSE removed one. Mark the map dirty so OnTimer
         //--- persists it on the NEXT tick (~100 ms) instead of waiting out
         //--- the 10 s cadence. The window matters since g_stateRestored
         //--- began suppressing the everOpened backfill: a mirror opened in
         //--- an unflushed window was never recorded as "opened before", so
         //--- ReopenClosedMirrors=false could not hold it closed later.
         //--- MODIFY touches only SL/TP - nothing the file carries.
         if(a.kind!=CP_ACT_MODIFY) g_mapDirty=true;
         //--- It worked, so the standing condition is gone. Reset the ladder
         //--- rather than leaving a stale count to punish the next, unrelated
         //--- failure with an hours-long park it never earned.
         g_backoff.Clear(a.key);
         if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
           {
            string sn=SenderLabel(a.senderIdx);
            g_backoff.Clear(sn+":"+(string)CP_ACT_MODIFY+":#t"+(string)a.ticket);
           }
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
         string sname=SenderLabel(a.senderIdx);
         g_log.Info(verb+sname+" "+a.uid+ref+" "+a.sym
                    +" "+detail);
        }
      else
        {
         // Two-Pass Sweeper: record failed batch close action ONLY for transient requotes / slippage (138, 10004, 10015)
         // Systemic errors (off quotes, broker busy, disabled) are left to the progressive ladder to prevent request flooding.
         bool isTransientRequote = (err==138 || err==10004 || err==10015);
         if(isBatchClose && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP) && sweepCount<CP_MAX_ACTIONS && isTransientRequote)
           {
            g_sweepFailed[sweepCount++]=a;
           }

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
         //--- R48-01: Only open actions encountering unsupported order types are recorded in g_unsupported
         if(err==-4 && a.kind==CP_ACT_OPEN)
           {
            g_unsupported.Add(a.key);
            if(g_onceFail.ShouldEmit("unsupported|"+SenderLabel(a.senderIdx)+"|"+a.uid))
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

         // R48-01 & MQL-02: Pending order volume modification is unsupported by broker API (err=-5).
         // Shift queue without putting into g_unsupported 15-minute lock. Safe SenderLabel() prevents array index -1 out of range.
         if(err==-5)
           {
            if(g_onceFail.ShouldEmit("pending_trim|"+SenderLabel(a.senderIdx)+"|"+a.uid))
               g_log.Warn("cannot partial close pending order for uid "+a.uid+" ticket "+(string)a.ticket
                          +" - broker API does not support partial close of pending orders");
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
         //--- AutoTrading off, or the trade context busy (MT4 4109, MT5 10027/10026/10017).
         //--- It is NOT the broker refusing the order: nothing reaches the broker at all,
         //--- so there is no request rate to protect, and climbing the ladder would park
         //--- the mirror for up to 24 hours AFTER the operator has switched AutoTrading
         //--- back on. Park it at the base rate and leave the ladder alone.
         if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
           {
            // BUG-01: Invalidate signature using exact 4-step probe hash to prevent freezing
            StopSigInvalidate(a.ticket);
            // N-05: Invalidate symbol info cache on broker invalid stops so next pass re-fetches geometry
            if(err==10016 || err==130) CopierInvalidateSymbolInfo(a.sym);
           }
         string sname=SenderLabel(a.senderIdx);
         string boKey=ActionBackoffKey(a);
         fails=1;
         if(CopierIsTradeDisabled(err))
           {
            fails=1;
            g_backoff.Park(boKey,CP_RETRY_BACKOFF_MS);
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
            g_backoff.Park(boKey,CP_MKTCLOSED_MS+jitter);
           }
         else
           {
            // R2-M03 & DEF-A01: Transient broker volatility errors (requote, off quotes, context busy, price changed)
            bool isTransientErr = (err==138 || err==136 || err==137 || err==145 || err==146 || 
                                   err==2 || err==6 || err==128 || err==135 || err==141 ||
                                   err==10004 || err==10006 || err==10011 || err==10012 || 
                                   err==10015 || err==10020 || err==10021 || err==10024 || err==10029);
            isTransientRequote = (err==138 || err==10004 || err==10015);
            bool queuedForSweep = (isBatchClose && (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_DEDUP) && isTransientRequote);
            if(err==146)
              {
               // R6-D1-02: MT4 trade context busy clears quickly: yield and park briefly (100ms)
               CopierWaitMs(50);
               fails=g_backoff.NotePark(boKey,100,5);
               //--- R22: an orphan/manual CLOSE has no sender to re-derive it,
               //--- so put it back before yielding the tick (same budget as L2).
               if(a.senderIdx<0 && a.kind==CP_ACT_CLOSE && fails<=5)
                 {
                  CopierAction retry146=a;
                  ShiftQueue();
                  PushAction(-1,CP_ACT_CLOSE,retry146.uid,retry146.sym,retry146.side,retry146.lots,
                             retry146.ticket,0,"",0.0,0.0,retry146.ordKind);
                  break;
                 }
               ShiftQueue();
               break; // R18-A02: Stop processing queue for this tick so remaining actions stay buffered
              }
            else if(queuedForSweep)
              {
               fails=1;
              }
            else if(isTransientErr)
              {
               // R5-D1-01 & DEF-A01: Allow fast 1.5s retries. For CP_ACT_OPEN, cap escalation so momentary blips never lock out for 24h
               fails=g_backoff.NotePark(boKey,1500,5);
               if(a.kind==CP_ACT_OPEN && fails>5)
                 {
                  g_backoff.Park(boKey,30000); // Cap open backoff to 30s max
                 }
              }
            else
              {
               fails=g_backoff.Note(boKey);
               if(a.kind==CP_ACT_OPEN && fails>4)
                 {
                  g_backoff.Park(boKey,60000); // Cap open backoff to 60s max
                 }
              }
           }
         // ISSUE-05 / N-04: If modify failed for an order that currently has NO stop loss (naked position),
         // park for only 2 seconds so safety SL protection can be retried without long delay.
         if(a.kind==CP_ACT_MODIFY && a.ticket!=0)
           {
            if(CopierTicketSL(a.ticket)<=0.0 && a.sl>0.0)
              {
               g_backoff.Park(boKey,2000);
              }
           }
         if(fails>=2 && g_onceFail.ShouldEmit("backoff|"+boKey))
           {
            bool isExit = (a.kind==CP_ACT_CLOSE || a.kind==CP_ACT_TRIM || a.kind==CP_ACT_DEDUP);
            bool isMod  = (a.kind==CP_ACT_MODIFY);
            long ms=isExit ? CopierExitBackoffMs(fails) : (isMod ? CopierModifyBackoffMs(fails) : CopierBackoffMs(fails));
            string waitTxt=isExit ? (IntegerToString(ms/1000)+"s") : (isMod ? (IntegerToString(ms/1000)+"s") : CopierBackoffText(fails));
            string why="refused "+((string)fails)+" time(s) running - "
                       +a.uid+" ("+a.sym+") parked for "
                       +waitTxt+". A repeat refusal is a"
                       +" standing condition, not a transient one; retrying"
                       +" fast is what gets an account throttled or blocked.";
            if(ms>=60*60*1000 || (isExit && fails>=3))
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
         else if(CopierIsTradeDisabled(err))
                             e2=(string)err+" (TRADE DISABLED at this terminal -"
                              +" AutoTrading is off, or the trade context is"
                              +" busy. Nothing is reaching the broker, so the"
                              +" order is retried at the base rate and the"
                              +" backoff ladder is deliberately NOT climbed:"
                              +" switch AutoTrading on and the mirror opens"
                              +" within a couple of seconds)";
         // sname already defined above
         if(g_onceFail.ShouldEmit("fail|"+sname+"|"
                                  +(string)a.kind+"|"+a.uid+"|"+(string)err))
            g_log.Warn("trade failed sender="+sname+" uid="+a.uid
                       +" sym="+a.sym+" kind="+(string)a.kind
                       +" err="+e2
                       +" (retrying in "+(string)(CP_RETRY_BACKOFF_MS/1000)
                       +"s; further identical failures reported at most"
                       +" once a minute)");
        }

      //--- L2: a close that has NO owning sender cannot be re-derived.
      //--- ConvergeSender only walks configured senders, so an operator's
      //--- `CMD close` on a manual/orphan position (senderIdx == -1) was executed
      //--- exactly once: one requote and the command answered OK while the
      //--- position stayed open forever, with nothing anywhere to retry it.
      //--- Re-queue while the retry budget lasts; the queue's 1s CLOSE cap keeps
      //--- the rate at one attempt per second and `skipped <= g_qn` bounds the pass.
      //--- R22: market-closed / trade-disabled are NOT a reason to give up - the
      //--- broker is not refusing THIS order, it is refusing everything until the
      //--- session opens or AutoTrading comes back. Those are re-queued without
      //--- spending the retry budget; boKey is already parked (CP_MKTCLOSED_MS or
      //--- the base rate), so the retry is paced by the backoff, not by this loop.
      bool waitOnly=(CopierIsTradeDisabled(err) || CopierIsMarketClosed(err));
      if(a.senderIdx<0 && a.kind==CP_ACT_CLOSE && (fails<=5 || waitOnly)
         && err!=-4 && err!=-5)
        {
         if(g_once.ShouldEmit("cmdretry|"+a.uid+"|"+(string)a.ticket))
            g_log.Warn("close of "+a.uid+" (ticket "+(string)a.ticket+", "+a.sym
                       +") was refused by the broker (err="+(string)err+") -"
                       +" re-queued for retry attempt "+(string)(fails+1)+" of 6."
                       +" There is no sender to re-issue it, so this queue is the"
                       +" only retry path.");
         CopierAction retry=a;
         ShiftQueue();
         done++;
         PushAction(-1,CP_ACT_CLOSE,retry.uid,retry.sym,retry.side,retry.lots,
                    retry.ticket,0,"",0.0,0.0,retry.ordKind);
         continue;
        }

      ShiftQueue();
      if(ok) done++; // R12-A02: Only count successful operations so rejected actions engage queue backoff
     }

   //--- Two-Pass Sweeper: for batch close operations (Martingale/Grid exits),
   //--- immediately perform a clean second sweep for any straggler orders that failed the fast pass
   if(isBatchClose && sweepCount > 0)
     {
#ifndef __MQL5__
      RefreshRates();
#endif
      // OPT-01: Paced second sweep wait
      CopierWaitMs(30);
      for(int s=0; s<sweepCount; s++)
        {
         CopierAction sa = g_sweepFailed[s];
         // M-11: Skip symbols currently verified as market closed
         if(g_mktClosed.Has(sa.sym)) continue;

         int sdev = (sa.senderIdx>=0 && sa.senderIdx<g_nSenders)?g_senderCfg[sa.senderIdx].deviationPoints:DeviationPoints;
         sdev = CopierScaleDeviationPoints(sa.sym, MathMax(sdev, 100));
         int serr = 0;
         double spx = 0.0;
#ifndef __MQL5__
         // L-04: Prefetch price on MT4 so in-loop RefreshRates is avoided
         int ordType = (sa.side==CP_SIDE_BUY)?OP_BUY:OP_SELL;
         spx = (ordType==OP_BUY)?MarketInfo(sa.sym,MODE_BID):MarketInfo(sa.sym,MODE_ASK);
#endif
         bool sok = CopierClosePosition(sa.ticket, sdev, serr, false, spx, sa.ordKind);
         if(sok)
           {
            // M-01: Update g_seen, g_ourCount and g_ourLots on Sweeper close success
            if(CopierSeenRingApplies(sa.kind)) g_seen.Add(sa.key);
            g_backoff.Clear(sa.key);
            //--- L4: mirror the main-path counter rules exactly. A manual/orphan
            //--- exit (senderIdx == -1) has no managed counters to give back - it
            //--- must decrement the ORPHAN tally instead. The old code decremented
            //--- g_ourPositions/g_ourCount for every straggler, so one orphan
            //--- closed through the sweeper permanently understated the managed
            //--- position count (and never decremented the orphan count at all).
            if(sa.ordKind==CP_ORD_MARKET)
              {
               if(sa.senderIdx>=0)
                 {
                  if(g_ourPositions>0) g_ourPositions--;
                  if(g_ourCount>0) g_ourCount--;
                  g_ourLots=MathMax(0.0,g_ourLots-sa.lots);
                 }
               else
                 {
                  if(g_orphanCount>0) g_orphanCount--;
                 }
               if(g_acctPositions>0) g_acctPositions--;
               if(sa.senderIdx>=0 && sa.senderIdx<CP_MAX_SENDERS)
                 {
                  sAddedCount[sa.senderIdx]--;
                  sAddedLots[sa.senderIdx]-=sa.lots;
                 }
              }
            else if(sa.ordKind==CP_ORD_PENDING)
              {
               if(sa.senderIdx>=0)
                 {
                  if(g_ourPending>0) g_ourPending--;
                  if(g_ourCount>0) g_ourCount--;
                  g_ourLots=MathMax(0.0,g_ourLots-sa.lots);
                 }
               else
                 {
                  if(g_orphanCount>0) g_orphanCount--;
                 }
               if(g_acctOrders>0) g_acctOrders--;
               //--- N57-14: the per-sender tallies were only decremented on the
               //--- MARKET branch above, so a pending order removed here left
               //--- sAddedCount/sAddedLots permanently one order high. Those
               //--- tallies feed the per-sender caps and the dashboard, so the
               //--- error accumulated for the life of the terminal.
               if(sa.senderIdx>=0 && sa.senderIdx<CP_MAX_SENDERS)
                 {
                  sAddedCount[sa.senderIdx]--;
                  sAddedLots[sa.senderIdx]-=sa.lots;
                 }
              }
            g_mapDirty=true;
            g_log.Info("Two-Pass Sweeper: successfully closed straggler ticket "+(string)sa.ticket+" uid "+sa.uid);
           }
         else
           {
            // MQL-02: Protect disabled trading and closed market from climbing 24h backoff ladder in Pass 2
            if(CopierIsTradeDisabled(serr))
              {
               g_backoff.Park(sa.key,CP_RETRY_BACKOFF_MS);
              }
            else if(CopierIsMarketClosed(serr))
              {
               g_mktClosed.Add(sa.sym);
               g_backoff.Park(sa.key,CP_MKTCLOSED_MS);
              }
            else
              {
               g_backoff.Note(sa.key);
              }
            g_log.Warn("Two-Pass Sweeper: straggler ticket "+(string)sa.ticket+" uid "+sa.uid+" failed second pass (err="+(string)serr+")");
           }
        }
      // NM-11: Release string references held by sweep array
      for(int sc=0; sc<sweepCount; sc++)
        {
         g_sweepFailed[sc].uid="";
         g_sweepFailed[sc].sym="";
         g_sweepFailed[sc].key="";
        }
     }

   //--- P1: arm the retry deadline when this pass processed NOTHING. A queue in
   //--- which every action is held would otherwise be walked end to end on every
   //--- tick, 200 times a second, to re-derive the same answer.
   //--- P3: something actually executed, so this account's position set changed
   //--- and the next reconcile must not wait for the sweep.
   bool allMktClosed = (g_qn>0 && done==0 && (mktClosedHeld>=g_qn || (mktClosedHeld>0 && mktClosedHeld==skipped)));
   if(done>0) g_convergeDirtyAll=true;
   CopierQueueNotePass(CopierNowMs(),g_qn,done,g_qBackoffMs,g_qRetryAtMs,g_qSpinPasses,allMktClosed);
   //--- entered the "nothing can drain" state: say so ONCE per episode. The
   //--- count resets on the next pass that processes anything, so a queue that
   //--- recovers and stalls again logs again rather than staying silent.
   if(g_qSpinPasses==1 && !allMktClosed)
      g_log.Info("queue cannot drain: all "+IntegerToString(g_qn)
                 +" action(s) are held. Periodic drain backs off (1s -> 10s -> 60s -> 5m -> 10m -> 30m -> 1h);"
                 +" event-driven drains still fire immediately.");
  }

#endif // __COPIER_RECVEXECUTE_MQH__
