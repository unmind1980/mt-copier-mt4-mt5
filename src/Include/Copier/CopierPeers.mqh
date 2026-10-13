//+------------------------------------------------------------------+
// CopierPeers.mqh - who is on the other end, how alive it is, and roughly
// how far away
//
// A fixed table of peers keyed on their ACCOUNT NUMBER, because that is the
// name an operator recognises. Both ends use it: the sender lists its
// receivers, the receiver lists its senders.
//
// ---------------------------------------------------------------------
// LIVENESS NEEDS A MESSAGE RATE ON BOTH SIDES
//
// The first version of this derived liveness from the traffic that already
// flows, to avoid adding a probe. That was wrong, and the failure was loud:
//
//   sender -> receiver : snapshot every 2s, heartbeat every 1s   (plenty)
//   receiver -> sender : STAT once a MINUTE                      (far too slow)
//
// With a 15s timeout and a 60s status cadence, the sender declared the
// receiver dead 45 seconds before the next message it would have heard
// arrived - every peer flapped down and up forever, and the operator got an
// Alert popup per cycle. So there IS a probe now, and there has to be.
//
// Latency is the probe's round trip: PING carries our monotonic millisecond
// clock, PONG returns that number untouched, and (now - echoed) is the true
// round trip with NO synchronised clocks involved. Subtracting two machines'
// wall clocks would measure the clock difference instead.
// ---------------------------------------------------------------------
#ifndef __COPIER_PEERS_MQH__
#define __COPIER_PEERS_MQH__

#include <Copier/CopierDefs.mqh>

#define CP_MAX_PEERS 16
//--- How long a baseline stays valid. Short enough that clock drift cannot
//--- masquerade as delay; long enough that a busy link still gets a clean
//--- sample to re-baseline on.
#define CP_PEER_BASE_MS (5*60*1000)

//--- The three liveness states. Two were not enough: a peer that has never
//--- been heard from is either brand new (its first probe is still in flight)
//--- or dead, and those need different words.
#define CP_PEER_DOWN    0
#define CP_PEER_CONNECT 1
#define CP_PEER_UP      2

//--- How long a newly met peer gets to answer before it counts as dead.
//--- Generous relative to a LAN round trip, because the cost of being wrong
//--- is asymmetric: showing "connecting" for a dead peer for three seconds is
//--- a cosmetic delay, while showing DISCONNECTED for a live one trains the
//--- operator to ignore the row.
#define CP_PEER_GRACE_MS 3000

class CopierPeerTable
  {
private:
   string            m_name[CP_MAX_PEERS];
   long              m_seen[CP_MAX_PEERS];     // last message from them (ms)
   long              m_ping[CP_MAX_PEERS];     // outstanding probe (ms), 0 = none
   long              m_rtt[CP_MAX_PEERS];      // last round trip (ms), -1 unknown
   //--- When this slot was first created, in monotonic ms. Only used to tell
   //--- "we have just met this peer and its first PONG is still in flight"
   //--- apart from "this peer has never answered at all" - which read
   //--- identically before, and made a healthy hub link shout DISCONNECTED
   //--- for the second between connecting and the first echo coming back.
   long              m_first[CP_MAX_PEERS];
   //--- A short piece of text the peer reported about ITSELF - the receiver's
   //--- risk state, for instance. Kept here so a panel can show "what is the
   //--- other end doing" without a second parallel array per caller.
   string            m_note[CP_MAX_PEERS];

   void              ResetSlot(const int i)
     {
      m_name[i]="";
      m_seen[i]=0;
      m_ping[i]=0;
      m_rtt[i]=-1;
      m_note[i]="";
      m_first[i]=0;
     }

   int               Find(const string name) const
     {
      for(int i=0;i<CP_MAX_PEERS;i++)
        {
         if(m_name[i]==name && StringLen(m_name[i])>0) return i;
        }
      return -1;
     }

   int               Slot(const string name)
     {
      int i=Find(name);
      if(i>=0) return i;
      for(i=0;i<CP_MAX_PEERS;i++)
        {
         if(StringLen(m_name[i])==0)
           {
            ResetSlot(i);
            m_name[i]=name;
            m_first[i]=CopierNowMs();
            return i;
           }
        }
      //--- full: reuse the one that has been silent longest, whose row matters
      //--- least. Evicting the freshest would make a busy panel flicker.
      int oldest=0;
      for(i=1;i<CP_MAX_PEERS;i++)
        {
         if(m_seen[i]<m_seen[oldest]) oldest=i;
        }
      ResetSlot(oldest);
      m_name[oldest]=name;
      m_first[oldest]=CopierNowMs();
      return oldest;
     }

public:
                     CopierPeerTable() { Clear(); }

   void              Clear()
     {
      for(int i=0;i<CP_MAX_PEERS;i++) ResetSlot(i);
     }

   //--- Any message from this peer proves it is alive. Separate from the RTT
   //--- below: liveness should be updated by everything that arrives, while
   //--- the round trip only means something for an actual echo.
   void              Seen(const string name)
     {
      if(StringLen(name)==0) return;
      m_seen[Slot(name)]=CopierNowMs();
     }

   //--- Remember when a probe went out, so the echo can be matched to it.
   void              ProbeSent(const string name,const long ms)
     {
      if(StringLen(name)==0) return;
      m_ping[Slot(name)]=ms;
     }

   //--- An echo came back carrying `ms`. Only accept it if it matches a probe
   //--- still outstanding - a stale or foreign echo would otherwise record a
   //--- round trip that never happened.
   bool              PongBack(const string name,const long ms)
     {
      if(StringLen(name)==0) return false;
      int i=Slot(name);
      m_seen[i]=CopierNowMs();
      if(m_ping[i]==0 || m_ping[i]!=ms) return false;
      m_rtt[i]=CopierNowMs()-ms;
      if(m_rtt[i]<0) m_rtt[i]=0;
      m_ping[i]=0;
      return true;
     }

   //--- What the peer said about itself, for display only.
   void              SetNote(const string name,const string note)
     {
      if(StringLen(name)==0) return;
      m_note[Slot(name)]=note;
     }

   string            NoteAt(const int i) const
     {
      if(i<0 || i>=CP_MAX_PEERS) return "";
      return m_note[i];
     }

   int               Count() const
     {
      int n=0;
      for(int i=0;i<CP_MAX_PEERS;i++)
        {
         if(StringLen(m_name[i])>0) n++;
        }
      return n;
     }

   string            NameAt(const int i) const
     {
      if(i<0 || i>=CP_MAX_PEERS) return "";
      return m_name[i];
     }

   //--- Last round trip in ms, or -1 if no echo has come back yet.
   long              RttAt(const int i) const
     {
      if(i<0 || i>=CP_MAX_PEERS) return -1;
      return m_rtt[i];
     }

   long              RttFor(const string name) const
     {
      int i=Find(name);
      return (i<0)?-1:m_rtt[i];
     }

   //--- How long since this peer was last heard from, in ms. A peer never
   //--- heard from reports -1 rather than a huge number, so callers can tell
   //--- "gone quiet" from "never arrived".
   long              SilentMs(const string name) const
     {
      int i=Find(name);
      if(i<0 || m_seen[i]<=0) return -1;
      return CopierNowMs()-m_seen[i];
     }

   long              SilentAt(const int i) const
     {
      if(i<0 || i>=CP_MAX_PEERS || m_seen[i]<=0) return -1;
      return CopierNowMs()-m_seen[i];
     }

   //--- How long this slot has existed, in ms. 0 if there is no such peer.
   long              AgeAt(const int i) const
     {
      if(i<0 || i>=CP_MAX_PEERS || m_first[i]<=0) return 0;
      return CopierNowMs()-m_first[i];
     }

   //--- One question, one answer, so the panel and the log cannot disagree.
   //---
   //--- Splitting this three ways is the whole point. A hub link is created and
   //--- probed in the same tick, so for the second before the first PONG lands
   //--- the peer has "never been heard from" - which is EXACTLY what a peer
   //--- that never answers looks like. Rendering both as DISCONNECTED meant a
   //--- perfectly good link announced itself as broken every single time it
   //--- came up.
   //---
   //--- `timeoutMs` is the caller's timeout, because the sender and receiver
   //--- tolerate different latencies.
   int               StateAt(const int i,const long timeoutMs) const
     {
      if(i<0 || i>=CP_MAX_PEERS || StringLen(m_name[i])==0) return CP_PEER_DOWN;
      long silent=m_seen[i]<=0?-1:CopierNowMs()-m_seen[i];
      if(silent<0)
         return (AgeAt(i)<CP_PEER_GRACE_MS)?CP_PEER_CONNECT:CP_PEER_DOWN;
      return (silent>timeoutMs)?CP_PEER_DOWN:CP_PEER_UP;
     }

   void              Forget(const string name)
     {
      int i=Find(name);
      if(i<0) return;
      ResetSlot(i);
     }
  };

#endif
//+------------------------------------------------------------------+
