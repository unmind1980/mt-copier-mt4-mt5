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
//| The COST OF ONE CALL, as a function of how many symbols are in      |
//| play. Its answer is memoised in CP_SYMFRESH_CACHE (16) entries,     |
//| which is smaller than the working set of any receiver touching more |
//| than sixteen symbols; past that point the entries evict each other, |
//| the 1 s TTL never applies, and every call walks the 256-slot table  |
//| and asks the terminal for a quote time.                             |
//|                                                                     |
//| WHAT THIS IS *NOT*                                                  |
//| ===================                                                 |
//| It is not a duty cycle. `CopierSymbolFeedStale()` is called only    |
//| where an ACTION is being decided: opening a position that is not    |
//| mirrored yet, re-closing a UID the operator closed by hand, and     |
//| draining the action queue. A converged receiver calls it ZERO times |
//| per tick, however many positions it holds.                          |
//|                                                                     |
//| The sustained case is a queue that cannot drain - a market that is  |
//| shut while N actions wait: each held action is rotated and          |
//| re-checked every tick, so that is N x 200 calls a second for as     |
//| long as the closure lasts. The `calls/s` column is that scenario,   |
//| not the steady state. Read it as "if N actions are stuck", not as   |
//| "if N positions are open".                                          |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <Copier/CopierDefs.mqh>
#include <Copier/CopierCodec.mqh>
#include <Copier/CopierSymbol.mqh>

//--- 1 ms system timer. Without it GetTickCount() advances in ~15.6 ms steps and
//--- a sub-16 ms measurement is 0 or 1 tick - which is what produced the
//--- "too coarse" rows and the meaningless 0.750 / 0.800 pair in the first run.
#import "winmm.dll"
int timeBeginPeriod(uint uPeriod);
int timeEndPeriod(uint uPeriod);
#import

//--- How long each row is measured for, in milliseconds.
//---
//--- A fixed CALL COUNT was the first version and it was a mistake: at 0.75 us
//--- per call, 20000 calls is 15 ms, which is exactly ONE tick of the default
//--- Windows timer - the whole table was reading quantisation noise. Measuring
//--- for a fixed DURATION self-scales: the fast rows simply run more calls.
input int InpMsPerRow = 400;

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

//--- One measurement: `n` symbols, round-robin, for `targetMs` milliseconds.
//--- Returns microseconds per call (or -1 when the timer still could not resolve
//--- it), and reports the call count and elapsed ms through the references so the
//--- table can show how much of the run was quantisation.
double Measure(const int n,const int targetMs,int &itersOut,long &msOut)
  {
   itersOut=0;
   msOut=0;
   string syms[];
   int realCount=0;
   BuildSymbols(n,syms,realCount);
   int ns=ArraySize(syms);
   if(ns<=0) return -1.0;

   CopierSymbolQuoteReset();
   //--- warm-up pass: the first visit to each symbol populates the table, and for
   //--- n <= CP_SYMFRESH_CACHE also the memo. Without this the first pass would be
   //--- measured as if it were the steady state.
   long sink=0;
   for(int w=0;w<ns;w++) sink+=CopierSymbolQuoteAgeMs(syms[w]);

   int iters=0;
   int idx=0;
   long t0=GetTickCount();
   while(true)
     {
      //--- inner batch of ns calls so the modulo is amortised out of the loop body
      for(int i=0;i<ns;i++)
        {
         sink+=CopierSymbolQuoteAgeMs(syms[idx]);
         idx++;
         if(idx>=ns) idx=0;
        }
      iters+=ns;
      if((long)(GetTickCount()-t0)>=targetMs) break;
     }
   long ms=(long)(GetTickCount()-t0);
   itersOut=iters;
   msOut=ms;
   if(ms<=0) return -1.0;
   return (ms*1000.0)/iters;
  }

void OnStart()
  {
   timeBeginPeriod(1);
   FileDelete("copier_symfresh_bench.log");
   g_log=FileOpen("copier_symfresh_bench.log",FILE_WRITE|FILE_TXT|FILE_ANSI);

   Out("================================================================");
   Out(" per-symbol quote-freshness gate - cost by working-set size");
   Out(" terminal: "+(string)TerminalInfoInteger(TERMINAL_BUILD)
       +"   symbols in Market Watch: "+(string)SymbolsTotal(true)
       +"   per row: "+(string)InpMsPerRow+" ms");
   Out(" memo capacity: CP_SYMFRESH_CACHE="+(string)CP_SYMFRESH_CACHE
       +"   table: CP_SYMFRESH_SLOTS="+(string)CP_SYMFRESH_SLOTS);
   Out("================================================================");
   Out("");
   Out("  symbols | us/call | calls/s if ALL held | implied % | ms  | calls");
   Out("  --------+---------+--------------------+-----------+-----+--------");

   int targetMs=(InpMsPerRow<100)?100:InpMsPerRow;
   for(int k=0;k<ArraySize(g_sizes);k++)
     {
      int n=g_sizes[k];
      int iters=0;
      long ms=0;
      double us=Measure(n,targetMs,iters,ms);
      if(us<0.0)
        {
         Out(StringFormat("  %7d |  (timer too coarse even at %d ms)",n,targetMs));
         continue;
        }
      //--- the sustained case: n actions held, rotated and re-checked every tick
      double callsPerSec=(double)n*200.0;
      double pct=(callsPerSec*us)/10000.0;      // us/s -> % of one core
      Out(StringFormat("  %7d | %7.3f | %17.0f | %9.2f%% | %4d | %d",
                       n,us,callsPerSec,pct,(int)ms,iters));
     }

   //--- The sustained case, projected from the measured per-call cost. This is
   //--- the number that matters for "my EA burns a core at the weekend": a queue
   //--- that cannot drain was walked end to end on EVERY tick, and P1 now walks
   //--- it at most once a second.
   Out("");
   Out("Queue drain with N actions held (per-call cost measured above):");
   Out("      N |  before P1: 200 passes/s | after P1: 1 pass/s | gain");
   Out("  ------+--------------------------+--------------------+------");
   for(int k=0;k<ArraySize(g_sizes);k++)
     {
      int n=g_sizes[k];
      if(n<20) continue;                    // a handful of held actions is noise
      int iters=0;
      long ms=0;
      double us=Measure(n,targetMs,iters,ms);
      if(us<0.0) continue;
      double beforeMs=(double)n*200.0*us/1000.0;   // ms of CPU per second
      double afterMs =(double)n*1.0*us/1000.0;
      double gain=(afterMs>0.0)?(beforeMs/afterMs):0.0;
      Out(StringFormat("  %5d | %13.1f ms/s (%5.2f%%) | %6.2f ms/s (%4.2f%%) | %4.0fx",
                       n,beforeMs,beforeMs/10.0,afterMs,afterMs/10.0,gain));
     }

   Out("");
   Out("Reading it:");
   Out("  * us/call is the measurement. The percentage assumes the SUSTAINED case:");
   Out("    that many actions stuck behind a shut market, re-checked every tick.");
   Out("    A converged receiver - positions open, nothing to do - calls this");
   Out("    function zero times per tick, so its real share is zero.");
   Out("  * The queue table above is arithmetic on the measured per-call cost, not");
   Out("    a second measurement: 200 passes/s is the old periodic drain, 1 pass/s");
   Out("    is the P1 backoff cap. Event-driven drains bypass the backoff.");
   Out("  * The step between 16 and 17 is the memo boundary: below it every call is");
   Out("    a cache hit, above it the entries evict each other and every call pays");
   Out("    the full path. The growth above 16 is the table scan, which averages");
   Out("    half the number of tracked symbols.");
   Out("  * Each row runs for InpMsPerRow milliseconds with the system timer at 1 ms,");
   Out("    so the ms column is also the number of ticks the average is built from -");
   Out("    a row with only a few ms is noise, and the table says so instead of");
   Out("    printing a confident-looking number.");
   Out("");
   Out("This script changes nothing and can be deleted after reading the log.");

   if(g_log!=INVALID_HANDLE) { FileClose(g_log); g_log=INVALID_HANDLE; }
   timeEndPeriod(1);
  }
//+------------------------------------------------------------------+
