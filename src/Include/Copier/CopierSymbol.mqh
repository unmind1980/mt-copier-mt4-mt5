//+------------------------------------------------------------------+
//| CopierSymbol.mqh - per-sender symbol translation                 |
//|                                                                   |
//| The sender broadcasts its OWN broker symbol names untouched       |
//| (so one sender can feed receivers at different brokers without    |
//| any configuration). The translation table therefore lives on the  |
//| receiver, one table per sender.                                   |
//|                                                                   |
//| Explicit mapping beats auto-detection: a silently wrong symbol is |
//| far worse than a rejected trade.                                  |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_SYMBOL_MQH__
#define __COPIER_SYMBOL_MQH__

#include "CopierDefs.mqh"

#define CP_MAX_SYMBOL_MAP 64

//--- Does this terminal know the symbol at all?
//---
//--- "Known" must mean the symbol EXISTS, not "has a price right now".
//--- The first version asked for the current BID, which is 0 for a symbol
//--- that exists but is not subscribed / has not received a tick yet. That
//--- produced a chicken-and-egg: the check gated the very call
//--- (CopierOpenMarket -> CopierSymbolEnsure -> SymbolSelect) that would
//--- have subscribed the symbol and made a price available.
//---
//--- Observed on the first real pilot run: 21 minutes of "symbol EURUSD ->
//--- EURUSD not offered by this broker; skipped", ending the instant the
//--- symbol was added to Market Watch by hand. Nothing was wrong with the
//--- copier - it simply refused to trade a symbol it could not yet price,
//--- and could never fix that by itself.
//---
//--- Now the check asks a static question and subscribes on MT5, so a
//--- fresh receiver starts mirroring without manual Market Watch setup.
//---
//--- Defined BEFORE the class on purpose: MQL4's compiler emits
//--- "warning 46: no #import declaration" if a bare function prototype
//--- appears at file scope.
//+------------------------------------------------------------------+
// Is this symbol inside a trading session right now?
//
// A PRE-FILTER, not a substitute for handling the rejection. The schedule is
// a PREDICTION: holidays, broker halts and early closes do not appear in it.
// So this cuts the number of doomed attempts; the err=132 path still has to
// exist, because only the broker knows the truth.
//
// SymbolInfoSessionTrade exists on BOTH platforms - verified by compiling a
// probe against this machine's MT4, alongside the negative control that proves
// a missing function would have failed. Do not assume from the docs alone.
//
// The three-valued outcome matters:
//   true  - inside a session, or no schedule to judge by
//   false - outside every session
// "No schedule" returns TRUE on purpose. Blocking on an unknown schedule would
// silently stop every trade on that symbol, which is far worse than sending an
// order that gets refused.
//+------------------------------------------------------------------+
//--- One-second cache. This is called from the converge loop for every
//--- desired position, and the answer can only change at a session boundary.
//--- NM-13: Expand cache slots to 64 and test with a 1-second window.
#define CP_SESS_CACHE 64
string g_sessKey[CP_SESS_CACHE];
long   g_sessAt[CP_SESS_CACHE];
bool   g_sessVal[CP_SESS_CACHE];
int    g_sessHead=0;

bool CopierInTradingSession(const string sym)
  {
   if(StringLen(sym)==0) return true;

   long now=CopierServerTime();
   for(int i=0;i<CP_SESS_CACHE;i++)
     {
      // NM-13: 1-second window matching CopierSymbolQuoteAgeMs
      if(g_sessKey[i]==sym && now-g_sessAt[i]<1) return g_sessVal[i];
     }

   //--- R48-07: Use TimeToStruct to obtain local broker day-of-week and seconds from midnight,
   //--- aligning with SymbolInfoSessionTrade's broker session offsets.
   MqlDateTime dt;
   TimeToStruct((datetime)now,dt);
   int secOfDay=dt.hour*3600 + dt.min*60 + dt.sec;
   int dow=dt.day_of_week;

   bool anySession=false;
   bool inside=false;
   for(int i=0;i<8;i++)          // far more sessions than any broker defines
     {
      datetime f=0,t=0;
      if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)dow,i,f,t)) break;
      if(f==0 && t==0) continue;
      anySession=true;
      long fs=(long)(f%86400);
      long ts=(long)(t%86400);
      if(ts==0 && t>f) ts=86400;
      if(fs<=ts)
        {
         if(secOfDay>=fs && secOfDay<=ts) { inside=true; break; }
        }
      else
        {
         if(secOfDay>=fs || secOfDay<=ts) { inside=true; break; }
        }
     }

   bool result=false;
   if(anySession)
     {
      result=inside;
     }
   else
     {
      // Check if broker defines trading sessions on any other day of the week
      bool brokerHasWeeklySessions=false;
      for(int d=0;d<7;d++)
        {
         if(d==dow) continue;
         datetime f=0,t=0;
         if(SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)d,0,f,t))
           {
            if(f!=0 || t!=0) { brokerHasWeeklySessions=true; break; }
           }
        }
      result=!brokerHasWeeklySessions;
     }

   g_sessKey[g_sessHead]=sym;
   g_sessAt[g_sessHead]=now;
   g_sessVal[g_sessHead]=result;
   g_sessHead++;
   if(g_sessHead>=CP_SESS_CACHE) g_sessHead=0;

   return result;
  }

//+------------------------------------------------------------------+
// Has this SYMBOL's own quote stream stopped advancing?
//
// The receiver's global feed gate watches the server CLOCK, and on MT4 that is
// enough: TimeCurrent() is driven by ticks, so it freezes at the weekly close
// and the gate fires.
//
// MT5 is different, and the difference is not cosmetic. There TimeCurrent() is
// kept alive by the terminal's connection to the trade server, so it KEEPS
// ADVANCING through the weekend while no quotes are arriving at all. The
// global gate therefore never fires on MT5, and the receiver went on trying to
// open positions against a shut market - once per cooldown, all weekend, each
// attempt earning a broker rejection.
//
// So the question has to be asked about the SYMBOL, not the clock: has THIS
// instrument's own quote time moved recently? That works on both platforms and
// needs no clock arithmetic - the elapsed time is measured with the monotonic
// tick counter, exactly as the global gate already does it.
//
// A symbol whose quotes have stopped cannot be priced, so nothing should be
// attempted on it. And holding costs nothing, because the RETURN of its quotes
// is itself the signal that the market reopened: the next pass after the feed
// resumes sees a fresh symbol and the entry goes through.
//+------------------------------------------------------------------+
// NM-05: Expand slots from 32 to 256 to cover multi-source environments (>32 symbols)
#define CP_SYMFRESH_SLOTS 256
string   g_sfKey[CP_SYMFRESH_SLOTS];
datetime g_sfQuote[CP_SYMFRESH_SLOTS];
long     g_sfChangedMs[CP_SYMFRESH_SLOTS];
int      g_sfHead=0;

//--- One-second memo, mirroring CP_SESS_CACHE above. It caches the AGE, not a
//--- verdict: a verdict would be wrong the moment two callers passed different
//--- thresholds, and silently so.
#define CP_SYMFRESH_CACHE 16
string g_sfcKey[CP_SYMFRESH_CACHE];
long   g_sfcAt[CP_SYMFRESH_CACHE];
long   g_sfcAge[CP_SYMFRESH_CACHE];
int    g_sfcHead=0;

//--- The symbol's own last quote time, in server time. 0 = not available.
//---
//--- MODE_TIME on MT4 is "last quote time" for that symbol, which is the
//--- question being asked. Not MODE_BID: that changes when the spread moves
//--- rather than when the instrument trades, and would report a symbol as
//--- alive while it is shut.
datetime CopierSymbolQuoteTime(const string sym)
  {
   if(StringLen(sym)==0) return 0;
#ifdef __MQL5__
   MqlTick tick;
   if(!SymbolInfoTick(sym,tick)) return 0;
   return tick.time;
#else
   return (datetime)MarketInfo(sym,MODE_TIME);
#endif
  }

//--- How far the server clock has already run past a symbol's last quote.
//---
//--- PURE on purpose, so it can be tested without a live terminal, a shut
//--- market, or a weekend - and this is the term that decides whether the gate
//--- bites on the FIRST pass after a re-attach, which is the whole point of it.
//---
//--- -1 means "cannot be measured": no quote time at all, or a quote time in
//--- the FUTURE, which is clock skew rather than information. A negative age
//--- must never be allowed to read as "fresh by a wide margin".
long CopierClockAgeMs(const datetime quoteTime,const long serverNow)
  {
   if(quoteTime<=0) return -1;
   // N77-04: If serverNow == quoteTime, age is 0 ms (freshly quoted right at current second).
   // Only quoteTime in the future (serverNow < quoteTime) is clock skew and returns -1.
   if(serverNow<(long)quoteTime) return -1;
   return (serverNow-(long)quoteTime)*1000;
  }

//--- Milliseconds since this symbol's quote time last CHANGED.
//---
//--- 0 for a symbol seen for the first time, so a newly configured symbol gets
//--- the full window to produce its first tick instead of being declared stale
//--- on arrival. Callers compare against their own threshold.
//---
//--- Memoised for one second, for the same reason CopierInTradingSession is:
//--- this runs from the converge loop and the outbox, both per-symbol per-tick,
//--- and the answer cannot change meaningfully inside a second when the
//--- thresholds it feeds are measured in tens of seconds.
long CopierSymbolQuoteAgeMs(const string sym)
  {
   if(StringLen(sym)==0) return 0;

   long now=CopierNowMs();
   for(int i=0;i<CP_SYMFRESH_CACHE;i++)
     {
      if(g_sfcKey[i]==sym && now-g_sfcAt[i]<1000) return g_sfcAge[i];
     }

   int slot=-1;
   for(int j=0;j<CP_SYMFRESH_SLOTS;j++)
     {
      if(g_sfKey[j]==sym) { slot=j; break; }
     }
   if(slot<0)
     {
      slot=g_sfHead;
      g_sfHead++;
      if(g_sfHead>=CP_SYMFRESH_SLOTS) g_sfHead=0;
      bool wasUsed=(StringLen(g_sfKey[slot])>0);
      g_sfKey[slot]=sym;
      g_sfQuote[slot]=0;
      // NM-05: If replacing an existing slot, set changedMs to 0 so it relies on clockAge
      // instead of resetting age to 0. First-ever seen slots still get 'now' grace period.
      g_sfChangedMs[slot]=wasUsed?0:now;
     }

   datetime qt=CopierSymbolQuoteTime(sym);
   if(qt!=g_sfQuote[slot])
     {
      g_sfQuote[slot]=qt;
      g_sfChangedMs[slot]=now;
     }
   long age=now-g_sfChangedMs[slot];

   //--- AND the age implied by the two clocks, which needs no history at all.
   //---
   //--- This is what lets the gate bite on the FIRST pass instead of after a
   //--- full stall window. A freshly attached receiver has no per-symbol
   //--- history, so a purely monotonic age starts at zero and cannot trip
   //--- until it has been watching for CP_SYM_STALL_MS - which is a full
   //--- window of doomed attempts against a market that was ALREADY shut when
   //--- the EA loaded. That is not hypothetical: it is four broker rejections
   //--- per symbol on every single re-attach.
   //---
   //--- It works because the two platforms differ exactly where it matters:
   //---
   //---   MT5  CopierServerTime() is TimeTradeServer(), which the terminal
   //---        keeps advancing from its trade-server connection. So
   //---        (server now - last quote) is already enormous at attach time.
   //---   MT4  CopierServerTime() is TimeCurrent(), which is tick-driven and
   //---        therefore frozen at the close. This term is ~0 there, and the
   //---        monotonic age above does the work instead - which is correct,
   //---        because on MT4 the global clock gate has already fired.
   //---
   //--- A quote time in the FUTURE (clock skew) is ignored rather than
   //--- trusted: a negative age is not information.
   long clockAge=CopierClockAgeMs(qt,CopierServerTime());
   if(clockAge>age) age=clockAge;

   g_sfcKey[g_sfcHead]=sym;
   g_sfcAt[g_sfcHead]=now;
   g_sfcAge[g_sfcHead]=age;
   g_sfcHead++;
   if(g_sfcHead>=CP_SYMFRESH_CACHE) g_sfcHead=0;

   return age;
  }

//--- Reset the tracker. Called from OnInit so a reinitialise cannot inherit a
//--- stale timestamp and hold every symbol for a minute on attach.
void CopierSymbolQuoteReset()
  {
   for(int i=0;i<CP_SYMFRESH_SLOTS;i++)
     {
      g_sfKey[i]="";
      g_sfQuote[i]=0;
      g_sfChangedMs[i]=0;
     }
   g_sfHead=0;
   for(int j=0;j<CP_SYMFRESH_CACHE;j++)
     {
      g_sfcKey[j]="";
      g_sfcAt[j]=0;
      g_sfcAge[j]=0;
     }
   g_sfcHead=0;
  }

//--- Is this symbol's feed stale enough to stop acting on it?
//---
//--- The question the callers actually ask. Thin on purpose: the memo lives on
//--- the age above, so a caller that wants a different threshold gets a
//--- correctly-answered question rather than whatever the previous caller
//--- happened to ask.
bool CopierSymbolFeedStale(const string sym,const long stallMs)
  {
   if(StringLen(sym)==0) return false;
   return CopierSymbolQuoteAgeMs(sym)>stallMs;
  }

//--- Is this symbol USABLE right now, without touching Market Watch?
//---
//--- Deliberately side-effect free so it can be called from a hot loop. It
//--- answers "can I price this?", not "does the broker offer this?" - a symbol
//--- the broker lists but has not selected answers NO here, and that is the
//--- case CopierSymbolExists() below exists to fix.
bool CopierSymbolReady(const string sym)
  {
   if(StringLen(sym)==0) return false;
#ifdef __MQL5__
   double point=0.0;
   if(!SymbolInfoDouble(sym,SYMBOL_POINT,point)) return false;
   return point>0.0;
#else
   return MarketInfo(sym,MODE_POINT)>0.0;
#endif
  }

bool CopierSymbolExists(const string sym)
  {
   if(StringLen(sym)==0) return false;

   //--- CHEAP CHECK FIRST. This runs from the converge loop, which is ~10 Hz
   //--- per symbol; touching Market Watch on every one of those calls is
   //--- pointless work when the symbol is already usable. Only a symbol that
   //--- is NOT yet usable is worth an attempt to select.
   if(CopierSymbolReady(sym)) return true;

#ifdef __MQL5__
   //--- SymbolSelect returns false for a symbol the broker does not offer,
   //--- and is a no-op when it is already in Market Watch. It is also what
   //--- makes the symbol's data available, so calling it here is the point.
   if(!SymbolSelect(sym,true)) return false;
   return CopierSymbolReady(sym);
#else
   //--- MT4 DOES have SymbolSelect, and it is required here.
   //---
   //--- This used to be a bare MarketInfo() call on the assumption that MT4
   //--- reports properties for any symbol the broker lists, Market Watch or
   //--- not. That assumption is WRONG: MarketInfo returns 0 for a symbol that
   //--- is offered but not selected, so a perfectly tradeable symbol was
   //--- reported "not offered by this broker" and skipped for good - the
   //--- receiver could never fix that by itself, and the operator saw a
   //--- plausible-looking error about a broker limitation that did not exist.
   //---
   //--- Verified by compiling a probe against this machine's MT4, WITH a
   //--- negative control (a deliberately invalid function) to prove the check
   //--- can fail. Do not "simplify" this back to a bare MarketInfo.
   if(!SymbolSelect(sym,true)) return false;
   return CopierSymbolReady(sym);
#endif
  }

class CopierSymbolMap
  {
private:
   string            m_from[CP_MAX_SYMBOL_MAP];
   string            m_to[CP_MAX_SYMBOL_MAP];
   int               m_n;
   string            m_suffix;

public:
                     CopierSymbolMap():m_n(0),m_suffix("") { Clear(); }

   void              Clear()
     {
      for(int i=0;i<CP_MAX_SYMBOL_MAP;i++) { m_from[i]=""; m_to[i]=""; }
      m_n=0;
     }

   //--- exact mapping: SenderSymbol -> ReceiverSymbol
   bool              Add(const string from,const string to)
     {
      if(StringLen(from)==0 || StringLen(to)==0) return false;
      for(int i=0;i<m_n;i++)
        {
         if(m_from[i]==from) { m_to[i]=to; return true; }
        }
      if(m_n>=CP_MAX_SYMBOL_MAP) return false;
      m_from[m_n]=from;
      m_to[m_n]=to;
      m_n++;
      return true;
     }

   //--- blanket suffix for everything not in the explicit table.
   //--- "" or "none" disables it.
   void              SetSuffix(const string sfx)
     {
      if(sfx=="" || sfx=="none" || sfx=="(none)") { m_suffix=""; return; }
      m_suffix=sfx;
     }

   string            Suffix() const { return m_suffix; }
   int               Count()  const { return m_n; }

   string            Map(const string sym) const
     {
      //--- 1) explicit table wins
      for(int i=0;i<m_n;i++)
        {
         if(m_from[i]==sym) return m_to[i];
        }
      //--- 2) suffix rule: check direct concatenation first (e.g. suffix="m" -> "EURUSDm"),
      //--- then fallback to dotted form if not already dotted (e.g. "EURUSD.m")
      if(StringLen(m_suffix)>0)
        {
         string cand1=sym+m_suffix;
         if(CopierSymbolExists(cand1)) return cand1;
         if(StringSubstr(m_suffix,0,1)!=".")
           {
            string cand2=sym+"."+m_suffix;
            if(CopierSymbolExists(cand2)) return cand2;
           }
        }
      //--- 3) as-is
      return sym;
     }

   //--- convenience: does this terminal know the symbol at all?
   static bool       Exists(const string sym) { return CopierSymbolExists(sym); }
  };

#endif
//+------------------------------------------------------------------+
