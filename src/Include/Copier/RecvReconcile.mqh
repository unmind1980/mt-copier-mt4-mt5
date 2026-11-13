//+------------------------------------------------------------------+
//| RecvReconcile.mqh                                                |
//| Part of CopierReceiver.mq4 - not a standalone header.            |
//+------------------------------------------------------------------+
//--- Lot sizing, partial-close trim, stop/target modify, account position scan and STAT encoders.
//--- Included at a fixed point inside CopierReceiver.mq4 and relies on
//--- the globals, inputs and helpers declared above that point. Moved
//--- verbatim out of the EA; do not include it from anywhere else.
#ifndef __COPIER_RECVRECONCILE_MQH__
#define __COPIER_RECVRECONCILE_MQH__

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
// Compute raw (pre-normalization) receiver lot size for `senderLots` in mode `g_lotMode[si]`.
// Equity and cross-currency conversions are evaluated ONLY in CP_SIZE_EQUITY_RATIO.
bool ComputeRawReceiverLots(const int si,const string sym,const double senderLots,
                            const CopierSymInfo &si2,double &outRawLots,bool &rejected,
                            const string senderSym="")
  {
   rejected=false;
   outRawLots=0.0;
   double symMult=(StringLen(senderSym)>0)?GetSymbolMultiplierForPair(si,senderSym,sym):GetSymbolMultiplier(si,sym);
   if(g_lotMode[si]==CP_SIZE_FIXED)
     {
      outRawLots=g_lotParam[si]*symMult;
     }
   else if(g_lotMode[si]==CP_SIZE_OFF)
     {
      outRawLots=senderLots*symMult;
     }
   else if(g_lotMode[si]==CP_SIZE_EQUITY_RATIO)
     {
      double myEq=CopierAccountEquity();
      if(myEq<=0.0) { rejected=true; return false; }
      double convSenderEq=g_senderEquity[si];
      string recCcy=CopierAccountCurrency();
      if(StringLen(g_senderCurrency[si])==0) { rejected=true; return false; }
      if(convSenderEq>0.0 && g_senderCurrency[si]!=recCcy)
        {
         double rate=CopierGetCurrencyCrossRate(g_senderCurrency[si],recCcy,g_suffix[si]);
         if(rate>0.0) convSenderEq*=rate;
         else
           {
            rejected=true;
            return false;
           }
        }
      if(convSenderEq<=0.0) { rejected=true; return false; }
      double eqRatio=myEq/convSenderEq;
      if(eqRatio>CP_MAX_EQUITY_RATIO) eqRatio=CP_MAX_EQUITY_RATIO;
      outRawLots=senderLots*eqRatio*g_lotParam[si]*symMult;
      if(senderLots>=si2.minLot && outRawLots<si2.minLot && si2.lotStep>0.0)
        {
         if(MathRound(outRawLots/si2.lotStep)*si2.lotStep >= si2.minLot)
            outRawLots=si2.minLot;
        }
     }
   else
     {
      outRawLots=senderLots*g_lotParam[si]*symMult;
     }
   if(!MathIsValidNumber(outRawLots) || outRawLots<=0.0)
     {
      outRawLots=0.0;
      rejected=true;
      return false;
     }
   return true;
  }

double ComputeReceiverLots(const int si,const string sym,const double senderLots,bool &rejected,const string senderSym="")
  {
   rejected=false;
   CopierSymInfo si2;
   if(!CopierGetSymbolInfo(sym,si2)) { rejected=true; return 0.0; }
   double rawEstimate=0.0;
   if(!ComputeRawReceiverLots(si,sym,senderLots,si2,rawEstimate,rejected,senderSym))
      return 0.0;
   if(si2.maxLot>0.0 && rawEstimate>si2.maxLot)
     {
      if(g_once.ShouldEmit("maxlotclamp|"+g_sid[si]+"|"+sym))
         g_log.Warn("sender "+g_sid[si]+" symbol "+sym+" computed lots "+DoubleToString(rawEstimate,2)+" exceeds broker maxLot "+DoubleToString(si2.maxLot,2)+"; clamped to maxLot");
      rawEstimate=si2.maxLot;
     }
   double lots=CopierNormalizeLot(rawEstimate,si2);
   if(lots<=0.0 || lots<si2.minLot) { rejected=true; return 0.0; }
   if(g_senderCfg[si].maxLotsPerPosition>0.0 && lots>g_senderCfg[si].maxLotsPerPosition)
     {
      lots=CopierNormalizeLot(g_senderCfg[si].maxLotsPerPosition,si2);
      // P2-22 fix: Check clamped lots against broker minLot
      if(lots<si2.minLot)
        {
         rejected=true;
         if(g_once.ShouldEmit("minlotclamp|"+g_sid[si]))
            g_log.Warn("sender "+g_sid[si]+" clamped size "+DoubleToString(lots,2)+" is below broker minLot "+DoubleToString(si2.minLot,2)+"; order rejected");
         return 0.0;
        }
     }
   return lots;
  }

double ComputeTargetLotsForMirrorRaw(const int si,const CopierPos &desired,const string sym,bool &outRejected)
  {
   outRejected=false;
   CopierSymInfo si2;
   if(!CopierGetSymbolInfo(sym,si2)) { outRejected=true; return 0.0; }
   double origLots=(desired.initLots>0.0)
                   ?desired.initLots
                   :GetOrUpdateSenderPeakLots(desired.uid,desired.lots);
   double targetLots=0.0;
   if(origLots>0.0 && desired.lots<origLots)
     {
      double rawBase=0.0;
      bool baseRej=false;
      if(!ComputeRawReceiverLots(si,sym,origLots,si2,rawBase,baseRej,desired.sym) || baseRej)
        {
         outRejected=true;
         return 0.0;
        }
      if(si2.maxLot>0.0 && rawBase>si2.maxLot)
        {
         if(g_once.ShouldEmit("maxlotclamp|"+g_sid[si]+"|"+sym))
            g_log.Warn("sender "+g_sid[si]+" symbol "+sym+" computed lots "+DoubleToString(rawBase,2)+" exceeds broker maxLot "+DoubleToString(si2.maxLot,2)+"; clamped to maxLot");
         rawBase=si2.maxLot;
        }
      if(g_senderCfg[si].maxLotsPerPosition>0.0 && rawBase>g_senderCfg[si].maxLotsPerPosition)
         rawBase=g_senderCfg[si].maxLotsPerPosition;
      // Single normalization after scaling by (desired.lots / origLots) avoids double lotStep rounding loss
      double rawScaled=rawBase*(desired.lots/origLots);
      targetLots=CopierNormalizeLot(rawScaled,si2);
      if(targetLots<=0.0 || targetLots<si2.minLot) return 0.0;
     }
   else
     {
      bool recRej=false;
      targetLots=ComputeReceiverLots(si,sym,desired.lots,recRej,desired.sym);
      if(recRej || targetLots<=0.0)
        {
         outRejected=true;
         return 0.0;
        }
     }
   return targetLots;
  }

double ComputeTargetLotsForMirror(const int si,const CopierPos &desired,const string sym)
  {
   bool rejected=false;
   double targetLots=ComputeTargetLotsForMirrorRaw(si,desired,sym,rejected);
   if(rejected || targetLots<=0.0) return 0.0;
   // N72-09: Never clamp sub-minLot lots up to minLot as it would silently inflate risk (see CopierSizing.mqh)
   return targetLots;
  }

void QueueTrimIfNeeded(const int si,const CopierPos &desired,const CopierPos &local,const double targetLotsCached=0.0)
  {
   if(local.kind!=CP_ORD_MARKET) return;

   CopierSymInfo si2;
   if(!CopierGetSymbolInfo(local.sym,si2)) return;

   //--- Sizing conversion: use cached targetLots if already computed by converge,
   //--- or compute directly (distinguishing rejection from sub-minLot partial trim).
   double targetLots=targetLotsCached;
   if(targetLots<=0.0)
     {
      bool targetRej=false;
      targetLots=ComputeTargetLotsForMirrorRaw(si,desired,local.sym,targetRej);
      if(targetRej) return;
      if(targetLots<=0.0 && desired.lots>0.0 && local.lots>si2.minLot+CP_LOT_EPS)
         targetLots=si2.minLot;
     }
   if(targetLots<=0.0) return;

   double diff=local.lots-targetLots;
   if(diff<=0.0) return;                       // local is not larger than target

   double step=si2.lotStep;
   if(step<=0.0) return;
   int digits=MathMax(CopierLotDigits(step),CopierLotDigits(si2.minLot));
   diff=NormalizeDouble(diff,digits);
   if(diff<step-CP_LOT_EPS) return;              // sub-step noise

   double trim=NormalizeDouble(MathFloor(diff/step+0.0000001)*step,digits);
   if(si2.maxLot>0.0 && trim>si2.maxLot)
     {
      trim=CopierNormalizeLot(si2.maxLot,si2);
      if(trim<=0.0) return;
     }
   if(trim<=0.0 || trim<si2.minLot-0.0000001) return;

   double remaining=NormalizeDouble(local.lots-trim,digits);
   if(remaining<si2.minLot-0.0000001)
     {
      // Quantize altTrim to broker lotStep grid (D3-01)
      double altTrim=CopierNormalizeLot(local.lots-si2.minLot,si2);
      if(si2.maxLot>0.0 && altTrim>si2.maxLot) altTrim=CopierNormalizeLot(si2.maxLot,si2);
      double altRemaining=NormalizeDouble(local.lots-altTrim,digits);
      if(altTrim>=si2.minLot-CP_LOT_EPS && altRemaining>=si2.minLot-CP_LOT_EPS)
        {
         trim=altTrim;
         remaining=altRemaining;
        }
      else
        {
         // Trimming would leave less than minLot, and cannot trim to minLot without
         // violating broker minLot. Do NOT close the entire position while sender
         // still holds it to avoid infinite reopen-close ping-pong churn.
         return;
        }
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
              stk,":"+CopierFmtDouble(targetLots,CP_DIGITS_LOTS));
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
// OPT-08: Find or allocate cache slot for stop signature with 4-step probing
//=====================================================================
int StopSigFindSlot(const long ticket)
  {
   if(ticket<=0) return 0;
   int base=(int)(((ulong)ticket^((ulong)ticket>>11))&(CP_STOPSIG_SLOTS-1));
   for(int step=0;step<4;step++)
     {
      int sh=(base+step)&(CP_STOPSIG_SLOTS-1);
      if(g_stopSig[sh].ticket==ticket || g_stopSig[sh].ticket==0) return sh;
     }
   return base;
  }

// BUG-01: Invalidate stop signature cache across all probed hash slots
void StopSigInvalidate(const long ticket)
  {
   if(ticket<=0) return;
   int base=(int)(((ulong)ticket^((ulong)ticket>>11))&(CP_STOPSIG_SLOTS-1));
   for(int step=0;step<4;step++)
     {
      int sh=(base+step)&(CP_STOPSIG_SLOTS-1);
      if(g_stopSig[sh].ticket==ticket)
        {
         g_stopSig[sh].ticket=0;
        }
     }
  }

//=====================================================================
void QueueModifyIfNeeded(const int si,const CopierPos &desired,
                         const CopierPos &local)
  {
   // Unified market closed check: if the market is shut, orders cannot be modified by broker API.
   if(SymbolMarketClosed(local.sym)) return;

   //--- Already evaluated with exactly these inputs (and the same override
   //--- table) and the answer was "nothing to do". See CopierStopSig.
   int sh=StopSigFindSlot(local.ticket);
   if(sh<0 || sh>=CP_STOPSIG_SLOTS) sh=0;
   if(local.ticket!=0
      && g_stopSig[sh].ticket==local.ticket
      && g_stopSig[sh].epoch==g_stOvEpoch)
     {
      if(MathAbs(g_stopSig[sh].v[0]-desired.sl)<0.0000001
         && MathAbs(g_stopSig[sh].v[1]-desired.tp)<0.0000001
         && MathAbs(g_stopSig[sh].v[2]-desired.openPx)<0.0000001
         && MathAbs(g_stopSig[sh].v[3]-local.sl)<0.0000001
         && MathAbs(g_stopSig[sh].v[4]-local.tp)<0.0000001
         && MathAbs(g_stopSig[sh].v[5]-local.pprice)<0.0000001
         && MathAbs(g_stopSig[sh].v[6]-local.pstop)<0.0000001
         && g_stopSig[sh].v[7]==(double)local.pexpire
         && MathAbs(g_stopSig[sh].v[8]-desired.pprice)<0.0000001
         && MathAbs(g_stopSig[sh].v[9]-desired.pstop)<0.0000001
         && g_stopSig[sh].v[10]==(double)desired.pexpire
         && g_stopSig[sh].v[11]==(double)local.kind
         && MathAbs(g_stopSig[sh].v[12]-local.openPx)<0.0000001)
         return;
     }

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
   double dSl=(g_senderCfg[si].mirrorstops)?desired.sl:0.0;
   double dTp=(g_senderCfg[si].mirrorstops)?desired.tp:0.0;
   double dOpn=desired.openPx;
   double dPPrice=desired.pprice;
   double dPStop=desired.pstop;
   long   dPExp=(desired.pexpire>0)?SenderTimeToOurs(si,desired.pexpire):0;
   int oi=StopsOvIndex(desired.uid,false);
   if(oi>=0 && g_stHasOv[oi])
     {
      bool slCaughtUp=(MathAbs(desired.sl-g_stOvSl[oi])<0.0000001);
      bool tpCaughtUp=(MathAbs(desired.tp-g_stOvTp[oi])<0.0000001);
      bool ppriceCaughtUp=(g_stOvPprice[oi]<=0.0 || MathAbs(desired.pprice-g_stOvPprice[oi])<0.0000001);
      bool pstopCaughtUp=(g_stOvPstop[oi]<=0.0 || MathAbs(desired.pstop-g_stOvPstop[oi])<0.0000001);
      bool pexpCaughtUp=(g_stOvPexp[oi]<=0 || desired.pexpire==g_stOvPexp[oi]);
      if(slCaughtUp && tpCaughtUp && ppriceCaughtUp && pstopCaughtUp && pexpCaughtUp)
        {
         g_stHasOv[oi]=false;               // the snapshot caught up
         g_stOvEpoch++;                     // invalidates the stop-geometry cache
        }
      else
        {
         dSl=(g_senderCfg[si].mirrorstops)?g_stOvSl[oi]:0.0;
         dTp=(g_senderCfg[si].mirrorstops)?g_stOvTp[oi]:0.0;
         dOpn=g_stOvOpn[oi];
         if(g_stOvPprice[oi]>0.0) dPPrice=g_stOvPprice[oi];
         if(g_stOvPstop[oi]>0.0)  dPStop=g_stOvPstop[oi];
         if(g_stOvPexp[oi]>0)     { long ovExp=SenderTimeToOurs(si,g_stOvPexp[oi]); if(ovExp>0) dPExp=ovExp; }
        }
     }

   //--- MQL-04: Determine actual inverted relationship based on real position sides
   //--- rather than assuming local.side matches current inverttrades configuration.
   bool actualInverted = (local.side != desired.side);

   //--- The sender's stops, as a distance, re-anchored on our own entry.
   double feedSl,feedTp;
   CopierMapInvertedStops(actualInverted,dSl,dTp,feedSl,feedTp);

   //--- BUG-05: For pending orders, anchor calculations to the pending order's updated trigger price (dPPrice)
   double effectiveLocalOpen=(local.kind==CP_ORD_PENDING)
                            ? ((dPPrice>0.0)?dPPrice:((local.pprice>0.0)?local.pprice:local.openPx))
                            : local.openPx;

   double wantSl,wantTp;
   if(actualInverted)
     {
      wantSl=CopierMirrorStopInverted(feedSl,dOpn,
                                      effectiveLocalOpen,local.side,true);
      wantTp=CopierMirrorStopInverted(feedTp,dOpn,
                                      effectiveLocalOpen,local.side,false);
     }
   else
     {
      wantSl=CopierMirrorStop(feedSl,dOpn,
                              effectiveLocalOpen,local.side,true);
      wantTp=CopierMirrorStop(feedTp,dOpn,
                              effectiveLocalOpen,local.side,false);
     }

   double effPStop=(dPStop>0.0)?dPStop:local.pstop;
   double anchorPx=(local.kind==CP_ORD_PENDING)
                   ? ((effPStop>0.0)?effPStop:effectiveLocalOpen)
                   : local.openPx;

   //--- the sender has no stop of its own, so the local backstop applies
   if(wantSl<=0.0 && g_senderCfg[si].emergencySLPips>0.0)
     {
      int e=0;
      if(local.kind==CP_ORD_PENDING)
        {
         double pipSize=CopierPipOf(si2);
         double rawSl=(local.side==CP_SIDE_BUY)?(anchorPx-g_senderCfg[si].emergencySLPips*pipSize)
                                               :(anchorPx+g_senderCfg[si].emergencySLPips*pipSize);
         wantSl=NormalizeDouble(rawSl,si2.digits);
        }
      else
        {
         wantSl=CopierEmergencySl(local.sym,local.side,anchorPx,
                                  g_senderCfg[si].emergencySLPips,si2,e);
        }
     }
   if(wantTp<=0.0 && g_senderCfg[si].emergencyTPPips>0.0)
     {
      int e=0;
      if(local.kind==CP_ORD_PENDING)
        {
         double pipSize=CopierPipOf(si2);
         double rawTp=(local.side==CP_SIDE_BUY)?(anchorPx+g_senderCfg[si].emergencyTPPips*pipSize)
                                               :(anchorPx-g_senderCfg[si].emergencyTPPips*pipSize);
         wantTp=NormalizeDouble(rawTp,si2.digits);
        }
      else
        {
         wantTp=CopierEmergencyTp(local.sym,local.side,anchorPx,
                                  g_senderCfg[si].emergencyTPPips,si2,e);
        }
     }

   // N87-07: Defend against clearing existing protective SL/TP when sender HAS a stop,
   // but mirror calculation failed to compute a valid level (e.g. invalid entry price / calculation failure).
   if(feedSl>0.0 && wantSl<=0.0)
     {
      wantSl=local.sl;
      if(g_once.ShouldEmit("slcalcunavail|"+local.uid))
         g_log.Warn("sender has SL="+DoubleToString(feedSl,si2.digits)
                    +" but mirror stop calculation returned 0; retaining local protective SL="
                    +DoubleToString(local.sl,si2.digits)+" to prevent bare position");
     }
   if(feedTp>0.0 && wantTp<=0.0)
     {
      wantTp=local.tp;
      if(g_once.ShouldEmit("tpcalcunavail|"+local.uid))
         g_log.Warn("sender has TP="+DoubleToString(feedTp,si2.digits)
                    +" but mirror TP calculation returned 0; retaining local TP="
                    +DoubleToString(local.tp,si2.digits));
     }

   //--- clear the broker's minimum distance BEFORE comparing, or a stop
   //--- that can only ever be clamped would look like a difference on
   //--- every single tick and queue a modify forever.
   //--- For pending orders, clamp against the order's trigger/limit price, NOT live market Bid/Ask!
   bool clampedSl=false, clampedTp=false;
   bool invertedCrossed=false;
   double rawWantSl=wantSl;
   double rawWantTp=wantTp;
   double noiseTol=MathMax(3.0*si2.stopLevel,10.0*si2.point);

   if(local.kind==CP_ORD_PENDING)
     {
      wantSl=CopierFitStopAt(rawWantSl,local.side,true,anchorPx,si2,clampedSl);
      wantTp=CopierFitStopAt(rawWantTp,local.side,false,anchorPx,si2,clampedTp);
      // BUG-06 & N-01: Protect pending orders against crossed stops
      if(anchorPx>0.0)
        {
         if(rawWantSl>0.0)
           {
            double distSl=(local.side==CP_SIDE_BUY)?(rawWantSl-anchorPx):(anchorPx-rawWantSl);
            if(distSl>=0.0) // crossed anchorPx
              {
               if(distSl<=noiseTol)
                 {
                  if(local.sl>0.0) { wantSl=local.sl; clampedSl=false; invertedCrossed=true; }
                  else if(g_senderCfg[si].emergencySLPips>0.0)
                    {
                     double emSlPx=(local.side==CP_SIDE_BUY) ? (anchorPx-g_senderCfg[si].emergencySLPips*CopierPipOf(si2))
                                                             : (anchorPx+g_senderCfg[si].emergencySLPips*CopierPipOf(si2));
                     wantSl=CopierFitStopAt(NormalizeDouble(emSlPx,si2.digits),local.side,true,anchorPx,si2,clampedSl);
                    }
                 }
               else clampedSl=true;
              }
           }
         if(rawWantTp>0.0)
           {
            double distTp=(local.side==CP_SIDE_BUY)?(anchorPx-rawWantTp):(rawWantTp-anchorPx);
            if(distTp>=0.0) // crossed anchorPx
              {
               if(distTp<=noiseTol)
                 {
                  if(local.tp>0.0) { wantTp=local.tp; clampedTp=false; invertedCrossed=true; }
                 }
               else clampedTp=true;
              }
           }
        }
      if((clampedSl || clampedTp) && g_once.ShouldEmit("slclamp|"+local.uid))
         g_log.Warn("stop for pending order "+local.uid+" "+local.sym+" was inside this"
                    +" broker's minimum distance and has been widened");
     }
   else
     {
      wantSl=CopierFitStop(rawWantSl,local.sym,local.side,true,si2,clampedSl);
      wantTp=CopierFitStop(rawWantTp,local.sym,local.side,false,si2,clampedTp);
      // ISSUE-02 / N-01: Distinguish noise crossing vs real breakthrough
      double mktPx=0.0;
      if(CopierGetClosePrice(local.sym,local.side,mktPx) && mktPx>0.0)
        {
         if(rawWantSl>0.0)
           {
            double distSl=(local.side==CP_SIDE_BUY)?(rawWantSl-mktPx):(mktPx-rawWantSl);
            if(distSl>=0.0) // crossed live market close price
              {
               if(distSl<=noiseTol)
                 {
                  // Noise crossing: retain local stop to avoid premature stopout, or use emergency SL if bare
                  if(local.sl>0.0) { wantSl=local.sl; clampedSl=false; invertedCrossed=true; }
                  else if(g_senderCfg[si].emergencySLPips>0.0)
                    {
                     double emSlPx=(local.side==CP_SIDE_BUY) ? (mktPx-g_senderCfg[si].emergencySLPips*CopierPipOf(si2))
                                                             : (mktPx+g_senderCfg[si].emergencySLPips*CopierPipOf(si2));
                     wantSl=CopierFitStop(NormalizeDouble(emSlPx,si2.digits),local.sym,local.side,true,si2,clampedSl);
                    }
                 }
               else
                 {
                  // Real breakthrough: market ran through stop. PROTOCOL.md: clamp to closest broker distance
                  clampedSl=true;
                 }
              }
           }
         if(rawWantTp>0.0)
           {
            double distTp=(local.side==CP_SIDE_BUY)?(mktPx-rawWantTp):(rawWantTp-mktPx);
            if(distTp>=0.0) // crossed live market close price
              {
               if(distTp<=noiseTol)
                 {
                  if(local.tp>0.0) { wantTp=local.tp; clampedTp=false; invertedCrossed=true; }
                 }
               else clampedTp=true;
              }
           }
        }
      if((clampedSl || clampedTp) && g_once.ShouldEmit("slclamp|"+local.uid))
         g_log.Warn("stop for "+local.uid+" "+local.sym+" was inside this"
                    +" broker's minimum distance and has been widened; the"
                    +" mirror is now WIDER than the sender's stop");
     }
   bool clamped=(clampedSl || clampedTp);
   //--- BUG-03 & N70-06: If emergency stop was configured but quote was temporarily missing (wantSl<=0 or wantTp<=0),
   //--- do NOT cache in g_stopSig, otherwise a naked position would permanently freeze without emergency stops!
   bool emergencyMissing = (g_senderCfg[si].emergencySLPips>0.0 && wantSl<=0.0)
                        || (g_senderCfg[si].emergencyTPPips>0.0 && wantTp<=0.0);

   bool pendingDiff=false;
   if(local.kind==CP_ORD_PENDING && desired.kind==CP_ORD_PENDING)
     {
      if(dPPrice>0.0 && MathAbs(local.pprice-dPPrice)>si2.point*0.5) pendingDiff=true;
      if(dPStop>0.0 && MathAbs(local.pstop-dPStop)>si2.point*0.5) pendingDiff=true;
      // DEF-A04: If desired.pexpire > 0 but dPExp == 0, clock offset is temporarily uncalibrated.
      // Do NOT wipe local.pexpire in this case. Only wipe if sender explicitly set pexpire == 0.
      if(desired.pexpire>0)
        {
         if(dPExp>0 && (local.pexpire<=0 || MathAbs(local.pexpire-dPExp)>2)) pendingDiff=true;
        }
      else if(desired.pexpire==0 && local.pexpire!=0)
        {
         datetime dayEnd=TimeCurrent() - (TimeCurrent()%86400) + 86399;
         if(MathAbs(local.pexpire-(long)dayEnd)>60) pendingDiff=true;
        }
     }

   // R11-A02 & R14-D04: Strict Ratchet Guard for market positions,
   // bypassed once when upgrading an initial EmergencySL to the sender's real SL.
   if(local.kind==CP_ORD_MARKET && local.sl>0.0 && wantSl>0.0 && !(g_emgSlApplied.Has(local.uid) && feedSl>0.0))
     {
      if(local.side==CP_SIDE_BUY && wantSl<local.sl)
        {
         wantSl=local.sl;
         clampedSl=false;
        }
      else if(local.side==CP_SIDE_SELL && wantSl>local.sl)
        {
         wantSl=local.sl;
         clampedSl=false;
        }
     }
   if(!StopsDiffer(local.sl,wantSl,si2) && g_emgSlApplied.Has(local.uid) && feedSl>0.0)
      g_emgSlApplied.Forget(local.uid);

   if(!StopsDiffer(local.sl,wantSl,si2) && !StopsDiffer(local.tp,wantTp,si2) && !pendingDiff)
     {
      //--- Nothing to change: record signature so next tick can skip immediately
      //--- MQL-01: When stop was clamped or deferred by inverted crossing, do NOT cache in g_stopSig
      if(local.ticket!=0)
        {
         if(!clamped && !emergencyMissing && !invertedCrossed)
           {
            g_stopSig[sh].ticket=local.ticket;
            g_stopSig[sh].epoch=g_stOvEpoch;
            g_stopSig[sh].v[0]=desired.sl;
            g_stopSig[sh].v[1]=desired.tp;
            g_stopSig[sh].v[2]=desired.openPx;
            g_stopSig[sh].v[3]=local.sl;
            g_stopSig[sh].v[4]=local.tp;
            g_stopSig[sh].v[5]=local.pprice;
            g_stopSig[sh].v[6]=local.pstop;
            g_stopSig[sh].v[7]=(double)local.pexpire;
            g_stopSig[sh].v[8]=desired.pprice;
            g_stopSig[sh].v[9]=desired.pstop;
            g_stopSig[sh].v[10]=(double)desired.pexpire;
            g_stopSig[sh].v[11]=(double)local.kind;
            g_stopSig[sh].v[12]=local.openPx;
           }
         else
           {
            g_stopSig[sh].ticket=0; // Invalidate cached signature on clamped or missing emergency stop
           }
        }
      return;
     }

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
   //--- The table is FIXED (CP_MAX_STOPS_OV) since the zero-allocation pass,
   //--- so it can refuse a new row. Indexing -1 would be a hard array-bounds
   //--- fault (MQL 4002) that aborts the tick and repeats on every tick for
   //--- as long as the condition holds - a stopped EA, not a noisy log.
   //--- Nothing is lost by skipping: the throttle is an optimisation, and the
   //--- modify below still goes out.
   if(oi<0)
     {
      if(g_once.ShouldEmit("stopsovfull"))
         g_log.Warn("stop-override table is full ("+(string)CP_MAX_STOPS_OV
                    +" UIDs); stop changes for new UIDs are no longer"
                    +" throttled. This clears as positions close.");
     }
   else
     {
      if(g_senderCfg[si].stopsThrottleSeconds>0 && g_stLastMs[oi]>=0
         && nowMs-g_stLastMs[oi]<(long)g_senderCfg[si].stopsThrottleSeconds*1000)
         return;
     }

   //--- the target stops are part of the dedup key: a SECOND change to a
   //--- different level is a different action, not a duplicate. Without
   //--- this the seen-ring would suppress it for its whole TTL and the
   //--- mirror would keep the first stop it ever saw.
   double actPPrice = (local.kind==CP_ORD_PENDING && dPPrice>0.0) ? dPPrice : local.pprice;
   double actPStop  = (local.kind==CP_ORD_PENDING && dPStop>0.0) ? dPStop : local.pstop;
   long   actPExp   = (local.kind==CP_ORD_PENDING) ? ((desired.pexpire>0 && dPExp==0) ? local.pexpire : dPExp) : local.pexpire;

   // DEF-10-03 & R18-A01: If existing or new pending entry/stops are within broker freezeLevel/stopLevel, modifications will be rejected (10016 / 145 / 130)
   double safeDist=MathMax(si2.freezeLevel, si2.stopLevel);
   if(safeDist>0.0)
     {
      if(local.kind==CP_ORD_PENDING)
        {
         double curEntPx=0.0;
         if(CopierGetPrice(local.sym,local.side,curEntPx) && curEntPx>0.0)
           {
            if((local.pprice>0.0 && MathAbs(curEntPx-local.pprice)<=safeDist) ||
               (local.pstop>0.0 && MathAbs(curEntPx-local.pstop)<=safeDist) ||
               (actPPrice>0.0 && MathAbs(curEntPx-actPPrice)<=safeDist) ||
               (actPStop>0.0 && MathAbs(curEntPx-actPStop)<=safeDist))
              {
               return;
              }
           }
        }
      else if(local.kind==CP_ORD_MARKET)
        {
         double curClosePx=0.0;
         if(CopierGetClosePrice(local.sym,local.side,curClosePx) && curClosePx>0.0)
           {
            if((local.sl>0.0 && MathAbs(curClosePx-local.sl)<=safeDist) ||
               (local.tp>0.0 && MathAbs(curClosePx-local.tp)<=safeDist))
              {
               return;
              }
           }
        }
     }

   string modKeyExtra = ":"+CopierFmtDouble(wantSl,CP_DIGITS_PX)
                       +":"+CopierFmtDouble(wantTp,CP_DIGITS_PX)
                       +":"+CopierFmtDouble(actPPrice,CP_DIGITS_PX)
                       +":"+CopierFmtDouble(actPStop,CP_DIGITS_PX)
                       +":"+(string)actPExp;
   bool pushed=PushAction(si,CP_ACT_MODIFY,desired.uid,local.sym,local.side,
                          0.0,local.ticket,0,
                          modKeyExtra,
                          wantSl,wantTp,
                          local.kind,local.ptype,actPPrice,actPStop,actPExp);

   //--- Action queued: only record signature and throttle timestamp when successfully pushed
   if(pushed)
     {
      if(oi>=0) g_stLastMs[oi]=nowMs; // R47-18: Consume throttle window only on successful queue push
      // BUG-06: Invalidate stopSig on push so an unexecuted in-flight modify action does not falsely freeze retry if broker rejects
      if(local.ticket!=0) g_stopSig[sh].ticket=0;
     }
  }

//=====================================================================
// Duplicate resolution: one UID must map to exactly ONE position.
//
// That invariant is what the converge uid index, the seen-ring and the state
// file all assume. When it breaks, the extra position is invisible to every
// other loop - the index returns the FIRST match - so the duplicate is never
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

   int drop[CP_MAX_POSITIONS];
   ArrayInitialize(drop,0);

   int removed=0;
   for(int i=0;i<ln;i++)
     {
      if(drop[i]!=0) continue;
      if(g_ignore.Has(loc[i].uid) || (si>=0 && si<g_nSenders && g_senderIgnore[si].Has(loc[i].uid))) continue;

      int groupN=0;
      for(int k=i;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         // R47-04: Exclude operator-ignored UIDs in group counting
         if(g_ignore.Has(loc[k].uid) || (si>=0 && si<g_nSenders && g_senderIgnore[si].Has(loc[k].uid))) continue;
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

      //--- what the sender says this UID should be right now, converted through
      //--- this receiver's sizing rules so the survivor comparison matches local target lots
      double want=-1.0;
      for(int d=0;d<g_desiredCount[si];d++)
        {
         if(g_desired[base+d].uid==loc[i].uid)
           {
            //--- N57-10: use the SAME target the converge pass will use.
            //---
            //--- This called ComputeReceiverLots, which knows nothing about
            //--- CP_SIZE_FIXED partial closes. In fixed-lot mode a sender that
            //--- opened 2.00 and has since trimmed to 1.00 leaves the receiver
            //--- holding 0.50 (1.00 scaled by 1.00/2.00). ComputeReceiverLots
            //--- still returns 1.00, so CopierPreferSurvivor - whose first rule
            //--- is "whoever matches `want` survives" - kept a stray 1.00
            //--- duplicate and closed the correct 0.50 position, then trimmed
            //--- the survivor back down. The operator paid the spread twice and
            //--- lost the original entry price.
            //--- the 3-arg form: it returns 0.0 when the target is rejected, so
            //--- there is no out-param to test.
            double tLots=ComputeTargetLotsForMirror(si,g_desired[base+d],loc[i].sym);
            if(tLots>0.0) want=tLots;
            else          want=g_desired[base+d].lots;
            break;
           }
        }

      int keep=i;
      for(int k=i+1;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         // R47-04: Exclude operator-ignored UIDs in survivor selection
         if(g_ignore.Has(loc[k].uid) || (si>=0 && si<g_nSenders && g_senderIgnore[si].Has(loc[k].uid))) continue;
         if(loc[k].uid!=loc[i].uid) continue;
         if(CopierPreferSurvivor(loc[k],loc[keep],want)) keep=k;
        }

      for(int k=i;k<ln;k++)
        {
         if(drop[k]!=0) continue;
         // R47-04: Exclude operator-ignored UIDs from drop and dedup action push
         if(g_ignore.Has(loc[k].uid) || (si>=0 && si<g_nSenders && g_senderIgnore[si].Has(loc[k].uid))) continue;
         if(loc[k].uid!=loc[i].uid) continue;
         if(k==keep) continue;
         // R14-A03: On MT5, a partially filled pending order leaves both a MARKET position
         // and a remaining PENDING order sharing the same ticket; neither is a duplicate.
         if(loc[k].ticket>0 && loc[k].ticket==loc[keep].ticket && loc[k].kind!=loc[keep].kind) continue;

         drop[k]=1;
         removed++;
         g_log.Warn("duplicate position for "+loc[k].uid+" "+loc[k].sym
                    +" lots="+DoubleToString(loc[k].lots,2)
                    +" ticket="+(string)loc[k].ticket
                    +" - keeping ticket "+(string)loc[keep].ticket
                    +" lots="+DoubleToString(loc[keep].lots,2)
                    +"; one UID must map to one position");
         PushAction(si,CP_ACT_DEDUP,loc[k].uid,loc[k].sym,loc[k].side,
                    loc[k].lots,loc[k].ticket,0,":"+(string)loc[k].ticket,
                    0.0,0.0,loc[k].kind);
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
struct CopierCachedOrder
  {
   long              ticket;
   long              magic;
   int               side;
   double            lots;
   double            openPx;
   double            sl;
   double            tp;
   long              openTime;
   int               kind;
   int               ptype;
   double            pprice;
   double            pstop;
   long              pexpire;
   string            uid;
   //--- The order comment, carried rather than re-read. Reading it is the
   //--- expensive half of the scan (a string API call per order per tick) and
   //--- the fast path has no use for it: identity is already resolved. It is
   //--- refreshed on the slow path, and it is still what the POS= telemetry
   //--- reports, so dropping it entirely would blind the dashboard.
   string            cmt;
   bool              isOrphan;
  };

CopierCachedOrder g_posCache[CP_MAX_POSITIONS];
//--- Scratch for the next generation of the cache.
//---
//--- Global rather than local ON PURPOSE. As a local it was constructed and
//--- zero-initialised on every 100 ms tick - 2048 structs, strings included,
//--- ~225 KB of memory traffic per call - and on MT4 it also ate that much
//--- stack. Only the first `an` entries are ever written or read.
//---
//--- Two arrays are unavoidable: the fast path READS the old generation while
//--- writing the new one, and the mapping is a permutation (a row can move),
//--- so writing in place would clobber a row that has not been read yet. MQL4
//--- only allows one-dimensional arrays of structs, so a 2-D double buffer
//--- with a flipped index is not available - hence the copy-back below, made
//--- conditional by g_cacheSrc so that a steady-state tick copies NOTHING.
CopierCachedOrder g_posCacheNext[CP_MAX_POSITIONS];
//--- Per row: 1 = the next generation differs from the cache and must be
//--- copied back, -1 = identical, copy is a no-op. Written for every i<an on
//--- every scan, so it never needs clearing.
int               g_cacheSrc[CP_MAX_POSITIONS];
int               g_posCacheCount=0;
long              g_lastFullScanMs=0;
int               g_lastOrdersTotal=-1;
long              g_lastPanelRenderMs=0;

CopierPos g_acctAllPos[CP_MAX_POSITIONS];
int       g_acctAllPosCount=0;
CopierPos g_rawScratch[CP_MAX_POSITIONS];
//--- Has ScanAndResolveAccountPositions() ever produced a result? Everything
//--- that consumes g_acctAllPos must know the difference between "the account
//--- holds nothing" and "nobody has looked yet" - the two are identical in the
//--- cache, and treating the second as the first is how the identity map got
//--- wiped on startup.
bool      g_acctScanned=false;

//--- uid -> index scratch for the converge diff. Global so the 32 KB tables
//--- are not built on the stack on every call, and so the per-tick cost is a
//--- rebuild rather than a construction.
CopierUidIndex g_locIdx;
CopierUidIndex g_desIdx;
CopierUidIndex g_qCloseIdx; // NM-01: Hash index for queuedCloseOrTrim

// NM-02: Ticket hash index for g_posCache to replace O(n^2) linear scan when order shifts
static int  s_posCacheTkSlot[CP_TICKIDX_SLOTS];
static uint s_posCacheTkHash[CP_TICKIDX_SLOTS];

int ScanAndResolveAccountPositions()
  {
   long now=CopierNowMs();
   int currentTotal=0;
#ifdef __MQL5__
   currentTotal=PositionsTotal()+OrdersTotal();
#else
   currentTotal=OrdersTotal();
#endif
   //--- Fallback full scan every 30s or whenever total order count changes
   bool forceFullScan=(now-g_lastFullScanMs>=30000) || (currentTotal!=g_lastOrdersTotal);
   if(forceFullScan)
     {
      g_lastFullScanMs=now;
      g_lastOrdersTotal=currentTotal;
     }

   //--- Comments are only read in bulk when this pass is a FULL revalidation
   //--- (every 30 s, or when the order count changed). A steady-state pass
   //--- reads the comment for the handful of rows that actually changed,
   //--- inside the slow path - see CopierReadCommentByTicket().
   //--- Writes directly into pre-allocated static g_rawScratch, zero ArrayResize.
   int an=CopierReadPositions(g_rawScratch,CP_MAX_POSITIONS,forceFullScan);

   g_acctAllPosCount=an;
   g_acctScanned=true;

   if(!forceFullScan && g_posCacheCount>0)
     {
      ArrayInitialize(s_posCacheTkSlot,0);
      for(int c=0;c<g_posCacheCount;c++)
        {
         long tk=g_posCache[c].ticket;
         uint h=(uint)(tk ^ (tk>>32));
         h=((h>>16)^h)*0x45d9f3b;
         h=((h>>16)^h)*0x45d9f3b;
         h=(h>>16)^h;
         int s=(int)(h&(CP_TICKIDX_SLOTS-1));
         for(int p=0;p<CP_TICKIDX_SLOTS;p++)
           {
            int k=(s+p)&(CP_TICKIDX_SLOTS-1);
            if(s_posCacheTkSlot[k]==0)
              {
               s_posCacheTkSlot[k]=c+1;
               s_posCacheTkHash[k]=h;
               break;
              }
           }
        }
     }

   for(int i=0;i<an;i++)
     {
      int matchIdx=-1;
      if(!forceFullScan)
        {
         //--- Prediction 1: Same index match (O(1) hit for 99.9% of steady-state ticks)
         if(i<g_posCacheCount && g_posCache[i].ticket==g_rawScratch[i].ticket)
           {
            if(g_posCache[i].magic==g_rawScratch[i].magic
               && g_posCache[i].side==g_rawScratch[i].side
               && g_posCache[i].kind==g_rawScratch[i].kind
               && g_posCache[i].ptype==g_rawScratch[i].ptype
               && g_posCache[i].openTime==g_rawScratch[i].openTime
               && g_posCache[i].pexpire==g_rawScratch[i].pexpire
               && g_posCache[i].lots==g_rawScratch[i].lots
               && g_posCache[i].openPx==g_rawScratch[i].openPx
               && g_posCache[i].sl==g_rawScratch[i].sl
               && g_posCache[i].tp==g_rawScratch[i].tp
               && g_posCache[i].pprice==g_rawScratch[i].pprice
               && g_posCache[i].pstop==g_rawScratch[i].pstop)
              {
               matchIdx=i;
              }
           }

         //--- NM-02: Prediction 2: O(1) hash probe replaces O(n^2) quadratic linear re-scan
         if(matchIdx<0 && g_posCacheCount>0)
           {
            long tk=g_rawScratch[i].ticket;
            uint h=(uint)(tk ^ (tk>>32));
            h=((h>>16)^h)*0x45d9f3b;
            h=((h>>16)^h)*0x45d9f3b;
            h=(h>>16)^h;
            int s=(int)(h&(CP_TICKIDX_SLOTS-1));
            for(int p=0;p<CP_TICKIDX_SLOTS;p++)
              {
               int k=(s+p)&(CP_TICKIDX_SLOTS-1);
               if(s_posCacheTkSlot[k]==0) break;
               if(s_posCacheTkHash[k]==h)
                 {
                  int c=s_posCacheTkSlot[k]-1;
                  if(g_posCache[c].ticket==g_rawScratch[i].ticket
                     && g_posCache[c].magic==g_rawScratch[i].magic
                     && g_posCache[c].side==g_rawScratch[i].side
                     && g_posCache[c].kind==g_rawScratch[i].kind
                     && g_posCache[c].ptype==g_rawScratch[i].ptype
                     && g_posCache[c].openTime==g_rawScratch[i].openTime
                     && g_posCache[c].pexpire==g_rawScratch[i].pexpire
                     && g_posCache[c].lots==g_rawScratch[i].lots
                     && g_posCache[c].openPx==g_rawScratch[i].openPx
                     && g_posCache[c].sl==g_rawScratch[i].sl
                     && g_posCache[c].tp==g_rawScratch[i].tp
                     && g_posCache[c].pprice==g_rawScratch[i].pprice
                     && g_posCache[c].pstop==g_rawScratch[i].pstop)
                    {
                     matchIdx=c;
                     break;
                    }
                 }
              }
           }
        }

      if(matchIdx>=0)
        {
         //--- FAST PATH: O(1) hit, zero allocations, reuse cached UID
         //---
         //--- When the row did not move (matchIdx == i) the next generation is
         //--- byte-for-byte the current one: the previous scan's copy-back left
         //--- g_posCacheNext[i] equal to g_posCache[i], and every numeric field
         //--- just compared equal. Copying it would be a struct assignment with
         //--- four string refcounts, per row, ten times a second, to arrive at
         //--- the value already there. g_cacheSrc[i]=-1 says "skip it".
         if(matchIdx==i) g_cacheSrc[i]=-1;
         else
           {
            g_posCacheNext[i]=g_posCache[matchIdx];
            g_cacheSrc[i]=1;                 // the row moved: copy back
           }
         g_rawScratch[i].uid=g_posCache[matchIdx].uid;
         g_rawScratch[i].cmt=g_posCache[matchIdx].cmt;   // carried, not re-read
         if(StringLen(g_rawScratch[i].uid)==0 && MagicToSender(g_rawScratch[i].magic)>=0)
           {
            //--- Broker was slow to write comment; recover it on fast path if UID is still missing
            g_rawScratch[i].cmt=CopierReadCommentByTicket(g_rawScratch[i]);
            g_rawScratch[i].uid=ResolveUid(g_rawScratch[i]);
            if(matchIdx==i)
              {
               g_posCache[i].cmt=g_rawScratch[i].cmt;
               g_posCache[i].uid=g_rawScratch[i].uid;
              }
            else
              {
               g_posCacheNext[i].cmt=g_rawScratch[i].cmt;
               g_posCacheNext[i].uid=g_rawScratch[i].uid;
              }
           }
         g_acctAllPos[i]=g_rawScratch[i];
        }
      else
        {
         //--- SLOW PATH: resolve UID on ticket change or numeric change
         g_cacheSrc[i]=1;                  // the next row is rebuilt from scratch
         if(!forceFullScan) g_rawScratch[i].cmt=CopierReadCommentByTicket(g_rawScratch[i]);
         string uid=ResolveUid(g_rawScratch[i]);
         g_rawScratch[i].uid=uid;
         g_acctAllPos[i]=g_rawScratch[i];

         int oursSi=MagicToSender(g_rawScratch[i].magic);
         bool isOurs=(oursSi>=0);
         bool orphan=(!isOurs && StringLen(CopierUidFromComment(g_rawScratch[i].cmt))>0);

         //--- Keep the durable UID <-> ticket map current - but only here.
         //--- LocalForSender used to Upsert every position on every tick,
         //--- which is a 2048-slot scan per position per tick to write the
         //--- same values back, and the 10-second SaveReceiverMap rebuilds
         //--- the whole table anyway. "This row is new or changed" is the only
         //--- moment the map can actually need an update.
         if(isOurs && StringLen(uid)==CP_UID_LEN)
           {
            CopierPos rec=g_rawScratch[i];
            rec.uid=uid;
            g_recKnown.Upsert(rec);

            //--- A mirror that EXISTS was opened by this receiver, so record
            //--- it for the ReopenClosedMirrors guard.
            //---
            //--- Skipped outright when a state file was restored at startup:
            //--- OnInit already seeded g_everOpened from it, and that ring IS
            //--- "the mirrors this receiver holds". Re-checking it here costs
            //--- a 4096-slot scan per row, over every row, on every 30-second
            //--- full revalidation - 1.2 million iterations at 300 positions.
            //--- Without a state file nothing was seeded, so the backfill is
            //--- the only thing standing in for it and must run.
            if(!g_stateRestored)
              {
               string openKey=g_sid[oursSi]+":"+(string)CP_ACT_OPEN+":"+uid;
               if(!g_everOpened.Has(openKey)) g_everOpened.Add(openKey);
              }
           }

         g_posCacheNext[i].ticket   =g_rawScratch[i].ticket;
         g_posCacheNext[i].magic    =g_rawScratch[i].magic;
         g_posCacheNext[i].side     =g_rawScratch[i].side;
         g_posCacheNext[i].lots     =g_rawScratch[i].lots;
         g_posCacheNext[i].openPx   =g_rawScratch[i].openPx;
         g_posCacheNext[i].sl       =g_rawScratch[i].sl;
         g_posCacheNext[i].tp       =g_rawScratch[i].tp;
         g_posCacheNext[i].openTime =g_rawScratch[i].openTime;
         g_posCacheNext[i].kind     =g_rawScratch[i].kind;
         g_posCacheNext[i].ptype    =g_rawScratch[i].ptype;
         g_posCacheNext[i].pprice   =g_rawScratch[i].pprice;
         g_posCacheNext[i].pstop    =g_rawScratch[i].pstop;
         g_posCacheNext[i].pexpire  =g_rawScratch[i].pexpire;
         g_posCacheNext[i].uid      =uid;
         g_posCacheNext[i].cmt      =g_rawScratch[i].cmt;
         g_posCacheNext[i].isOrphan =orphan;
        }
     }

   //--- Copy back ONLY the rows that actually differ. On a steady-state tick
   //--- (no order opened, closed, moved or re-priced) that is zero rows, so
   //--- the per-tick cost of the cache drops from `an` struct assignments with
   //--- four string refcounts each to `an` integer tests.
   //---
   //--- Invariant this relies on: for every i<an, g_posCacheNext[i] equals
   //--- g_posCache[i] at the end of each scan - either because it was copied,
   //--- or because it was never touched and already matched. The two places
   //--- that used to break it (a cmt refresh, a moved row) now write through
   //--- the same rule.
   for(int i=0;i<an;i++)
      if(g_cacheSrc[i]>0) g_posCache[i]=g_posCacheNext[i];
   // OPT-85-04: Clear string handles in vacated slots when position count contracts
   for(int i=an;i<g_posCacheCount;i++)
     {
      g_posCache[i].uid="";
      g_posCache[i].cmt="";
     }
   g_posCacheCount=an;

   return an;
  }

string EncodeReceiverPositions()
  {
   if(g_acctAllPosCount<=0) return "";
   CopierStrBuilder sb;
   int count=0;
   for(int i=0;i<g_acctAllPosCount;i++)
     {
      bool ours=(MagicToSender(g_acctAllPos[i].magic)>=0);
      int isManaged=ours?1:0;
      string cmt=g_acctAllPos[i].cmt;
      //--- P2-6: g_acctAllPos is already populated with live comments from CopierReadPositions.
      //--- Only fallback to ticket lookup if comment is empty, avoiding O(n^2) redundant scans.
      if(ours && StringLen(cmt)==0)
        {
         string liveCmt=CopierReadCommentByTicket(g_acctAllPos[i]);
         if(StringLen(liveCmt)>0)
           {
            cmt=liveCmt;
            g_acctAllPos[i].cmt=liveCmt;
            if(i<g_posCacheCount && g_posCache[i].ticket==g_acctAllPos[i].ticket)
               g_posCache[i].cmt=liveCmt;
           }
        }
      if(count>0) sb.Add(CP_SEP_REC);
      string rec=(string)g_acctAllPos[i].ticket+CP_SEP_ITEM
                 +CopierSanitizeSymbol(g_acctAllPos[i].sym)+CP_SEP_ITEM
                 +(string)g_acctAllPos[i].side+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].lots,CP_DIGITS_LOTS)+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].openPx,5)+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].sl,5)+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].tp,5)+CP_SEP_ITEM
                 +(string)g_acctAllPos[i].magic+CP_SEP_ITEM
                 +(string)isManaged+CP_SEP_ITEM
                 +CopierSanitizeComment(cmt)+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].profit,2)+CP_SEP_ITEM
                 +CopierFmtDouble(g_acctAllPos[i].swap,2)+CP_SEP_ITEM
                 +(string)g_acctAllPos[i].openTime;
      sb.Add(rec);
      count++;
      //--- CP_MAX_POSITIONS, not 128. 128 was a leftover from when the
      //--- position table itself was small: the receiver happily mirrors up to
      //--- 2048, and the dashboard then showed 128 rows next to a HELD= count
      //--- of 300 with nothing saying the list was cut. The whole list is
      //--- compressed on the wire (typically a few tens of KB), once a minute.
      if(count>=CP_MAX_POSITIONS) break;
     }
   return CopierCompressField(sb.Result());
  }

string EncodeReceiverWaitList()
  {
   CopierStrBuilder sb;
   int count=0;
   for(int i=0;i<g_qn;i++)
     {
      if(g_q[g_qHead+i].kind!=CP_ACT_OPEN) continue;
      if(count>0) sb.Add(CP_SEP_REC);
      // MQL-03: Use sender openPx for market orders, fallback to pprice for pending orders
      double qPx=(g_q[g_qHead+i].openPx>0.0)?g_q[g_qHead+i].openPx:g_q[g_qHead+i].pprice;
      string rec=g_q[g_qHead+i].uid+CP_SEP_ITEM
                 +CopierSanitizeSymbol(g_q[g_qHead+i].sym)+CP_SEP_ITEM
                 +(string)g_q[g_qHead+i].side+CP_SEP_ITEM
                 +CopierFmtDouble(g_q[g_qHead+i].lots,CP_DIGITS_LOTS)+CP_SEP_ITEM
                 +CopierFmtDouble(MathMax(0.0,qPx),5)+CP_SEP_ITEM
                 +"queued"+CP_SEP_ITEM
                 +"Queued in broker dispatch";
      sb.Add(rec);
      count++;
      if(count>=CP_MAX_POSITIONS) break;
     }
   for(int i=0;i<g_waitItemsCount;i++)
     {
      if(count>=CP_MAX_POSITIONS) break;
      if(count>0) sb.Add(CP_SEP_REC);
      string rec=g_waitItems[i].uid+CP_SEP_ITEM
                 +CopierSanitizeSymbol(g_waitItems[i].sym)+CP_SEP_ITEM
                 +(string)g_waitItems[i].side+CP_SEP_ITEM
                 +CopierFmtDouble(g_waitItems[i].lots,CP_DIGITS_LOTS)+CP_SEP_ITEM
                 +CopierFmtDouble(g_waitItems[i].openPx,5)+CP_SEP_ITEM
                 +g_waitItems[i].stage+CP_SEP_ITEM
                 +CopierSanitize(g_waitItems[i].reason,48);
      sb.Add(rec);
      count++;
     }
   return CopierCompressField(sb.Result());
  }

#endif // __COPIER_RECVRECONCILE_MQH__
