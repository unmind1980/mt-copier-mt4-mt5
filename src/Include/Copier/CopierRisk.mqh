//+------------------------------------------------------------------+
//| CopierRisk.mqh - risk switches (the circuit breakers)            |
//|                                                                   |
//| These exist because the copier's job is to reproduce SOMEONE      |
//| ELSE'S trading, and it has no opinion about whether that trading  |
//| is sane. A sender with a fat finger, a broken lot calculation, or |
//| simply a much larger account will happily tell the receiver to    |
//| open something ruinous, and the receiver will faithfully do it.   |
//|                                                                   |
//| Every switch defaults to OFF, so an unconfigured receiver behaves |
//| exactly as it did before this file existed.                       |
//|                                                                   |
//| WHAT IS GATED: opening a NEW position, and nothing else. A trim,  |
//| a close, a dedup removal or a stop adjustment all reduce or       |
//| preserve risk, so blocking any of them would be backwards - and   |
//| blocking a CLOSE would be actively dangerous.                     |
//|                                                                   |
//| Deliberately depends on CopierDefs only, so the self-test can     |
//| drive it with synthetic equity curves and no broker.              |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_RISK_MQH__
#define __COPIER_RISK_MQH__

#include "CopierDefs.mqh"

//=====================================================================
// The limits. 0 / false means "switch off", everywhere.
//=====================================================================
struct CopierRiskLimits
  {
   double maxLotsPerPosition;   // 0 = off. Cap on a single mirrored position
   double maxTotalLots;         // 0 = off. Cap on aggregate mirrored volume
   int    maxOpenPositions;     // 0 = off. Cap on concurrent mirrored positions
   double dailyLossPct;         // 0 = off. Stop for the day after this % loss
   double maxDrawdownPct;       // 0 = off. Stop until reload after this % fall
  };

//=====================================================================
// The equity level at which a percentage switch trips.
//
// This is the number an operator actually wants: "stop when equity is
// 5% down" is abstract, "stop at or below 9500.00" is actionable. It is
// the single definition of the boundary - CopierLossExceeded() is
// expressed in terms of it, so the threshold the switch uses and the
// threshold the log quotes can never drift apart.
//=====================================================================
double CopierLossTripLevel(const double baseline,const double pct)
  {
   if(!MathIsValidNumber(baseline) || baseline<=0.0) return 0.0;
   if(!MathIsValidNumber(pct) || pct<=0.0)      return 0.0;   // switch off: no level
   if(pct>=100.0) return 0.0; // 100% loss trips only on complete wipeout (equity <= 0)
   return baseline*(1.0-pct/100.0);
  }

//=====================================================================
// Has the loss from `baseline` reached `pct` percent?
//
// Measured on EQUITY, not balance, so open positions count. A stop that
// ignored floating loss would sit quiet through exactly the situation it
// exists for.
//
// `<=` rather than `<`: "down 5%" should trip at exactly 5%, and the
// boundary is the case a test will actually exercise.
//=====================================================================
bool CopierLossExceeded(const double equity,const double baseline,const double pct)
  {
   if(!MathIsValidNumber(equity) || !MathIsValidNumber(baseline) || !MathIsValidNumber(pct)) return false;
   if(pct<=0.0)      return false;   // switch off
   if(baseline<=0.0) return false;   // nothing to measure from
   if(pct>=100.0)    return (equity<=0.0); // complete wipeout
   return (equity<=CopierLossTripLevel(baseline,pct));
  }

//=====================================================================
// Do the size / count / volume caps allow one more position of `lots`?
//
// Pure, so every boundary is testable. `why` is filled with a message
// meant to be read by a human at 3am, not a code.
//=====================================================================
bool CopierRiskAllowsOpen(const CopierRiskLimits &lim,const double lots,
                          const int openCount,const double totalLots,
                          string &why)
  {
   why="";
   if(lim.maxLotsPerPosition>0.0 && lots>lim.maxLotsPerPosition+0.0000001)
     {
      why="this position is "+DoubleToString(lots,2)+" lots and"
          +" MaxLotsPerPosition is "+DoubleToString(lim.maxLotsPerPosition,2);
      return false;
     }
   if(lim.maxOpenPositions>0 && openCount>=lim.maxOpenPositions)
     {
      why="already holding "+(string)openCount+" position(s) and"
          +" MaxOpenPositions is "+(string)lim.maxOpenPositions;
      return false;
     }
   if(lim.maxTotalLots>0.0 && totalLots+lots>lim.maxTotalLots+0.0000001)
     {
      why="adding "+DoubleToString(lots,2)+" would take total volume to "
          +DoubleToString(totalLots+lots,2)+" and MaxTotalLots is "
          +DoubleToString(lim.maxTotalLots,2);
      return false;
     }
   return true;
  }

//=====================================================================
// The stateful half: remembers the baselines the two percentage
// switches are measured from.
//=====================================================================
class CopierRisk
  {
private:
   CopierRiskLimits  m_lim;
   bool              m_armed;
   long              m_day;
   double            m_dayStartEquity;
   double            m_peakEquity;
   bool              m_dailyTripped;
   bool              m_ddTripped;
   bool              m_justTripped;

public:
                     CopierRisk():m_armed(false),m_day(0),
                     m_dayStartEquity(0.0),m_peakEquity(0.0),
                     m_dailyTripped(false),m_ddTripped(false),
                     m_justTripped(false) {}

   //=================================================================
   // Apply a new set of limits.
   //
   // THIS MUST RE-EVALUATE THE LATCHES, and the reason is a MetaTrader
   // behaviour that is easy to miss: changing an EA's inputs reinitialises
   // it - OnDeinit then OnInit - but does NOT reset its globals, because the
   // process stays alive. So a tripped switch survived the operator turning
   // it off, and the only way out was to remove and re-add the EA. Reported
   // from a live test: DailyLossPct went 0.1 -> 0 and the receiver kept
   // refusing new entries.
   //
   // A change of limits therefore clears both latches and lets the next
   // observation re-derive them against the NEW limits and the CURRENT
   // equity. A switch that is now off, or no longer exceeded, clears; one
   // that is still exceeded re-trips immediately, which is correct.
   //
   // The comparison is deliberately exact. These values come straight from
   // input fields, so "did the operator change it" is an equality question,
   // not an approximate one - and an input change that does NOT touch the
   // limits must leave the latches alone.
   //
   // The peak is deliberately KEPT: it is a property of the account's equity
   // curve, not of the configuration. Keeping it is what makes "raise the
   // drawdown threshold to resume" behave sensibly instead of silently
   // re-basing the drawdown to zero.
   //=================================================================
   void              Configure(const CopierRiskLimits &lim)
     {
      bool changed=(m_lim.maxLotsPerPosition!=lim.maxLotsPerPosition
                    || m_lim.maxTotalLots  !=lim.maxTotalLots
                    || m_lim.maxOpenPositions!=lim.maxOpenPositions
                    || m_lim.dailyLossPct  !=lim.dailyLossPct
                    || m_lim.maxDrawdownPct!=lim.maxDrawdownPct);
      m_lim=lim;
      if(!changed) return;
      m_dailyTripped=false;
      m_ddTripped=false;
     }

   bool              Enabled() const
     {
      return (m_lim.maxLotsPerPosition>0.0 || m_lim.maxTotalLots>0.0
              || m_lim.maxOpenPositions>0 || m_lim.dailyLossPct>0.0
              || m_lim.maxDrawdownPct>0.0);
     }

   //--- Take one observation. `equity` and `serverDay` are passed in
   //--- rather than read here, so a test can replay an equity curve.
   //---
   //--- `dayStartEquity` must be the equity at the START of the server day,
   //--- not at EA start - otherwise restarting the EA mid-day silently
   //--- forgives the morning's losses, which is exactly when the switch
   //--- matters most. The receiver derives it from balance minus today's
   //--- realised P&L, which stays constant through the day.
   void              ObserveAt(const double equity,const long serverDay,
                               const double dayStartEquity)
     {
      if(!MathIsValidNumber(equity)) return;
      // P3-6 & P2-12: If account equity dropped to zero or negative (complete blowout), trip immediately
      if(equity<=0.0)
        {
         if(!m_dailyTripped) { m_dailyTripped=true; m_justTripped=true; }
         if(!m_ddTripped) { m_ddTripped=true; m_justTripped=true; }
         return;
        }

      if(!m_armed)
        {
         m_day=serverDay;
         m_dayStartEquity=dayStartEquity;
         if(dayStartEquity>0.0) m_armed=true; // INC-03: Only permanently arm once valid dayStartEquity is established
         if(equity>m_peakEquity) m_peakEquity=equity;
        }
      else if(serverDay!=m_day)
        {
         m_day=serverDay;
         m_dayStartEquity=dayStartEquity;
         m_dailyTripped=false;
        }
      else if(dayStartEquity>0.0 && (m_dayStartEquity<=0.0 || MathAbs(dayStartEquity-m_dayStartEquity)>0.001))
        {
         // INC-03 & N49-01: Update and heal m_dayStartEquity when recalibrated intraday or after initial zero
         m_dayStartEquity=dayStartEquity;
        }

      if(equity>m_peakEquity) m_peakEquity=equity;

      if(!m_dailyTripped
         && CopierLossExceeded(equity,m_dayStartEquity,m_lim.dailyLossPct))
        {
         m_dailyTripped=true;
         m_justTripped=true;
        }
      if(!m_ddTripped
         && CopierLossExceeded(equity,m_peakEquity,m_lim.maxDrawdownPct))
        {
         m_ddTripped=true;
         m_justTripped=true;
        }
     }

   //--- true exactly once, on the observation that tripped something, so
   //--- the caller can act on the transition instead of on the state
   bool              TakeJustTripped()
     {
      bool v=m_justTripped;
      m_justTripped=false;
      return v;
     }

   bool              DailyTripped() const { return m_dailyTripped; }
   bool              DrawdownTripped() const { return m_ddTripped; }
   bool              AnyTripped() const { return (m_dailyTripped||m_ddTripped); }

   //--- Restore a peak measured in an EARLIER run.
   //---
   //--- WHY THIS EXISTS
   //--- ===============
   //--- The peak is the baseline the drawdown switch is measured from, and it
   //--- lived only in memory. Every terminal restart therefore re-based it to
   //--- the equity of the moment - so the one switch whose whole job is
   //--- "stop and look at this" was silently forgiven by the very event most
   //--- likely to follow a bad day. The receiver persists it beside the
   //--- position state and calls this before the first observation.
   //---
   //--- Only ever RAISES: a stored peak lower than the current one is
   //--- history that the live curve has already surpassed.
   void              SeedPeak(const double peak)
     {
      if(peak>m_peakEquity) m_peakEquity=peak;
     }

   double            DayStartEquity() const { return m_dayStartEquity; }
   double            PeakEquity() const { return m_peakEquity; }

   //=================================================================
   // The two trip messages.
   //
   // They quote the equity, the baseline it is measured against, how far
   // down that is, AND the level at which the switch trips. "Down 5%" does
   // not tell an operator where the line actually is, and that is exactly
   // the question they are asking when they read the line.
   //
   // `equity` is a parameter rather than read here so the text is
   // reproducible in a test.
   //=================================================================
   string            DailyWhy(const double equity) const
     {
      string s="daily loss limit reached: equity "+DoubleToString(equity,2);
      if(m_dayStartEquity>0.0)
         s+=", down "
            +DoubleToString(100.0*(m_dayStartEquity-equity)/m_dayStartEquity,2)
            +"% from the day's opening equity "
            +DoubleToString(m_dayStartEquity,2)
            +"; the "+DoubleToString(m_lim.dailyLossPct,2)+"% limit trips at or"
            +" below "
            +DoubleToString(CopierLossTripLevel(m_dayStartEquity,m_lim.dailyLossPct),2);
      s+=". New entries resume on the next server day";
      return s;
     }

   string            DrawdownWhy(const double equity) const
     {
      string s="drawdown limit reached: equity "+DoubleToString(equity,2);
      if(m_peakEquity>0.0)
         s+=", down "
            +DoubleToString(100.0*(m_peakEquity-equity)/m_peakEquity,2)
            +"% from the session peak "+DoubleToString(m_peakEquity,2)
            +"; the "+DoubleToString(m_lim.maxDrawdownPct,2)+"% limit trips at or"
            +" below "
            +DoubleToString(CopierLossTripLevel(m_peakEquity,m_lim.maxDrawdownPct),2);
      s+=". Raise MaxDrawdownPct or reload the EA to resume";
      return s;
     }

   //--- A STABLE identifier for whatever is blocking right now.
   //---
   //--- The human messages above quote live equity and therefore change on
   //--- every tick. Using one as a rate-limit key would defeat the rate
   //--- limiter entirely - every message would look like a new one - so the
   //--- caller keys on THIS and prints the message.
   string            BlockKey() const
     {
      if(m_dailyTripped) return "daily";
      if(m_ddTripped)    return "drawdown";
      return "";
     }

   //--- The whole decision for one prospective entry.
   //---
   //--- `held` is what EXISTS; `pending` is what the queue is about to ADD.
   //--- They are separate arguments ON PURPOSE. Passing only the held
   //--- figures is the bug that let MaxOpenPositions=3 open four positions:
   //--- converge queues several opens in a single pass, and every one of
   //--- them was checked against the same pre-open numbers. A caller that
   //--- has no pending work simply passes zeros, but it has to say so.
   bool              AllowOpen(const double lots,
                               const int heldCount,const double heldLots,
                               const int pendingCount,const double pendingLots,
                               string &why)
     {
      why="";
      if(m_dailyTripped)
        {
         why=DailyWhy(CopierAccountEquity());
         return false;
        }
      if(m_ddTripped)
        {
         why=DrawdownWhy(CopierAccountEquity());
         return false;
        }
      return CopierRiskAllowsOpen(m_lim,lots,
                                  heldCount+pendingCount,
                                  heldLots+pendingLots,why);
     }

   //--- One line for the log. Empty when nothing is configured, so the
   //--- caller can skip printing it entirely.
   string            Status() const
     {
      string s="";
      if(m_lim.maxLotsPerPosition>0.0)
         s+="maxLotsPerPosition="+DoubleToString(m_lim.maxLotsPerPosition,2)+" ";
      if(m_lim.maxTotalLots>0.0)
         s+="maxTotalLots="+DoubleToString(m_lim.maxTotalLots,2)+" ";
      if(m_lim.maxOpenPositions>0)
         s+="maxOpenPositions="+(string)m_lim.maxOpenPositions+" ";
      if(m_lim.dailyLossPct>0.0)
         s+="dailyLossPct="+DoubleToString(m_lim.dailyLossPct,2)+" ";
      if(m_lim.maxDrawdownPct>0.0)
         s+="maxDrawdownPct="+DoubleToString(m_lim.maxDrawdownPct,2)+" ";
      return s;
     }

   //--- Why the switch is currently blocking, for the repeat report.
   //--- The SAME text the blocked-entry line uses, so the two always agree
   //--- instead of drifting apart as one of them gets edited.
   string            TripReason() const
     {
      double eq=CopierAccountEquity();
      if(m_dailyTripped) return DailyWhy(eq);
      if(m_ddTripped)    return DrawdownWhy(eq);
      return "";
     }

   double            DailyLossPct() const { return m_lim.dailyLossPct; }
   double            MaxDrawdownPct() const { return m_lim.maxDrawdownPct; }
   void              SetDayStartEquity(const double eq) { if(eq>0.0) m_dayStartEquity=eq; }
  };

#endif
//+------------------------------------------------------------------+
