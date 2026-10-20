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
   double            tickSize;
   double            contractSize;
  };

//=====================================================================
// Symbol helpers
//=====================================================================
bool CopierSymbolEnsure(const string sym)
  {
#ifdef __MQL5__
   return SymbolSelect(sym,true);
#else
   return MarketInfo(sym,MODE_ASK)>0.0;
#endif
  }

bool CopierGetSymbolInfo(const string sym,CopierSymInfo &si)
  {
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
   SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE,si.tickSize);
   SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE,si.contractSize);
#else
   si.point=MarketInfo(sym,MODE_POINT);
   si.digits=(int)MarketInfo(sym,MODE_DIGITS);
   si.minLot=MarketInfo(sym,MODE_MINLOT);
   si.maxLot=MarketInfo(sym,MODE_MAXLOT);
   si.lotStep=MarketInfo(sym,MODE_LOTSTEP);
   si.stopLevel=MarketInfo(sym,MODE_STOPLEVEL)*si.point;
   si.tickSize=MarketInfo(sym,MODE_TICKSIZE);
   si.contractSize=MarketInfo(sym,MODE_LOTSIZE);
#endif
   if(si.point<=0.0)      return false;
   if(si.digits<0)        si.digits=5;
   if(si.minLot<=0.0)     si.minLot=0.01;
   if(si.maxLot<=0.0)     si.maxLot=100.0;
   if(si.lotStep<=0.0)    si.lotStep=0.01;
   if(si.tickSize<=0.0)   si.tickSize=si.point;
   if(si.contractSize<=0.0) si.contractSize=100000.0;
   return true;
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
   ArrayResize(times,cap);
   for(int i=0;i<cap;i++) times[i]=CopierM1BarTime(sym,i);
   return CopierCountBarsAfter(times,cap,from,cap);
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
//=====================================================================
double CopierRealizedToday(const long dayStart)
  {
   double sum=0.0;
#ifdef __MQL5__
   datetime from=(datetime)dayStart;
   //--- the upper bound must be in the future: HistorySelect excludes
   //--- anything at or after it, and deals are stamped with server time
   datetime to=(datetime)(CopierServerTime()+86400);
   if(!HistorySelect(from,to)) return 0.0;
   int n=HistoryDealsTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=HistoryDealGetTicket(i);
      if(t==0) continue;
      //--- profit and swap are zero on an entry deal, but commission is
      //--- charged there, so every deal is summed rather than only exits
      sum+=HistoryDealGetDouble(t,DEAL_PROFIT)
          +HistoryDealGetDouble(t,DEAL_SWAP)
          +HistoryDealGetDouble(t,DEAL_COMMISSION);
     }
#else
   int total=OrdersHistoryTotal();
   for(int i=0;i<total;i++)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if((long)OrderCloseTime()<dayStart) continue;
      sum+=OrderProfit()+OrderSwap()+OrderCommission();
     }
#endif
   return sum;
  }

//--- midnight of the current server day, in server time
long CopierServerDayStart()
  {
   return (CopierServerTime()/86400)*86400;
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
   double px=NormalizeDouble(p.pprice,si.digits);
   double stop=NormalizeDouble(p.pstop,si.digits);

#ifdef __MQL5__
   long pt=CopierPendToPlatformType(p.ptype);
   if(pt<0) { outErr=-4; return false; }

   long fillMode=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING filling=ORDER_FILLING_RETURN;
   if((fillMode&SYMBOL_FILLING_FOK)!=0)      filling=ORDER_FILLING_FOK;
   else if((fillMode&SYMBOL_FILLING_IOC)!=0) filling=ORDER_FILLING_IOC;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action      =TRADE_ACTION_PENDING;
   req.symbol      =sym;
   req.volume      =p.lots;
   req.type        =(ENUM_ORDER_TYPE)pt;
   req.price       =px;
   req.sl          =p.sl;
   req.tp          =p.tp;
   req.deviation   =(ulong)deviationPoints;
   req.magic       =(ulong)magic;
   req.comment     =cmt;
   req.type_filling=filling;
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
   if(!OrderSend(req,res)) { outErr=(int)res.retcode; return false; }
   if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED)
      return true;
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
   int ticket=OrderSend(sym,cmd,p.lots,px,deviationPoints,p.sl,p.tp,cmt,
                        (int)magic,(datetime)p.pexpire,clrNONE);
   if(ticket<0)
     {
      outErr=GetLastError();
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
      if(n>=maxOut) break;

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
      //--- POSITION_IDENTIFIER is server-stable; POSITION_TICKET is not
      p.ticket=(long)PositionGetInteger(POSITION_IDENTIFIER);
      p.magic=(long)PositionGetInteger(POSITION_MAGIC);
      p.openTime=(long)PositionGetInteger(POSITION_TIME);
      p.kind=CP_ORD_MARKET;
      p.ptype=0; p.pprice=0.0; p.pstop=0.0; p.pexpire=0;
      p.used=true;
      //--- grow in chunks: one ArrayResize per order per tick is 300 calls
      //--- on a busy account, and the array is capped by maxOut anyway
      if(n>=ArraySize(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
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
      if((long)OrderGetInteger(ORDER_STATE)!=ORDER_STATE_PLACED) continue;
      int pt=CopierPendFromPlatformType((long)OrderGetInteger(ORDER_TYPE));
      if(pt==0) continue;
      if(n>=maxOut) break;

      CopierPos p;
      p.uid="";
      p.sym=OrderGetString(ORDER_SYMBOL);
      p.cmt=readComment ? OrderGetString(ORDER_COMMENT) : "";
      p.side=CopierPendingSide(pt);
      p.lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
      p.openPx=OrderGetDouble(ORDER_PRICE_OPEN);   // the trigger price
      p.sl=OrderGetDouble(ORDER_SL);
      p.tp=OrderGetDouble(ORDER_TP);
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
      p.used=true;
      //--- grow in chunks: one ArrayResize per order per tick is 300 calls
      //--- on a busy account, and the array is capped by maxOut anyway
      if(n>=ArraySize(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
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
      if(n>=maxOut) break;

      CopierPos p;
      p.uid="";
      p.sym=OrderSymbol();
      p.cmt=readComment ? OrderComment() : "";
      p.lots=OrderLots();
      p.openPx=OrderOpenPrice();
      p.sl=OrderStopLoss();
      p.tp=OrderTakeProfit();
      p.ticket=(long)OrderTicket();
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
         p.pprice=OrderOpenPrice();                   // the trigger price
         p.pstop=0.0;                                 // MT4 has no stop-limit
         p.pexpire=(long)OrderExpiration();
        }
      p.used=true;
      //--- grow in chunks: one ArrayResize per order per tick is 300 calls
      //--- on a busy account, and the array is capped by maxOut anyway
      if(n>=ArraySize(out)) ArrayResize(out,(n*2<32)?32:((n*2>maxOut)?maxOut:n*2),maxOut);
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
   if(OrderSelect((int)p.ticket,SELECT_BY_TICKET)) return OrderComment();
   return "";
#endif
  }

string CopierReadCommentByTicket(const long ticket)
  {
   CopierPos p;
   p.ticket=ticket;
   p.kind=CP_ORD_MARKET;
   return CopierReadCommentByTicket(p);
  }

//=====================================================================
// MT5: POSITION_IDENTIFIER is stable but PositionClose needs the
// CURRENT position ticket. Resolve at execution time - never cache it.
//=====================================================================
bool CopierResolveCloseTicket(const long identifier,long &ticket,bool &isPending)
  {
   ticket=0;
   isPending=false;
#ifdef __MQL5__
   //--- positions first: POSITION_IDENTIFIER is stable, and it is what a
   //--- filled pending order's identifier becomes
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
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
      if((long)OrderGetInteger(ORDER_STATE)!=ORDER_STATE_PLACED) continue;
      ticket=(long)tk;
      isPending=true;
      return true;
     }
   return false;
#else
   if(!OrderSelect((int)identifier,SELECT_BY_TICKET,MODE_TRADES)) return false;
   ticket=identifier;
   int t=(int)OrderType();
   isPending=(t!=OP_BUY && t!=OP_SELL);
   return true;
#endif
  }

//--- convenience for the callers that do not care about the distinction
bool CopierResolveCloseTicket(const long identifier,long &ticket)
  {
   bool pending=false;
   return CopierResolveCloseTicket(identifier,ticket,pending);
  }

//=====================================================================
// MT4 partial close: the broker CLOSES the old order and opens the
// remainder as a NEW ticket, with the comment set to "from #<old>".
// Recovering that chain is the only way to keep the UID alive across
// a partial close on MT4.
//=====================================================================
long CopierMt4FromTicket(const string comment)
  {
   if(StringLen(comment)==0) return 0;
   string low=comment;
   //--- StringToLower modifies the string in-place by reference in MQL4/MQL5.
   StringToLower(low);
   int p=StringFind(low,"from #");
   if(p<0) return 0;
   int start=p+6;
   string digits="";
   for(int i=start;i<StringLen(comment);i++)
     {
      string c=StringSubstr(comment,i,1);
      if(c<"0" || c>"9") break;
      digits+=c;
     }
   if(StringLen(digits)==0) return 0;
   return (long)StringToInteger(digits);
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
   trade.SetDeviationInPoints((ulong)deviationPoints);
   trade.SetTypeFillingBySymbol(sym);
   trade.SetAsyncMode(false);
   bool ok;
   if(side==CP_SIDE_BUY) ok=trade.Buy(lots,sym,0.0,sl,tp,comment);
   else                  ok=trade.Sell(lots,sym,0.0,sl,tp,comment);
   if(!ok) outErr=(int)trade.ResultRetcode();
   return ok;
#else
   RefreshRates();
   double px=0.0;
   if(!CopierGetPrice(sym,side,px)) { outErr=-2; return false; }
   int cmd=(side==CP_SIDE_BUY)?OP_BUY:OP_SELL;
   int ticket=OrderSend(sym,cmd,lots,px,deviationPoints,sl,tp,comment,(int)magic,0,clrNONE);
   if(ticket<0)
     {
      outErr=GetLastError();
      return false;
     }
   return true;
#endif
  }

//=====================================================================
// Close (fully) a position identified by its stable identifier.
//=====================================================================
bool CopierClosePosition(const long identifier,const int deviationPoints,int &outErr)
  {
   outErr=0;
   long ticket=0;
   bool pending=false;
   if(!CopierResolveCloseTicket(identifier,ticket,pending))
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
      if(!OrderSend(req,res)) { outErr=(int)res.retcode; return false; }
      if(res.retcode==TRADE_RETCODE_DONE
         || res.retcode==TRADE_RETCODE_PLACED
         || res.retcode==TRADE_RETCODE_NO_CHANGES)
         return true;
      outErr=(int)res.retcode;
      return false;
     }
   CTrade trade;
   trade.SetDeviationInPoints((ulong)deviationPoints);
   trade.SetAsyncMode(false);
   bool ok=trade.PositionClose((ulong)ticket);
   if(!ok) outErr=(int)trade.ResultRetcode();
   return ok;
#else
   if(!OrderSelect((int)ticket,SELECT_BY_TICKET,MODE_TRADES)) { outErr=0; return true; }
   if(pending)
     {
      bool del=OrderDelete((int)ticket,clrNONE);
      if(!del) outErr=GetLastError();
      return del;
     }
   RefreshRates();
   double lots=OrderLots();
   int type=(int)OrderType();
   double px=(type==OP_BUY)?MarketInfo(OrderSymbol(),MODE_BID):MarketInfo(OrderSymbol(),MODE_ASK);
   bool ok=OrderClose((int)ticket,lots,px,deviationPoints,clrNONE);
   if(!ok) outErr=GetLastError();
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
      //--- the resolver left this order selected, so its trigger price is
      //--- readable and must be passed back unchanged
      req.price =OrderGetDouble(ORDER_PRICE_OPEN);
      req.sl    =sl;
      req.tp    =tp;
      if(!OrderSend(req,res)) { outErr=(int)res.retcode; return false; }
      if(res.retcode==TRADE_RETCODE_DONE
         || res.retcode==TRADE_RETCODE_PLACED
         || res.retcode==TRADE_RETCODE_NO_CHANGES)
         return true;
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
      || res.retcode==TRADE_RETCODE_NO_CHANGES)
      return true;
   outErr=(int)res.retcode;
   return false;
#else
   if(!OrderSelect((int)ticket,SELECT_BY_TICKET,MODE_TRADES))
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
                        const string comment,const int deviationPoints,int &outErr)
  {
   outErr=0;
   if(lots<=0.0) return true;

   long ticket=0;
   if(!CopierResolveCloseTicket(identifier,ticket))
     {
      outErr=0;            // already gone
      return true;
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
      req.deviation    =(ulong)deviationPoints;
      req.magic        =(ulong)magic;
      req.comment      =comment;   // <- the whole point of doing this by hand
      req.type_filling =candidates[attempt];

      bool sent=OrderSend(req,res);
      outErr=(int)res.retcode;

      if(sent && (res.retcode==TRADE_RETCODE_DONE
                  || res.retcode==TRADE_RETCODE_PLACED
                  || res.retcode==TRADE_RETCODE_DONE_PARTIAL))
         return true;

      //--- only an unsupported filling mode justifies another attempt
      if(res.retcode!=TRADE_RETCODE_INVALID_FILL) return false;
     }
   return false;
#else
   if(!OrderSelect((int)ticket,SELECT_BY_TICKET,MODE_TRADES))
     {
      outErr=0;
      return true;
     }
   double have=OrderLots();
   //--- closing the whole thing is a different operation with different
   //--- rounding; refuse rather than risk a full exit by accident
   if(lots>=have-0.0000001) return false;

   RefreshRates();
   int type=(int)OrderType();
   double px=(type==OP_BUY)?MarketInfo(OrderSymbol(),MODE_BID)
                           :MarketInfo(OrderSymbol(),MODE_ASK);
   bool ok=OrderClose((int)ticket,lots,px,deviationPoints,clrNONE);
   if(!ok) outErr=GetLastError();
   return ok;
#endif
  }

//=====================================================================
// Account mode - matters for MT5 netting accounts where a reverse
// signal flips the existing position instead of opening a new one.
//=====================================================================
int CopierAccountMode()
  {
#ifdef __MQL5__
   long mode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)  return 1;   // hedging
   return 2;                                                  // netting/exchange
#else
   return 1;                                                  // MT4 is hedging
#endif
  }

bool CopierIsNettingAccount() { return CopierAccountMode()==2; }

#endif
//+------------------------------------------------------------------+
