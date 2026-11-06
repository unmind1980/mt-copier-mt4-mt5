//+------------------------------------------------------------------+
//|                                       CopierSymFreshBench.mq4     |
//|                                                                   |
//| Diagnostic only: measures the per-symbol quote-freshness gate.     |
//| Touches no broker, places no trade, needs no account, no network.  |
//| Drop it on any chart, read the Experts log (and                    |
//| copier_symfresh_bench.log), then remove it.                       |
//|                                                                   |
//| WHAT IT ANSWERS                                                   |
//| ===============                                                    |
//| `CopierSymbolFeedStale()` is asked once per desired entry, once per |
//| local position and once per queued action, on EVERY timer tick -    |
//| and the tick is PollMs, 5 ms by default. Its answer is memoised in  |
//| CP_SYMFRESH_CACHE (16) entries, which is smaller than the working   |
//| set of any receiver mirroring more than sixteen symbols. Past that   |
//| point the entries evict each other between ticks, the 1 s TTL never |
//| helps, and every call walks the 256-slot table and asks the         |
//| terminal for a quote time.                                           |
//|                                                                     |
//| The table below walks the working set across that boundary, so the  |
//| cliff at 17 symbols is visible rather than argued about.            |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <Copier/CopierDefs.mqh>
#include <Copier/CopierCodec.mqh>
#include <Copier/CopierSymbol.mqh>

//--- Calls per measurement. Bigger = steadier, slower. 20000 takes a few
//--- seconds in total across the whole table.
input int InpIterations = 20000;

//--- The working sets to measure. 16 is CP_SYMFRESH_CACHE; 17 is the first
//--- size that cannot fit in the memo.
int g_sizes[8] = {1, 8, 16, 17, 20, 32, 50, 100};

int  g_log=INVALID_HANDLE;

void Out(const string s)
  {
   Print(s);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,s); FileFlush(g_log); }
  }

//--- Build `n` symbol names. Real Market Watch names first (the platform call is
//--- part of what is measured); padded with names the terminal does not know when
//--- the Market Watch is short, which keeps the TABLE the same size - the scan
//--- cost stays representative, the platform call becomes the cheap unknown path.
void BuildSymbols(const int n,string &syms[],int &realCount)
  {
   ArrayResize(syms,0);
   realCount=0;
   int total=SymbolsTotal(true);
   for(int i=0;i<total && ArraySize(syms)<n;i++)
     {
      string s=SymbolName(i,true);
      if(StringLen(s)==0) continue;
      int m=ArraySize(syms);
      ArrayResize(syms,m+1,128);
      syms[m]=s;
      realCount++;
     }
   while(ArraySize(syms)<n)
     {
      int m=ArraySize(syms);
      ArrayResize(syms,m+1,128);
      syms[m]="CPBENCH"+(string)m;
     }
  }

//--- One measurement: `n` symbols, `iter` calls, round-robin.
//--- Returns microseconds per call, or -1 if the timer could not resolve it.
double Measure(const int n,const int iter)
  {
   string syms[];
   int realCount=0;
   BuildSymbols(n,syms,realCount);
   if(ArraySize(syms)<=0) return -1.0;

   CopierSymbolQuoteReset();
   //--- warm-up pass: the first visit to each symbol populates the table, and for
   //--- n <= CP_SYMFRESH_CACHE also the memo. Without this the first pass would be
   //--- measured as if it were the steady state.
   long sink=0;
   for(int w=0;w<ArraySize(syms);w++) sink+=CopierSymbolQuoteAgeMs(syms[w]);

   long t0=GetTickCount();
   for(int i=0;i<iter;i++) sink+=CopierSymbolQuoteAgeMs(syms[i%ArraySize(syms)]);
   long ms=(long)(GetTickCount()-t0);
   if(ms<=0) return -1.0;              // below the timer's granularity
   return (ms*1000.0)/iter;
  }

void OnStart()
  {
   FileDelete("copier_symfresh_bench.log");
   g_log=FileOpen("copier_symfresh_bench.log",FILE_WRITE|FILE_TXT|FILE_ANSI);

   Out("================================================================");
   Out(" per-symbol quote-freshness gate - cost by working-set size");
   Out(" terminal: "+(string)TerminalInfoInteger(TERMINAL_BUILD)
       +"   symbols in Market Watch: "+(string)SymbolsTotal(true)
       +"   iterations: "+(string)InpIterations);
   Out(" memo capacity: CP_SYMFRESH_CACHE="+(string)CP_SYMFRESH_CACHE
       +"   table: CP_SYMFRESH_SLOTS="+(string)CP_SYMFRESH_SLOTS);
   Out("================================================================");
   Out("");
   Out("  symbols | us/call | calls/s @200Hz x2 | implied % of one core");
   Out("  --------+---------+-------------------+---------------------");

   for(int k=0;k<ArraySize(g_sizes);k++)
     {
      int n=g_sizes[k];
      double us=Measure(n,InpIterations);
      if(us<0.0)
        {
         Out(StringFormat("  %7d |  (timer too coarse - raise InpIterations)",n));
         continue;
        }
      double callsPerSec=(double)n*200.0*2.0;   // 200 ticks/s, 2 call sites/symbol
      double pct=(callsPerSec*us)/10000.0;      // us/s -> % of one core
      Out(StringFormat("  %7d | %7.3f | %17.0f | %20.2f%%",n,us,callsPerSec,pct));
     }

   Out("");
   Out("Reading it:");
   Out("  * us/call is the measurement. The percentage multiplies it by the call");
   Out("    rate a receiver with this many symbols actually generates, assuming one");
   Out("    desired entry and one local position per symbol - it is an implication,");
   Out("    not a measurement.");
   Out("  * The step between 16 and 17 is the memo boundary. Below it every call is");
   Out("    a cache hit; above it the entries evict each other between ticks and");
   Out("    every call pays the full path.");
   Out("  * Timer granularity is ~15 ms on Windows, so a run shorter than that");
   Out("    reports 'too coarse' rather than a wrong number.");
   Out("");
   Out("This script changes nothing and can be deleted after reading the log.");

   if(g_log!=INVALID_HANDLE) { FileClose(g_log); g_log=INVALID_HANDLE; }
  }
//+------------------------------------------------------------------+
