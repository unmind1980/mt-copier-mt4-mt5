//+------------------------------------------------------------------+
//| CopierState.mqh - bounded in-memory tables + atomic state file   |
//|                                                                   |
//| Every structure here has a FIXED upper bound. There is no map, no |
//| dictionary, no ever-growing array anywhere in this codebase. If a |
//| table is full we drop the newest and log a warning - we never     |
//| grow. This is the core antidote to the FX Blue-ish symptom of     |
//| memory creeping up until the terminal must be restarted.          |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_STATE_MQH__
#define __COPIER_STATE_MQH__

#include "CopierDefs.mqh"
#include "CopierCodec.mqh"

//=====================================================================
// Fixed-size table of currently open positions.
// Capacity is CP_MAX_POSITIONS. Slots are reused immediately when a
// position disappears from the snapshot.
//=====================================================================
class CopierPosTable
  {
private:
   CopierPos         m_p[CP_MAX_POSITIONS];
   int               m_n;

   //--- A slot only counts when it is marked used AND carries a
   //--- well-formed UID. Never trust `used` on its own: a slot can look
   //--- occupied while holding nothing, and a phantom slot with an empty
   //--- UID would be exported in a snapshot and turned into a stream of
   //--- bogus CLOSE signals.
   bool              SlotValid(const int i) const
     {
      return m_p[i].used && StringLen(m_p[i].uid)==CP_UID_LEN;
     }

public:
   //--- number of genuinely occupied slots. Exposed because it is the
   //--- honest answer to "how much is in this table", and because the
   //--- regression test asserts on it directly.
   int               UsedCount() const
     {
      int n=0;
      for(int i=0;i<CP_MAX_POSITIONS;i++) { if(SlotValid(i)) n++; }
      return n;
     }

   //--- Clear() in the constructor is NOT optional.
   //---
   //--- MQL does not reliably zero-initialise an array of structs that
   //--- contain strings, so a table that skips this can start life with
   //--- phantom occupied slots. The symptoms are subtle and nasty:
   //--- Count() overcounts, PruneTo() reports removing rows that were
   //--- never written, CopyTo() exports entries with empty UIDs (which
   //--- then travel inside a SNAP message), and the sender's close-
   //--- detection loop emits a CLOSE for an empty UID on every tick.
   //--- The self-test caught exactly this; it was a real production bug,
   //--- not a test artefact.
                     CopierPosTable() { Clear(); }

   int               Count() const { return UsedCount(); }
   bool              IsFull() const { return UsedCount()>=CP_MAX_POSITIONS; }

   void              Clear()
     {
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         m_p[i].used=false;
         m_p[i].uid="";
         m_p[i].sym="";
         m_p[i].cmt="";
         m_p[i].side=0;
         m_p[i].lots=0.0;
         m_p[i].openPx=0.0;
         m_p[i].sl=0.0;
         m_p[i].tp=0.0;
         m_p[i].ticket=0;
         m_p[i].magic=0;
         m_p[i].openTime=0;
        }
      m_n=0;
     }

   int               Find(const string uid) const
     {
      if(StringLen(uid)!=CP_UID_LEN) return -1;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(SlotValid(i) && m_p[i].uid==uid) return i;
        }
      return -1;
     }

   int               FindByTicket(const long ticket) const
     {
      if(ticket==0) return -1;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(SlotValid(i) && m_p[i].ticket==ticket) return i;
        }
      return -1;
     }

   bool              At(const int i,CopierPos &out) const
     {
      if(i<0 || i>=CP_MAX_POSITIONS || !SlotValid(i)) return false;
      out=m_p[i];
      return true;
     }

   bool              Get(const string uid,CopierPos &out) const
     {
      int i=Find(uid);
      if(i<0) return false;
      out=m_p[i];
      return true;
     }

   //--- Look a position up by its broker identifier rather than by UID.
   //--- This is what survives a partial close on MT5, where the terminal
   //--- OVERWRITES the position's comment and destroys the UID stored in it.
   bool              GetByTicket(const long ticket,CopierPos &out) const
     {
      int i=FindByTicket(ticket);
      if(i<0) return false;
      out=m_p[i];
      return true;
     }

   //--- Replace the whole table with another one's contents.
   void              CopyFrom(const CopierPosTable &src)
     {
      Clear();
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!src.m_p[i].used) continue;
         Upsert(src.m_p[i]);
        }
     }

   //--- insert or update by UID. Returns false when the table is full or
   //--- the UID is malformed (storing an entry we could never match again
   //--- would just be a future phantom slot).
   bool              Upsert(const CopierPos &p)
     {
      if(StringLen(p.uid)!=CP_UID_LEN) return false;
      int i=Find(p.uid);
      if(i>=0)
        {
         m_p[i]=p;
         m_p[i].used=true;
         return true;
        }
      for(int k=0;k<CP_MAX_POSITIONS;k++)
        {
         if(!SlotValid(k))
           {
            m_p[k]=p;
            m_p[k].used=true;
            m_n++;
            return true;
           }
        }
      return false;
     }

   bool              Remove(const string uid)
     {
      int i=Find(uid);
      if(i<0) return false;
      m_p[i].used=false;
      m_p[i].uid="";
      m_n=UsedCount();          // resync, never trust the arithmetic
      return true;
     }

   bool              UpdateAt(const int i,const CopierPos &p)
     {
      if(i<0 || i>=CP_MAX_POSITIONS) return false;
      m_p[i]=p;
      m_p[i].used=true;
      return true;
     }

   bool              RemoveAt(const int i)
     {
      if(i<0 || i>=CP_MAX_POSITIONS) return false;
      m_p[i].used=false;
      m_p[i].uid="";
      m_n=UsedCount();
      return true;
     }

   int               InsertEmpty(const CopierPos &p)
     {
      if(StringLen(p.uid)!=CP_UID_LEN) return -1;
      for(int k=0;k<CP_MAX_POSITIONS;k++)
        {
         if(!SlotValid(k))
           {
            m_p[k]=p;
            m_p[k].used=true;
            m_n++;
            return k;
           }
        }
      return -1;
     }

   //--- export to a dense dynamic array (used for encoding snapshots)
   //--- Export for snapshot encoding. Only well-formed rows leave here:
   //--- anything else would be broadcast to receivers as a position with
   //--- an empty identity, which they cannot map to anything.
   int               CopyTo(CopierPos &out[]) const
     {
      ArrayResize(out,0,CP_MAX_POSITIONS);
      int n=0;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!SlotValid(i)) continue;
         if(n>=CP_MAX_POSITIONS) break;
         ArrayResize(out,n+1,CP_MAX_POSITIONS);
         out[n]=m_p[i];
         n++;
        }
      return n;
     }

   //--- drop every UID that is NOT in the given set. This is how a
   //--- snapshot prunes the table back down (bounded growth guarantee).
   int               PruneTo(const CopierPos &desired[],const int desiredCount)
     {
      int removed=0;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!SlotValid(i)) continue;
         bool keep=false;
         for(int k=0;k<desiredCount;k++)
           {
            if(StringLen(desired[k].uid)!=CP_UID_LEN) continue;
            if(desired[k].uid==m_p[i].uid) {keep=true; break;}
           }
         if(!keep)
           {
            m_p[i].used=false;
            m_p[i].uid="";
            removed++;
           }
        }
      m_n=UsedCount();          // derived, so Count() can never disagree
      return removed;
     }
  };

//=====================================================================
// Fixed-size ring buffer for idempotency: remembers the last
// CP_SEEN_RING action keys so a duplicated delivery (reconnect storm,
// event + snapshot both firing) cannot execute the same action twice.
//=====================================================================
class CopierSeenRing
  {
private:
   string            m_k[CP_SEEN_RING];
   long              m_t[CP_SEEN_RING];
   int               m_head;
   long              m_ttlMs;

public:
   //--- same reasoning as CopierPosTable: an uncleared array of strings
   //--- may start life holding junk, which would make Has() report a key
   //--- as already processed and silently drop a real trade action.
                     CopierSeenRing():m_head(0),m_ttlMs(300000) { Clear(); }

   void              SetTtlMs(const long ms) { m_ttlMs=ms; }

   void              Clear()
     {
      for(int i=0;i<CP_SEEN_RING;i++) { m_k[i]=""; m_t[i]=0; }
      m_head=0;
     }

   bool              Has(const string key) const
     {
      long now=CopierNowMs();
      for(int i=0;i<CP_SEEN_RING;i++)
        {
         if(StringLen(m_k[i])==0) continue;
         if(now-m_t[i]>m_ttlMs) continue;
         if(m_k[i]==key) return true;
        }
      return false;
     }

   long              GetTime(const string key) const
     {
      long now=CopierNowMs();
      for(int i=0;i<CP_SEEN_RING;i++)
        {
         if(StringLen(m_k[i])==0) continue;
         if(now-m_t[i]>m_ttlMs) continue;
         if(m_k[i]==key) return m_t[i];
        }
      return 0;
     }

   void              Add(const string key)
     {
      m_k[m_head]=key;
      m_t[m_head]=CopierNowMs();
      m_head++;
      if(m_head>=CP_SEEN_RING) m_head=0;
     }

   //--- Drop a key so the same action may be taken again immediately.
   //---
   //--- The ring exists to cover the window between "we sent the order"
   //--- and "the terminal reports the position" - without it, a slow
   //--- broker confirmation makes the converge loop queue the same open
   //--- over and over. But it must NOT keep blocking once the position is
   //--- actually visible, or a legitimate re-open is suppressed for the
   //--- whole TTL: if you close a mirrored position by hand while the
   //--- sender still holds it, the copier would silently refuse to restore
   //--- it for up to ten minutes. Converge calls Forget() the moment it
   //--- sees the UID locally, so the guard covers only the in-flight window.
   void              Forget(const string key)
     {
      for(int i=0;i<CP_SEEN_RING;i++)
        {
         if(m_k[i]==key) { m_k[i]=""; m_t[i]=0; }
        }
     }

   //--- Drop every key starting with `prefix`.
   //---
   //--- Needed because some keys carry more than the UID: a TRIM key is
   //--- "sid:kind:uid:targetVolume", so one UID's entries cannot be named
   //--- exactly. Without this, a trim back to a volume that had been reached
   //--- before stays suppressed even though the position has since been
   //--- closed and re-opened.
   //---
   //--- Prefix matching is safe here because UIDs are fixed-length: no UID
   //--- is a prefix of another, so "sid:kind:UID" cannot collide.
   void              ForgetPrefix(const string prefix)
     {
      int n=StringLen(prefix);
      if(n==0) return;
      for(int i=0;i<CP_SEEN_RING;i++)
        {
         if(StringLen(m_k[i])<n) continue;
         if(StringSubstr(m_k[i],0,n)==prefix) { m_k[i]=""; m_t[i]=0; }
        }
     }
  };

#define CP_BACKOFF_SLOTS 256   // distinct keys remembered; oldest evicted

//--- The ladder, in one place so the receiver, the log text and the tests
//--- all read the same numbers. The long end is deliberate: it exists to
//--- stop retrying fast enough for a human to intervene, not to eventually
//--- succeed.
long CopierBackoffMs(const int fails)
  {
   if(fails<=1) return 2000;
   if(fails==2) return 60*1000;
   if(fails==3) return 5*60*1000;
   if(fails==4) return 15*60*1000;
   if(fails==5) return 60*60*1000;
   if(fails==6) return 6*60*60*1000;
   if(fails==7) return 12*60*60*1000;
   return 24*60*60*1000;
  }

//--- "900000" tells a reader nothing at 3am; "15m" does.
string CopierBackoffText(const int fails)
  {
   long ms=CopierBackoffMs(fails);
   if(ms<60000)   return (string)(ms/1000)+"s";
   if(ms<3600000) return (string)(ms/60000)+"m";
   return (string)(ms/3600000)+"h";
  }

class CopierBackoff
  {
private:
   string            m_k[CP_BACKOFF_SLOTS];
   int               m_n[CP_BACKOFF_SLOTS];   // consecutive failures
   long              m_t[CP_BACKOFF_SLOTS];   // when it last failed (ms)
   long              m_u[CP_BACKOFF_SLOTS];   // do not retry before (ms)

   int               Find(const string key) const
     {
      if(StringLen(key)==0) return -1;
      for(int i=0;i<CP_BACKOFF_SLOTS;i++)
        {
         if(m_k[i]==key) return i;
        }
      return -1;
     }

   //--- Empty slot if there is one; otherwise evict the entry that is
   //--- parked longest, since it is the one whose ladder has climbed
   //--- highest and therefore the least likely to be retried soon anyway.
   int               FreeSlot()
     {
      for(int i=0;i<CP_BACKOFF_SLOTS;i++)
        {
         if(StringLen(m_k[i])==0) return i;
        }
      int worst=0;
      for(int i=1;i<CP_BACKOFF_SLOTS;i++)
        {
         if(m_u[i]>m_u[worst]) worst=i;
        }
      return worst;
     }

public:
                     CopierBackoff()
     {
      for(int i=0;i<CP_BACKOFF_SLOTS;i++)
        {
         m_k[i]="";
         m_n[i]=0;
         m_t[i]=0;
         m_u[i]=0;
        }
     }

   bool              Blocked(const string key)
     {
      int i=Find(key);
      if(i<0) return false;
      return CopierNowMs()<m_u[i];
     }

   int               Count(const string key)
     {
      int i=Find(key);
      return (i<0)?0:m_n[i];
     }

   //--- Record a failure and escalate. Returns the new consecutive count.
   int               Note(const string key)
     {
      long now=CopierNowMs();
      int i=Find(key);
      int n=1;
      if(i>=0)
        {
         //--- A failure arriving long after the previous one is a NEW
         //--- problem, not a continuation of the old one. Without this, a
         //--- single blip yesterday would put today's unrelated failure
         //--- straight onto a 24-hour ladder.
         long prev=CopierBackoffMs(m_n[i]);
         n=((now-m_t[i])>prev*2)?1:(m_n[i]+1);
        }
      else
         i=FreeSlot();

      if(n>8) n=8;
      m_k[i]=key;
      m_n[i]=n;
      m_t[i]=now;
      m_u[i]=now+CopierBackoffMs(n);
      return n;
     }

   //--- Park the key WITHOUT touching the ladder.
   //---
   //--- For a failure that is not the broker refusing the ORDER - this
   //--- terminal refusing to SEND, for instance. Nothing reaches the broker,
   //--- so there is no request rate to protect, and escalating would park the
   //--- action for hours after the operator has already fixed the cause.
   void              Park(const string key,const long ms)
     {
      int i=Find(key);
      if(i<0) i=FreeSlot();
      if(StringLen(m_k[i])==0)
        {
         m_k[i]=key;
         m_n[i]=0;
        }
      m_t[i]=CopierNowMs();
      m_u[i]=CopierNowMs()+ms;
     }

   //--- Success: the condition is gone, so drop the ladder entirely rather
   //--- than let a stale count penalise the next unrelated failure.
   void              Clear(const string key)
     {
      int i=Find(key);
      if(i<0) return;
      m_k[i]="";
      m_n[i]=0;
      m_t[i]=0;
      m_u[i]=0;
     }
  };

//=====================================================================
// State file. Rewritten in full every time, never appended.
//
// NOTE on atomicity: a true rename is not available here. FileMove does
// not compile consistently across the MetaTrader builds this project
// targets, and FileCopy - which looks like the portable answer - is NOT:
// MQL4 takes (src, common_flag, dst) where MQL5 takes (src, dst, flags),
// so the obvious swap compiles on one platform and fails on the other
// (METRADER error 199, measured on the MT4 targets, 2026-10-18). So the
// swap here is WRITE-SUCCESSOR, COPY-BYTES-IN-PLACE, DELETE-SUCCESSOR.
//
// The original order (delete the only copy, then rewrite it in place) was
// worse in the one case that matters: a save that failed HALFWAY (disk
// full, handles exhausted by another EA) destroyed the previous state
// before proving the new one could be written, and the next restart
// rebuilt identity from comments alone. Writing the successor first means
// a failed save leaves the previous file exactly as it was.
//
// The residual crash window is "mid-copy of a finished file" rather than
// "mid-rewrite of every line", and a torn result is still caught by the
// "END:<n>" marker: Load() rejects a file whose END marker is missing or
// whose count disagrees, and the caller then falls back to rebuilding
// identity from the order comments. The state file is a cache, not the
// source of truth, so this is safe.
//=====================================================================
#define CP_STATE_TAG_HDR "HDR:"
#define CP_STATE_TAG_POS "POS:"
#define CP_STATE_TAG_END "END:"

class CopierStateFile
  {
public:
   static bool       Save(const string path,const string header,
                          const CopierPos &pos[],const int count)
     {
      //--- The successor is written FIRST. If this open fails, or the
      //--- writes below fail, the previous state file is untouched - the
      //--- caller can fall back to it across a restart instead of nothing.
      string tmp=path+".tmp";
      FileDelete(tmp);
      //--- shareable for the same reason as the log: the state file is the
      //--- authoritative record of what a sender holds, and being unable to
      //--- read it while the EA runs makes it useless as a diagnostic.
      int h=FileOpen(tmp,FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;   // the OLD file is untouched

      FileWrite(h,CP_STATE_TAG_HDR+header);
      int written=0;
      int n=count;
      if(n>CP_STATE_MAX_LINES) n=CP_STATE_MAX_LINES;
      for(int i=0;i<n;i++)
        {
         if(StringLen(pos[i].uid)!=CP_UID_LEN) continue;
         FileWrite(h,CP_STATE_TAG_POS+CopierEncodeRec(pos[i]));
         written++;
        }
      FileWrite(h,CP_STATE_TAG_END+(string)written);
      FileFlush(h);
      FileClose(h);

      //--- Swap the successor over the old file. No FileCopy (not portable)
      //--- and no FileMove (not available): read the successor back and
      //--- write it over the target in place. Opening the target FAILS
      //--- leaves the old state as it was; opening it TRUNCATES it, so a
      //--- crash mid-copy is caught by the END marker in Load, exactly as
      //--- before - but a failed save no longer destroys what was there.
      int rh=FileOpen(tmp,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(rh==INVALID_HANDLE) return false;
      int wh=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(wh==INVALID_HANDLE)
        {
         FileClose(rh);
         return false;                      // old file intact, tmp kept
        }
      while(!FileIsEnding(rh))
         FileWrite(wh,FileReadString(rh));
      FileClose(rh);
      FileFlush(wh);
      FileClose(wh);
      FileDelete(tmp);
      return true;
     }

   static bool       Load(const string path,string &header,
                          CopierPos &pos[],int &count)
     {
      header="";
      count=0;
      ArrayResize(pos,0);
      int h=FileOpen(path,FILE_READ|FILE_TXT|FILE_ANSI
                     |FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h==INVALID_HANDLE) return false;

      int expected=-1;
      int got=0;
      while(!FileIsEnding(h) && got<=CP_STATE_MAX_LINES)
        {
         string line=FileReadString(h);
         if(StringLen(line)==0) continue;
         if(StringFind(line,CP_STATE_TAG_HDR)==0)
           {
            header=StringSubstr(line,StringLen(CP_STATE_TAG_HDR));
            continue;
           }
         if(StringFind(line,CP_STATE_TAG_END)==0)
           {
            expected=(int)StringToInteger(StringSubstr(line,StringLen(CP_STATE_TAG_END)));
            continue;
           }
         if(StringFind(line,CP_STATE_TAG_POS)==0)
           {
            string rec=StringSubstr(line,StringLen(CP_STATE_TAG_POS));
            CopierPos p;
            if(CopierDecodeRec(rec,p))
              {
               ArrayResize(pos,got+1,CP_MAX_POSITIONS);
               pos[got]=p;
               got++;
              }
            continue;
           }
        }
      FileClose(h);
      //--- truncated / torn file: caller must fall back to rebuilding
      //--- from order comments rather than trusting this
      if(expected<0 || expected!=got) return false;
      count=got;
      return true;
     }
  };

#endif
//+------------------------------------------------------------------+
