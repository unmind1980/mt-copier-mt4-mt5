//+------------------------------------------------------------------+
//| RecvConverge.mqh                                                 |
//| Part of CopierReceiver.mq4 - not a standalone header.            |
//+------------------------------------------------------------------+
//--- Sender clock mapping, exposure counting and ConvergeSender.
//--- Included at a fixed point inside CopierReceiver.mq4 and relies on
//--- the globals, inputs and helpers declared above that point. Moved
//--- verbatim out of the EA; do not include it from anywhere else.
#ifndef __COPIER_RECVCONVERGE_MQH__
#define __COPIER_RECVCONVERGE_MQH__

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
   if(!g_srvEverMoved || !g_senderClockOffsetValid[si]) return 0;
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
      if(g_q[g_qHead+i].kind!=CP_ACT_OPEN) continue;      // a close is not exposure
      if(g_q[g_qHead+i].sym!=sym) continue;
      if(sameDirOnly && g_q[g_qHead+i].side!=side) continue;
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

   //--- P3: this is one pass over one sender's desired set, so the per-symbol
   //--- verdicts below are reused within it and dropped at the top of the next.
   g_staleVerdict.Reset();
   g_sessVerdict.Reset();

   // MQL-02: Safely reset this sender's wait metrics without affecting other senders
   g_waitHeld-=g_senderWaitHeld[si];
   g_waitLots=MathMax(0.0,g_waitLots-g_senderWaitLots[si]);
   g_mktHeld-=g_senderMktHeld[si];
   g_mktHeldLots=MathMax(0.0,g_mktHeldLots-g_senderMktHeldLots[si]);
   g_senderWaitHeld[si]=0;
   g_senderWaitLots[si]=0.0;
   g_senderMktHeld[si]=0;
   g_senderMktHeldLots[si]=0.0;
   ClearWaitItems(si);

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

   int ln=LocalForSender(si,g_acctAllPos,g_acctAllPosCount);
   int base=si*CP_MAX_POSITIONS;

   double sLots=0.0;
   for(int k=0;k<ln;k++) sLots+=g_locScratch[k].lots;

   //--- one UID, one position. Has to run BEFORE the diff below:
   //--- the index returns the FIRST match, so a duplicate left in place
   //--- could be the copy chosen for a trim while the real mirror is ignored.
   //---
   //--- The index answers "does any other row share this uid" in one pass.
   //--- Only when it does is the quadratic dedup worth running - which, on a
   //--- normal account, is never: the old code paid 90,000 string compares a
   //--- tick to discover there were no duplicates.
   g_locIdx.Build(g_locScratch,0,ln);
   if(g_locIdx.Count()<ln)
     {
      ln=DedupLocal(si,base,g_locScratch,ln);
      g_locIdx.Build(g_locScratch,0,ln);
      // P2-21: Recompute sLots after deduping local positions
      sLots=0.0;
      for(int k=0;k<ln;k++) sLots+=g_locScratch[k].lots;
     }

   int    pendCount=0;
   double pendLots=0.0;
   PendingOpens(pendCount,pendLots);
   int    sPendCount=0;
   double sPendLots=0.0;
   PendingOpensForSender(si,sPendCount,sPendLots);

   //--- mirrored but no longer desired -> close (queued BEFORE opens so exits win margin & queue capacity)
   //---
   //--- Same index trick in the other direction: "is this local uid still in
   //--- the desired set" used to be a scan of every desired row for every
   //--- local row.
   if(ln>0) g_desIdx.Build(g_desired,base,g_desiredCount[si]);
   for(int i=0;i<ln;i++)
     {
      if(g_desIdx.Find(g_desired,g_locScratch[i].uid)>=0) continue;

      if(g_ignore.Has(g_locScratch[i].uid) || g_senderIgnore[si].Has(g_locScratch[i].uid)) continue;

      if(g_senderCfg[si].ignoreallexitsignals)
        {
         if(g_once.ShouldEmit("gateexit|"+g_sid[si]+"|"+g_locScratch[i].uid))
            g_log.Warn("sender "+g_sid[si]+" IgnoreAllExitSignals is on - NOT closing "
                       +g_locScratch[i].uid+" "+g_locScratch[i].sym+" even though the sender"
                       +" has exited it. This account is still in that trade"
                       +" and nothing here will close it. Close it by hand, or"
                       +" add "+g_locScratch[i].uid+" to the IgnoreUids input to stop"
                       +" being told.");
         continue;
        }

      g_reopenExpected.Forget(g_sid[si]+":"+g_locScratch[i].uid);
      PushAction(si,CP_ACT_CLOSE,g_locScratch[i].uid,g_locScratch[i].sym,g_locScratch[i].side,g_locScratch[i].lots,g_locScratch[i].ticket,
                 0,"",0.0,0.0,g_locScratch[i].kind);
     }

   //--- Pre-scan queued CLOSE and TRIM actions for this sender once per tick,
   //--- NM-01: Built into g_qCloseIdx hash table to achieve true O(N + Q) lookup.
   static string queuedCloseOrTrim[CP_MAX_ACTIONS];
   static int queuedPrevCount=0;
   for(int k=0;k<queuedPrevCount;k++) queuedCloseOrTrim[k]="";
   int queuedCloseOrTrimCount=0;
   if(g_qn>0)
     {
      for(int q=0;q<g_qn;q++)
        {
         int qidx=g_qHead+q;
         if(g_q[qidx].senderIdx==si && (g_q[qidx].kind==CP_ACT_CLOSE || g_q[qidx].kind==CP_ACT_TRIM))
           {
            queuedCloseOrTrim[queuedCloseOrTrimCount++]=g_q[qidx].uid;
           }
        }
     }
   queuedPrevCount=queuedCloseOrTrimCount;
   if(queuedCloseOrTrimCount>0)
      g_qCloseIdx.BuildFromStrings(queuedCloseOrTrim,queuedCloseOrTrimCount);
   else
      g_qCloseIdx.Clear();

   //--- desired but not mirrored -> open
   for(int i=0;i<g_desiredCount[si];i++)
     {
      CopierPos d=g_desired[base+i];

      //--- the operator asked us to leave this one alone (IgnoreUids)
      if(g_ignore.Has(d.uid) || g_senderIgnore[si].Has(d.uid)) continue;

      int li=g_locIdx.Find(g_locScratch,d.uid);
      bool hasPartialSibling=false;

      // R17-A02: Match local partial-fill market position even if its comment still carries parent pending UID
      if(li<0 && d.kind==CP_ORD_MARKET && d.ticket>0)
        {
         for(int sk=0; sk<ln; sk++)
           {
            if(g_locScratch[sk].kind!=CP_ORD_MARKET) continue;
            long locSenderTkt=CopierSenderTicketFromComment(g_locScratch[sk].cmt);
            if(locSenderTkt!=d.ticket) continue;

            for(int pk=0; pk<ln; pk++)
              {
               if(pk==sk) continue;
               if(g_locScratch[pk].ticket==g_locScratch[sk].ticket && g_locScratch[pk].kind==CP_ORD_PENDING)
                 {
                  li=sk;
                  hasPartialSibling=true;
                  g_locScratch[sk].uid=d.uid;
                  g_recKnown.Upsert(g_locScratch[sk]);
                  break;
                 }
              }
            if(li>=0) break;
           }
        }
      if(li>=0 && g_locScratch[li].ticket>0)
        {
         int matchIdx=-1;
         for(int sk=0;sk<ln;sk++)
           {
            if(sk==li) continue;
            if(g_locScratch[sk].uid==d.uid
               && g_locScratch[sk].ticket==g_locScratch[li].ticket
               && g_locScratch[sk].kind!=g_locScratch[li].kind)
              {
               hasPartialSibling=true;
               if(g_locScratch[sk].kind==d.kind && matchIdx<0) matchIdx=sk;
              }
           }
         if(matchIdx>=0) li=matchIdx;
        }
      if(li>=0)
        {
         //--- Clear seen keys only when there is NO in-flight close/trim queued,
         //--- and for TRIM only when volume has actually converged to the desired level.
         //--- Otherwise, clearing the seen key while an action is still queued or pending broker fill
         //--- causes duplicate execution on the next tick.
         //--- NM-01: O(1) hash probe replaces nested O(N*Q) linear loop
         bool hasQueued=(g_qCloseIdx.FindInStrings(queuedCloseOrTrim,d.uid)>=0);
         //--- N80-01: targetLots is unconditionally computed once per matched position.
         //--- hasQueued strictly guards seen-key clearing, NEVER suppressing lot calculation.
         double targetLots=ComputeTargetLotsForMirror(si,d,g_locScratch[li].sym);

         // BUG-04 & SEC-01 & R1-M02 & DEF-A03 & DEF-09-05: If operator manually closed this UID from WebUI/CMD, retry closing it until gone.
         // While close is pending or retrying with broker, local position MUST still converge protective stops (SL/TP)
         // to avoid naked risk. Do NOT call QueueTrimIfNeeded here to avoid conflicting simultaneous CLOSE + TRIM actions.
         if(g_manualClosed.Has(d.uid) || g_manualClosed.HasSenderTicket(g_sid[si],g_locScratch[li].ticket))
           {
            if(!SymbolMarketClosed(g_locScratch[li].sym))
              {
               PushAction(si,CP_ACT_CLOSE,d.uid,g_locScratch[li].sym,g_locScratch[li].side,
                          g_locScratch[li].lots,g_locScratch[li].ticket,
                          0,"",0.0,0.0,g_locScratch[li].kind);
              }
            QueueModifyIfNeeded(si,d,g_locScratch[li]);
            continue;
           }

         if(!hasQueued)
           {
            if(targetLots>0.0 && g_locScratch[li].lots<=targetLots+CP_LOT_EPS)
               g_seen.ForgetUidActions(g_sid[si],d.uid);
            else
               g_seen.ForgetPrefix(g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid);
           }

         //--- NOTE: no g_everOpened.Add() here any more.
         //---
         //--- It used to run for every matched position on every tick, which
         //--- is 300 writes at 10 Hz - enough to cycle the whole 4096-slot
         //--- ring in about 1.4 seconds and evict the very entries the
         //--- ReopenClosedMirrors guard depends on. The ring is filled where
         //--- it belongs: when an open actually succeeds (ExecuteQueue), and
         //--- from the state file at startup for positions that were already
         //--- open.

         if(g_locScratch[li].kind!=d.kind && !hasPartialSibling)
           {
            //--- PENDING on local, but MARKET on sender: sender's pending order filled.
            //--- Give local pending order up to PendingFillGraceSeconds to fill naturally
            //--- before cancelling and re-opening, avoiding unnecessary cancellation & chase slippage.
            if(g_locScratch[li].kind==CP_ORD_PENDING && d.kind==CP_ORD_MARKET)
              {
               double graceSec=g_senderCfg[si].pendingfillgraceseconds;
               if(graceSec>0.0)
                 {
                  string graceKey=g_sid[si]+":fillgrace:"+d.uid;
                  long firstMs=g_fillGraceRing.GetTime(graceKey);
                  long nowMs=CopierNowMs();
                  if(firstMs==0)
                    {
                     g_fillGraceRing.Add(graceKey);
                     g_log.Info("uid "+d.uid+" "+d.sym+" filled on sender; waiting up to "
                                +DoubleToString(graceSec,1)+"s for local pending order to fill naturally");
                     continue;
                    }
                  else if(nowMs-firstMs < (long)(graceSec*1000.0))
                    {
                     continue; // still within grace window; let broker fill it naturally
                    }
                  // C1: Grace period expired without filling naturally.
                  // Do NOT Forget(graceKey) here! Retain graceKey so subsequent ticks before broker
                  // confirms deletion do NOT re-initialize a fresh 1.5s grace cycle.
                  // It will be cleaned up on line 5332 once kinds match, or when the pending order disappears.
                  if(g_once.ShouldEmit("fillgraceexp|"+d.uid))
                     g_log.Warn("uid "+d.uid+" "+d.sym+" fill grace expired ("
                                +DoubleToString(graceSec,1)+"s) - cancelling pending mirror and re-opening as market");
                 }
              }

            // P2-23 fix: only log when action is successfully queued
            if(PushAction(si,CP_ACT_CLOSE,d.uid,g_locScratch[li].sym,g_locScratch[li].side,
                          g_locScratch[li].lots,g_locScratch[li].ticket,
                          0,"",0.0,0.0,g_locScratch[li].kind))
              {
               g_reopenExpected.Add(g_sid[si]+":"+d.uid);
               if(g_once.ShouldEmit("kindchg|"+d.uid))
                  g_log.Info("uid "+d.uid+" changed kind on the sender ("
                             +(string)g_locScratch[li].kind+" -> "+(string)d.kind
                             +"); cancelling the mirror and re-opening it");
              }
            continue;
           }

         g_fillGraceRing.Forget(g_sid[si]+":fillgrace:"+d.uid);

         // MQL-04: Runtime hot-switch inverttrades check
         int expectedSide = g_senderCfg[si].inverttrades ? -d.side : d.side;
         if(g_locScratch[li].side != expectedSide)
           {
            if(!g_senderCfg[si].ignoreallexitsignals)
              {
               g_log.Warn("uid "+d.uid+" position side opposite to current inverttrades setting ("
                          +((g_locScratch[li].side==CP_SIDE_BUY)?"BUY":"SELL")+" vs expected "
                          +((expectedSide==CP_SIDE_BUY)?"BUY":"SELL")+"); closing old position to re-open");
               g_reopenExpected.Add(g_sid[si]+":"+d.uid);
               PushAction(si,CP_ACT_CLOSE,d.uid,g_locScratch[li].sym,g_locScratch[li].side,
                          g_locScratch[li].lots,g_locScratch[li].ticket,
                          0,"",0.0,0.0,g_locScratch[li].kind);
               continue;
              }
           }

         CopierSymInfo si2;
         bool haveSi2=CopierGetSymbolInfo(g_locScratch[li].sym,si2);
         bool eqRatioNoTrim=false;
         if(g_lotMode[si]==CP_SIZE_EQUITY_RATIO)
           {
            double origLots=(d.initLots>0.0)
                            ?d.initLots
                            :GetOrUpdateSenderPeakLots(d.uid,d.lots);
            bool overCap=(haveSi2 && si2.maxLot>0.0 && g_locScratch[li].lots>si2.maxLot+CP_LOT_EPS)
                       ||(g_senderCfg[si].maxLotsPerPosition>0.0
                          && g_locScratch[li].lots>g_senderCfg[si].maxLotsPerPosition+CP_LOT_EPS);
            if(!overCap && origLots>0.0 && d.lots>=origLots-CP_LOT_EPS)
               eqRatioNoTrim=true;
           }

         // N49-02 & N80-01: Pending order volume adjustment (cancel + re-place)
         // MetaTrader broker APIs cannot modify volume on existing pending orders.
         if(!eqRatioNoTrim && d.kind==CP_ORD_PENDING && g_locScratch[li].kind==CP_ORD_PENDING)
           {
            if(haveSi2 && targetLots>0.0 && si2.lotStep>0.0)
              {
               if(MathAbs(g_locScratch[li].lots-targetLots)>=si2.lotStep*0.999999)
                 {
                  g_log.Info("uid "+d.uid+" pending order volume changed ("
                             +DoubleToString(g_locScratch[li].lots,2)+" -> "+DoubleToString(targetLots,2)
                             +"); cancelling and re-placing pending order");
                  g_reopenExpected.Add(g_sid[si]+":"+d.uid);
                  PushAction(si,CP_ACT_CLOSE,d.uid,g_locScratch[li].sym,g_locScratch[li].side,
                             g_locScratch[li].lots,g_locScratch[li].ticket,
                             0,"",0.0,0.0,g_locScratch[li].kind);
                  continue;
                 }
              }
           }

         QueueModifyIfNeeded(si,d,g_locScratch[li]);
         if(!eqRatioNoTrim) QueueTrimIfNeeded(si,d,g_locScratch[li],targetLots);
         continue;
        }

      //--- N84-06: Desired but not mirrored = an OPEN candidate.
      //--- If operator manually closed this position, NEVER reopen it while sender still holds it.
      //--- Placed here after li>=0 check so if manual close is still pending or delayed by broker,
      //--- the existing local position continues to have SL/TP/Trim managed normally.
      if(g_manualClosed.Has(d.uid)) continue;

      // D2-M02: Prevent opening new positions if local account position table is full
      if(g_acctAllPosCount>=CP_MAX_POSITIONS)
        {
         if(g_once.ShouldEmit("acct_pos_table_full"))
            g_log.Warn("D2-M02: account position count reached CP_MAX_POSITIONS ("+(string)CP_MAX_POSITIONS+"); skipping new open for uid "+d.uid);
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

      //--- 1. Base control & signal gates (evaluated FIRST, zero extra computation)
      if(g_cmdPaused)
        {
         if(g_once.ShouldEmit("cmdpause"))
            g_log.Warn("paused by a hub command - no new mirrors are opened."
                       +" Existing ones are still managed normally. RESUME"
                       +" clears this.");
         continue;
        }

      if(g_senderCfg[si].ignorenewentrysignals)
        {
         if(g_once.ShouldEmit("gatenew|"+g_sid[si]))
            g_log.Info("sender "+g_sid[si]+" IgnoreNewEntrySignals is on - no new mirrors are"
                       +" opened. Existing ones are still managed normally.");
         continue;
        }

      if(!g_senderPermittedMagic[si].AllowsLong(d.magic))
        {
         if(g_once.ShouldEmit("gatemagic|"+g_sid[si]+"|"+(string)d.magic))
            g_log.Info("sender "+g_sid[si]+" reports magic "+(string)d.magic
                       +" on "+d.sym+", which is not in PermittedMagic - its"
                       +" entries are skipped");
         continue;
        }

      if(g_senderCfg[si].minsenderlotsize>0.0 && d.lots<g_senderCfg[si].minsenderlotsize) continue;
      if(g_senderCfg[si].maxsenderlotsize>0.0 && d.lots>g_senderCfg[si].maxsenderlotsize) continue;

      //--- R58-01: RESTORED the pending-only gate that N57-02 removed.
      //---
      //--- N57-02 let a market entry carry the sender's stops so it would not
      //--- open bare. The motive was right, the mechanism was not: it copied a
      //--- PRICE from one broker's book onto another's, which is precisely what
      //--- CopierMirrorStop exists to prevent - see CopierDefs.mqh:1185, "the
      //--- sender's stop cannot be copied as a price ... what is copied instead
      //--- is the DISTANCE from the entry".
      //---
      //--- Only a pending order may carry an absolute stop, because its entry
      //--- price is copied verbatim as well and the two sides agree by
      //--- construction. A market entry fills at a price that did not exist when
      //--- the action was queued.
      //---
      //--- Two ways that goes wrong in practice: the stop can land on the wrong
      //--- side of the receiver's fill (rejected, or an instant stop-out when it
      //--- lands far away), and - because osl is computed BEFORE the InvertTrades
      //--- flip twenty lines below - an inverted entry carries a stop from the
      //--- opposite direction. MT5 has no err-130 fallback (CopierModel:779), so
      //--- that order is simply rejected and the mirror never opens at all.
      //---
      //--- The converge pass re-stops a market entry on the next tick through
      //--- CopierMirrorStop, which re-anchors by DISTANCE against the actual
      //--- fill - the one algorithm in this codebase that is correct for this.
      double osl=(d.kind==CP_ORD_PENDING && g_senderCfg[si].mirrorstops)?d.sl:0.0;
      double otp=(d.kind==CP_ORD_PENDING && g_senderCfg[si].mirrorstops)?d.tp:0.0;
      int senderSide=d.side;

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

      if(g_senderCfg[si].nobuy && d.side==CP_SIDE_BUY)   continue;
      if(g_senderCfg[si].nosell && d.side==CP_SIDE_SELL) continue;

      //--- 2. Symbol resolution & permissions
      string rsym=MapSymbol(si,d.sym,g_suffix[si]);
      if(!g_senderPermitted[si].Allows(rsym))
        {
         if(g_once.ShouldEmit("gatesym|"+g_sid[si]+"|"+rsym))
            g_log.Info("sender "+g_sid[si]+" symbol "+rsym+" is not in PermittedSymbols - its"
                       +" entries are skipped");
         continue;
        }

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

      //--- 3. Lot calculation
      bool rejected=false;
      // R6-D2-03: Use ComputeTargetLotsForMirror to respect partial-fill scaling & rejection
      double lots=ComputeTargetLotsForMirror(si,d,rsym);
      if(lots<=0.0) rejected=true;
      if(rejected || lots<=0.0)
        {
         if(g_once.ShouldEmit("lotsrej|"+g_sid[si]+"|"+d.uid))
            g_log.Warn("lot sizing rejected "+d.uid+" "+rsym
                       +" senderLots="+DoubleToString(d.lots,2));
         continue;
        }

      //--- 4. Market state, clock & trading hours (holds tracked with calculated lots)
      if(!g_srvEverMoved
         || CopierNowMs()-g_srvChangedMs>CP_FEED_STALL_MS)
        {
         if(g_once.ShouldEmit("stall|"+g_sid[si]))
            g_log.Warn("no quotes for "
                       +(string)((CopierNowMs()-g_srvChangedMs)/1000)+"s - the server"
                       +" clock is not advancing, so the market is closed or"
                       +" the feed is down. Holding new entries; nothing can"
                       +" be priced from a stale clock.");
         g_senderMktHeld[si]++;
         g_senderMktHeldLots[si]+=lots;
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Server clock halted / feed stall");
         continue;
        }

      if(SymbolMarketClosed(rsym))
        {
         if(g_once.ShouldEmit("mktclosed|"+rsym))
            g_log.Info("market for "+rsym+" is closed (session, stale quotes, or broker closed) - holding new entries; they go through when it reopens");
         g_senderMktHeld[si]++;
         g_senderMktHeldLots[si]+=lots;
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Market closed / session shut");
         continue;
        }

      int warmupElapsed=0;
      if(SymbolInOpenWarmup(rsym, warmupElapsed))
        {
         if(g_once.ShouldEmit("warmup_converge|"+rsym))
            g_log.Info("market open warmup active for "+rsym+" ("
                       +IntegerToString(MarketOpenDelayMinutes*60 - warmupElapsed)+"s remaining) - holding new entries");
         g_senderMktHeld[si]++;
         g_senderMktHeldLots[si]+=lots;
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_open_warmup","Market open warmup cooldown");
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
         g_senderMktHeld[si]++;
         g_senderMktHeldLots[si]+=lots;
         g_mktHeld++;
         g_mktHeldLots+=lots;
         AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"market_closed","Outside sender trading window");
         continue;
        }

      //--- 5. Existing position & delay/pullback gates

      if(g_senderCfg[si].checkforexistingposition!=EXIST_OFF)
        {
         bool sameDirOnly=(g_senderCfg[si].checkforexistingposition==EXIST_SAME_DIR);
         if(AccountExposure(g_acctAllPos,g_acctAllPosCount,rsym,d.side,sameDirOnly)>0)
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
            g_log.Warn("cannot measure how old "+d.uid+" "+rsym+" is (sender openTime="
                       +(string)d.openTime+", clock known="
                       +(g_senderClockKnown[si]?"yes":"no")+", offset="
                       +(string)g_senderClockOffset[si]+"s). Holding until clock offset is calibrated.");
        }

      {
       long waitSec=(long)g_senderCfg[si].waitforhours*3600+(long)g_senderCfg[si].waitforminutes*60
                   +(long)g_senderCfg[si].waitforseconds;
       if(waitSec>0)
         {
          if(openedOurs>0)
            {
             if(ageSec<waitSec)
               {
                if(g_once.ShouldEmit("wait|"+g_sid[si]+"|"+rsym))
                   g_log.Info("holding "+rsym+" - the sender opened it "
                              +CopierSecText(ageSec)+" ago and the configured wait"
                              +" is "+CopierSecText(waitSec)+", so it will enter in"
                              +" "+CopierSecText(waitSec-ageSec));
                g_senderWaitHeld[si]++;
                g_senderWaitLots[si]+=lots;
                g_waitHeld++;
                g_waitLots+=lots;
                AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Wait open delay ("+CopierSecText(waitSec-ageSec)+")");
                continue;
               }
            }
          else
            {
             // BUG-85-01: Fail-safe: waitSec was configured > 0, but clock offset is not yet calibrated (openedOurs <= 0).
             // Do NOT enter immediately! Hold until clock offset is calibrated.
             g_senderWaitHeld[si]++;
             g_senderWaitLots[si]+=lots;
             g_waitHeld++;
             g_waitLots+=lots;
             AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Holding: waiting for clock offset calibration");
             continue;
            }
         }
      }

      if(g_senderCfg[si].waitforminutesbar>0)
        {
         if(openedOurs>0)
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
               g_senderWaitHeld[si]++;
               g_senderWaitLots[si]+=lots;
               g_waitHeld++;
               g_waitLots+=lots;
               AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Waiting for M1 bars ("+(string)bars+"/"+(string)g_senderCfg[si].waitforminutesbar+")");
               continue;
              }
           }
         else
           {
            // BUG-85-01: Fail-safe: waitforminutesbar was configured > 0, hold until clock is calibrated
            g_senderWaitHeld[si]++;
            g_senderWaitLots[si]+=lots;
            g_waitHeld++;
            g_waitLots+=lots;
            AddWaitItem(d.uid,rsym,d.side,lots,d.openPx,g_magic[si],"gate_delayed","Holding: waiting for clock offset calibration for bars");
            continue;
           }
        }

      // MQL-05: Profit/pullback gating only applies to active market positions, not pending orders
      if(d.kind==CP_ORD_MARKET && g_senderCfg[si].waitforprofitpips!=0.0 && d.openPx>0.0)
        {
         CopierSymInfo pi;
         if(CopierGetSymbolInfo(rsym,pi))
           {
            double closePx=0.0;
            // BUG-02: Use sender's original side (senderSide) to evaluate sender's profit/pullback,
            // preventing inverttrades from flipping the evaluation direction.
            if(CopierGetClosePrice(rsym,senderSide,closePx))
              {
               //--- Dig3/Dig5 => JPY-style 3/5-digit quoting, where a pip is
               //--- 10 points, not 1. This is the SAME rule PipSize() applies
               //--- everywhere else, and it used to be written out inline here -
               //--- two spellings of one rule is exactly how they drift apart.
               double pipSize=PipSize(pi);
               double profitPips=(senderSide==CP_SIDE_BUY)
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
                  g_senderWaitHeld[si]++;
                  g_senderWaitLots[si]+=lots;
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

      //--- 6. Risk limits & broker quota
      string riskWhy="";
      if(!g_risk.AllowOpen(lots,g_ourPositions,g_ourLots,g_ourPending+pendCount,pendLots,riskWhy))
        {
         string blockKey=g_risk.BlockKey();
         if(StringLen(blockKey)==0) blockKey=riskWhy;
         g_riskBlocked++;
         if(g_once.ShouldEmit("risk|"+blockKey))
            g_log.Warn("risk switch blocked a new entry - "+riskWhy);
         continue;
        }

      //--- Per-sender specific risk gate
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

      if(g_brokerOrdLimit>0 && (g_acctPositions+g_acctOrders+pendCount)>=g_brokerOrdLimit)
        {
         if(g_once.ShouldEmit("brokerlimit|any"))
            g_log.Warn("at this broker's order limit of "
                       +(string)g_brokerOrdLimit+" (positions "
                       +(string)g_acctPositions+" + pending "
                       +(string)g_acctOrders+" + queued "
                       +(string)pendCount+") - not sending more. Skipped,"
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
                             d.kind,d.ptype,d.pprice,d.pstop,
                             (d.pexpire>0)?SenderTimeToOurs(si,d.pexpire):0,d.openPx);
      if(queued)
        {
         pendCount++;
         pendLots+=lots;
         sPendCount++;
         sPendLots+=lots;
        }

      string openKey=g_sid[si]+":"+(string)CP_ACT_OPEN+":"+d.uid;
      if(queued && g_everOpened.Has(openKey)
         && g_once.ShouldEmit("restore|"+d.uid))
         g_log.Info("RESTORING "+d.uid+" "+rsym+" - the sender still holds it"
                    +" and this account does not (closed by hand, by another"
                    +" EA, or by a stop-out). To leave it alone, add "+d.uid
                    +" to the IgnoreUids input");
     }

   //--- N84-02, N84-07 & L2: Garbage collect manually closed entries.
   //---
   //--- Three kinds of entry live in this ring and they must NOT be collected
   //--- the same way:
   //---   * real UIDs      -> collected when the owning sender no longer holds them
   //---                        in its desired set (the original rule);
   //---   * "#t<localTkt>" -> a position whose broker comment was mangled, so it
   //---                        has no UID at all. It can never appear in the
   //---                        desired set (which carries 8-hex UIDs), so the old
   //---                        rule deleted it on the very next tick - the mirror
   //---                        was then re-opened immediately after the operator
   //---                        closed it. Collect it when the local ticket is
   //---                        gone, or after a generous TTL as a backstop;
   //---   * ticket-only    -> same treatment as "#t", just without the prefix.
   if(g_manualClosed.Count()>0 && g_ready[si])
     {
      bool gcChanged=false;
      string curSid=g_sid[si];
      long gcNow=CopierNowMs();
      for(int m=g_manualClosed.Count()-1; m>=0; m--)
        {
         string mUid=g_manualClosed.GetUid(m);
         long   mTkt=g_manualClosed.GetTicket(m);
         string mSid=g_manualClosed.GetSid(m);

         bool uidIsTicketPlaceholder=(StringLen(mUid)>=2 && StringSubstr(mUid,0,2)=="#t");
         if(StringLen(mUid)==0 || uidIsTicketPlaceholder)
           {
            if(mTkt<=0) continue;
            long ageMs=(long)(gcNow-(long)g_manualClosed.GetAt(m));
            if(!LocalTicketStillOpen(mTkt) || ageMs>CP_MANUAL_CLOSED_TTL_MS)
              {
               g_log.Info("ManualClosed GC: ticket "+IntegerToString(mTkt)+" ("
                          +(StringLen(mUid)>0?mUid:"no uid")+") is "
                          +(LocalTicketStillOpen(mTkt)?"older than the ignore TTL":"no longer open locally")
                          +". Removed from ignore table.");
               g_manualClosed.RemoveAt(m);
               gcChanged=true;
              }
            continue;
           }
         //--- direct O(D) GC: if entry belongs to this sender, check this sender's
         //--- desired set only. Entries attributed to ANOTHER sender are left alone.
         if(StringLen(mSid)>0)
           {
            if(mSid!=curSid) continue;
            // N-01: If local ticket is still open and within TTL, do NOT purge prematurely
            if(mTkt>0 && LocalTicketStillOpen(mTkt))
              {
               long ageMs=(long)(gcNow-(long)g_manualClosed.GetAt(m));
               if(ageMs<=CP_MANUAL_CLOSED_TTL_MS) continue;
              }
            bool senderStillHolds=false;
            for(int d=0; d<g_desiredCount[si]; d++)
              {
               if(g_desired[base+d].uid==mUid) { senderStillHolds=true; break; }
              }
            if(!senderStillHolds)
              {
               g_log.Info("ManualClosed GC: UID "+mUid+" ("+mSid+") was closed by operator and sender no longer holds it. Removed from ignore table.");
               g_manualClosed.RemoveAt(m);
               gcChanged=true;
              }
           }
         else
           {
            // N-01: If local ticket is still open and within TTL, do NOT purge prematurely
            if(mTkt>0 && LocalTicketStillOpen(mTkt))
              {
               long ageMs=(long)(gcNow-(long)g_manualClosed.GetAt(m));
               if(ageMs<=CP_MANUAL_CLOSED_TTL_MS) continue;
              }
            bool anySenderHolds=false;
            bool allSendersReady=true;
            for(int s=0; s<g_nSenders; s++)
              {
               if(!g_ready[s]) { allSendersReady=false; }
               int sbase=s*CP_MAX_POSITIONS;
               for(int d=0; d<g_desiredCount[s]; d++)
                 {
                  if(g_desired[sbase+d].uid==mUid) { anySenderHolds=true; break; }
                 }
               if(anySenderHolds) break;
              }
            if(!anySenderHolds && allSendersReady)
              {
               g_log.Info("ManualClosed GC: legacy UID "+mUid+" was closed by operator and no sender holds it. Removed from ignore table.");
               g_manualClosed.RemoveAt(m);
               gcChanged=true;
              }
           }
        }
      if(gcChanged) CmdStateSave(); // N83-02: Synchronize disk state when manual closed entries are GC'd
     }
   RecomputeWaitTotals();
  }

#endif // __COPIER_RECVCONVERGE_MQH__
