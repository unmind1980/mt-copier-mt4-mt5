//+------------------------------------------------------------------+
//| CopierSizing.mqh - lot conversion                                |
//|                                                                   |
//| MVP supports two modes only:                                      |
//|   CP_SIZE_MULTIPLIER  lots = senderLots * param * symbolMultiplier|
//|   CP_SIZE_FIXED       lots = param ( * symbolMultiplier )         |
//|                                                                   |
//| Sizing is always done on the RECEIVER, at receive time, from the  |
//| sender's reported volume - never from a size the sender decided.  |
//| The result is then snapped to the receiver broker's own           |
//| LOTSTEP / MINLOT / MAXLOT. Getting this wrong is landmine #3.     |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_SIZING_MQH__
#define __COPIER_SIZING_MQH__

#include "CopierDefs.mqh"
#include "CopierModel.mqh"

#define CP_SIZE_MULTIPLIER 0
#define CP_SIZE_FIXED      1
//--- Pass the sender's volume through unchanged. Distinct from MULTIPLIER
//--- with param 1.0 only in what it says: "do not adjust" is a clearer
//--- statement than "multiply by one", and it cannot be broken later by
//--- someone editing LotParam.
#define CP_SIZE_OFF        2

//--- THE INPUT DROPDOWN USES THESE SAME NUMBERS. There is one numbering now.
//---
//--- It did not always. The dialog had its own (0=off 1=multiplier 2=fixed)
//--- with a mapping function between the two, on the theory that the dialog's
//--- order was friendlier to read. That was a latent bug with three separate
//--- ways to bite:
//---
//---   * anything carrying the RAW value - a saved .set, a chart template -
//---     meant one thing at the input and another in the code;
//---   * the central hub has to write `lotmode=` into copier.ini, and a number
//---     written from the dialog's numbering would be read back under the
//---     internal one, silently sizing every mirror by the wrong rule;
//---   * both numberings happened to use 1 for "multiplier", which is exactly
//---     the coincidence that lets a plain cast pass a smoke test and still be
//---     wrong for the other two.
//---
//--- The dialog still SHOWS Off / Multiplier / Fixed in that order; the enum
//--- in the EA assigns the values explicitly, so display order and numbering
//--- are independent concerns.
//---
//--- UPGRADE NOTE: with a saved input set, SenderLotMode=2 used to mean Fixed
//--- and now means Off. The startup log prints the effective mode in words, so
//--- this is visible on the first run - check it once.

//--- Is this one of the three known codes?
bool CopierLotModeValid(const int mode)
  {
   return (mode==CP_SIZE_MULTIPLIER || mode==CP_SIZE_FIXED || mode==CP_SIZE_OFF);
  }

//--- Normalise a mode from the EA input. Anything unrecognised becomes
//--- MULTIPLIER, the historical default. Kept as a function rather than used
//--- directly so there is ONE place that decides what an unknown value means.
int CopierLotModeInternal(const int mode)
  {
   return CopierLotModeValid(mode)?mode:CP_SIZE_MULTIPLIER;
  }

//--- `lotmode=` in copier.ini.
//---
//--- Accepts BOTH the historical words and the numeric codes, because the
//--- central hub will push a value and a number it writes must not fall back
//--- to multiplier in silence. An unrecognised word still falls back to
//--- multiplier, as it always has.
//---
//--- `recognised` reports whether the value was understood at all. Callers are
//--- expected to SAY SO when it was not: falling back is right, doing it
//--- quietly is the "sized by a rule you did not choose, and nothing said"
//--- failure this file is arranged to avoid.
int CopierLotModeFromText(const string raw,bool &recognised)
  {
   string m=CopierTrim(raw);
   //--- StringToLower modifies the string in-place by reference in MQL4/MQL5.
   StringToLower(m);

   if(m=="off")        { recognised=true; return CP_SIZE_OFF; }
   if(m=="fixed")      { recognised=true; return CP_SIZE_FIXED; }
   if(m=="multiplier") { recognised=true; return CP_SIZE_MULTIPLIER; }

   //--- the numeric form, in the SAME numbering the EA input uses
   if(m=="0") { recognised=true; return CP_SIZE_MULTIPLIER; }
   if(m=="1") { recognised=true; return CP_SIZE_FIXED; }
   if(m=="2") { recognised=true; return CP_SIZE_OFF; }

   recognised=false;
   return CP_SIZE_MULTIPLIER;
  }

//--- The mode in words, for a log line. A numeric code tells an operator
//--- nothing, and the upgrade note above is exactly the kind of thing that is
//--- only checkable if the effective setting is printed.
string CopierLotModeText(const int mode)
  {
   if(mode==CP_SIZE_OFF)   return "off (pass the sender's lots through)";
   if(mode==CP_SIZE_FIXED) return "fixed";
   return "multiplier";
  }

//--- how many decimals does the broker's volume step need?
int CopierLotDigits(const double step)
  {
   for(int d=0; d<=8; d++)
     {
      double scaled=step*MathPow(10,d);
      if(MathAbs(scaled-MathRound(scaled))<0.0000001) return d;
     }
   return 2;
  }

//--- snap DOWN to LOTSTEP and clamp to [0, MAXLOT].
//---
//--- It deliberately does NOT raise a too-small value up to MINLOT.
//--- Doing that destroys the very information the caller needs: after
//--- clamping, "below the broker minimum" and "exactly the broker
//--- minimum" are indistinguishable, so a signal that should have been
//--- rejected would instead be placed at the minimum lot - silently
//--- multiplying the risk on a small account. The minimum-lot decision
//--- belongs to CopierComputeLots(), which can still see the shortfall.
double CopierNormalizeLot(const double lots,const CopierSymInfo &si)
  {
   if(lots<=0.0) return 0.0;
   int digits=CopierLotDigits(si.lotStep);
   double steps=MathFloor(lots/si.lotStep+0.0000001);
   double v=NormalizeDouble(steps*si.lotStep,digits);
   if(v<0.0) v=0.0;
   if(v>si.maxLot)
     {
      //--- floor the cap to a whole number of steps too, otherwise we
      //--- hand the broker a volume that is not on its lot grid
      double capSteps=MathFloor(si.maxLot/si.lotStep+0.0000001);
      v=NormalizeDouble(capSteps*si.lotStep,digits);
     }
   return v;
  }

//--- returns the final lot size; sets rejected=true when the trade
//--- should be skipped rather than rounded up to the broker minimum
double CopierComputeLots(const double senderLots,const int mode,const double param,
                         const double symMultiplier,const CopierSymInfo &si,
                         const double minLots,const double maxLots,
                         bool &rejected)
  {
   rejected=false;
   double raw=0.0;
   if(mode==CP_SIZE_FIXED)               raw=param*symMultiplier;
   else if(mode==CP_SIZE_OFF)            raw=senderLots*symMultiplier;
   else                                  raw=senderLots*param*symMultiplier;
   if(raw<=0.0) { rejected=true; return 0.0; }

   double v=CopierNormalizeLot(raw,si);
   if(v<=0.0) { rejected=true; return 0.0; }

   //--- below broker minimum after conversion: skip, do NOT round up.
   //--- Rounding up silently multiplies risk on small accounts.
   if(v<si.minLot) { rejected=true; return 0.0; }

   if(minLots>0.0 && v<minLots) { rejected=true; return 0.0; }
   if(maxLots>0.0 && v>maxLots) v=CopierNormalizeLot(maxLots,si);
   return v;
  }

//=====================================================================
// Push a stop/limit price out until it clears the broker's minimum
// distance from the market.
//
// Both terminals reject a stop closer than SYMBOL_TRADE_STOPS_LEVEL
// (MT4 #130 / MT5 10016), and MT5 rejects the WHOLE OrderSend rather than
// just the stop - so an unclamped stop does not merely fail to protect the
// position, it can stop the position existing at all. That was already
// true of EmergencySLPips before this helper existed.
//
// Clamping WIDENS the stop, which is the safe direction: the position
// lives longer instead of being stopped out early. It also resolves the
// "already past its stop" case correctly - a stop the market has run
// through gets clamped to the closest distance the broker allows, so the
// position exits almost immediately, which is what the sender's position
// did too.
//
// `clamped` reports that it happened, so the divergence is logged once
// rather than hidden.
//
// `marketPx` must be the price the position would CLOSE at - bid for a
// buy, ask for a sell - because that is what the broker measures the
// minimum against. CopierFitStop() below fetches it; this variant takes it
// as an argument so the arithmetic can be tested without a live symbol.
//=====================================================================
double CopierFitStopAt(const double px,const int side,const bool isSl,
                       const double marketPx,const CopierSymInfo &si,
                       bool &clamped)
  {
   clamped=false;
   if(px<=0.0) return 0.0;
   if(marketPx<=0.0) return NormalizeDouble(px,si.digits);
   if(si.stopLevel<=0.0) return NormalizeDouble(px,si.digits);

   //--- which way is "further from the market"?
   //---   a buy's stop-loss, and a sell's take-profit, sit BELOW the market
   bool below=(isSl ? (side==CP_SIDE_BUY) : (side==CP_SIDE_SELL));

   double out=px;
   if(below)
     {
      double minPx=marketPx-si.stopLevel;
      if(out>minPx) { out=minPx; clamped=true; }
     }
   else
     {
      double minPx=marketPx+si.stopLevel;
      if(out<minPx) { out=minPx; clamped=true; }
     }
   return NormalizeDouble(out,si.digits);
  }

//--- convenience wrapper: fetch the close price and delegate. If the price
//--- cannot be read the value is returned untouched rather than guessed at;
//--- the broker then rejects it and the failure is visible in the log,
//--- which beats silently moving a stop based on a stale quote.
double CopierFitStop(const double px,const string sym,const int side,
                     const bool isSl,const CopierSymInfo &si,bool &clamped)
  {
   double marketPx=0.0;
   if(!CopierGetClosePrice(sym,side,marketPx))
     {
      clamped=false;
      return NormalizeDouble(px,si.digits);
     }
   return CopierFitStopAt(px,side,isSl,marketPx,si,clamped);
  }

//=====================================================================
// Optional safety net. Off by default (EmergencySLPips=0) per the
// agreed design: on sender disconnect we stop new entries and keep
// existing positions, without forcing a close. Turning this on makes
// every copied position carry a local stop as a backstop.
//=====================================================================
double CopierEmergencySl(const string sym,const int side,const double openPx,
                         const double slPips,const CopierSymInfo &si,int &outErr)
  {
   outErr=0;
   if(slPips<=0.0) return 0.0;
   double px=0.0;
   if(!CopierGetPrice(sym,side,px)) { outErr=-2; return 0.0; }
   double ref=(openPx>0.0)?openPx:px;
   //--- pip = 10 points on 3/5-digit FX, 1 point elsewhere. This is a
   //--- heuristic; override with CustomPipSizes if your broker differs.
   double pipSize=(si.digits==3 || si.digits==5)?si.point*10.0:si.point;
   double sl=(side==CP_SIDE_BUY)?(ref-slPips*pipSize):(ref+slPips*pipSize);
   //--- clear the broker's minimum distance. Without this a small
   //--- EmergencySLPips makes every OrderSend fail outright on MT5, since
   //--- the stop is part of the opening request.
   bool clamped=false;
   return CopierFitStop(NormalizeDouble(sl,si.digits),sym,side,true,si,clamped);
  }

#endif
//+------------------------------------------------------------------+
