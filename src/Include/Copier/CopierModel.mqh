//+------------------------------------------------------------------+
//| CopierModel.mqh - the MT4 / MT5 platform adapter                 |
//|                                                                   |
//| THIS IS THE ONLY FILE (besides CopierDefs.mqh) THAT MAY CONTAIN   |
//| #ifdef __MQL5__. Everything above it works on the normalised      |
//| CopierPos model. MT4 is order-based and has no trade events; MT5  |
//| is position-based and its events are unreliable. Both are made to |
//| look identical here.                                              |
//|                                                                   |
//| Rules encoded below:                                              |
//|  * MT4: no OnTrade/OnTradeTransaction -> caller must poll.        |
//|  * MT5: OnTradeTransaction is used ONLY as a "state is dirty"     |
//|    flag. A single market order fires 6-7 transactions, order is   |
//|    not guaranteed, the 1024-deep queue drops under load, and the  |
//|    position can be visible before deal history is queryable. So   |
//|    we never trust the transaction payload - we re-read state.     |
//|  * Identity: MT4 order ticket / MT5 POSITION_IDENTIFIER (never    |
//|    POSITION_TICKET, which changes on partial close).              |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_MODEL_MQH__
#define __COPIER_MODEL_MQH__

#include "CopierDefs.mqh"
#ifdef __MQL5__
#include <Trade/Trade.mqh>
#endif

struct CopierSymInfo
  {
   double            point;
   int               digits;
   double            minLot;
   double            maxLot;
   double            lotStep;
   double            stopLevel;   // in price units, not points
   double            freezeLevel; // in price units, not points
   double            tickSize;
   double            contractSize;
   string            sym;

   void CopierSymInfo()
     {
      point=0.0;
      digits=0;
      minLot=0.0;
      maxLot=0.0;
      lotStep=0.0;
      stopLevel=0.0;
      freezeLevel=0.0;
      tickSize=0.0;
      contractSize=0.0;
      sym="";
     }
  };

//--- The pip size, in price units.
//---
//--- ONE definition, on purpose. This rule was written out inline in four
//--- places - CopierEmergencySl, CopierEmergencyTp, the profit-pullback gate
//--- in ConvergeSender, and the receiver's own PipSize() - and every one of
//--- them had to agree, because a stop placed at "50 pips" means something
//--- different on a 3-digit JPY pair and a 5-digit EURUSD. Four copies of a
//--- heuristic is a guarantee that a future change updates three of them.
//---
//--- It is a HEURISTIC by nature: the real pip depends on the broker's
//--- quoting, which is exactly why it lives in exactly one place now.
double CopierPipOf(const CopierSymInfo &si)
  {
   // R6-D3-03 & D-07: Commodities (Gold/Silver) & Crypto/Indices pip scaling
   if(StringFind(si.sym,"XAU")>=0 || StringFind(si.sym,"GOLD")>=0)
      return (si.digits==3) ? si.point*100.0 : (si.digits==2 ? si.point*10.0 : 0.10);
   if(StringFind(si.sym,"XAG")>=0 || StringFind(si.sym,"SILVER")>=0)
      return (si.digits==3) ? si.point*10.0 : si.point;
   // Indices & Crypto: 1 pip = 1.0 price unit
   if(StringFind(si.sym,"BTC")>=0 || StringFind(si.sym,"ETH")>=0 ||
      StringFind(si.sym,"SOL")>=0 || StringFind(si.sym,"XRP")>=0 || StringFind(si.sym,"LTC")>=0 ||
      StringFind(si.sym,"US30")>=0 || StringFind(si.sym,"WS30")>=0 || StringFind(si.sym,"DJ30")>=0 || StringFind(si.sym,"DJI")>=0 || StringFind(si.sym,"DJIA")>=0 || StringFind(si.sym,"DJX")>=0 ||
      StringFind(si.sym,"US500")>=0 || StringFind(si.sym,"SPX500")>=0 || StringFind(si.sym,"SP500")>=0 ||
      StringFind(si.sym,"NAS100")>=0 || StringFind(si.sym,"USTEC")>=0 || StringFind(si.sym,"US100")>=0 ||
      StringFind(si.sym,"GER40")>=0 || StringFind(si.sym,"DE40")>=0 || StringFind(si.sym,"GER30")>=0 || StringFind(si.sym,"DE30")>=0 || StringFind(si.sym,"DAX")>=0 ||
      StringFind(si.sym,"UK100")>=0 || StringFind(si.sym,"FTSE")>=0 ||
      StringFind(si.sym,"JP225")>=0 || StringFind(si.sym,"NI225")>=0 || StringFind(si.sym,"HK50")>=0)
      return (si.point>0.0 ? 1.0 : 1.0);
   if(si.digits<=1) return (si.point>0.0 ? si.point : 1.0);
   return (si.digits==3 || si.digits==5) ? si.point*10.0 : si.point;
  }

// R6-D10-01: Discrete-tick rounding utility for non-forex instruments
double CopierRoundToTick(const double price, const CopierSymInfo &si)
  {
   if(si.tickSize<=0.0) return NormalizeDouble(price, si.digits);
   return NormalizeDouble(MathRound(price / si.tickSize) * si.tickSize, si.digits);
  }

// R7-D1-02 & D-10: Normalize deviation points across 2/3/4/5-digit symbols
int CopierScaleDeviationPoints(const string sym,const int devPoints)
  {
   if(devPoints<=0) return 0;
   CopierSymInfo si;
   if(!CopierGetSymbolInfo(sym,si)) return devPoints;
   double pipSize=CopierPipOf(si);
   if(pipSize<=0.0 || si.point<=0.0) return devPoints;
   int pointsPerPip=(int)MathRound(pipSize/si.point);
   if(pointsPerPip<=1) return MathMax(1,(int)MathRound((double)devPoints/10.0));
   if(pointsPerPip>10) return MathMax(1,(int)MathRound((double)devPoints*((double)pointsPerPip/10.0)));
   return devPoints;
  }

//=====================================================================
// Symbol helpers
//=====================================================================
bool CopierSymbolEnsure(const string sym)
  {
#ifdef __MQL5__
   return SymbolSelect(sym,true);
#else
   if(SymbolSelect(sym,true)) return true;
   return MarketInfo(sym,MODE_ASK)>0.0;
#endif
  }

#define CP_SYMINFO_CACHE_SLOTS 64
struct CopierSymInfoCacheEntry
  {
   string         sym;
   CopierSymInfo  si;
   long           expMs;
  };
static CopierSymInfoCacheEntry g_siCache[CP_SYMINFO_CACHE_SLOTS];

bool CopierGetSymbolInfo(const string sym,CopierSymInfo &si)
  {
   if(StringLen(sym)==0) return false;
   // ISSUE-13 / O-01: Direct-mapped 64-slot cache with 30s TTL
   // Eliminates 99.9% of redundant system API calls in high-position converge passes.
   long now=CopierNowMs();
   uint h=2166136261;
   int slen=StringLen(sym);
   for(int k=0;k<slen;k++) { h^=(uint)StringGetCharacter(sym,k); h*=16777619; }
   int slot=(int)(h % CP_SYMINFO_CACHE_SLOTS);
   if(g_siCache[slot].sym==sym && now<g_siCache[slot].expMs)
     {
      si=g_siCache[slot].si;
      return true;
     }

#ifdef __MQL5__
   if(!SymbolInfoDouble(sym,SYMBOL_POINT,si.point)) return false;
   si.digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN,si.minLot);
   SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX,si.maxLot);
   SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP,si.lotStep);
   //--- STOPS_LEVEL is an INTEGER property, not a double one. Asking for
   //--- it through SymbolInfoDouble is a compile error, and silently
   //--- getting it wrong would mean placing stops inside the broker's
   //--- minimum distance (MT4 #130 / MT5 10016).
   long lvl=0;
   SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL,lvl);
   si.stopLevel=(double)lvl*si.point;
   long fLvl=0;
   SymbolInfoInteger(sym,SYMBOL_TRADE_FREEZE_LEVEL,fLvl);
   si.freezeLevel=(double)fLvl*si.point;
   SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE,si.tickSize);
   SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE,si.contractSize);
#else
   si.point=MarketInfo(sym,MODE_POINT);
   si.digits=(int)MarketInfo(sym,MODE_DIGITS);
   si.minLot=MarketInfo(sym,MODE_MINLOT);
   si.maxLot=MarketInfo(sym,MODE_MAXLOT);
   si.lotStep=MarketInfo(sym,MODE_LOTSTEP);
   si.stopLevel=MarketInfo(sym,MODE_STOPLEVEL)*si.point;
   si.freezeLevel=MarketInfo(sym,MODE_FREEZELEVEL)*si.point;
   si.tickSize=MarketInfo(sym,MODE_TICKSIZE);
   si.contractSize=MarketInfo(sym,MODE_LOTSIZE);
#endif
   si.sym=sym;
   if(si.point<=0.0)      return false;
   if(si.digits<0)        si.digits=5;
   if(si.minLot<=0.0)     si.minLot=0.01;
   if(si.maxLot<=0.0)     si.maxLot=100.0;
   if(si.lotStep<=0.0)    si.lotStep=0.01;
   if(si.stopLevel<0.0)   si.stopLevel=0.0;
   if(si.freezeLevel<0.0) si.freezeLevel=0.0;
   if(si.tickSize<=0.0)   si.tickSize=si.point;
   if(si.contractSize<=0.0) si.contractSize=100000.0;

   g_siCache[slot].sym=sym;
   g_siCache[slot].si=si;
   g_siCache[slot].expMs=now+30000;
   return true;
  }

// N-05: Explicit invalidation of syminfo cache on broker rejections (10016 / 130)
void CopierInvalidateSymbolInfo(const string sym)
  {
   if(StringLen(sym)==0) return;
   uint h=2166136261;
   int slen=StringLen(sym);
   for(int k=0;k<slen;k++) { h^=(uint)StringGetCharacter(sym,k); h*=16777619; }
   int slot=(int)(h % CP_SYMINFO_CACHE_SLOTS);
   if(g_siCache[slot].sym==sym) g_siCache[slot].expMs=0;
  }

// BUG-04: Full invalidation of symbol cache on OnInit to prevent stale specifications
void CopierSymInfoReset()
  {
   for(int i=0;i<CP_SYMINFO_CACHE_SLOTS;i++)
     {
      g_siCache[i].sym="";
      g_siCache[i].expMs=0;
     }
  }

//+------------------------------------------------------------------+
// M1 bar counting.
//
// Bars, not minutes. A bar only exists while the market is OPEN, so a
// weekend, a holiday or a session break does not advance the count - which is
// the whole reason both a minutes parameter and a bars parameter exist. "Wait
// 5 minutes" and "wait 5 M1 bars" are the same thing at 10am on a Tuesday and
// completely different things at 5pm on a Friday.
//+------------------------------------------------------------------+
//--- Open time of the M1 bar `shift` back from the newest, or 0 if the
//--- terminal cannot supply it (no history yet, symbol not in Market Watch).
//---
//--- MQL4 has iTime() natively. MQL5 does NOT - it only appears there as an
//--- MQL4-compatibility shim in Functions.mqh, and relying on that include is
//--- exactly the kind of thing that compiles on one platform and not the
//--- other. CopyTime is the native MQL5 call.
datetime CopierM1BarTime(const string sym,const int shift)
  {
#ifdef __MQL5__
   datetime t[];
   if(CopyTime(sym,PERIOD_M1,shift,1,t)!=1) return 0;
   return t[0];
#else
   return (datetime)iTime(sym,PERIOD_M1,shift);
#endif
  }

//--- How many of the first `n` bar times are strictly after `from`?
//---
//--- Pure, and separated from the terminal call on purpose: the counting is
//--- the part with the off-by-one in it, and it should be testable without
//--- needing a symbol, history or a live terminal.
//---
//--- The cap is not just a safety rail, it is the optimisation: callers only
//--- ever ask "has it reached N?", so the loop stops at N rather than walking
//--- a day of bars on every pass for every position.
//---
//--- Returns 0 when `from` is unusable, which callers must read as "cannot
//--- measure" and not as "no time has passed".
int CopierCountBarsAfter(const datetime &times[],const int n,
                         const datetime from,const int cap)
  {
   if(from<=0 || cap<=0) return 0;
   int c=0;
   for(int i=0;i<n && i<cap;i++)
     {
      if(times[i]<=0)    break;   // no history / not in Market Watch
      if(times[i]<=from) break;   // reached the bar that was current at `from`
      c++;
     }
   return c;
  }

//--- How many M1 bars have opened strictly after `from` on this terminal.
int CopierM1BarsSince(const string sym,const datetime from,const int cap)
  {
   if(from<=0 || cap<=0) return 0;

   datetime times[];
#ifdef __MQL5__
   ArraySetAsSeries(times,true);
   int got=CopyTime(sym,PERIOD_M1,0,cap,times);
   if(got<=0) return 0;
   return CopierCountBarsAfter(times,got,from,cap);
#else
   ArrayResize(times,cap);
   for(int i=0;i<cap;i++) times[i]=CopierM1BarTime(sym,i);
   return CopierCountBarsAfter(times,cap,from,cap);
#endif
  }

bool CopierGetPrice(const string sym,const int side,double &px)
  {
#ifdef __MQL5__
   MqlTick tick;
   if(!SymbolInfoTick(sym,tick)) return false;
   px=(side==CP_SIDE_BUY)?tick.ask:tick.bid;
#else
   RefreshRates();
   px=(side==CP_SIDE_BUY)?MarketInfo(sym,MODE_ASK):MarketInfo(sym,MODE_BID);
#endif
   return px>0.0;
  }

//=====================================================================
// The price a position of this side would CLOSE at: bid for a buy, ask
// for a sell.
//
// This is the opposite side of the spread from CopierGetPrice(), and it is
// the one that matters for stops: SYMBOL_TRADE_STOPS_LEVEL is measured
// from the current close price, so checking a buy's stop against the ask
// would under-state the distance by the spread and let through a stop the
// broker then rejects (MT4 #130 / MT5 10016).
//=====================================================================
bool CopierGetClosePrice(const string sym,const int side,double &px)
  {
#ifdef __MQL5__
   MqlTick tick;
   if(!SymbolInfoTick(sym,tick)) return false;
   px=(side==CP_SIDE_BUY)?tick.bid:tick.ask;
#else
   RefreshRates();
   px=(side==CP_SIDE_BUY)?MarketInfo(sym,MODE_BID):MarketInfo(sym,MODE_ASK);
#endif
   return px>0.0;
  }

bool CopierIsConnected()
  {
#ifdef __MQL5__
   return (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
#else
   return (bool)IsConnected();
#endif
  }

//=====================================================================
// R4-D3-01: Cross-currency conversion rate between two account currencies.
// Returns multiplier: valueInToCcy = valueInFromCcy * rate.
//=====================================================================
//=====================================================================
// Currency cross rate with broker suffix resolution
//=====================================================================
string CopierResolveCrossSymbol(const string pair,const string extraSuffix="")
  {
   if(CopierSymbolEnsure(pair)) return pair;
   if(StringLen(extraSuffix)>0)
     {
      string custom=pair+extraSuffix;
      if(CopierSymbolEnsure(custom)) return custom;
      if(StringSubstr(extraSuffix,0,1)!=".")
        {
         string customDot=pair+"."+extraSuffix;
         if(CopierSymbolEnsure(customDot)) return customDot;
        }
     }
   string sfx[]={"m",".r","pro",".pro",".ecn","ecn","+","_i","c","i",".c",".raw","_std"};
   for(int i=0;i<ArraySize(sfx);i++)
     {
      string cand=pair+sfx[i];
      if(CopierSymbolEnsure(cand)) return cand;
     }
   return "";
  }

double CopierGetCurrencyCrossRate(const string fromCcyRaw,const string toCcyRaw,const string extraSuffix="")
  {
   string fromCcy=CopierTrim(fromCcyRaw);
   string toCcy=CopierTrim(toCcyRaw);
   StringToUpper(fromCcy);
   StringToUpper(toCcy);
   if(fromCcy==toCcy || StringLen(fromCcy)==0 || StringLen(toCcy)==0) return 1.0;

   // Direct pair: fromCcy + toCcy (e.g. USDJPY -> 1 USD = px JPY)
   string direct=CopierResolveCrossSymbol(fromCcy+toCcy,extraSuffix);
   if(StringLen(direct)>0)
     {
      double px=0.0;
      if(CopierGetPrice(direct,CP_SIDE_SELL,px) && px>0.0) return px;
     }

   // Inverted pair: toCcy + fromCcy (e.g. EURUSD -> 1 EUR = px USD -> 1 USD = 1/px EUR)
   string inverted=CopierResolveCrossSymbol(toCcy+fromCcy,extraSuffix);
   if(StringLen(inverted)>0)
     {
      double px=0.0;
      if(CopierGetPrice(inverted,CP_SIDE_BUY,px) && px>0.0) return 1.0/px;
     }

   // Intermediate via USD
   if(fromCcy!="USD" && toCcy!="USD")
     {
      double r1=CopierGetCurrencyCrossRate(fromCcy,"USD",extraSuffix);
      double r2=CopierGetCurrencyCrossRate("USD",toCcy,extraSuffix);
      if(r1>0.0 && r2>0.0) return r1*r2;
     }

   // Intermediate via EUR fallback
   if(fromCcy!="EUR" && toCcy!="EUR")
     {
      double r1=CopierGetCurrencyCrossRate(fromCcy,"EUR",extraSuffix);
      double r2=CopierGetCurrencyCrossRate("EUR",toCcy,extraSuffix);
      if(r1>0.0 && r2>0.0) return r1*r2;
     }

   return 0.0;
  }

//=====================================================================
// MT5: POSITION_IDENTIFIER is stable but PositionClose needs the
// CURRENT position ticket. Resolve at execution time - never cache it.
//=====================================================================
bool CopierResolveCloseTicket(const long identifier,long &ticket,bool &isPending,const int preferredKind=-1)
  {
   ticket=0;
   isPending=false;
#ifdef __MQL5__
   // If caller explicitly requested a pending order, search OrdersTotal() ONLY
   if(preferredKind==CP_ORD_PENDING)
     {
      int ot=OrdersTotal();
      for(int i=0;i<ot;i++)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0) continue;
         if((long)tk!=identifier) continue;
         if(!OrderSelect(tk)) continue;
         long ost=(long)OrderGetInteger(ORDER_STATE);
         if(ost!=ORDER_STATE_PLACED && ost!=ORDER_STATE_PARTIAL) continue;
         ticket=(long)tk;
         isPending=true;
         return true;
        }
      return false; // Strict match: do NOT fall through to positions!
     }

   // If caller explicitly requested a market position, search positions ONLY
   if(preferredKind==CP_ORD_MARKET)
     {
      if(identifier>0 && PositionSelectByTicket((ulong)identifier))
        {
         if((long)PositionGetInteger(POSITION_IDENTIFIER)==identifier)
           {
            ticket=identifier;
            return true;
           }
        }
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if((long)PositionGetInteger(POSITION_IDENTIFIER)==identifier)
           {
            ticket=(long)tk;
            return true;
           }
        }
      return false; // Strict match: do NOT fall through to working orders!
     }

   //--- M-03 fast path: In >95% of positions without partial fills, ticket == identifier.
   //--- Test directly via PositionSelectByTicket to avoid looping over PositionsTotal().
   if(identifier>0 && PositionSelectByTicket((ulong)identifier))
     {
      if((long)PositionGetInteger(POSITION_IDENTIFIER)==identifier)
        {
         ticket=identifier;
         return true;
        }
     }

   //--- positions first: POSITION_IDENTIFIER is stable, and it is what a
   //--- filled pending order's identifier becomes. PositionGetTicket(i) already
   //--- selects the position into terminal cache.
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if((long)PositionGetInteger(POSITION_IDENTIFIER)==identifier)
        {
         ticket=(long)tk;
         return true;
        }
     }
   //--- then WORKING pending orders. They live in the ORDERS list, are
   //--- addressed by their own ticket, and are not positions at all - so a
   //--- positions-only scan finds nothing and every pending cancel would be
   //--- reported as "already gone" while the order sat there.
   int ot=OrdersTotal();
   for(int i=0;i<ot;i++)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if((long)tk!=identifier) continue;
      if(!OrderSelect(tk)) continue;
      long ost=(long)OrderGetInteger(ORDER_STATE);
      if(ost!=ORDER_STATE_PLACED && ost!=ORDER_STATE_PARTIAL) continue;
      ticket=(long)tk;
      isPending=true;
      return true;
     }
   return false;
#else
   if(identifier<=0 || (ulong)identifier>0xFFFFFFFF) return false;
   if(!OrderSelect((int)(uint)identifier,SELECT_BY_TICKET,MODE_TRADES)) return false;
   // R47-01: OrderSelect by ticket ignores pool in MT4; closed orders in history must return false
   if(OrderCloseTime()!=0) return false;
   int t=(int)OrderType();
   isPending=(t!=OP_BUY && t!=OP_SELL);
   if(preferredKind==CP_ORD_PENDING && !isPending) return false;
   if(preferredKind==CP_ORD_MARKET && isPending) return false;
   ticket=identifier;
   return true;
#endif
  }

//--- convenience for the callers that do not care about the distinction
bool CopierResolveCloseTicket(const long identifier,long &ticket)
  {
   bool pending=false;
   return CopierResolveCloseTicket(identifier,ticket,pending,-1);
  }

double CopierTicketSL(const long ticket)
  {
   if(ticket<=0) return 0.0;
#ifdef __MQL5__
   long realTicket=0;
   bool isPending=false;
   if(CopierResolveCloseTicket(ticket,realTicket,isPending))
     {
      if(isPending)
        {
         if(OrderSelect((ulong)realTicket)) return OrderGetDouble(ORDER_SL);
        }
      else
        {
         if(PositionSelectByTicket((ulong)realTicket)) return PositionGetDouble(POSITION_SL);
        }
     }
   if(PositionSelectByTicket((ulong)ticket))
      return PositionGetDouble(POSITION_SL);
   if(OrderSelect((ulong)ticket))
      return OrderGetDouble(ORDER_SL);
   return 0.0;
#else
   if(OrderSelect((int)ticket,SELECT_BY_TICKET) && OrderCloseTime()==0)
      return OrderStopLoss();
   return 0.0;
#endif
  }

//=====================================================================
// Realised P&L (profit + swap + commission) on deals closed since
// `dayStart`, in server time.
//
// This exists so the daily-loss switch survives a restart. The obvious
// baseline - equity when the EA started - silently forgives the morning's
// losses if you reload the receiver at 3pm, which is precisely when the
// switch is supposed to matter.
//
// balance - realisedToday is the day's STARTING balance, and that quantity
// stays constant through the day: as losses accumulate the balance falls by
// the same amount the realised total does. So the caller can recompute it
// whenever it likes without drifting, and a restart lands on the same
// number.
//
// Walks history, so the caller must not call it per tick - once a minute
// and on a day change is plenty.
//--- N49-13: Returns outOk=false when HistorySelect fails (e.g. broker history unavailable)
//--- to prevent fail-open baseline wipeout in RefreshRisk.
//=====================================================================
double CopierRealizedToday(const long dayStart,bool &outOk)
  {
   outOk=true;
   double sum=0.0;
#ifdef __MQL5__
   datetime from=(datetime)dayStart;
   //--- the upper bound must be in the future: HistorySelect excludes
   //--- anything at or after it, and deals are stamped with server time
   datetime to=(datetime)(CopierServerTime()+86400);
   if(!HistorySelect(from,to)) { outOk=false; return 0.0; }
   int n=HistoryDealsTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=HistoryDealGetTicket(i);
      if(t==0) continue;
      long dtype=HistoryDealGetInteger(t,DEAL_TYPE);
      if(dtype==DEAL_TYPE_BALANCE || dtype==DEAL_TYPE_CREDIT || dtype==DEAL_TYPE_BONUS) continue;
      //--- profit and swap are zero on an entry deal, but commission is
      //--- charged there, so every deal is summed rather than only exits
      sum+=HistoryDealGetDouble(t,DEAL_PROFIT)
          +HistoryDealGetDouble(t,DEAL_SWAP)
          +HistoryDealGetDouble(t,DEAL_COMMISSION)
          +HistoryDealGetDouble(t,DEAL_FEE);
     }
#else
   if(!IsConnected()) { outOk=false; return 0.0; }
   int total=OrdersHistoryTotal();
   for(int i=total-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      int otype=OrderType();
      if(otype!=OP_BUY && otype!=OP_SELL) continue;
      if((long)OrderCloseTime()<dayStart) continue; // MT4 MODE_HISTORY order depends on UI sort; scan all entries
      sum+=OrderProfit()+OrderSwap()+OrderCommission();
     }
#endif
   return sum;
  }

double CopierRealizedToday(const long dayStart)
  {
   bool ok=true;
   return CopierRealizedToday(dayStart,ok);
  }

//--- Sum open-order commissions/swap on MT4 so cold-start/rollover cashFlow math stays symmetric
double CopierOpenCommissionsMT4()
  {
   double sum=0.0;
#ifndef __MQL5__
   int total=OrdersTotal();
   for(int i=0;i<total;i++)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      int ot=OrderType();
      if(ot!=OP_BUY && ot!=OP_SELL) continue;
      sum+=OrderCommission();
     }
#endif
   return sum;
  }

//--- midnight of the current server day, in server time
//--- R48-05: Use TimeToStruct to find local calendar day start, avoiding UTC modulo offset errors
long CopierServerDayStart()
  {
   datetime now=(datetime)CopierServerTime();
   if(now<=0) return 0;
   MqlDateTime dt;
   TimeToStruct(now,dt);
   dt.hour=0;
   dt.min=0;
   dt.sec=0;
   return (long)StructToTime(dt);
  }

//=====================================================================
// Read currently open MARKET positions into the normalised model.
// uid is left empty - the caller resolves identity (sender: from its
// own table by ticket; receiver: from the order comment).
//=====================================================================
//=====================================================================
// Pending-order type mapping. Kept here because it is the only part that
// needs the platform constants; everything above it speaks CP_PEND_*.
//
// An unmapped type returns 0 and is SKIPPED, never approximated. Mirroring
// a stop-limit as a plain stop would silently change the order the sender
// placed, which is worse than not mirroring it at all.
//=====================================================================
int CopierPendFromPlatformType(const long t)
  {
#ifdef __MQL5__
   if(t==ORDER_TYPE_BUY_LIMIT)      return CP_PEND_BUYLIMIT;
   if(t==ORDER_TYPE_SELL_LIMIT)     return CP_PEND_SELLLIMIT;
   if(t==ORDER_TYPE_BUY_STOP)       return CP_PEND_BUYSTOP;
   if(t==ORDER_TYPE_SELL_STOP)      return CP_PEND_SELLSTOP;
   if(t==ORDER_TYPE_BUY_STOP_LIMIT) return CP_PEND_BUYSTOPLIMIT;
   if(t==ORDER_TYPE_SELL_STOP_LIMIT)return CP_PEND_SELLSTOPLIMIT;
#else
   if(t==OP_BUYLIMIT)      return CP_PEND_BUYLIMIT;
   if(t==OP_SELLLIMIT)     return CP_PEND_SELLLIMIT;
   if(t==OP_BUYSTOP)       return CP_PEND_BUYSTOP;
   if(t==OP_SELLSTOP)      return CP_PEND_SELLSTOP;
#endif
   return 0;
  }

//--- The inverse, for placing.
long CopierPendToPlatformType(const int pt)
  {
#ifdef __MQL5__
   if(pt==CP_PEND_BUYLIMIT)      return ORDER_TYPE_BUY_LIMIT;
   if(pt==CP_PEND_SELLLIMIT)     return ORDER_TYPE_SELL_LIMIT;
   if(pt==CP_PEND_BUYSTOP)       return ORDER_TYPE_BUY_STOP;
   if(pt==CP_PEND_SELLSTOP)      return ORDER_TYPE_SELL_STOP;
   if(pt==CP_PEND_BUYSTOPLIMIT)  return ORDER_TYPE_BUY_STOP_LIMIT;
   if(pt==CP_PEND_SELLSTOPLIMIT) return ORDER_TYPE_SELL_STOP_LIMIT;
#else
   if(pt==CP_PEND_BUYLIMIT)      return OP_BUYLIMIT;
   if(pt==CP_PEND_SELLLIMIT)     return OP_SELLLIMIT;
   if(pt==CP_PEND_BUYSTOP)       return OP_BUYSTOP;
   if(pt==CP_PEND_SELLSTOP)      return OP_SELLSTOP;
   //--- MT4 has no stop-limit order type at all. Reported by the caller.
#endif
   return -1;
  }

//=====================================================================
// Place a pending order.
//
// The mirror is placed at the SAME trigger price the sender used, NOT a
// distance-adjusted one. That is the opposite of the stop-loss rule, and
// deliberately so: a stop's distance is the risk, but a pending order's
// price IS the trade. A buy limit 50 pips below is a different trade from
// one 20 pips below, so moving it to fit this broker's market would
// silently change what is being mirrored. If the price is not valid here
// the broker rejects it and the log says so, which is the honest outcome.
//
// Returns true on success; on failure outErr carries the broker's code.
//=====================================================================
bool CopierPlacePending(const CopierPos &p,const string sym,
                        const long magic,const int deviationPoints,
                        int &outErr)
  {
   outErr=0;
   if(p.kind!=CP_ORD_PENDING) { outErr=-3; return false; }
   if(!CopierPendingTypeKnown(p.ptype)) { outErr=-4; return false; }
   if(!CopierSymbolEnsure(sym)) { outErr=-1; return false; }

   CopierSymInfo si;
   if(!CopierGetSymbolInfo(sym,si)) { outErr=-2; return false; }

   string cmt=CopierCommentForUid(p.uid,p.ticket);
   double px=CopierRoundToTick(p.pprice,si);
   double stop=CopierRoundToTick(p.pstop,si);
   double sl=(p.sl>0.0)?CopierRoundToTick(p.sl,si):0.0;
   double tp=(p.tp>0.0)?CopierRoundToTick(p.tp,si):0.0;

#ifdef __MQL5__
   long pt=CopierPendToPlatformType(p.ptype);
   if(pt<0) { outErr=-4; return false; }

   // BUG-03: MT5 pending orders require ORDER_FILLING_RETURN per MT5 spec.
   // Fallback order: RETURN first (standard for pending orders), then FOK/IOC if supported.
   long fillMode=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING candidates[3];
   int nCand=0;
   candidates[nCand++]=ORDER_FILLING_RETURN;
   if((fillMode&SYMBOL_FILLING_FOK)!=0) candidates[nCand++]=ORDER_FILLING_FOK;
   if((fillMode&SYMBOL_FILLING_IOC)!=0) candidates[nCand++]=ORDER_FILLING_IOC;

   MqlTradeRequest req;
   MqlTradeResult  res;

   for(int attempt=0;attempt<nCand;attempt++)
     {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action      =TRADE_ACTION_PENDING;
      req.symbol      =sym;
      req.volume      =p.lots;
      req.type        =(ENUM_ORDER_TYPE)pt;
      req.price       =px;
      req.sl          =sl;
      req.tp          =tp;
      req.deviation   =(ulong)MathMax(0,deviationPoints);
      req.magic       =(ulong)magic;
      req.comment     =cmt;
      req.type_filling=candidates[attempt];
      if(CopierPendingNeedsStop(p.ptype)) req.stoplimit=stop;
      if(p.pexpire>0)
        {
         req.type_time =ORDER_TIME_SPECIFIED;
         req.expiration=(datetime)p.pexpire;
        }
      else
        {
         req.type_time =ORDER_TIME_GTC;
        }

      bool sent=OrderSend(req,res);
      if(sent && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED))
         return true;

      // 10022 (TRADE_RETCODE_INVALID_EXPIRATION): retry as GTC if broker rejects specified expiration
      if(res.retcode==10022 && req.type_time!=ORDER_TIME_GTC)
        {
         req.type_time=ORDER_TIME_GTC;
         req.expiration=0;
         sent=OrderSend(req,res);
         if(sent && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED))
            return true;
        }

      // 10030 (TRADE_RETCODE_INVALID_FILL): try next candidate
      if(res.retcode==10030 && attempt+1<nCand)
         continue;

      outErr=(int)res.retcode;
      return false;
     }

   outErr=(int)res.retcode;
   return false;
#else
   long pt=CopierPendToPlatformType(p.ptype);
   if(pt<0)
     {
      //--- MT4 has no stop-limit order type at all
      outErr=-4;
      return false;
     }
   int cmd=(int)pt;
   int safeMagic=(magic>2147483647 || magic<0)?(int)(magic & 0x7FFFFFFF):(int)magic;
   int ticket=OrderSend(sym,cmd,p.lots,px,MathMax(0,deviationPoints),sl,tp,cmt,
                        safeMagic,(datetime)p.pexpire,clrNONE);
   if(ticket<0)
     {
      int e=GetLastError();
      if(e==147 && p.pexpire>0) // ERR_TRADE_EXPIRATION_DENIED: retry as GTC
        {
         ticket=OrderSend(sym,cmd,p.lots,px,MathMax(0,deviationPoints),sl,tp,cmt,safeMagic,0,clrNONE);
         if(ticket>=0) return true;
         e=GetLastError();
        }
      outErr=e;
      return false;
     }
   return true;
#endif
  }

//=====================================================================
// Read currently open MARKET positions AND working pending orders into the
// normalised model.
//
// Pending orders travel the same path as positions on purpose: they are the
// same mirroring problem (create it, size it, remove it when the sender
// removes it), so they belong in the same table, the same desired set and
// the same record rather than in a parallel universe that would need its
// own converge loop.
//
// `kind` distinguishes them. uid is left empty - the caller resolves
// identity (sender: from its own table by ticket; receiver: from the order
// comment).
//=====================================================================
int CopierReadPositions(CopierPos &out[],const int maxOut,const bool readComment=true)
  {
   int n=0;
#ifdef __MQL5__
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(n>=maxOut)
        {
         Print("[copier] CRITICAL: Terminal positions exceed max capacity (",maxOut,"); table saturated, truncation occurred!");
         break;
        }

      CopierPos p;
      p.uid="";
      p.sym=PositionGetString(POSITION_SYMBOL);
      p.cmt=readComment ? PositionGetString(POSITION_COMMENT) : "";
      long type=(long)PositionGetInteger(POSITION_TYPE);
      p.side=(type==POSITION_TYPE_BUY)?CP_SIDE_BUY:CP_SIDE_SELL;
      p.lots=PositionGetDouble(POSITION_VOLUME);
      p.openPx=PositionGetDouble(POSITION_PRICE_OPEN);
      p.sl=PositionGetDouble(POSITION_SL);
      p.tp=PositionGetDouble(POSITION_TP);
      p.profit=PositionGetDouble(POSITION_PROFIT);
      p.swap=PositionGetDouble(POSITION_SWAP);
      //--- POSITION_IDENTIFIER is server-stable; POSITION_TICKET is not
      p.ticket=(long)PositionGetInteger(POSITION_IDENTIFIER);
      p.magic=(long)PositionGetInteger(POSITION_MAGIC);
      p.openTime=(long)PositionGetInteger(POSITION_TIME);
      p.kind=CP_ORD_MARKET;
      p.ptype=0; p.pprice=0.0; p.pstop=0.0; p.pexpire=0;
      p.initLots=0.0;   // N-03: receiver bookkeeping only
      p.used=true;
      //--- grow in chunks if dynamic; if fixed static buffer, check bounds
      if(n>=ArraySize(out))
        {
         if(ArrayIsDynamic(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
         else break;
        }
      out[n]=p;
      n++;
     }

   //--- pending orders live in the ORDERS list, not the POSITIONS list
   int ot=OrdersTotal();
   for(int i=0;i<ot;i++)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(!OrderSelect(tk)) continue;
      long ost=(long)OrderGetInteger(ORDER_STATE);
      if(ost!=ORDER_STATE_PLACED && ost!=ORDER_STATE_PARTIAL) continue;
      int pt=CopierPendFromPlatformType((long)OrderGetInteger(ORDER_TYPE));
      if(pt==0) continue;
      if(n>=maxOut)
        {
         Print("[copier] CRITICAL: Terminal positions exceed max capacity (",maxOut,"); table saturated, truncation occurred!");
         break;
        }

      CopierPos p;
      p.uid="";
      p.sym=OrderGetString(ORDER_SYMBOL);
      p.cmt=readComment ? OrderGetString(ORDER_COMMENT) : "";
      p.side=CopierPendingSide(pt);
      p.lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
      p.openPx=OrderGetDouble(ORDER_PRICE_OPEN);   // the trigger price
      p.sl=OrderGetDouble(ORDER_SL);
      p.tp=OrderGetDouble(ORDER_TP);
      p.profit=0.0;
      p.swap=0.0;
      //--- the ORDER ticket, which is also what the position's
      //--- POSITION_IDENTIFIER becomes when this order fills. That is what
      //--- carries the UID across activation without any extra machinery.
      p.ticket=(long)tk;
      p.magic=(long)OrderGetInteger(ORDER_MAGIC);
      p.openTime=(long)OrderGetInteger(ORDER_TIME_SETUP);
      p.kind=CP_ORD_PENDING;
      p.ptype=pt;
      p.pprice=OrderGetDouble(ORDER_PRICE_OPEN);
      p.pstop=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      p.pexpire=(long)OrderGetInteger(ORDER_TIME_EXPIRATION);
      ENUM_ORDER_TYPE_TIME tt=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      if(tt==ORDER_TIME_DAY && p.pexpire<=0)
        {
         datetime dayEnd=TimeCurrent() - (TimeCurrent()%86400) + 86399;
         p.pexpire=(long)dayEnd;
        }
      p.initLots=0.0;   // N-03: receiver bookkeeping only
      p.used=true;
      //--- grow in chunks if dynamic; if fixed static buffer, check bounds
      if(n>=ArraySize(out))
        {
         if(ArrayIsDynamic(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
         else break;
        }
      out[n]=p;
      n++;
     }
#else
   //--- MT4 keeps market and pending orders in one list, so this is a single
   //--- pass with a branch rather than two loops.
   int total=OrdersTotal();
   for(int i=0;i<total;i++)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderCloseTime()!=0) continue;              // already in history
      int type=(int)OrderType();
      if(n>=maxOut)
        {
         Print("[copier] CRITICAL: Terminal positions exceed max capacity (",maxOut,"); table saturated, truncation occurred!");
         break;
        }

      CopierPos p;
      p.uid="";
      p.sym=OrderSymbol();
      p.cmt=readComment ? OrderComment() : "";
      p.lots=OrderLots();
      p.openPx=OrderOpenPrice();
      p.sl=OrderStopLoss();
      p.tp=OrderTakeProfit();
      p.profit=OrderProfit();
      p.swap=OrderSwap();
      p.ticket=(long)(uint)OrderTicket();
      p.magic=(long)OrderMagicNumber();
      p.openTime=(long)OrderOpenTime();
      p.kind=CP_ORD_MARKET;
      p.ptype=0; p.pprice=0.0; p.pstop=0.0; p.pexpire=0;

      if(type==OP_BUY || type==OP_SELL)
        {
         p.side=(type==OP_BUY)?CP_SIDE_BUY:CP_SIDE_SELL;
        }
      else
        {
         int pt=CopierPendFromPlatformType(type);
         if(pt==0) continue;                          // not a type we mirror
         p.side=CopierPendingSide(pt);
         p.kind=CP_ORD_PENDING;
         p.ptype=pt;
         p.profit=0.0;
         p.swap=0.0;
         p.pprice=OrderOpenPrice();                   // the trigger price
         p.pstop=0.0;                                 // MT4 has no stop-limit
         p.pexpire=(long)OrderExpiration();
        }
      p.initLots=0.0;   // N-03: receiver bookkeeping only
      p.used=true;
      //--- grow in chunks if dynamic; if fixed static buffer, check bounds
      if(n>=ArraySize(out))
        {
         if(ArrayIsDynamic(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
         else break;
        }
      out[n]=p;
      n++;
     }
#endif
   return n;
  }

//=====================================================================
// The comment of ONE order, addressed by the identifier CopierPos carries.
//
// Exists so a caller can skip comments in the bulk scan and pay for them only
// on the rows that changed. The bulk path reads all of them; this reads one.
//
// MT5 needs the scan: CopierPos.ticket is POSITION_IDENTIFIER, which is not
// what PositionSelectByTicket() takes, and it is not the same number as
// POSITION_TICKET in general - matching on the identifier is the only correct
// lookup. Pending orders live in the ORDERS list and are addressed by their
// own ticket, so they are a direct select.
//
// Cost is one scan of the terminal's order list. It is only reached from the
// receiver's slow path (a row that is new, or whose numbers changed), so it
// runs for a handful of rows, not for the whole account.
//=====================================================================
string CopierReadCommentByTicket(const CopierPos &p)
  {
#ifdef __MQL5__
   if(p.kind==CP_ORD_MARKET)
     {
      // P2-6 Fast path: direct select by ticket first
      if(PositionSelectByTicket((ulong)p.ticket))
        {
         if((long)PositionGetInteger(POSITION_IDENTIFIER)==p.ticket)
            return PositionGetString(POSITION_COMMENT);
        }
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(!PositionSelectByTicket(tk)) continue;
         if((long)PositionGetInteger(POSITION_IDENTIFIER)!=p.ticket) continue;
         return PositionGetString(POSITION_COMMENT);
        }
      return "";
     }
   if(OrderSelect((ulong)p.ticket)) return OrderGetString(ORDER_COMMENT);
   return "";
#else
   if(p.ticket<=0 || (ulong)p.ticket>0xFFFFFFFF) return "";
   if(OrderSelect((int)(uint)p.ticket,SELECT_BY_TICKET) && OrderCloseTime()==0) return OrderComment();
   return "";
#endif
  }


//=====================================================================
// MT4 partial close / rollover / split ticket renumbering:
// The broker closes the old order and opens the remainder as a new
// ticket, annotating the comment (e.g. "from #<old>", "from#<old>",
// "split #<old>", "roll #<old>", "from <old>").
// Robust token & delimiter parsing ensures the UID is tracked across
// diverse MT4 broker bridges without string allocations.
//=====================================================================
long CopierMt4FromTicket(const string comment)
  {
   if(StringLen(comment)==0) return 0;
   string low=comment;
   //--- StringToLower modifies the string in-place by reference in MQL4/MQL5.
   StringToLower(low);

   // Search for broker ticket inheritance keywords
   int p=-1;
   int kwLen=0;
   int pFrom=StringFind(low,"from");
   int pSplit=StringFind(low,"split");
   int pRoll=StringFind(low,"roll");

   if(pFrom>=0)       { p=pFrom;  kwLen=4; }
   else if(pSplit>=0) { p=pSplit; kwLen=5; }
   else if(pRoll>=0)
     {
      p=pRoll;
      kwLen=(StringFind(low,"rollover")==pRoll)?8:4;
     }
   if(p<0) return 0;

   int i=p+kwLen;
   int n=StringLen(comment);

   // Skip whitespace
   while(i<n && (StringGetCharacter(comment,i)==' ' || StringGetCharacter(comment,i)=='\t')) i++;

   // Skip optional '#' or ':'
   if(i<n && (StringGetCharacter(comment,i)=='#' || StringGetCharacter(comment,i)==':'))
     {
      i++;
      while(i<n && (StringGetCharacter(comment,i)==' ' || StringGetCharacter(comment,i)=='\t')) i++;
     }

   // Extract contiguous digits
   int startDigits=i;
   while(i<n)
     {
      ushort c=StringGetCharacter(comment,i);
      if(c<'0' || c>'9') break;
      i++;
     }
   if(i<=startDigits) return 0;

   return CopierParseLongRange(comment,startDigits,i);
  }

//=====================================================================
// "There is no market to send to" - and the code differs by PLATFORM.
//
//   MT4: 132   (no result / market closed)
//   MT5: 10018 (TRADE_RETCODE_MARKET_CLOSED)
//
// This predicate exists because those two were checked in DIFFERENT places:
// the failure MESSAGE knew both, but the market-closed COOLDOWN only knew
// MT4's. So on MT5 the cooldown never armed, and every entry was retried
// every two seconds for a whole weekend - exactly the storm the cooldown was
// written to stop. Nothing looked wrong, because the log line said
// "market closed" the entire time.
//
// The general shape: a condition that is recognised in one place and acted on
// in another will eventually be recognised in one and not the other. One
// predicate, used by both.
//=====================================================================
bool CopierIsMarketClosed(const int err)
  {
   return (err==132 || err==10018);
  }

//=====================================================================
// "This terminal or account will not send orders right now"
//
//   MT4: 4109 (ERR_TRADE_DISABLED: AutoTrading off, or live trading not allowed in EA properties)
//   MT5: 10027 (TRADE_RETCODE_AUTOTRADING_DISABLED: AutoTrading button off)
//        10026 (TRADE_RETCODE_CLIENT_DISABLES_AT)
//        10017 (TRADE_RETCODE_TRADE_DISABLED: Trade disabled by broker/terminal)
//
// These represent a local or terminal-level state rather than a broker
// refusal of this specific order. The order is retried at the base rate
// without climbing the exponential backoff ladder, so turning AutoTrading
// back on resumes mirroring promptly rather than waiting out hours of backoff.
//=====================================================================
bool CopierIsTradeDisabled(const int err)
  {
   return (err==4109 || err==10027 || err==10026 || err==10017);
  }

#ifdef __MQL5__
//=====================================================================
// Helper: Execute a market DEAL via CTrade with 10030 (INVALID_FILL)
// native OrderSend fallback across FOK/IOC/RETURN candidates.
//=====================================================================
bool CopierMql5DealWithFilling(CTrade &trade,const string sym,const int side,const double lots,
                               const double sl,const double tp,const string comment,
                               const long magic,const int deviationPoints,
                               int &outErr,ulong &outOrder,ulong &outDeal)
  {
   outErr=0;
   outOrder=0;
   outDeal=0;
   bool ok=false;
   if(side==CP_SIDE_BUY) ok=trade.Buy(lots,sym,0.0,sl,tp,comment);
   else                  ok=trade.Sell(lots,sym,0.0,sl,tp,comment);
   uint rc=trade.ResultRetcode();
   if(!ok && (rc==TRADE_RETCODE_DONE_PARTIAL || rc==TRADE_RETCODE_PLACED))
      ok=true;
   if(ok)
     {
      outOrder=trade.ResultOrder();
      outDeal=trade.ResultDeal();
      return true;
     }
   // R2-D1-M02 & R11-A01: 10030 (TRADE_RETCODE_INVALID_FILL) candidate fallback using native OrderSend
   // Bypasses CTrade::PositionOpen's internal FillingCheck() which forcefully resets type_filling to FOK
   int lastErr=(int)rc;
   if(rc==10030)
     {
      long fillMode=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
      ENUM_ORDER_TYPE_FILLING candidates[3];
      int nCand=0;
      if((fillMode&SYMBOL_FILLING_FOK)!=0) candidates[nCand++]=ORDER_FILLING_FOK;
      if((fillMode&SYMBOL_FILLING_IOC)!=0) candidates[nCand++]=ORDER_FILLING_IOC;
      candidates[nCand++]=ORDER_FILLING_RETURN;
      MqlTradeRequest req;
      MqlTradeResult  res;
      for(int a=0; a<nCand; a++)
        {
         ZeroMemory(req);
         ZeroMemory(res);
         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = sym;
         req.volume       = lots;
         req.type         = (side==CP_SIDE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         req.price        = (side==CP_SIDE_BUY)?SymbolInfoDouble(sym,SYMBOL_ASK):SymbolInfoDouble(sym,SYMBOL_BID);
         req.sl           = sl;
         req.tp           = tp;
         req.deviation    = (deviationPoints > 0) ? (ulong)deviationPoints : 0;
         req.magic        = (ulong)magic;
         req.comment      = comment;
         req.type_filling = candidates[a];

         bool sent=OrderSend(req,res);
         lastErr=(int)res.retcode;
         if(sent && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL || res.retcode==TRADE_RETCODE_PLACED))
           {
            outOrder=res.order;
            outDeal=res.deal;
            return true;
           }
         if(res.retcode!=10030) break;
        }
     }
   outErr=(lastErr!=0)?lastErr:(int)trade.ResultRetcode();
   return false;
  }
#endif

//=====================================================================
// Open a market position.
// Returns true on success. On failure outErr carries the broker /
// terminal return code (MT5 retcode, MT4 GetLastError()).
//=====================================================================
bool CopierOpenMarket(const string sym,const int side,const double lots,
                      const double sl,const double tp,const string comment,
                      const long magic,const int deviationPoints,
                      int &outErr)
  {
   outErr=0;
   if(!CopierSymbolEnsure(sym)) { outErr=-1; return false; }

#ifdef __MQL5__
   CTrade trade;
   trade.SetExpertMagicNumber((ulong)magic);
   // N81-03: Guard against signed negative deviationPoints underflow to 18446744073709551615
   trade.SetDeviationInPoints(deviationPoints > 0 ? (ulong)deviationPoints : 0);
   trade.SetTypeFillingBySymbol(sym);
   trade.SetAsyncMode(false);
   ulong ord=0, deal=0;
   bool ok=CopierMql5DealWithFilling(trade,sym,side,lots,sl,tp,comment,magic,deviationPoints,outErr,ord,deal);
   if(!ok)
     {
      //--- DEF-61-02: TRADE_RETCODE_INVALID_STOPS (10016) fallback.
      //--- On ECN brokers or during spread/StopLevel widening, market orders with
      //--- non-zero SL/TP are rejected with 10016. Fall back to opening flat
      //--- (SL=0, TP=0) so the trade is not lost to exponential backoff, then
      //--- attempt immediate stop placement (and let converge re-clamp if needed).
      if(outErr==10016 && (sl>0.0 || tp>0.0))
        {
         int flatErr=0;
         ok=CopierMql5DealWithFilling(trade,sym,side,lots,0.0,0.0,comment,magic,deviationPoints,flatErr,ord,deal);
         if(ok)
           {
            outErr=0;
            // N71-08: In MT5, position identifier matches the initial order ticket (ResultOrder),
            // not the fill deal ticket (ResultDeal). Prioritize order over deal.
            ulong posId=(ord>0)?ord:deal;
            if(posId>0)
              {
               // BUG-02: Protect against crossed stops on fallback.
               // If stop already crossed market, do NOT hard-clamp to mkBid - mkStop (which causes instant stop-out)
               // and do not send invalid crossed stop to ECN zero stop-level broker (repeats 10016).
               // Set crossed stop to 0.0 and let converge/QueueModifyIfNeeded place it safely on next tick.
               double fsl=sl, ftp=tp;
               if(fsl>0.0 || ftp>0.0)
                 {
                  double mkPoint=SymbolInfoDouble(sym,SYMBOL_POINT);
                  double mkStop=(double)MathMax(SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(sym,SYMBOL_TRADE_FREEZE_LEVEL))*mkPoint;
                  int    mkDig=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
                  double mkBid=SymbolInfoDouble(sym,SYMBOL_BID);
                  double mkAsk=SymbolInfoDouble(sym,SYMBOL_ASK);
                  if(side==CP_SIDE_BUY)
                    {
                     if(fsl>0.0)
                       {
                        if(fsl>=mkBid) fsl=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && mkBid-fsl<mkStop) fsl=NormalizeDouble(mkBid-mkStop,mkDig);
                       }
                     if(ftp>0.0)
                       {
                        if(ftp<=mkAsk) ftp=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && ftp-mkBid<mkStop) ftp=NormalizeDouble(MathMax(mkBid+mkStop,mkAsk+mkPoint),mkDig);
                       }
                    }
                  else
                    {
                     if(fsl>0.0)
                       {
                        if(fsl<=mkAsk) fsl=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && fsl-mkAsk<mkStop) fsl=NormalizeDouble(mkAsk+mkStop,mkDig);
                       }
                     if(ftp>0.0)
                       {
                        if(ftp>=mkBid) ftp=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && mkAsk-ftp<mkStop) ftp=NormalizeDouble(MathMin(mkAsk-mkStop,mkBid-mkPoint),mkDig);
                       }
                    }
                  CopierSymInfo siEcn;
                  if(CopierGetSymbolInfo(sym,siEcn))
                    {
                     if(fsl>0.0) fsl=CopierRoundToTick(fsl,siEcn);
                     if(ftp>0.0) ftp=CopierRoundToTick(ftp,siEcn);
                    }
                 }
               // BUG-05: In MT5, position index in terminal cache might lag deal execution.
               // Verify position is resolvable before attempting modify stops; if not yet indexed,
               // do not call CopierModifyStops (which would treat not-found as "already gone" and return true).
               if(fsl>0.0 || ftp>0.0)
                 {
                  long resTicket=0; bool resPending=false;
                  if(CopierResolveCloseTicket((long)posId,resTicket,resPending))
                    {
                     int mErr=0;
                     CopierModifyStops((long)posId,sym,fsl,ftp,mErr);
                    }
                 }
              }
           }
         else
           {
            if(flatErr!=0) outErr=flatErr;
           }
        }
     }
   return ok;
#else
   RefreshRates();
   double px=0.0;
   if(!CopierGetPrice(sym,side,px)) { outErr=-2; return false; }
   int cmd=(side==CP_SIDE_BUY)?OP_BUY:OP_SELL;
   int safeMagic=(magic>2147483647 || magic<0)?(int)(magic & 0x7FFFFFFF):(int)magic;
   int ticket=-1;
   double initialPx=px;
   double pointVal=MarketInfo(sym,MODE_POINT);
   outErr=0;
   for(int attempt=0;attempt<3;attempt++)
     {
      ticket=OrderSend(sym,cmd,lots,px,MathMax(0,deviationPoints),sl,tp,comment,safeMagic,0,clrNONE);
      if(ticket>=0) { outErr=0; break; }
      outErr=GetLastError();
      if(outErr==135 || outErr==136 || outErr==138) // ERR_PRICE_CHANGED, ERR_OFF_QUOTES, ERR_REQUOTE
        {
         CopierWaitMs(10);
         RefreshRates();
         if(!CopierGetPrice(sym,side,px)) break;
         // DEF-B04: Hard cap on cumulative slippage across retries to prevent runaway market chase
         if(pointVal>0.0 && MathAbs(px-initialPx)/pointVal > MathMax(30,(deviationPoints>0?deviationPoints:30))) break;
         continue;
        }
      break;
     }
   if(ticket<0)
     {
      //--- R14-A04: outErr already holds GetLastError() from the final OrderSend attempt;
      //--- reading GetLastError() a second time clears it to 0 and disables err-130 fallback.
      //--- ECN broker / Market Execution fallback: on ECN brokers, OrderSend
      //--- forbids non-zero SL/TP on market entry and returns err 130 (ERR_INVALID_STOPS).
      //--- Fall back to opening with SL=0, TP=0, then apply stops via OrderModify.
      if(outErr==130 && (sl>0.0 || tp>0.0))
        {
         RefreshRates();
         if(CopierGetPrice(sym,side,px))
           {
            ticket=OrderSend(sym,cmd,lots,px,MathMax(0,deviationPoints),0.0,0.0,comment,safeMagic,0,clrNONE);
            if(ticket>=0)
              {
               outErr=0;
               //--- Apply the stops immediately on the newly opened position
               //--- N57-13: re-clamp first. The fill can slip far enough that the
               //--- original sl/tp now sits inside MODE_STOPLEVEL, and then the
               //--- modify below fails with the same err 130 that sent us down
               //--- this path - leaving the position with no stop at all until
               //--- the next converge pass. CopierSizing's CopierFitStop is not
               //--- reachable from here (this header is included BY it), so the
               //--- clamp is done inline against the live bid/ask.
               //--- sl/tp are const parameters, hence the local copies.
               // BUG-02: Protect against crossed stops on fallback.
               // If stop already crossed market, do NOT hard-clamp to mkBid - mkStop (which causes instant stop-out)
               // and do not send invalid crossed stop to ECN zero stop-level broker (repeats 130).
               // Set crossed stop to 0.0 and let converge/QueueModifyIfNeeded place it safely on next tick.
               double fsl=sl, ftp=tp;
               if(fsl>0.0 || ftp>0.0)
                 {
                  double mkPoint=MarketInfo(sym,MODE_POINT);
                  double mkStop=MathMax(MarketInfo(sym,MODE_STOPLEVEL),MarketInfo(sym,MODE_FREEZELEVEL))*mkPoint;
                  int    mkDig=(int)MarketInfo(sym,MODE_DIGITS);
                  double mkBid=MarketInfo(sym,MODE_BID);
                  double mkAsk=MarketInfo(sym,MODE_ASK);
                  if(cmd==OP_BUY)
                    {
                     if(fsl>0.0)
                       {
                        if(fsl>=mkBid) fsl=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && mkBid-fsl<mkStop) fsl=NormalizeDouble(mkBid-mkStop,mkDig);
                       }
                     if(ftp>0.0)
                       {
                        if(ftp<=mkAsk) ftp=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && ftp-mkBid<mkStop) ftp=NormalizeDouble(MathMax(mkBid+mkStop,mkAsk+mkPoint),mkDig);
                       }
                    }
                  else
                    {
                     if(fsl>0.0)
                       {
                        if(fsl<=mkAsk) fsl=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && fsl-mkAsk<mkStop) fsl=NormalizeDouble(mkAsk+mkStop,mkDig);
                       }
                     if(ftp>0.0)
                       {
                        if(ftp>=mkBid) ftp=0.0; // crossed: defer to converge
                        else if(mkStop>0.0 && mkAsk-ftp<mkStop) ftp=NormalizeDouble(MathMin(mkAsk-mkStop,mkBid-mkPoint),mkDig);
                       }
                    }
                  CopierSymInfo siEcn;
                  if(CopierGetSymbolInfo(sym,siEcn))
                    {
                     if(fsl>0.0) fsl=CopierRoundToTick(fsl,siEcn);
                     if(ftp>0.0) ftp=CopierRoundToTick(ftp,siEcn);
                    }
                 }
               if(OrderSelect(ticket,SELECT_BY_TICKET))
                 {
                  int mErr=0;
                  if(!CopierModifyStops((long)ticket,sym,fsl,ftp,mErr))
                    {
                     Print("[copier] WARN: ECN open succeeded (ticket ",ticket,") but immediate stops modify failed: err=",mErr);
                    }
                 }
               return true;
              }
            else
              {
               outErr=GetLastError();
              }
           }
        }
      return false;
     }
   return true;
#endif
  }

//=====================================================================
// Close (fully) a position identified by its stable identifier.
//=====================================================================
bool CopierClosePosition(const long identifier,const int deviationPoints,int &outErr,const bool asyncMode=false,const double px=0.0,const int ordKind=-1)
  {
   outErr=0;
   long ticket=0;
   bool pending=false;
   if(!CopierResolveCloseTicket(identifier,ticket,pending,ordKind))
     {
      //--- already gone: treat as success so the caller stops retrying
      outErr=0;
      return true;
     }

#ifdef __MQL5__
   if(pending)
     {
      //--- a working order is REMOVED, not closed. Sending PositionClose
      //--- against it would find no position and report a failure for an
      //--- order that is sitting right there.
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action=TRADE_ACTION_REMOVE;
      req.order =(ulong)ticket;
      if(asyncMode)
        {
         if(!OrderSendAsync(req,res)) { outErr=(int)res.retcode; return false; }
         return true;
        }
      if(!OrderSend(req,res)) { outErr=(int)res.retcode; return false; }
      if(res.retcode==TRADE_RETCODE_DONE
         || res.retcode==TRADE_RETCODE_PLACED
         || res.retcode==TRADE_RETCODE_NO_CHANGES)
         return true;
      outErr=(int)res.retcode;
      return false;
     }
   CTrade trade;
   trade.SetDeviationInPoints((ulong)MathMax(0,deviationPoints));
   string sym=PositionGetString(POSITION_SYMBOL);
   if(StringLen(sym)==0 && PositionSelectByTicket((ulong)ticket))
      sym=PositionGetString(POSITION_SYMBOL);
   if(StringLen(sym)>0) trade.SetTypeFillingBySymbol(sym);
   trade.SetAsyncMode(asyncMode);
   bool ok=trade.PositionClose((ulong)ticket);
   // R2-D1-M02: 10030 (TRADE_RETCODE_INVALID_FILL) candidate fallback
   if(!ok && trade.ResultRetcode()==10030)
     {
      string sym=PositionGetString(POSITION_SYMBOL);
      long fillMode=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
      ENUM_ORDER_TYPE_FILLING candidates[3];
      int nCand=0;
      if((fillMode&SYMBOL_FILLING_FOK)!=0) candidates[nCand++]=ORDER_FILLING_FOK;
      if((fillMode&SYMBOL_FILLING_IOC)!=0) candidates[nCand++]=ORDER_FILLING_IOC;
      candidates[nCand++]=ORDER_FILLING_RETURN;
      for(int a=0; a<nCand; a++)
        {
         trade.SetTypeFilling(candidates[a]);
         ok=trade.PositionClose((ulong)ticket);
         if(ok || trade.ResultRetcode()!=10030) break;
        }
     }
   if(!ok) outErr=(int)trade.ResultRetcode();
   return ok;
#else
   if(ticket<=0 || (ulong)ticket>0xFFFFFFFF) { outErr=ERR_INVALID_TICKET; return false; }
   if(!OrderSelect((int)(uint)ticket,SELECT_BY_TICKET,MODE_TRADES) || OrderCloseTime()!=0) { outErr=0; return true; }
   if(pending)
     {
      int tcWait=0;
      while(IsTradeContextBusy() && tcWait++<15) CopierWaitMs(10);
      bool del=OrderDelete((int)(uint)ticket,clrNONE);
      if(!del) outErr=GetLastError();
      return del;
     }
   double lots=OrderLots();
   bool ok=false;
   for(int attempt=0; attempt<3; attempt++)
     {
      int tcWait=0;
      while(IsTradeContextBusy() && tcWait++<15) CopierWaitMs(10);
      double closePx=px;
      int type=(int)OrderType();
      if(attempt>0 || closePx<=0.0)
        {
         RefreshRates();
         closePx=(type==OP_BUY)?MarketInfo(OrderSymbol(),MODE_BID):MarketInfo(OrderSymbol(),MODE_ASK);
        }
      ok=OrderClose((int)(uint)ticket,lots,closePx,MathMax(0,deviationPoints),clrNONE);
      if(ok) break;
      outErr=GetLastError();
      if(outErr!=138 && outErr!=135 && outErr!=136 && outErr!=146) break;
      CopierWaitMs(20);
     }
   return ok;
#endif
  }

//=====================================================================
// Set the stop-loss / take-profit of an existing position.
//
// `sl` / `tp` of 0.0 mean "remove it", and that is a real instruction
// here: the receiver mirrors the sender's stops faithfully, so a sender
// that clears its stop clears the mirror's too.
//
// The caller is responsible for having already decided the value is
// different and for having clamped it to the broker's minimum distance -
// this function only sends.
//
// Returns true when the position is gone, already in the wanted state, or
// the change succeeded. False only on a real failure, with outErr set.
//=====================================================================
bool CopierModifyStops(const long identifier,const string sym,
                       const double sl,const double tp,int &outErr)
  {
   outErr=0;
   long ticket=0;
   bool pending=false;
   if(!CopierResolveCloseTicket(identifier,ticket,pending))
     {
      outErr=0;              // already gone: treat as success, stop retrying
      return true;
     }

#ifdef __MQL5__
   if(pending)
     {
      //--- A working order is MODIFIED, not SLTP'd. TRADE_ACTION_SLTP
      //--- addresses a POSITION, so against a pending order it finds
      //--- nothing and the stop is silently never set.
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action=TRADE_ACTION_MODIFY;
      req.order =(ulong)ticket;
      req.symbol=sym;
      //--- the resolver left this order selected, so its trigger price is
      //--- readable and must be passed back unchanged
      req.price =OrderGetDouble(ORDER_PRICE_OPEN);
      req.sl    =sl;
      req.tp    =tp;
      double stp=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      if(stp>0.0) req.stoplimit=stp;
      datetime exp=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(exp>0)
        {
         req.type_time =ORDER_TIME_SPECIFIED;
         req.expiration=exp;
        }
      else
        {
         req.type_time =ORDER_TIME_GTC;
        }
      if(!OrderSend(req,res))
        {
         if(res.retcode==10022 && req.type_time==ORDER_TIME_SPECIFIED)
           {
            req.type_time=ORDER_TIME_GTC;
            req.expiration=0;
            if(OrderSend(req,res))
              {
               if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED || res.retcode==TRADE_RETCODE_NO_CHANGES)
                  return true;
              }
           }
         outErr=(int)res.retcode;
         return false;
        }
      if(res.retcode==TRADE_RETCODE_DONE
         || res.retcode==TRADE_RETCODE_PLACED
         || res.retcode==TRADE_RETCODE_NO_CHANGES)
         return true;
      if(res.retcode==10022 && req.type_time==ORDER_TIME_SPECIFIED)
        {
         req.type_time=ORDER_TIME_GTC;
         req.expiration=0;
         if(OrderSend(req,res))
           {
            if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED || res.retcode==TRADE_RETCODE_NO_CHANGES)
               return true;
           }
        }
      outErr=(int)res.retcode;
      return false;
     }
   //--- Built by hand rather than with CTrade::PositionModify, for the same
   //--- reason the partial close is: it keeps the request explicit and lets
   //--- us name the symbol, which some builds require on SLTP.
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action  =TRADE_ACTION_SLTP;
   req.position=(ulong)ticket;
   req.symbol  =sym;
   req.sl      =sl;
   req.tp      =tp;

   if(!OrderSend(req,res)) { outErr=(int)res.retcode; return false; }
   //--- NO_CHANGES is not a failure: a racing snapshot can ask for a state
   //--- the broker already holds, and the wanted state is reached either way
   if(res.retcode==TRADE_RETCODE_DONE
      || res.retcode==TRADE_RETCODE_PLACED
      || res.retcode==TRADE_RETCODE_NO_CHANGES
      || res.retcode==10009
      || res.retcode==10025
      || res.retcode==10036)
     {
      outErr=0;
      return true;
     }
   outErr=(int)res.retcode;
   return false;
#else
   if(ticket<=0 || (ulong)ticket>0xFFFFFFFF) { outErr=ERR_INVALID_TICKET; return false; }
   if(!OrderSelect((int)(uint)ticket,SELECT_BY_TICKET,MODE_TRADES) || OrderCloseTime()!=0)
     {
      outErr=0;
      return true;
     }
   //--- MT4 changes only the stops, so the open price is passed back
   //--- unchanged. OrderExpiration() reads from the selected order, which
   //--- is why the select above has to happen first.
   double openPx=OrderOpenPrice();
   bool ok=OrderModify((int)ticket,openPx,sl,tp,OrderExpiration(),clrNONE);
   if(!ok)
     {
      int e=GetLastError();
      //--- 1 = ERR_NO_RESULT, "no changes": the broker already holds these
      //--- stops, so the wanted state is reached despite the reported error
      if(e==1) return true;
      outErr=e;
      return false;
     }
   return true;
#endif
  }

//=====================================================================
// Modify a pending order's price, stops, stoplimit, and expiration.
//=====================================================================
bool CopierModifyPendingOrder(const long identifier,const string sym,
                              const double price,const double sl,const double tp,
                              const double stoplimit,const datetime expire,int &outErr)
  {
   outErr=0;
   long ticket=0;
   bool pending=false;
   // DEF-A02: Search for pending order first to prevent partially filled MT5 positions hijacking the modify
   if(!CopierResolveCloseTicket(identifier,ticket,pending,CP_ORD_PENDING))
     {
      // INC-02: If no working pending order exists, check if it filled into a market position
      if(CopierResolveCloseTicket(identifier,ticket,pending,CP_ORD_MARKET) && !pending)
        {
         return CopierModifyStops(identifier,sym,sl,tp,outErr);
        }
      outErr=0;
      return true;
     }

   if(!pending)
     {
      return CopierModifyStops(identifier,sym,sl,tp,outErr);
     }

   double modPx=price;
   double modStopLimit=stoplimit;
   double modSl=sl;
   double modTp=tp;
   CopierSymInfo si;
   if((modPx>0.0 || modStopLimit>0.0 || modSl>0.0 || modTp>0.0) && CopierGetSymbolInfo(sym,si))
     {
      if(modPx>0.0)        modPx=CopierRoundToTick(modPx,si);
      if(modStopLimit>0.0) modStopLimit=CopierRoundToTick(modStopLimit,si);
      if(modSl>0.0)        modSl=CopierRoundToTick(modSl,si);
      if(modTp>0.0)        modTp=CopierRoundToTick(modTp,si);
     }

#ifdef __MQL5__
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action=TRADE_ACTION_MODIFY;
   req.order =(ulong)ticket;
   req.symbol=sym;
   req.price =(modPx>0.0)?modPx:OrderGetDouble(ORDER_PRICE_OPEN);
   req.sl    =modSl;
   req.tp    =modTp;
   if(modStopLimit>0.0) req.stoplimit=modStopLimit;
   if(expire>0)
     {
      req.type_time =ORDER_TIME_SPECIFIED;
      req.expiration=expire;
     }
   else
     {
      req.type_time =ORDER_TIME_GTC;
     }
   if(!OrderSend(req,res))
     {
      if(res.retcode==10022 && req.type_time==ORDER_TIME_SPECIFIED)
        {
         req.type_time=ORDER_TIME_GTC;
         req.expiration=0;
         if(OrderSend(req,res))
           {
            if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED || res.retcode==TRADE_RETCODE_NO_CHANGES)
               return true;
           }
        }
      outErr=(int)res.retcode;
      return false;
     }
   if(res.retcode==TRADE_RETCODE_DONE
      || res.retcode==TRADE_RETCODE_PLACED
      || res.retcode==TRADE_RETCODE_NO_CHANGES)
      return true;
   if(res.retcode==10022 && req.type_time==ORDER_TIME_SPECIFIED)
     {
      req.type_time=ORDER_TIME_GTC;
      req.expiration=0;
      if(OrderSend(req,res))
        {
         if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED || res.retcode==TRADE_RETCODE_NO_CHANGES)
            return true;
        }
     }
   outErr=(int)res.retcode;
   return false;
#else
   if(ticket<=0 || (ulong)ticket>0xFFFFFFFF) { outErr=ERR_INVALID_TICKET; return false; }
   if(!OrderSelect((int)(uint)ticket,SELECT_BY_TICKET,MODE_TRADES) || OrderCloseTime()!=0)
     {
      outErr=0;
      return true;
     }
   double openPx=(modPx>0.0)?modPx:OrderOpenPrice();
   datetime exp=expire;
   bool ok=OrderModify((int)ticket,openPx,modSl,modTp,exp,clrNONE);
   if(!ok)
     {
      int e=GetLastError();
      if(e==147 && exp>0)
        {
         if(OrderModify((int)ticket,openPx,modSl,modTp,0,clrNONE)) return true;
         e=GetLastError();
        }
      if(e==1) return true;
      outErr=e;
      return false;
     }
   return true;
#endif
  }

//=====================================================================
// Partially close a position: reduce it by `lots` and leave the rest.
//
// Both platforms support this natively, with different calls:
//   MT4: OrderClose() with a volume SMALLER than the order's own volume
//        performs a partial close; the remainder keeps its ticket.
//   MT5: CTrade::PositionClosePartial() on the position ticket.
//
// Only ever called with a volume strictly less than the current one - the
// caller clamps - because "close more than exists" is a full close on MT5
// and an error on MT4.
//=====================================================================
bool CopierClosePartial(const long identifier,const double lots,
                        const string sym,const int side,const long magic,
                        const string comment,const int deviationPoints,int &outErr,
                        double &outClosedLots)
  {
   outErr=0;
   outClosedLots=0.0;
   if(lots<=0.0) return true;

   long ticket=0;
   bool isPending=false;
   // R47-02: Use 3-arg resolver to capture isPending
   if(!CopierResolveCloseTicket(identifier,ticket,isPending))
     {
      outErr=0;            // already gone
      return true;
     }

   if(isPending)
     {
      outErr=-5;           // R48-01: distinct error: partial close of pending orders is unsupported by broker API
      return false;
     }

#ifdef __MQL5__
   //--- Built by hand rather than with CTrade::PositionClosePartial.
   //---
   //--- CTrade clears the request and never sets a comment, so the closing
   //--- order carries an EMPTY comment - and MT5 then writes that empty
   //--- comment onto the position. The order silently loses the "tc|<uid>|"
   //--- identity the whole system is built on, and it stops being
   //--- identifiable in the terminal. Sending the request directly is the
   //--- only way to put our comment on the closing deal.
   MqlTick tick;
   if(!SymbolInfoTick(sym,tick)) { outErr=-2; return false; }

   if(!PositionSelectByTicket((ulong)ticket))
     {
      outErr=0;
      return true;
     }
   double have=PositionGetDouble(POSITION_VOLUME);
   //--- L-03: 1e-9, not 1e-7. Volumes travel with CP_DIGITS_LOTS = 8 decimals,
   //--- so the smallest meaningful step is 1e-8 - and 1e-7 is TEN of those. On a
   //--- micro position (0.00000020 lots) a legitimate 50% partial close
   //--- (0.00000010) therefore satisfied "lots >= have - 1e-7" and was refused
   //--- as if it were a full close. 1e-9 is still far above the ~1e-16 noise of
   //--- parsing and subtraction, so an exact-equality test behaves exactly.
   if(lots>=have-0.000000001)
     {
      outErr=-3;
      return false;
     }
   double minVol=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   if(minVol>0.0 && have-lots>0.000000001 && have-lots<minVol-0.000000001)
     {
      outErr=-6; // R12-A04: residual volume would violate broker minLot
      return false;
     }

   //--- Candidate fillings, best guess first. CTrade used to pick one for us
   //--- via SetTypeFillingBySymbol() and silently retry on rejection; doing
   //--- the request by hand means we own that fallback. Only an
   //--- INVALID_FILL retcode (10030) is worth a second attempt - retrying
   //--- anything else would double-send a close.
   long fillMode=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING candidates[3];
   int nCand=0;
   if((fillMode&SYMBOL_FILLING_FOK)!=0) candidates[nCand++]=ORDER_FILLING_FOK;
   if((fillMode&SYMBOL_FILLING_IOC)!=0) candidates[nCand++]=ORDER_FILLING_IOC;
   candidates[nCand++]=ORDER_FILLING_RETURN;

   MqlTradeRequest req;
   MqlTradeResult  res;

   for(int attempt=0;attempt<nCand;attempt++)
     {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       =TRADE_ACTION_DEAL;
      req.position     =(ulong)ticket;
      req.symbol       =sym;
      req.volume       =lots;
      req.type         =(side==CP_SIDE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.price        =(side==CP_SIDE_BUY)?tick.bid:tick.ask;
      req.deviation    =(ulong)MathMax(0,deviationPoints);
      req.magic        =(ulong)magic;
      req.comment      =comment;   // <- the whole point of doing this by hand
      req.type_filling =candidates[attempt];

      bool sent=OrderSend(req,res);
      outErr=(int)res.retcode;

      if(sent && (res.retcode==TRADE_RETCODE_DONE
                  || res.retcode==TRADE_RETCODE_PLACED
                  || res.retcode==TRADE_RETCODE_DONE_PARTIAL))
        {
         if(res.retcode==TRADE_RETCODE_DONE_PARTIAL)
            outClosedLots=(res.volume>0.0)?MathMin(lots,res.volume):0.0;
         else
            outClosedLots=(res.volume>0.0)?MathMin(lots,res.volume):lots;
         return true;
        }

      //--- only an unsupported filling mode justifies another attempt
      if(res.retcode!=TRADE_RETCODE_INVALID_FILL) return false;
     }
   return false;
#else
   if(ticket<=0 || (ulong)ticket>0xFFFFFFFF) { outErr=ERR_INVALID_TICKET; return false; }
   if(!OrderSelect((int)(uint)ticket,SELECT_BY_TICKET,MODE_TRADES) || OrderCloseTime()!=0)
     {
      outErr=0;
      return true;
     }
   double have=OrderLots();
   //--- closing the whole thing is a different operation with different
   //--- rounding; refuse rather than risk a full exit by accident.
   //--- L-03: same 1e-9 as the MT5 branch - 1e-7 is ten 8-decimal steps and
   //--- rejected a real half-close on a micro position.
   if(lots>=have-0.000000001) { outErr=-3; return false; }

   RefreshRates();
   int type=(int)OrderType();
   double px=(type==OP_BUY)?MarketInfo(OrderSymbol(),MODE_BID)
                           :MarketInfo(OrderSymbol(),MODE_ASK);
   bool ok=OrderClose((int)ticket,lots,px,MathMax(0,deviationPoints),clrNONE);
   if(ok) outClosedLots=lots;
   else   outErr=GetLastError();
   return ok;
#endif
  }

bool CopierClosePartial(const long identifier,const double lots,
                        const string sym,const int side,const long magic,
                        const string comment,const int deviationPoints,int &outErr)
  {
   double closedLots=0.0;
   return CopierClosePartial(identifier,lots,sym,side,magic,comment,deviationPoints,outErr,closedLots);
  }

//=====================================================================
// Account mode - matters for MT5 netting accounts where a reverse
// signal flips the existing position instead of opening a new one.
//=====================================================================
int CopierAccountMode()
  {
#ifdef __MQL5__
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN)<=0)
      return -1; // Unknown / connecting: do not assume netting
   long mode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)  return 1;   // hedging
   return 2;                                                  // netting/exchange
#else
   return 1;                                                  // MT4 is hedging
#endif
  }

bool CopierIsHedgingAccount() { return CopierAccountMode()==1; }
bool CopierIsNettingAccount() { return CopierAccountMode()==2; }

//=====================================================================
// Check if a ticket has closed or been removed in trade history.
// Used by Sender for immediate 0ms debounced close detection.
//=====================================================================
bool CopierIsTicketClosedInHistory(const long ticket)
  {
   if(ticket<=0) return false;
#ifdef __MQL5__
   //--- L3: `ticket` here is POSITION_IDENTIFIER (see CopierScanPositions), NOT
   //--- POSITION_TICKET. PositionSelectByTicket(identifier) therefore returns
   //--- false for any position whose ticket has changed - which happens on a
   //--- partial close and on overnight rollover. That false negative made a LIVE
   //--- position look closed the moment it had been trimmed once, so a single
   //--- scan hiccup emitted CLOSE (and the next scan re-opened it as a new UID).
   //--- Walk the position list and compare identifiers instead.
   for(int pi=PositionsTotal()-1;pi>=0;pi--)
     {
      ulong ptk=PositionGetTicket(pi);
      if(ptk==0) continue;
      if((long)PositionGetInteger(POSITION_IDENTIFIER)==ticket) return false;
     }

   if(HistorySelectByPosition((ulong)ticket))
     {
      int deals=HistoryDealsTotal();
      double inVol=0.0, outVol=0.0;
      for(int i=0; i<deals; i++)
        {
         ulong dt=HistoryDealGetTicket(i);
         if(dt==0) continue;
         long entry=HistoryDealGetInteger(dt,DEAL_ENTRY);
         double vol=HistoryDealGetDouble(dt,DEAL_VOLUME);
         //--- L3: a netting reversal (DEAL_ENTRY_INOUT) closes the old volume AND
         //--- opens the new one. Counting it only as an exit left inVol at 0, so
         //--- the closure test below could never become true for a position that
         //--- was born from a reversal.
         if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_STATE) inVol+=vol;
         else if(entry==DEAL_ENTRY_INOUT)
           {
            if(inVol==0.0)
              {
               // R6-D2-01: Position born from a reversal deal: initialize inVol with initial deal volume
               inVol+=vol;
              }
            else
              {
               // Reversal closing this position: count closing portion towards outVol
               double closingVol = MathMin(vol, MathMax(0.0, inVol - outVol));
               outVol += closingVol;
              }
           }
         else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY) outVol+=vol;
        }
      // Only considered fully closed when total exit volume matches or exceeds total entry volume
      //--- L-03: 1e-9. With 1e-7 a position of 0.00000020 lots whose history
      //--- showed only HALF of it closed (outVol 0.00000010) satisfied this and
      //--- was reported fully closed, so the receiver would drop a mirror the
      //--- sender still holds. Below one 8-decimal step, sum noise cannot reach it.
      if(inVol>0.0 && outVol>=inVol-0.000000001)
         return true;
     }
   if(!HistoryOrderSelect((ulong)ticket))
     {
      // HistorySelectByPosition only caches orders with POSITION_IDENTIFIER == ticket.
      // Cancelled/expired pending orders have ORDER_POSITION_ID == 0; populate history cache to query them.
      datetime hFrom=(datetime)(CopierServerTime()-86400*3);
      datetime hTo=(datetime)(CopierServerTime()+86400);
      HistorySelect(hFrom,hTo);
     }
   if(HistoryOrderSelect((ulong)ticket))
     {
      long state=HistoryOrderGetInteger((ulong)ticket,ORDER_STATE);
      // P2-19: ORDER_STATE_FILLED means pending order converted to market position, NOT closed/canceled
      if(state==ORDER_STATE_CANCELED || state==ORDER_STATE_EXPIRED || state==ORDER_STATE_REJECTED)
         return true;
     }
   return false;
#else
   if(ticket<=0 || (ulong)ticket>0xFFFFFFFF) return false;
   if(OrderSelect((int)(uint)ticket,SELECT_BY_TICKET,MODE_HISTORY))
     {
      return (OrderCloseTime()>0);
     }
   return false;
#endif
  }

#endif
//+------------------------------------------------------------------+
