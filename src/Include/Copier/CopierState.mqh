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
// Table sizes. Both MUST be declared before the classes that size an
// array with them: a #define that appears below its use is simply not
// there yet, and the error it produces ("invalid index value") points at
// the array rather than at the missing constant.
//=====================================================================
#define CP_UIDIDX_SLOTS 4096      // power of two; 2048 entries fit at 50% load
//--- Ticket index. Half the size is enough: tickets are 64-bit integers, so
//--- collisions are rarer, and the sender's table is already keyed on uid.
#define CP_TICKIDX_SLOTS 2048     // power of two

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
   //--- where the last free-slot search stopped. Slots are handed out in
   //--- order, so starting from 0 every time made a restart that re-adopts
   //--- 300 positions walk the whole 2048-slot table 300 times.
   int               m_hint;

   //--- ticket -> slot index.
   //---
   //--- FindByTicket() is a linear scan of all 2048 slots, and the sender
   //--- calls it once per position per tick to attach a UID: 300 positions
   //--- is 614,000 integer comparisons a tick, ~6 million a second, to answer
   //--- a question a hash answers in one probe.
   //---
   //--- REBUILT, never maintained incrementally. Every mutation point would
   //--- have to keep it in step - Clear, Upsert, UpdateAt, RemoveAt,
   //--- CopyFrom, PruneTo - and one missed path is silent corruption. A
   //--- rebuild is 2048 integer reads once a tick, which is 300x cheaper than
   //--- what it replaces, and it cannot drift.
   //
   //--- m_tkValid=false simply means "stale": the indexed lookup then falls
   //--- back to the linear scan, so a caller that forgot to rebuild is slow
   //--- rather than wrong.
   uint              m_tkHash[CP_TICKIDX_SLOTS];
   int               m_tkSlot[CP_TICKIDX_SLOTS];   // slot index + 1; 0 = empty
   int               m_tkMask;
   bool              m_tkValid;

   uint              TicketHash(const long ticket) const
     {
      //--- Constants that fit a SIGNED 32-bit int, deliberately. An `u`
      //--- suffix on a literal is accepted by one compiler and rejected with
      //--- "some operator expected" by the other, and a header that only
      //--- compiles on MT5 is not a header.
      //
      //--- Tickets are also masked in 16-bit halves rather than shifted by 32,
      //--- because 0xFFFFFFFF as a literal is -1 on a 32-bit int and relying
      //--- on how that converts is a coin toss.
      uint h=(uint)(ticket & 0xFFFF);
      h^=(uint)((ticket>>16) & 0xFFFF);
      h^=(uint)((ticket>>32) & 0xFFFF);
      h^=(uint)((ticket>>48) & 0xFFFF);
      h*=16777619;                       // FNV-32 prime
      h^=(h>>13);
      h*=16777619;
      h^=(h>>7);
      return h & 0x7FFFFFFF;
     }

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
   int               Count() const { return m_n; }
   bool              IsFull() const { return m_n>=CP_MAX_POSITIONS; }

   //--- fast summary without copying any CopierPos struct or strings
   void              Summary(int &nPos,int &nOrd,double &totalLots) const
     {
      nPos=0;
      nOrd=0;
      totalLots=0.0;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!SlotValid(i)) continue;
         if(m_p[i].kind==CP_ORD_PENDING) nOrd++; else nPos++;
         totalLots+=m_p[i].lots;
        }
     }

   //--- Rebuild the ticket index. One pass, once per tick.
   void              RebuildTicketIndex()
     {
      m_tkValid=false;
      ArrayInitialize(m_tkSlot,0);
      int n=0;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!SlotValid(i)) continue;
         uint h=TicketHash(m_p[i].ticket);
         int  s=(int)(h&m_tkMask);
         bool placed=false;
         for(int p=0;p<CP_TICKIDX_SLOTS;p++)
           {
            int k=(int)((s+p)&m_tkMask);
            if(m_tkSlot[k]==0)
              {
               m_tkSlot[k]=i+1;
               m_tkHash[k]=h;
               n++;
               placed=true;
               break;
              }
            //--- same ticket twice: keep the FIRST, like the linear scan
            if(m_tkHash[k]==h && m_p[m_tkSlot[k]-1].ticket==m_p[i].ticket)
              { placed=true; break; }
           }
         if(!placed) return;                  // table full - cannot happen
        }
      m_tkValid=true;
     }

   bool              IsTicketIndexValid() const { return m_tkValid; }

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
         m_p[i].kind=0;
         m_p[i].ptype=0;
         m_p[i].pprice=0.0;
         m_p[i].pstop=0.0;
         m_p[i].pexpire=0;
        }
      m_n=0;
      m_hint=0;
      m_tkMask=CP_TICKIDX_SLOTS-1;
      ArrayInitialize(m_tkSlot,0);
      m_tkValid=false;
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
      //--- indexed when one has been built this tick, linear otherwise
      if(m_tkValid)
        {
         uint h=TicketHash(ticket);
         int  s=(int)(h&m_tkMask);
         for(int p=0;p<CP_TICKIDX_SLOTS;p++)
           {
            int k=(int)((s+p)&m_tkMask);
            if(m_tkSlot[k]==0) return -1;
            if(m_tkHash[k]==h && m_p[m_tkSlot[k]-1].ticket==ticket)
               return m_tkSlot[k]-1;
           }
         return -1;
        }
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

   //--- Fast numeric-only diff check against slot i.
   //--- Reads numeric fields in-place: ZERO struct copies, ZERO string allocations.
   bool              CheckSlot(const int i,
                               bool &stopsDiff,
                               bool &lotsDiff,
                               bool &kindDiff,
                               bool &otherDiff,
                               double &prevLots,
                               int &prevKind,
                               long &prevTicket,
                               const CopierPos &cur) const
     {
      if(i<0 || i>=CP_MAX_POSITIONS || !SlotValid(i)) return false;
      stopsDiff=(MathAbs(m_p[i].sl-cur.sl)>0.0000001 || MathAbs(m_p[i].tp-cur.tp)>0.0000001);
      lotsDiff =(MathAbs(m_p[i].lots-cur.lots)>0.0000001);
      kindDiff =(m_p[i].kind!=cur.kind || m_p[i].ticket!=cur.ticket);
      otherDiff=(MathAbs(m_p[i].openPx-cur.openPx)>0.0000001
                || MathAbs(m_p[i].pprice-cur.pprice)>0.0000001
                || MathAbs(m_p[i].pstop-cur.pstop)>0.0000001
                || m_p[i].ptype!=cur.ptype
                || m_p[i].pexpire!=cur.pexpire);
      prevLots  =m_p[i].lots;
      prevKind  =m_p[i].kind;
      prevTicket=m_p[i].ticket;
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
   //---
   //--- A straight copy, not Clear()+Upsert() per row. Upsert() looks the row
   //--- up by UID first (a 2048-slot linear scan) and then scans again for a
   //--- free slot, so rebuilding an N-row table that way is O(N^2): at 2048
   //--- rows that is ~8 million comparisons, and it ran on the receiver's
   //--- 10-second identity-map save. Slot validity is decided by SlotValid()
   //--- (used AND an 8-char uid), so copying raw slots cannot introduce a
   //--- phantom row that the old path would have filtered.
   void              CopyFrom(const CopierPosTable &src)
     {
      Clear();
      for(int i=0;i<CP_MAX_POSITIONS;i++) m_p[i]=src.m_p[i];
      m_n=src.m_n;
      m_hint=src.m_hint;
      m_tkValid=false;
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
         m_tkValid=false;
         return true;
        }
      //--- hand out slots from the hint, like InsertEmpty: starting at 0 every
      //--- time made a 2048-row state restore walk the table 2048 times
      int k=m_hint;
      for(int j=0;j<CP_MAX_POSITIONS;j++)
        {
         if(!SlotValid(k))
           {
            m_p[k]=p;
            m_p[k].used=true;
            m_n++;
            m_hint=k+1;
            if(m_hint>=CP_MAX_POSITIONS) m_hint=0;
            m_tkValid=false;
            return true;
           }
         k++;
         if(k>=CP_MAX_POSITIONS) k=0;
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
      m_tkValid=false;
      return true;
     }

   bool              UpdateAt(const int i,const CopierPos &p)
     {
      if(i<0 || i>=CP_MAX_POSITIONS) return false;
      bool wasValid=SlotValid(i);
      m_p[i]=p;
      m_p[i].used=true;
      if(!wasValid) m_n++;
      m_tkValid=false;
      return true;
     }

   //--- In-place numeric update of an active slot.
   //--- Preserves stable strings (uid, sym, cmt) without copying.
   //--- If ticket did not change, preserves m_tkValid to avoid re-hashing next tick.
   bool              UpdateNumericAt(const int i,const CopierPos &cur)
     {
      if(i<0 || i>=CP_MAX_POSITIONS || !SlotValid(i)) return false;
      bool ticketChanged=(m_p[i].ticket!=cur.ticket);
      m_p[i].sl      =cur.sl;
      m_p[i].tp      =cur.tp;
      m_p[i].lots    =cur.lots;
      m_p[i].kind    =cur.kind;
      m_p[i].ptype   =cur.ptype;
      m_p[i].openPx  =cur.openPx;
      m_p[i].pprice  =cur.pprice;
      m_p[i].pstop   =cur.pstop;
      m_p[i].pexpire =cur.pexpire;
      m_p[i].ticket  =cur.ticket;
      if(ticketChanged) m_tkValid=false;
      return true;
     }

   bool              RemoveAt(const int i)
     {
      if(i<0 || i>=CP_MAX_POSITIONS) return false;
      if(!SlotValid(i)) return false;
      m_p[i].used=false;
      m_p[i].uid="";
      if(m_n>0) m_n--;
      //--- a slot just became free: hand it out next rather than searching
      m_hint=i;
      m_tkValid=false;
      return true;
     }

   int               InsertEmpty(const CopierPos &p)
     {
      if(StringLen(p.uid)!=CP_UID_LEN) return -1;
      int k=m_hint;
      for(int j=0;j<CP_MAX_POSITIONS;j++)
        {
         if(!SlotValid(k))
           {
            m_p[k]=p;
            m_p[k].used=true;
            m_n++;
            m_hint=k+1;
            if(m_hint>=CP_MAX_POSITIONS) m_hint=0;
            m_tkValid=false;
            return k;
           }
         k++;
         if(k>=CP_MAX_POSITIONS) k=0;
        }
      return -1;
     }

   //--- export to a dense dynamic array (used for encoding snapshots)
   //--- Export for snapshot encoding. Only well-formed rows leave here:
   //--- anything else would be broadcast to receivers as a position with
   //--- an empty identity, which they cannot map to anything.
   int               CopyTo(CopierPos &out[]) const
     {
      int cap=(m_n<=CP_MAX_POSITIONS)?m_n:CP_MAX_POSITIONS;
      if(ArrayIsDynamic(out)) ArrayResize(out,cap,CP_MAX_POSITIONS);
      int n=0;
      for(int i=0;i<CP_MAX_POSITIONS;i++)
        {
         if(!SlotValid(i)) continue;
         if(n>=ArraySize(out)) break;
         out[n]=m_p[i];
         n++;
        }
      if(ArrayIsDynamic(out) && n!=cap) ArrayResize(out,n);
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
            m_tkValid=false;
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
   //--- How many slots actually hold a key.
   //---
   //--- The ring is 4096 slots wide and, in steady state, EMPTY: keys are
   //--- written when an action executes and cleared as soon as the position
   //--- shows up. Without this counter every query walked all 4096 slots to
   //--- discover that, and converge does three such walks per position per
   //--- tick - 3.7 million iterations per tick at 300 positions, for nothing.
   //---
   //--- m_occ / m_occN are the same idea taken one step further: not just HOW
   //--- MANY slots are occupied, but WHICH ones, packed at the front. Every
   //--- query then walks m_occN entries instead of the whole ring. That
   //--- matters most exactly when the counter alone does not help: the ring is
   //--- never empty while anything is in flight, so the "ring is empty" exit
   //--- below is a steady-state optimisation, and a busy account - the one
   //--- that needs the headroom - pays for 300 occupied slots out of 4096.
   int               m_occ[CP_SEEN_RING];
   int               m_occN;
   int               m_used;      // == m_occN; kept as a named alias

public:
   //--- same reasoning as CopierPosTable: an uncleared array of strings
   //--- may start life holding junk, which would make Has() report a key
   //--- as already processed and silently drop a real trade action.
                     CopierSeenRing():m_head(0),m_ttlMs(300000),
                                      m_occN(0),m_used(0) { Clear(); }

   void              SetTtlMs(const long ms) { m_ttlMs=ms; }

   int               UsedCount() const { return m_used; }

   void              Clear()
     {
      for(int i=0;i<CP_SEEN_RING;i++) { m_k[i]=""; m_t[i]=0; }
      m_head=0;
      m_occN=0;
      m_used=0;
     }

   bool              Has(const string key) const
     {
      if(m_used==0) return false;
      long now=CopierNowMs();
      for(int j=0;j<m_occN;j++)
        {
         int i=m_occ[j];
         if(StringLen(m_k[i])==0) continue;
         if(now-m_t[i]>m_ttlMs) continue;
         if(m_k[i]==key) return true;
        }
      return false;
     }

   long              GetTime(const string key) const
     {
      if(m_used==0) return 0;
      long now=CopierNowMs();
      for(int j=0;j<m_occN;j++)
        {
         int i=m_occ[j];
         if(StringLen(m_k[i])==0) continue;
         if(now-m_t[i]>m_ttlMs) continue;
         if(m_k[i]==key) return m_t[i];
        }
      return 0;
     }

   //--- Drop the slot at occupied-list position `j`, sliding the LAST
   //--- occupied index into its place. Callers are iterating the list
   //--- themselves, so they must NOT advance j after calling this.
   void              DropAt(const int j)
     {
      int i=m_occ[j];
      m_k[i]="";
      m_t[i]=0;
      m_occN--;
      if(j<m_occN) m_occ[j]=m_occ[m_occN];
      m_used=m_occN;
     }

   void              Add(const string key)
     {
      //--- an empty slot becoming occupied is a new occupied index; an
      //--- occupied one being overwritten is already in the list
      if(StringLen(m_k[m_head])==0)
        {
         m_occ[m_occN]=m_head;
         m_occN++;
         m_used=m_occN;
        }
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
      int j=0;
      while(j<m_occN)
        {
         int i=m_occ[j];
         if(m_k[i]==key) DropAt(j);   // j NOT advanced: swapped-in slot unchecked
         else            j++;
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
      if(m_occN==0) return;
      int n=StringLen(prefix);
      if(n==0) return;
      int j=0;
      while(j<m_occN)
        {
         int i=m_occ[j];
         if(StringLen(m_k[i])>=n && StringSubstr(m_k[i],0,n)==prefix)
            DropAt(j);
         else
            j++;
        }
     }

   //--- Clear the OPEN / CLOSE / TRIM keys of ONE uid in a single pass.
   //---
   //--- Converge used to call ForgetPrefix() three times per position per
   //--- tick. The three prefixes have the same length and differ only in the
   //--- action digit, so one walk can settle all three: exact match for
   //--- OPEN and CLOSE (their keys end at the uid), prefix match only for
   //--- TRIM (its key carries the target volume, so it is strictly longer).
   void              ForgetUidActions(const string sid,const string uid)
     {
      if(m_occN==0) return;
      string pOpen =sid+":"+(string)CP_ACT_OPEN +":"+uid;
      string pClose=sid+":"+(string)CP_ACT_CLOSE+":"+uid;
      string pTrim =sid+":"+(string)CP_ACT_TRIM +":"+uid;
      int    nExact=StringLen(pOpen);
      int    j=0;
      while(j<m_occN)
        {
         string k=m_k[m_occ[j]];
         int  nk=StringLen(k);
         bool hit=false;
         if(nk<nExact)
            { j++; continue; }
         if(nk==nExact)
           {
            //--- the bare form: "sid:kind:uid"
            hit=(k==pOpen || k==pClose || k==pTrim);
           }
         else
           {
            //--- a suffixed form. PushAction appends `keyExtra` to the same
            //--- base - a pending OPEN carries its order kind, a TRIM its
            //--- target volume - so these must be matched by PREFIX, exactly
            //--- as the three ForgetPrefix() calls this replaced did.
            //--- StringFind() == 0 is a prefix test with no allocation.
            hit=(StringFind(k,pOpen)==0
                 || StringFind(k,pClose)==0
                 || StringFind(k,pTrim)==0);
           }
         if(hit) DropAt(j);
         else    j++;
        }
     }

   //--- Recompute the occupied list and drop entries past their TTL.
   //---
   //--- Called once a minute: an expired key is still an occupied slot as far
   //--- as Add() is concerned, so without this the counter would ratchet up
   //--- and the cheap "ring is empty" exit would never be taken again.
   void              PruneExpired()
     {
      long now=CopierNowMs();
      int j=0;
      while(j<m_occN)
        {
         int i=m_occ[j];
         if(now-m_t[i]>m_ttlMs) DropAt(j);
         else                    j++;
        }
     }
  };

//=====================================================================
// uid -> array index, rebuilt once per converge pass.
//
// The converge diff is two nested loops - "for each desired, is it local?"
// and "for each local, is it still desired?" - and both used to answer by
// scanning the other array with 8-character string compares. At 300
// positions that is 2 x 90,000 comparisons per tick, per sender.
//
// A UID is exactly 8 characters from a 32-letter alphabet, so a hash of it
// is cheap and collisions are rare enough that one string compare on a hash
// match settles the question. This is the same "fixed table, no map" shape
// the rest of the codebase uses; it is rebuilt from scratch every pass so
// there is nothing to invalidate.
//=====================================================================
//--- (CP_UIDIDX_SLOTS and CP_TICKIDX_SLOTS are declared at the top of this
//--- file, because CopierPosTable sizes an array with them.)

class CopierUidIndex
  {
private:
   int               m_slot[CP_UIDIDX_SLOTS];   // array index + 1; 0 = empty
   uint              m_hash[CP_UIDIDX_SLOTS];
   int               m_mask;
   int               m_n;

   uint              HashOf(const string uid) const
     {
      uint h=2166136261;                        // FNV-1a
      int  n=StringLen(uid);
      for(int i=0;i<n;i++)
        {
         h^=(uint)StringGetCharacter(uid,i);
         h*=16777619;
        }
      return h;
     }

public:
                     CopierUidIndex():m_mask(CP_UIDIDX_SLOTS-1),m_n(0)
        { ArrayInitialize(m_slot,0); }

   void              Clear()
     {
      ArrayInitialize(m_slot,0);
      m_n=0;
     }

   //--- number of DISTINCT uids indexed. A count below the number of rows
   //--- means at least two rows share a uid - which is how DedupLocal gets
   //--- to skip its quadratic pass in the normal case.
   int               Count() const { return m_n; }

   void              Build(const CopierPos &arr[],const int base,const int count)
     {
      Clear();
      for(int i=0;i<count;i++)
        {
         string uid=arr[base+i].uid;
         if(StringLen(uid)!=CP_UID_LEN) continue;
         uint hf=HashOf(uid);
         int  s=(int)(hf&m_mask);
         bool done=false;
         for(int p=0;p<CP_UIDIDX_SLOTS;p++)
           {
            int k=(int)((s+p)&m_mask);
            if(m_slot[k]==0)
              {
               //--- stored ABSOLUTE, so Find() can hand back an index the
               //--- caller can use directly, whatever base it passed
               m_slot[k]=base+i+1;
               m_hash[k]=hf;
               m_n++;
               done=true;
               break;
              }
            //--- already present: keep the FIRST row, which is what the
            //--- linear scan this replaced returned.
            if(m_hash[k]==hf && arr[m_slot[k]-1].uid==uid) { done=true; break; }
           }
         if(!done) return;                       // table full - cannot happen
        }
     }

   int               Find(const CopierPos &arr[],const string uid) const
     {
      if(StringLen(uid)!=CP_UID_LEN) return -1;
      uint hf=HashOf(uid);
      int  s=(int)(hf&m_mask);
      for(int p=0;p<CP_UIDIDX_SLOTS;p++)
        {
         int k=(int)((s+p)&m_mask);
         if(m_slot[k]==0) return -1;
         if(m_hash[k]==hf && arr[m_slot[k]-1].uid==uid) return m_slot[k]-1;
        }
      return -1;
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
   //--- key -> slot hash index, same open-addressing shape
   //--- CopierPosTable::RebuildTicketIndex uses for tickets. The lookup runs
   //--- on every PushAction for every candidate action, so at 300 positions
   //--- and 10 Hz a linear scan of 256 keys is ~770,000 string compares a
   //--- second; this makes it a single probe with one compare on a hit.
   int               m_h[CP_BACKOFF_SLOTS];   // tag
   int               m_slot[CP_BACKOFF_SLOTS];// 0 = empty, else slot index + 1

   uint              HashOf(const string key) const
     {
      uint h=2166136261;                        // FNV-1a
      int  n=StringLen(key);
      for(int i=0;i<n;i++)
        {
         h^=(uint)StringGetCharacter(key,i);
         h*=16777619;
        }
      return h;
     }

   //--- 24-bit tag; always positive, and a collision only costs one extra
   //--- string compare, never a wrong answer (the key is still compared).
   int               TagOf(const uint h) const { return (int)(h & 0x00FFFFFF)+1; }

   bool              IsBetweenCircular(const int a,const int b,const int c) const
     {
      if(a<=c) return (b>=a && b<c);
      return (b>=a || b<c);
     }

   int               FindHashSlot(const string key) const
     {
      if(StringLen(key)==0) return -1;
      int tag=TagOf(HashOf(key));
      int mask=CP_BACKOFF_SLOTS-1;
      int k=(int)(HashOf(key) & (uint)mask);
      for(int probes=0;probes<CP_BACKOFF_SLOTS;probes++)
        {
         int s=m_slot[k];
         if(s==0) return -1;                  // empty: not present
         int idx=s-1;
         if(m_h[k]==tag && idx>=0 && idx<CP_BACKOFF_SLOTS && m_k[idx]==key) return k;
         k=(k+1)&mask;                          // linear probe
        }
      return -1;
     }

   int               Find(const string key) const
     {
      int k=FindHashSlot(key);
      return (k>=0)?(m_slot[k]-1):-1;
     }

   void              InsertHash(const int i,const uint h)
     {
      int tag=TagOf(h);
      int mask=CP_BACKOFF_SLOTS-1;
      int k=(int)(h & (uint)mask);
      //--- BOUNDED probes. The index is only ever rebuilt from live keys, so a
      //--- free bucket always exists and this never runs long - but an
      //--- unbounded `while` here is the difference between "a stale index
      //--- degrades lookups" and "the EA hangs forever", and this table has
      //--- already been through one index/slot desync.
      for(int probes=0;probes<CP_BACKOFF_SLOTS;probes++)
        {
         if(m_slot[k]==0)
           {
            m_h[k]=tag;
            m_slot[k]=i+1;
            return;
           }
         if(m_h[k]==tag && m_slot[k]==i+1) return;   // already indexed
         k=(k+1)&mask;
        }
      //--- Table genuinely full (cannot happen: FreeSlot evicts first). Rebuild
      //--- once and give up rather than spin.
      EraseHash(i);
     }

   //--- Backward-shift deletion in O(1) expected time, without full rebuild.
   //--- Fills the hole at bucket `i` by shifting entries along the cyclic probe chain.
   void              EraseHashSlot(int i)
     {
      int mask=CP_BACKOFF_SLOTS-1;
      int j=i;
      while(true)
        {
         m_slot[i]=0;
         m_h[i]=0;
         int r=0;
         while(true)
           {
            j=(j+1)&mask;
            int s=m_slot[j];
            if(s==0) return;                   // reached empty bucket, cluster ended
            int idx=s-1;
            if(idx<0 || idx>=CP_BACKOFF_SLOTS || StringLen(m_k[idx])==0)
              {
               EraseHash(i);                   // corrupt/stray bucket: rebuild cleanly
               return;
              }
            r=(int)(HashOf(m_k[idx]) & (uint)mask);
            if(IsBetweenCircular(r,i,j)) break;
           }
         m_slot[i]=m_slot[j];
         m_h[i]=m_h[j];
         i=j;
        }
     }

   //--- Remove one key from the hash index, then REBUILD the whole index from
   //--- the live keys.
   void              EraseHash(const int i)
     {
      ArrayInitialize(m_h,0);
      ArrayInitialize(m_slot,0);
      for(int k=0;k<CP_BACKOFF_SLOTS;k++)
         if(StringLen(m_k[k])>0) InsertHash(k,HashOf(m_k[k]));
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
      int k=FindHashSlot(m_k[worst]);
      m_k[worst]="";
      if(k>=0) EraseHashSlot(k);
      else     EraseHash(worst);
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
         m_h[i]=0;
         m_slot[i]=0;
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
      bool isNew=(i<0);
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
      if(StringLen(m_k[i])>0 && m_k[i]!=key) EraseHash(i);
      m_k[i]=key;
      m_n[i]=n;
      m_t[i]=now;
      m_u[i]=now+CopierBackoffMs(n);
      if(isNew) InsertHash(i,HashOf(key));
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
         InsertHash(i,HashOf(key));
        }
      m_t[i]=CopierNowMs();
      m_u[i]=CopierNowMs()+ms;
     }

   //--- Success: the condition is gone, so drop the ladder entirely rather
   //--- than let a stale count penalise the next unrelated failure.
   void              Clear(const string key)
     {
      int k=FindHashSlot(key);
      if(k<0) return;
      int i=m_slot[k]-1;
      m_k[i]="";
      m_n[i]=0;
      m_t[i]=0;
      m_u[i]=0;
      EraseHashSlot(k);
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
      bool copyOk=true;
      while(!FileIsEnding(rh))
        {
         string line=FileReadString(rh);
         if(FileWrite(wh,line)<=0)
           {
            copyOk=false;
            break;
           }
        }
      FileClose(rh);
      FileFlush(wh);
      FileClose(wh);
      if(!copyOk) return false;                  // write failed: keep tmp, report false
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
      while(!FileIsEnding(h) && got<CP_STATE_MAX_LINES)
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
