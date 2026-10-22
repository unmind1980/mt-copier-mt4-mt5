//+------------------------------------------------------------------+
// CopierFilter.mqh - shared allow/deny lists
//
// One implementation, used by BOTH the sender (which decides what to
// broadcast) and the receiver (which decides what to mirror).
//
// That sharing is the point. The sender already had a symbol list with the
// "! means exclude" convention; the receiver needs the identical rule for
// PermittedSymbols. Two copies of "parse a CSV and honour a leading !" is
// how the two ends end up disagreeing about what "!EURUSD" means - and the
// symptom would be a symbol silently dropped at one end and mirrored at the
// other, with neither side logging anything wrong.
//+------------------------------------------------------------------+
#ifndef __COPIER_FILTER_MQH__
#define __COPIER_FILTER_MQH__

#include <Copier/CopierDefs.mqh>

class CopierList
  {
private:
   string            m_item[];
   bool              m_exclude;   // the list began with "!"
   bool              m_active;
   int               m_strayBang; // items that carried a "!" of their own

public:
                     CopierList():m_exclude(false),m_active(false),
                                  m_strayBang(0) {}

   bool              Active() const { return m_active; }

   //--- Items that had their own leading "!". The list still works - the
   //--- stray marks are stripped - but the count is exposed so the caller can
   //--- say something, because the alternative is a user believing they wrote
   //--- a reject list when they actually wrote one item called "!GBPUSD".
   int               StrayBangs() const { return m_strayBang; }

   //--- "EURUSD,GBPUSD"      -> only these
   //--- "!EURUSD,GBPUSD"     -> everything except these
   //--- ""                   -> no filtering at all
   //---
   //--- Blank means INACTIVE rather than "deny everything": an empty input is
   //--- the default, and defaulting to "mirror nothing" would make a fresh
   //--- install look broken.
   void              Set(const string csv)
     {
      ArrayResize(m_item,0);
      m_exclude=false;
      m_active=false;
      m_strayBang=0;

      string s=CopierTrim(csv);
      if(StringLen(s)==0) return;

      if(StringSubstr(s,0,1)=="!")
        {
         m_exclude=true;
         s=CopierTrim(StringSubstr(s,1));
        }

      string parts[];
      int n=StringSplit(s,',',parts);
      int kept=0;
      for(int i=0;i<n;i++)
        {
         string v=CopierTrim(parts[i]);
         if(StringLen(v)==0) continue;      // tolerate "A,,B" and trailing ","

         //--- A "!" on an INDIVIDUAL item is a very common misreading: people
         //--- write "!EURUSD,!GBPUSD" meaning "exclude both". Taken literally
         //--- the second item is a symbol NAMED "!GBPUSD", which matches
         //--- nothing, so GBPUSD is not excluded and nothing anywhere says so.
         //--- Strip it and count it: the intent works, and the caller can tell
         //--- the user their list was not quite what they thought.
         if(StringSubstr(v,0,1)=="!")
           {
            m_strayBang++;
            v=CopierTrim(StringSubstr(v,1));
            if(StringLen(v)==0) continue;
           }

         ArrayResize(m_item,kept+1);
         m_item[kept]=v;
         kept++;
        }
      m_active=(kept>0);
     }

   //--- Case-SENSITIVE on purpose. The receiver matches against the broker's
   //--- own symbol names, and "eurusd" and "EURUSD" are different strings to
   //--- the terminal - silently lower-casing them would make a list that
   //--- looks right match nothing, or worse, match the wrong symbol.
   bool              Allows(const string v) const
     {
      if(!m_active) return true;
      bool found=false;
      for(int i=0;i<ArraySize(m_item);i++)
        {
         if(m_item[i]==v) { found=true; break; }
        }
      return m_exclude ? !found : found;
     }

   int               Count() const { return ArraySize(m_item); }
  };

//+------------------------------------------------------------------+
// Trading windows.
//
// Compared against the terminal's clock, i.e. SERVER time. That is the
// useful frame here: what these windows usually exist to avoid - a session
// open, a rollover, a news release - happens at a fixed server time, not at
// a fixed local time in the operator's country.
//
// "HH:MM-HH:MM", comma-separated. Two cases are easy to get wrong and are
// handled explicitly below:
//
//   * END BEFORE START wraps past midnight. 22:00-02:00 is ONE window that
//     runs through midnight, not an empty range. Treating it as empty would
//     silently forbid trading during the exact hours it was written to allow.
//     Note: In DayTradingTimes, wrapping applies to that calendar day's
//     00:00-02:00 and 22:00-24:00. To explicitly bridge across two days, specify
//     each day (e.g. "Mon=22:00-24:00;Tue=00:00-02:00").
//   * START == END means all day. A zero-length window is never what anyone
//     means, and 00:00-00:00 is the natural way to write "always".
//+------------------------------------------------------------------+
#define CP_TT_MAX 8

long CopierParseHhMm(const string s)
  {
   string p[];
   int n=StringSplit(CopierTrim(s),':',p);
   if(n<2) return -1;
   int h=(int)StringToInteger(CopierTrim(p[0]));
   int m=(int)StringToInteger(CopierTrim(p[1]));
   if(h<0 || h>23 || m<0 || m>59) return -1;
   return (long)h*3600+(long)m*60;
  }

//--- 0=Sun .. 6=Sat, matching TimeDayOfWeek() in both MQL4 and MQL5
int CopierDayIndex(const string name)
  {
   string s=name;
   //--- StringToLower modifies the string in-place by reference in MQL4/MQL5.
   StringToLower(s);
   if(s=="sun") return 0;
   if(s=="mon") return 1;
   if(s=="tue") return 2;
   if(s=="wed") return 3;
   if(s=="thu") return 4;
   if(s=="fri") return 5;
   if(s=="sat") return 6;
   return -1;
  }

//--- "08:00-12:00,13:00-17:00" -> pairs of seconds-since-midnight
int CopierParseRanges(const string csv,long &from[],long &to[])
  {
   ArrayResize(from,0);
   ArrayResize(to,0);
   string s=CopierTrim(csv);
   if(StringLen(s)==0) return 0;

   string parts[];
   int n=StringSplit(s,',',parts);
   int kept=0;
   for(int i=0;i<n;i++)
     {
      string r=CopierTrim(parts[i]);
      if(StringLen(r)==0) continue;
      int dash=StringFind(r,"-");
      if(dash<=0) continue;                      // needs both sides
      long a=CopierParseHhMm(StringSubstr(r,0,dash));
      long b=CopierParseHhMm(StringSubstr(r,dash+1));
      if(a<0 || b<0) continue;                   // malformed: skip this range
      if(kept>=CP_TT_MAX) break;
      ArrayResize(from,kept+1);
      ArrayResize(to,kept+1);
      from[kept]=a;
      to[kept]=b;
      kept++;
     }
   return kept;
  }

class CopierTradingTimes
  {
private:
   bool              m_active;
   long              m_from[CP_TT_MAX];
   long              m_to[CP_TT_MAX];
   int               m_n;
   bool              m_daySet[7];
   long              m_dFrom[7*CP_TT_MAX];   // flat, because passing a row of
   long              m_dTo[7*CP_TT_MAX];     // a 2D array is not portable
   int               m_dN[7];

   //--- Same test, against a ROW of the flat day arrays rather than a copy of
   //--- it. The day branch used to declare two long[CP_TT_MAX] locals and copy
   //--- the row into them on every call - on every tick, for every position
   //--- that reached the hours gate. Reading the row in place is the same
   //--- answer with no copy and no local array to construct.
   bool              HitAt(const long &fr[],const long &to[],const int base,
                           const int n,const int sec) const
     {
      for(int i=0;i<n;i++)
        {
         long a=fr[base+i],b=to[base+i];
         if(a==b) return true;                    // all day
         if(a<b) { if(sec>=a && sec<=b) return true; }
         else    { if(sec>=a || sec<=b) return true; }   // wraps midnight
        }
      return false;
     }

   bool              Hit(const long &fr[],const long &to[],const int n,
                         const int sec) const
     {
      return HitAt(fr,to,0,n,sec);
     }

public:
                     CopierTradingTimes():m_active(false),m_n(0)
     {
      for(int i=0;i<7;i++) { m_daySet[i]=false; m_dN[i]=0; }
      for(int i=0;i<7*CP_TT_MAX;i++) { m_dFrom[i]=0; m_dTo[i]=0; }
     }

   bool              Active() const { return m_active; }

   void              Set(const string daily,const string perDay)
     {
      m_n=CopierParseRanges(daily,m_from,m_to);
      for(int i=0;i<7;i++) { m_daySet[i]=false; m_dN[i]=0; }

      string s=CopierTrim(perDay);
      if(StringLen(s)>0)
        {
         string parts[];
         int np=StringSplit(s,';',parts);
         for(int i=0;i<np;i++)
           {
            string e=CopierTrim(parts[i]);
            if(StringLen(e)==0) continue;
            int eq=StringFind(e,"=");
            if(eq<=0) continue;
            int di=CopierDayIndex(StringSubstr(e,0,eq));
            if(di<0) continue;

            //--- an empty right-hand side is meaningful: it CLOSES that day
            long f[],t[];
            int k=CopierParseRanges(StringSubstr(e,eq+1),f,t);
            m_daySet[di]=true;
            m_dN[di]=(k>CP_TT_MAX)?CP_TT_MAX:k;
            for(int j=0;j<m_dN[di];j++)
              {
               m_dFrom[di*CP_TT_MAX+j]=f[j];
               m_dTo[di*CP_TT_MAX+j]=t[j];
              }
           }
        }

      bool anyDay=false;
      for(int i=0;i<7;i++) { if(m_daySet[i]) anyDay=true; }
      m_active=(m_n>0) || anyDay;
     }

   //--- Decomposed by ARITHMETIC, not by TimeHour/TimeMinute/TimeDayOfWeek.
   //---
   //--- Those helpers are not portable: MQL4 has TimeSeconds (plural) and no
   //--- TimeSecond, while MQL5 has no TimeHour at all - it expects
   //--- MqlDateTime + TimeToStruct. A `datetime` is seconds since 1970-01-01
   //--- on BOTH platforms, so plain arithmetic works everywhere and cannot
   //--- drift with a terminal build.
   //---
   //--- The +4 is because 1970-01-01 was a Thursday, and the result is
   //--- indexed 0=Sunday to match the DayTradingTimes names.
   static int        SecOfDay(const datetime t) { return (int)((long)t%86400); }
   static int        DayOfWeek7(const datetime t)
     { return (int)((((long)t/86400)+4)%7); }

   //--- `now` must be SERVER time - pass CopierServerTime(), not TimeLocal().
   bool              Allows(const datetime now) const
     {
      if(!m_active) return true;
      int sec=SecOfDay(now);
      int dow=DayOfWeek7(now);

      //--- 1) Check if the previous day had a midnight-wrapping session (a > b)
      //--- that extends into today's early morning (sec <= b).
      int prevDow=(dow+6)%7;
      if(m_daySet[prevDow])
        {
         int pn=m_dN[prevDow];
         int pBase=prevDow*CP_TT_MAX;
         for(int j=0;j<pn;j++)
           {
            if(m_dFrom[pBase+j]>m_dTo[pBase+j] && sec<=m_dTo[pBase+j]) return true;
           }
        }

      //--- 2) a day named in DayTradingTimes REPLACES the blanket list for that
      //--- day rather than adding to it: "Mon=08:00-12:00" must not also
      //--- inherit the weekday 13:00-17:00 window.
      if(m_daySet[dow])
        {
         int n=m_dN[dow];
         return HitAt(m_dFrom,m_dTo,dow*CP_TT_MAX,n,sec);
        }
      return Hit(m_from,m_to,m_n,sec);
     }
  };

#endif
//+------------------------------------------------------------------+
