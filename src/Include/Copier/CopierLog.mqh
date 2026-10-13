//+------------------------------------------------------------------+
//| CopierLog.mqh - size-rotated, rate-limited logger                |
//|                                                                   |
//| Unbounded logging is one of the classic causes of the "memory     |
//| creeps up until you restart the terminal" symptom in a copier.    |
//| This logger enforces:                                             |
//|   * hard size cap per file, N generations, oldest dropped         |
//|   * rate limiting of identical repeated messages                  |
//|   * ERR level always mirrored to the Experts log                  |
//| Callers must still exercise discipline: never log per tick.       |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_LOG_MQH__
#define __COPIER_LOG_MQH__

#include "CopierDefs.mqh"

#define CP_LOG_ERR   0
#define CP_LOG_WARN  1
#define CP_LOG_INFO  2
#define CP_LOG_DEBUG 3

//--- files live flat in MQL\Files (no subdirectory: avoids depending on
//--- FolderCreate behaviour differences between MT4 and MT5 builds)
#define CP_LOG_PREFIX "copier_"
#define CP_LOG_SUFFIX ".log"

class CopierLog
  {
private:
   int               m_handle;
   string            m_base;
   long              m_bytes;
   int               m_minLevel;
   int               m_gen;      // current generation file index

   //--- rate limiter: one slot for identical consecutive messages
   string            m_lastMsg;
   int               m_lastLevel;
   long              m_lastMs;
   int               m_repeats;

   string            PathOf(const int gen)
     {
      return CP_LOG_PREFIX+m_base+"."+(string)gen+CP_LOG_SUFFIX;
     }

   //--- which generation is currently being appended to.
   //---
   //--- This is kept in a sidecar file because the obvious alternative -
   //--- "pick the generation after the newest one that exists" - recycles a
   //--- generation on EVERY EA restart, whether or not anything filled up.
   //--- Measured consequence on a real pilot: with 3 generations and a few
   //--- restarts, the log became three disjoint time windows with 11-minute
   //--- holes, and a genuine divergence could no longer be told apart from
   //--- missing history. Rotation must be driven by SIZE, not by restarts.
   string            GenPath() { return CP_LOG_PREFIX+m_base+".gen"; }

   int               ReadGen()
     {
      int h=FileOpen(GenPath(),FILE_READ|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return -1;
      string s=FileReadString(h);
      FileClose(h);
      int g=(int)StringToInteger(s);
      if(g<0 || g>=CP_LOG_GENERATIONS) return -1;
      return g;
     }

   void              WriteGen(const int g)
     {
      FileDelete(GenPath());
      int h=FileOpen(GenPath(),FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return;
      FileWrite(h,(string)g);
      FileClose(h);
     }

   //--- Rotation without FileMove.
   //--- FileMove is avoided on purpose: its parameter count differs
   //--- between MetaTrader builds and it fails to compile on the ones
   //--- tested here. Instead we walk a fixed set of generation files and
   //--- reuse the oldest slot, which keeps the file count constant and
   //--- needs nothing but FileDelete/FileOpen.
   //--- FILE_SHARE_READ is not optional here. MQL's FileOpen takes the file
   //--- exclusively by default, so while the EA runs nothing else can read
   //--- the log - not tail, not the log checker, not an editor. That
   //--- defeats the entire point of logging during a live test, and it is
   //--- exactly when you most want to look.
   bool              TryOpen()
     {
      m_handle=FileOpen(PathOf(m_gen),
                        FILE_WRITE|FILE_TXT|FILE_ANSI
                        |FILE_SHARE_READ|FILE_SHARE_WRITE);
      return m_handle!=INVALID_HANDLE;
     }

   //--- fresh=false: append to whatever is already there (a restart must
   //--- NOT destroy history). fresh=true: this generation is being
   //--- recycled because the log filled up, so clear it first.
   void              Open(const bool fresh)
     {
      if(fresh) FileDelete(PathOf(m_gen));
      TryOpen();

      if(m_handle==INVALID_HANDLE)
        {
         //--- The intended generation may be held by a stale handle - a
         //--- previous instance that was killed rather than unloaded, an
         //--- editor, a virus scanner. Seen for real: the sender logged
         //--- "cannot open log file" and then ran with NO file log at all.
         //--- Walk the other generations before giving up.
         int start=m_gen;
         for(int t=1;t<CP_LOG_GENERATIONS;t++)
           {
            m_gen=(start+t)%CP_LOG_GENERATIONS;
            FileDelete(PathOf(m_gen));
            if(TryOpen())
              {
               WriteGen(m_gen);      // keep the sidecar honest
               break;
              }
           }
        }

      if(m_handle==INVALID_HANDLE)
        {
         Print("Copier: cannot open any log file for ",m_base,
               " - continuing with the Experts window only");
         return;
        }
      FileSeek(m_handle,0,SEEK_END);
      m_bytes=(long)FileSize(m_handle);
     }

   void              Rotate()
     {
      if(m_handle!=INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
        }
      m_gen++;
      if(m_gen>=CP_LOG_GENERATIONS) m_gen=0;   // wraps: oldest is recycled
      WriteGen(m_gen);
      Open(true);
     }

public:
                     CopierLog():m_handle(INVALID_HANDLE),m_base("default"),
                     m_bytes(0),m_minLevel(CP_LOG_WARN),m_gen(0),
                     m_lastMsg(""),m_lastLevel(-1),m_lastMs(0),m_repeats(0) {}
                    ~CopierLog() { if(m_handle!=INVALID_HANDLE) FileClose(m_handle); }

   void              Init(const string tag,const int minLevel=CP_LOG_WARN)
     {
      m_base=tag;
      m_minLevel=minLevel;
      //--- continue in the generation we were last writing to, appending.
      //--- A restart must not lose history; only a size-driven rotation
      //--- recycles a generation.
      int g=ReadGen();
      if(g<0) g=0;
      m_gen=g;
      WriteGen(m_gen);
      Open(false);
     }

   void              SetLevel(const int level) { m_minLevel=level; }

   //--- flush any pending "xN" summary; call once per timer tick
   void              Tick()
     {
      if(m_repeats>0 && CopierNowMs()-m_lastMs>5000)
        {
         Emit(m_lastLevel,m_lastMsg+" [x"+(string)(m_repeats+1)+"]");
         m_repeats=0;
         m_lastMsg="";
         m_lastLevel=-1;
        }
     }

   void              Write(const int level,const string msg)
     {
      if(level>m_minLevel) return;
      long now=CopierNowMs();
      //--- identical message within 1s -> count it, don't emit
      if(level==m_lastLevel && msg==m_lastMsg && now-m_lastMs<1000)
        {
         m_repeats++;
         return;
        }
      if(m_repeats>0)
        {
         Emit(m_lastLevel,m_lastMsg+" [x"+(string)(m_repeats+1)+"]");
         m_repeats=0;
        }
      m_lastMsg=msg;
      m_lastLevel=level;
      m_lastMs=now;
      Emit(level,msg);
     }

   void              Error(const string m) { Write(CP_LOG_ERR,m);   }
   void              Warn(const string m)  { Write(CP_LOG_WARN,m);  }
   void              Info(const string m)  { Write(CP_LOG_INFO,m);  }
   //--- NOTE: deliberately NOT called Debug(). mql-zmq's Mql/Lang/Mql.mqh
   //--- defines `#define Debug(msg) ...` as a preprocessor macro, so any
   //--- `something.Debug(x)` call in a translation unit that includes the
   //--- binding gets macro-expanded into garbage. Avoid that name.
   void              Verbose(const string m) { Write(CP_LOG_DEBUG,m); }

private:
   void              Emit(const int level,const string msg)
     {
      string lv="D";
      if(level==CP_LOG_ERR)       lv="E";
      else if(level==CP_LOG_WARN) lv="W";
      else if(level==CP_LOG_INFO) lv="I";

      string line=TimeToString((datetime)CopierServerTime(),TIME_DATE|TIME_SECONDS)
                  +" "+lv+" "+msg;

      //--- Mirror EVERY emitted line to the Experts window, not just errors.
      //---
      //--- Only printing errors made a perfectly healthy EA look dead: the
      //--- Experts tab - the first place anyone looks - stayed empty while
      //--- the file log filled up normally, and "the EA is showing no log"
      //--- reads as "the EA is broken". The level filter above is the
      //--- control: if a line is worth writing, it is worth showing.
      Print("[Copier] "+line);

      if(m_handle==INVALID_HANDLE) return;

      FileWrite(m_handle,line);
      FileFlush(m_handle);
      m_bytes=(long)FileSize(m_handle);
      if(m_bytes>CP_MAX_LOG_BYTES) Rotate();
     }
  };

//=====================================================================
// Emit a message once per key, then at most once per re-warn interval.
//
// The rate limiter inside CopierLog only collapses IDENTICAL messages that
// arrive within one second of each other. It cannot help with a condition
// that is legitimately true on every timer tick for a long time - for
// example "the receiver's broker does not offer this symbol", which stays
// true until a human fixes it.
//
// Measured on real pilot logs: 2542 lines / 264 KB in 21 minutes from that
// single warning, at 10 timer ticks a second. Rotating the log keeps the
// disk usage bounded, but the log stops being readable - which is the same
// unbounded-noise failure this codebase is built to avoid, just reached by
// a different route.
//
// So anything that can repeat indefinitely goes through here instead.
//=====================================================================
#define CP_ONCE_MAX 64

class CopierOnceLog
  {
private:
   string            m_key[CP_ONCE_MAX];
   long              m_last[CP_ONCE_MAX];
   int               m_n;
   long              m_repeatMs;

public:
   //--- an "already warned" key is cleared only by the re-warn interval,
   //--- so the default is deliberately long: ten minutes
                     CopierOnceLog():m_n(0),m_repeatMs(600000) { Clear(); }

   void              Clear()
     {
      for(int i=0;i<CP_ONCE_MAX;i++) { m_key[i]=""; m_last[i]=0; }
      m_n=0;
     }

   void              SetRepeatMs(const long ms) { m_repeatMs=ms; }
   int               Count() const { return m_n; }

   //--- true when this key should be emitted now
   bool              ShouldEmit(const string key)
     {
      long now=CopierNowMs();
      for(int i=0;i<m_n;i++)
        {
         if(m_key[i]!=key) continue;
         if(now-m_last[i]<m_repeatMs) return false;
         m_last[i]=now;
         return true;
        }

      if(m_n<CP_ONCE_MAX)
        {
         m_key[m_n]=key;
         m_last[m_n]=now;
         m_n++;
         return true;
        }

      //--- table full: evict the least recently emitted key rather than
      //--- going permanently silent on new conditions
      int oldest=0;
      for(int i=1;i<CP_ONCE_MAX;i++)
        {
         if(m_last[i]<m_last[oldest]) oldest=i;
        }
      m_key[oldest]=key;
      m_last[oldest]=now;
      return true;
     }
  };

#endif
//+------------------------------------------------------------------+
