//+------------------------------------------------------------------+
//| RecvRisk.mqh                                                     |
//| Part of CopierReceiver.mq4 - not a standalone header.            |
//+------------------------------------------------------------------+
//--- RefreshRisk and the risk close-all path.
//--- Included at a fixed point inside CopierReceiver.mq4 and relies on
//--- the globals, inputs and helpers declared above that point. Moved
//--- verbatim out of the EA; do not include it from anywhere else.
#ifndef __COPIER_RECVRISK_MQH__
#define __COPIER_RECVRISK_MQH__

void RefreshRisk()
  {
   // D4-M04: Disconnected terminal returns 0 equity; avoid false blowout shutdown while offline
   if(!CopierIsConnected()) return;
   int an=ScanAndResolveAccountPositions();
   int cnt=0;
   int orphan=0;
   int oursPos=0,oursPend=0;
   double lots=0.0;
   int nPos=0,nOrd=0;
   for(int i=0;i<an;i++)
     {
      //--- counted for EVERYTHING on the account, not just ours: a broker's
      //--- position cap does not care who opened the position
      if(g_acctAllPos[i].kind==CP_ORD_PENDING) nOrd++; else nPos++;
      if(MagicToSender(g_acctAllPos[i].magic)<0)
        {
         //--- Match the dashboard panel's orphan definition: only positions
         //--- carrying our copier UID comment count, never another EA's trades.
         if(g_posCache[i].isOrphan) orphan++;
         continue;
        }
      if(g_acctAllPos[i].kind==CP_ORD_PENDING) oursPend++; else oursPos++;
      cnt++;
      lots+=g_acctAllPos[i].lots;
     }
   g_acctPositions=nPos;
   g_acctOrders=nOrd;
   g_ourPositions=oursPos;
   g_ourPending=oursPend;
   g_ourCount=cnt;
   g_ourLots=lots;
   g_orphanCount=orphan;

   long now=CopierNowMs();
   long dayStart=CopierServerDayStart();
   if(dayStart<=0) return; // Prevent state corruption on uninitialized or disconnected clock
   static double s_lastCheckedBalance=0.0;
   double curBalRisk=CopierAccountBalance();
   if(s_lastCheckedBalance==0.0) s_lastCheckedBalance=curBalRisk;
   bool balChanged=(MathAbs(curBalRisk-s_lastCheckedBalance)>0.01);
   bool dayChanged=(dayStart!=g_riskDay);
   if(dayChanged)
     {
      //--- L1: a COLD start is not a day rollover.
      //--- On a mid-day (re)start with no same-day risk file, g_riskDay is 0.
      //--- Treating that like "the clock just crossed midnight" sampled the
      //--- CURRENT equity/balance as the day-start baseline, which:
      //---   * forgave every loss already realised this morning (the switch the
      //---     operator set for 3% silently read 0% for the first minute), and
      //---   * froze whatever floating P/L existed at attach time into the
      //---     baseline once the 60s recalibration added its cash-flow delta.
      //--- Derive the day-start BALANCE from balance-minus-realised instead, and
      //--- use it as the equity baseline (a flat account at day start equals its
      //--- balance, and today's floating P/L then correctly counts as loss).
      bool wasColdStart=(g_riskDay==0);
      g_riskDay=dayStart;
      double openComm=0.0;
      //--- R22: the day-start balance is derived as (balance - realised) in ALL
      //--- three places: cold start, rollover, and the 60s recalibration below.
      //--- MT4 books an open trade's commission into the balance only when it
      //--- closes, so subtracting open commissions here made the next
      //--- recalibration see a phantom cash flow of exactly that amount and
      //--- scale the baseline and peak down once a day. Kept at 0 deliberately.
      if(wasColdStart)
        {
         bool rOk=false;
         double realized=CopierRealizedToday(dayStart,rOk);
         double curBal=CopierAccountBalance();
#ifndef __MQL5__
         // BUG-07: In MT4, history sync is asynchronous after terminal startup.
         // If total history is 0 and uptime is under 10s, treat as history not ready yet.
         if(OrdersHistoryTotal()==0 && (CopierNowMs()-g_bootMs)<10000) rOk=false;
#endif
         if(rOk)
           {
            double trueStartBal=(curBal-openComm)-realized;
            if(trueStartBal>0.0)
              {
               g_riskDayStartBalance=trueStartBal;
               g_riskDayStartEquity=trueStartBal;
              }
            else
              {
               //--- realised history inconsistent with the balance (deposit/withdrawal
               //--- today): fall back to the live account rather than a negative baseline
               g_riskDayStartBalance=curBal;
               g_riskDayStartEquity=CopierAccountEquity();
              }
            g_lastRealizedMs=now;
           }
         else
           {
            //--- history not ready yet: leave the baseline unset so the
            //--- recalibration branch below retries on the very next tick
            g_riskDayStartBalance=0.0;
            g_riskDayStartEquity=0.0;
            g_lastRealizedMs=0;
           }
        }
      else
        {
         g_lastRealizedMs=now;
         // Derive opening balance exactly across rollover tick gap by stripping post-midnight realized P/L
         bool rOk=false;
         double realized=CopierRealizedToday(dayStart,rOk);
         double curBal=CopierAccountBalance();
         if(rOk)
           {
            double trueStartBal=(curBal-openComm)-realized;
            g_riskDayStartBalance=(trueStartBal>0.0)?trueStartBal:curBal;
           }
         else
           {
            g_riskDayStartBalance=0.0;
            g_riskDayStartEquity=0.0;
            g_lastRealizedMs=0;
           }
         if(rOk)
           {
            // Preserve pre-midnight floating equity offset to avoid false trip on pre-existing floating loss (D4-03)
            // D-02: Pre-existing floating losses MUST be preserved across rollover to prevent baseline inflation at midnight!
            double curEq=CopierAccountEquity();
            double floatingOffset=curEq-curBal;
            g_riskDayStartEquity=MathMax(0.0, g_riskDayStartBalance+floatingOffset);
           }
        }
      g_risk.SetDayStartEquity(g_riskDayStartEquity);
     }
   // R4-D4-01 & R10-D02: Throttle history scan to 60s once established, only breaking out when balance changes.
   // Evaluated unconditionally (not else-if) so weekend/day-change cash flows adjust HWM before ObserveAt!
   if((g_riskDayStartEquity<=0.0 ? (now-g_lastRealizedMs>10000) : (now-g_lastRealizedMs>60000 || balChanged)))
     {
      g_lastRealizedMs=now;
      if(!CopierIsConnected()) return;
      // N49-01 & N49-13: Recalibrate baseline dynamically on intraday cash flow
      // Guarded by rOk so history fetch failures keep existing baseline instead of wiping to 0.
      bool rOk=false;
      double realized=CopierRealizedToday(dayStart,rOk);
#ifndef __MQL5__
      // BUG-07: In MT4, history sync is asynchronous after terminal startup.
      // If total history is 0 and uptime is under 10s, treat as history not ready yet.
      if(OrdersHistoryTotal()==0 && (CopierNowMs()-g_bootMs)<10000) rOk=false;
#endif
      if(rOk)
        {
         s_lastCheckedBalance=curBalRisk; // R10-D02: Commit balance cache ONLY when history fetch succeeded
         double curBal=CopierAccountBalance();
         //--- N56-01: g_riskDayStartBalance MUST hold the day-start balance,
         //--- i.e. the live balance with today's realized P/L stripped out.
         //--- Storing the live balance here makes the cash-flow delta
         //---   (curBal-realized) - g_riskDayStartBalance
         //--- collapse to -realized, which then re-adds itself to the baseline
         //--- on EVERY recalibration tick. With a realized loss the baseline
         //--- inflates once a minute until the daily-loss guard trips and
         //--- force-closes every position; with a realized profit it decays
         //--- toward zero and silently disables the guard.
         //--- The anchor is "balance at day start", so it must be derived, not
         //--- sampled from the live account.
         if(g_riskDayStartEquity<=0.0)
           {
            double derivedBase=curBal-realized;
            if(derivedBase>0.0)
              {
               g_riskDayStartEquity=derivedBase;
               g_riskDayStartBalance=derivedBase;
               g_risk.SetDayStartEquity(derivedBase);
              }
           }
         else
           {
            double dayStartBal=curBal-realized;
            if(g_riskDayStartBalance<=0.0) g_riskDayStartBalance=dayStartBal;
            double cashFlow=dayStartBal-g_riskDayStartBalance;
            if(MathAbs(cashFlow)>0.01)
              {
               double postEq=CopierAccountEquity();
               double preEq=postEq-cashFlow;
               if(preEq>0.0 && postEq>0.0 && g_riskDayStartEquity>0.0)
                  g_riskDayStartEquity=MathMax(0.0, g_riskDayStartEquity*(postEq/preEq));
               else
                  g_riskDayStartEquity=MathMax(0.0, g_riskDayStartEquity+cashFlow);
               g_riskDayStartBalance=dayStartBal;
               g_risk.SetDayStartEquity(g_riskDayStartEquity);
               g_risk.AdjustPeakForCashFlow(cashFlow, preEq);
               RiskPeakSave(true);
              }
           }
        }
     }
   g_risk.ObserveAt(CopierAccountEquity(),dayStart/86400,g_riskDayStartEquity);
   // NL-01: Warn if daily loss guard is enabled but baseline cannot be measured
   if(g_riskDayStartEquity<=0.0 && g_risk.DailyLossPct()>0.0 && g_once.ShouldEmit("risk_day_baseline_zero"))
     {
      g_log.Warn("NL-01: daily loss guard inactive because day-start equity baseline is <= 0");
     }
   //--- Persist the peak so a terminal restart cannot re-base the drawdown
   //--- switch. Internally throttled to once a minute; a rising peak that is
   //--- lost to a crash understates the baseline by that minute's gain, which
   //--- is the safe direction (it can never falsely block trading).
   // R6-D4-02: Force-save peak immediately on rollover day change or when peak updates
   if(dayChanged) RiskPeakSave(true);
   else if(g_risk.PeakEquity()>0.0) RiskPeakSave(false);
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
      if(g_q[g_qHead+i].kind!=CP_ACT_OPEN) continue;
      count++;
      lots+=g_q[g_qHead+i].lots;
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
int CloseAllOurs(const string reason,int &failedCount,int &totalMatching)
  {
   int an=CopierReadPositions(g_scanScratch,CP_MAX_POSITIONS);
   int queued=0;
   failedCount=0;
   totalMatching=0;
   for(int i=0;i<an;i++)
     {
      int si=MagicToSender(g_scanScratch[i].magic);
      if(si<0) continue;                      // not ours
      string uid=ResolveUid(g_scanScratch[i]);
      if(StringLen(uid)==0)
        {
         //--- The magic says this IS ours, but the UID cannot be recovered:
         //--- the broker overwrote the comment, or this terminal restarted and
         //--- g_recKnown has not been rebuilt yet.
         //---
         //--- Skipping it - which is what this used to do - leaves a live
         //--- position that nothing on this side will ever close, while the
         //--- sender may already be flat. That is an open exposure the
         //--- operator never sees, and it appears at exactly the moment a
         //--- risk trip or a hub closeall is trying to get us flat.
         //---
         //--- So it is closed anyway. The queue is keyed by UID, so it needs
         //--- SOMETHING unique per position: a ticket-derived placeholder is
         //--- unique, stable across retries (so backoff and the seen ring work
         //--- normally), and can never collide with a real UID - a real one is
         //--- 8 characters of Crockford base32, and '#' is not in that set.
         //---
         //--- The placeholder lives only in the action key. It is never added
         //--- to g_recKnown (the UID <-> ticket map), never looked up in it,
         //--- and never written to a comment, so rebuilding that map later
         //--- still sees only real UIDs. CP_ACT_CLOSE executes on a.ticket,
         //--- so the placeholder never reaches the broker.
         uid="#t"+(string)g_scanScratch[i].ticket;
         if(g_once.ShouldEmit("closeall_nouid|"+(string)g_scanScratch[i].ticket))
            g_log.Warn("CloseAll: ticket "+(string)g_scanScratch[i].ticket
                       +" carries our magic "+(string)g_scanScratch[i].magic
                       +" but no recoverable UID - closing it anyway under a"
                       +" ticket-derived key");
        }
      if(g_ignore.Has(uid) || (si>=0 && g_senderIgnore[si].Has(uid))) continue;         // handed over to the operator
      totalMatching++;
      string actKey=g_sid[si]+":"+(string)CP_ACT_CLOSE+":"+uid;
      // NH-01: Clear backoff/seen ONLY on the initial explicit closeall request (StringLen(reason)>0).
      // Background retry passes leave backoff intact so repeated broker errors back off to 5s intervals.
      if(StringLen(reason)>0)
        {
         g_seen.Forget(actKey);
         g_backoff.Clear(actKey);
        }
      if(PushAction(si,CP_ACT_CLOSE,uid,g_scanScratch[i].sym,g_scanScratch[i].side,g_scanScratch[i].lots,
                 g_scanScratch[i].ticket,0,"",0.0,0.0,g_scanScratch[i].kind))
         queued++;
      else
        {
         // NH-01: Only count as true queue failure if queue is actually saturated
         if(g_qn>=CP_MAX_ACTIONS)
           {
            failedCount++;
            if(g_once.ShouldEmit("closeall_qfull|"+uid))
               g_log.Error("CloseAll: action queue full for ticket "+(string)g_scanScratch[i].ticket+" uid "+uid);
           }
        }
     }
   if(StringLen(reason)>0)
      g_log.Error(reason+" - queueing closes for "+(string)queued
                 +" of our "+(string)totalMatching+" position(s)"+((failedCount>0)?(" ("+(string)failedCount+" queue full failed)"):""));
   return queued;
  }

int CloseAllOurs(const string reason)
  {
   int failed=0, total=0;
   return CloseAllOurs(reason,failed,total);
  }

void RiskCloseEverything()
  {
   int failed=0, total=0;
   CloseAllOurs("RiskCloseAllOnTrip is on",failed,total);
   // BUG-03: Set pending flag whenever there are positions to close, keeping retry and emergency slippage active
   if(total>0) g_riskCloseAllPending=true;
  }

#endif // __COPIER_RECVRISK_MQH__
