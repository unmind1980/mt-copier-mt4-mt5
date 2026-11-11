//+------------------------------------------------------------------+
//| CopierTransport.mqh - ZeroMQ plumbing (wraps mql-zmq)            |
//|                                                                   |
//| ONE socket per process. The sender binds a single PUB; the        |
//| receiver connects a single SUB. Both streams - events and         |
//| snapshots - share it, distinguished by the envelope's T= field.   |
//|                                                                   |
//| Hard rules enforced here, because breaking any of them is exactly |
//| how you end up with a copier that has to be restarted every few   |
//| hours:                                                            |
//|                                                                   |
//|  1. ONE context per terminal process, shared by name.            |
//|  2. Sockets are created in OnInit and destroyed in OnDeinit.      |
//|     NEVER create/close a socket per tick - that leaks, and it is  |
//|     the single most common self-inflicted wound.                  |
//|  3. ZMQ_LINGER=0 always. A non-zero linger blocks zmq_ctx_term    |
//|     and the terminal will hang on shutdown / EA reload.           |
//|  4. Every recv uses ZMQ_DONTWAIT. A blocking recv in MQL blocks   |
//|     the EA thread and can wedge the whole terminal.               |
//|  5. Explicit HWMs, so queues can never grow without bound when a  |
//|     peer is slow or away.                                         |
//|  6. Explicit ZMQ_MAXMSGSIZE, so a peer cannot make this process   |
//|     allocate an arbitrary amount of memory before we ever get to  |
//|     look at the message. The parser has its own length check, but |
//|     it runs AFTER libzmq has read and buffered the whole frame -  |
//|     which is one step too late to be a defence. See CP_MAXMSGSIZE |
//|     in CopierDefs.mqh.                                            |
//|                                                                   |
//| WHY ONE SOCKET, AND WHY CONFLATE HAD TO GO                        |
//|                                                                   |
//| The snapshot stream wants "keep only the newest" semantics, and   |
//| ZMQ_CONFLATE is the obvious way to get them. But CONFLATE is a    |
//| PER-SOCKET option: setting it on a socket that also carries events |
//| would silently drop trading instructions. That, and nothing else, |
//| is why there used to be two sockets.                              |
//|                                                                   |
//| The conflation is therefore done in the drain loop instead - see  |
//| the receiver's OnTimer. Applying only the LAST snapshot of a batch |
//| is exactly equivalent to applying all of them in order, because a |
//| snapshot is a full state replacement rather than a delta. So the  |
//| same guarantee is obtained without a second socket, and without    |
//| depending on a library option that has already bitten this project |
//| (CONFLATE on a PUB delivered empty messages on the libzmq 4.2.0   |
//| that this binding shipped then - see the history in               |
//| doc/PROTOCOL.md. Both ends run 4.3.5 now; the rule is unchanged.)  |
//| AND WHY XPUB / XSUB RATHER THAN PUB / SUB                         |
//|                                                                   |
//| PUB and SUB are each strictly one-way, which makes "the receiver  |
//| reports its status back" look like it needs a second socket. It   |
//| does not. XPUB and XSUB are the EXTENDED pub/sub types and they   |
//| are bidirectional: an XSUB peer may send up to the XPUB, and the  |
//| XPUB delivers those messages to the application.                  |
//|                                                                   |
//| That is not taken on faith. tools/zmq_bidir_test.py measures it,  |
//| and the design rests on all four results:                         |
//|                                                                   |
//|   * one XPUB send still reaches EVERY XSUB subscriber (fan-out)   |
//|   * an XSUB send arrives at the XPUB on the same socket           |
//|   * the subscription filter still works                           |
//|   * with one receiver attached to SEVERAL senders, a status       |
//|     message reaches only ONE of them - the uplink round-robins,   |
//|     it does NOT broadcast. SendUp compensates by sending @hub     |
//|     frames twice. This line used to claim "broadcast to all",     |
//|     which was simply false and hid a real defect.                 |
//|                                                                   |
//| Two consequences to keep in mind:                                 |
//|                                                                   |
//|   * XSUB DOES NOT AUTO-SUBSCRIBE. The application must send the   |
//|     subscription itself - one byte, 0x01 for everything.          |
//|   * the XPUB receives those subscription bytes mixed in with real |
//|     status messages, so the sender must DECODE what it drains     |
//|     rather than assume every message is status.                   |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_TRANSPORT_MQH__
#define __COPIER_TRANSPORT_MQH__

#include "CopierDefs.mqh"
#include <Zmq/Zmq.mqh>

//--- deliberately unreadable global name for the shared context
#define CP_CTX_NAME "__c0p13r_zmq_ctx_d41d8__"

//--- Max messages drained per timer tick.
//---
//--- One socket now carries both streams, so this is the bound on the whole
//--- input side rather than on one stream. At the real message rate (a few
//--- per second, plus a snapshot every SnapshotSeconds) it is never reached;
//--- the receiver checks whether it was, and says so, because hitting it
//--- means the EA is falling behind.
#define CP_DRAIN_MAX 256

//--- Queue depth. Generous on purpose: a PUB DROPS when its send queue is
//--- full, and unlike the old conflated snapshot socket there is no "the
//--- newest one will still get through" guarantee once everything shares one
//--- queue. The receiver drains at PollMs, so in practice this never fills;
//--- it exists so a peer that goes away cannot grow the queue without bound.
//--- N49-12: Queue depth aligned with CP_MAX_ACTIONS 256 to absorb 74+ order bursts safely
#define CP_SNDHWM 1024
#define CP_RCVHWM 1024

#import "libzmq.dll"
int zmq_errno(void);
#import
int CopierZmqErrno() { return zmq_errno(); }

#define CP_MAX_XSUB_SUBS 256

class CopierTransport
  {
private:
   string            m_ctxName;   // per-instance; empty = the shared default
   Context          *m_ctx;
   Socket           *m_pub;      // sender: XPUB - sends data, receives status
   Socket           *m_sub;      // receiver: XSUB - receives data, sends status
   int               m_errno;
   string            m_subPrefixes[CP_MAX_XSUB_SUBS];
   //--- N-01: how many SUBSCRIBE frames we have actually sent for this prefix
   //--- on the current socket. XPUB counts a (pipe, prefix) subscription per
   //--- 0x01 it receives, so one 0x00 only cancels ONE of them: a periodic
   //--- re-subscribe (HubAnnounce, every 5 s) left the count permanently above
   //--- zero and made every Unsubscribe a no-op - the removed sender's stream
   //--- kept arriving for the life of the socket. Counting what we sent and
   //--- replaying that many 0x00 on removal is the only bookkeeping that stays
   //--- correct for BOTH cases (a subscribe that was actually lost, and one
   //--- that landed twice).
   int               m_subSent[CP_MAX_XSUB_SUBS];
   int               m_nSubPrefixes;
   int               m_connectedHubs;
   //--- F-18: the socket is mid-multipart and the closing frame did not land.
   //--- ZMQ has no "cancel a partial message": once `sendMore(topic)` succeeds the
   //--- next `send` is a continuation, so an unclosed frame makes every later
   //--- message append to the broken one - the peer sees one enormous malformed
   //--- frame instead of N good ones. Tracked so the next SendUp can try to close
   //--- it before writing anything new.
   bool              m_midMultipart;
   bool              m_midInboundMultipart;

   int               DrainSocket(Socket *s,string &out[],const int maxMsgs)
     {
      int limit=(maxMsgs<CP_DRAIN_MAX)?maxMsgs:CP_DRAIN_MAX;
      if(ArrayIsDynamic(out)) ArrayResize(out,limit);
      if(CheckPointer(s)==POINTER_INVALID)
        {
         //--- same reason as DrainFrames: leave the array EMPTY, not sized
         //--- for `limit` and still holding the previous tick's payloads
         if(ArrayIsDynamic(out)) ArrayResize(out,0);
         return 0;
        }

      int got=0;
      for(int i=0;i<limit;i++)
        {
         ZmqMsg msg;
         if(!s.recv(msg,true)) break;   // EAGAIN -> nothing pending
         string data=msg.getData();
         // R6-D6-02 & R12-B01: Drain any remaining frames of THIS multipart message without draining subsequent messages
         bool hasMore=msg.more();
         while(hasMore)
           {
            ZmqMsg discard;
            if(!s.recv(discard,true)) break;
            hasMore=discard.more();
           }
         if(StringLen(data)==0) continue;
         if(got>=ArraySize(out)) break;
         out[got]=data;
         got++;
        }
      if(ArrayIsDynamic(out)) ArrayResize(out,got);
      return got;
     }

   void              Hardening(Socket *s)
     {
      if(CheckPointer(s)==POINTER_INVALID || !s.valid()) return;
      //--- must be 0: otherwise shutdown blocks
      s.setLinger(0);
      int ivl = 100 + (MathRand() % 400); // R6-D6-01: Reconnect backoff with jitter to prevent SYN storms
      s.setReconnectInterval(ivl);
      s.setReconnectIntervalMax(5000);
      s.setImmediate(true);
      //--- Native ZMTP heartbeats to promptly detect half-open TCP connections
      //--- and reclaim dead peer send pipes within 15 seconds.
      s.setHeartbeatInterval(5000);
      s.setHeartbeatTimeout(15000);
      //--- The ONLY inbound-size guard libzmq enforces, and the only one that
      //--- can act before the memory is committed. CP_MAX_MSG_LEN checks the
      //--- same bound, but in the parser - by which point the frame has
      //--- already been read and buffered, so a peer announcing a huge frame
      //--- costs this process the allocation and is rejected only afterwards.
      //--- Here libzmq disconnects it mid-read instead.
      //---
      //--- Set on EVERY socket, bound and connected alike: both ends can be
      //--- reached by a hostile peer, and the receiver's XSUB accepts frames
      //--- from anything it connects to.
      s.setMaxMessageSize(CP_MAXMSGSIZE);
     }

   //--- F-18: If an earlier SendUp wrote frame 0 (MORE) and frame 1 failed on EAGAIN,
   //--- libzmq holds the socket mid-multipart until an empty terminating frame lands.
   bool              CloseDanglingMultipart()
     {
      if(!m_midMultipart) return true;
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      if(!m_sub.send("",true))
        {
         m_errno=CopierZmqErrno();
         return false;
        }
      m_midMultipart=false;
      return true;
     }

   //--- Send a raw XSUB subscription control frame ([0x01|0x00] + UTF-8 prefix bytes).
   //--- Avoids MQL string NUL-termination truncating "\x00"+prefix to 0 bytes.
   bool              SendSubControlFrame(const uchar cmdByte,const string prefix)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      if(!CloseDanglingMultipart()) return false;
      uchar pbytes[];
      StringToUtf8(prefix,pbytes,false);
      int plen=ArraySize(pbytes);
      uchar frame[];
      ArrayResize(frame,1+plen);
      frame[0]=cmdByte;
      for(int k=0;k<plen;k++) frame[1+k]=pbytes[k];
      if(!m_sub.send(frame,true))
        {
         m_errno=CopierZmqErrno();
         return false;
        }
      return true;
     }

   //--- Decode a 40-character Z85 CURVE key into the 32 raw bytes that the
   //--- ZMQ_CURVE_* options actually take.
   //---
   //--- This helper exists because the binding's STRING overloads cannot be
   //--- used for these options. setStringOption() defaults to ending=true, so
   //--- StringToUtf8 appends a NUL and a 40-character key reaches
   //--- zmq_setsockopt as 41 bytes. libzmq accepts exactly 32 (binary) or 40
   //--- (Z85) and rejects anything else with EINVAL - and the bool that
   //--- reports it was IGNORED at every call site here, so a CURVE link
   //--- configured that way never completed a handshake and said nothing
   //--- anywhere. The uchar[] overloads are correct (exactly 32 bytes), so
   //--- the fix is to decode first and call those.
   static bool       CurveRaw(const string z85,uchar &raw[])
     {
      ArrayResize(raw,0);
      string clean=z85;
      StringTrimLeft(clean); StringTrimRight(clean);
      if(StringLen(clean)!=CP_CURVE_KEY_LEN) return false;
      if(!Z85::decode(clean,raw)) return false;
      if(ArraySize(raw)!=CP_CURVE_KEY_BYTES) return false;
      return true;
     }

public:
                     CopierTransport():m_ctx(NULL),m_pub(NULL),m_sub(NULL),
                     m_errno(0),m_nSubPrefixes(0),m_connectedHubs(0),m_midMultipart(false),
                     m_midInboundMultipart(false) {}

                    ~CopierTransport() { Close(); }

   int               LastErrno() const { return m_errno; }

   //--- Must be called BEFORE InitContext(). Empty means "use the shared
   //--- default context", which is what a single instance wants.
   void              SetInstanceName(const string n)
     {
      m_ctxName=(StringLen(n)>0)?(CP_CTX_NAME+"_"+n):"";
     }

   //=================================================================
   // Context initialization. Each EA instance owns a dedicated zmq_ctx_new()
   // handle directly by passing NULL, avoiding 64-bit pointer-to-double
   // truncation and CriticalSection concurrency bugs in GlobalVariable.mqh.
   //=================================================================
   bool              InitContext()
     {
      if(CheckPointer(m_ctx)!=POINTER_INVALID) return true;
      m_ctx=new Context(NULL);
      if(CheckPointer(m_ctx)==POINTER_INVALID) return false;
      return true;
     }

   //=================================================================
   // SENDER side: one PUB socket, one port.
   //
   // Events and snapshots go out of the same socket and are told apart by
   // the envelope's T= field. No ZMQ_CONFLATE anywhere - see the header.
   //=================================================================
   bool              BindSender(const string bindAddr,const int port,
                                const bool useCurve,
                                const string curveSecretKey)
     {
      if(!InitContext()) return false;

      //--- XPUB, not PUB. See the header: it publishes exactly like PUB and
      //--- additionally RECEIVES, which is what lets a receiver report back
      //--- over the same socket instead of needing one of its own.
      if(CheckPointer(m_pub)!=POINTER_INVALID) { delete m_pub; m_pub=NULL; }
      m_pub=new Socket(m_ctx,ZMQ_XPUB);
      if(CheckPointer(m_pub)==POINTER_INVALID || !m_pub.valid()) { if(CheckPointer(m_pub)!=POINTER_INVALID) { delete m_pub; m_pub=NULL; } return false; }
      Hardening(m_pub);
      m_pub.setSendHighWaterMark(CP_SNDHWM);
      if(useCurve)
        {
         //--- Fail CLOSED. If CURVE was asked for and the key cannot be
         //--- installed, binding anyway would quietly serve plaintext - the
         //--- exact silent downgrade the operator asked us not to do.
         if(StringLen(curveSecretKey)==0)
           {
            delete m_pub; m_pub=NULL;
            return false;
           }
         uchar sec[];
         if(!CurveRaw(curveSecretKey,sec) || !m_pub.setCurveServer(true) || !m_pub.setCurveSecretKey(sec))
           {
            delete m_pub; m_pub=NULL;
            return false;
           }
        }
      //--- "*" or "10.0.0.5" is accepted as well as "tcp://*". Same reason as
      //--- the receiver's endpoint: the scheme is the only one this speaks,
      //--- and leaving it out should not be a silent ZeroMQ failure.
      if(!m_pub.bind(CopierNormalizeEndpoint(bindAddr)+":"+(string)port))
        {
         m_errno=CopierZmqErrno();
         delete m_pub; m_pub=NULL;
         return false;
        }
      return true;
     }

   //=================================================================
   // RECEIVER side: one SUB socket, connected to every sender's single
   // endpoint.
   //
   // A SUB socket may connect to many endpoints, so N senders still cost
   // exactly one socket - not N, and no longer 2.
   //
   // ZMQ_CONFLATE IS NOT SET, AND MUST NOT BE. It is per-socket, so it
   // would conflate the event stream as well as the snapshot stream, and
   // dropping a trading instruction is not recoverable the way dropping a
   // snapshot is.
   //=================================================================
   bool              ConnectReceiver(const string &endpoints[],const int nEndpoints,
                                     const bool useCurve,
                                     const string &serverKeys[],
                                     const string myPublicKey,const string mySecretKey)
     {
      if(!InitContext()) return false;

      if(CheckPointer(m_sub)!=POINTER_INVALID) { delete m_sub; m_sub=NULL; }
      m_nSubPrefixes=0;
      for(int sp=0;sp<CP_MAX_XSUB_SUBS;sp++) { m_subPrefixes[sp]=""; m_subSent[sp]=0; }
      m_sub=new Socket(m_ctx,ZMQ_XSUB);
      if(CheckPointer(m_sub)==POINTER_INVALID || !m_sub.valid()) { if(CheckPointer(m_sub)!=POINTER_INVALID) { delete m_sub; m_sub=NULL; } return false; }
      Hardening(m_sub);
      m_sub.setReceiveHighWaterMark(CP_RCVHWM);
      m_sub.setSendHighWaterMark(CP_SNDHWM);
      if(useCurve)
        {
         uchar pub[],sec[];
         if(!CurveRaw(myPublicKey,pub) || !CurveRaw(mySecretKey,sec) ||
            !m_sub.setCurvePublicKey(pub) || !m_sub.setCurveSecretKey(sec))
           {
            delete m_sub; m_sub=NULL;
            return false;
           }
         if(nEndpoints>1)
           {
            for(int k=1;k<nEndpoints;k++)
              {
               if(StringLen(endpoints[k])>0 && serverKeys[k]!=serverKeys[0])
                 {
                  Print("[copier] ERROR: Multiple senders with different CURVE server keys on one receiver socket is not supported by libzmq.");
                  delete m_sub; m_sub=NULL;
                  return false;
                 }
              }
           }
        }
      for(int i=0;i<nEndpoints;i++)
        {
         if(StringLen(endpoints[i])==0) continue;
         if(useCurve)
           {
            //--- ONE serverkey per SOCKET, not per connection: a second
            //--- assignment replaces the first, so several senders with
            //--- several DIFFERENT keys cannot all be reached from this one
            //--- socket. That is a libzmq property, not a choice - the direct
            //--- channel's CURVE therefore supports one key for all its
            //--- senders (i.e. a shared key), while the hub link - one
            //--- endpoint, one key - has no such limit.
            if(StringLen(serverKeys[i])==0)
              {
               Print("[copier] ERROR: Missing CURVE server key for endpoint ",endpoints[i]);
               m_errno=22; // EINVAL
               delete m_sub; m_sub=NULL;
               return false;
              }
            uchar sk[];
            if(!CurveRaw(serverKeys[i],sk) || !m_sub.setCurveServerKey(sk))
              {
               Print("[copier] ERROR: Invalid CURVE server key for endpoint ",endpoints[i]);
               m_errno=22; // EINVAL
               delete m_sub; m_sub=NULL;
               return false;
              }
           }
         if(!m_sub.connect(endpoints[i]))
           {
            m_errno=CopierZmqErrno();
            delete m_sub; m_sub=NULL;
            return false;
           }
        }
      //--- XSUB DOES NOT AUTO-SUBSCRIBE, unlike SUB. The application must
      //--- send the subscription itself: one byte, 0x01 for "everything",
      //--- 0x00 to unsubscribe. setsockopt(ZMQ_SUBSCRIBE) is documented for
      //--- SUB only, so it is not used here.
      //--- Connect endpoints first so the subscription is routed across the active pipe.
      m_sub.send("\x01",true);
      return true;
     }

   //=================================================================
   // CENTRAL CHANNEL (Tier 2). Same m_sub socket, different conventions.
   //
   // ConnectHub() connects WITHOUT subscribing to anything. That difference
   // is the whole reason it is not just ConnectReceiver() with one endpoint:
   // ConnectReceiver() sends \x01, "give me everything", which is right when
   // the peer is one sender you chose. Against a hub it is wrong - it would
   // deliver every OTHER sender's stream as well, which is precisely what the
   // topic frame exists to avoid.
   //
   // So the caller connects, then subscribes to exactly the prefixes it wants:
   // its own control topic, plus one per sender it mirrors.
   //=================================================================
   bool              ConnectHub(const string endpoint,
                                const bool useCurve,
                                const string hubPublicKey,
                                const string myPublicKey,const string mySecretKey)
     {
      if(!InitContext()) return false;
      if(StringLen(endpoint)==0) return false;

      //--- "10.8.0.1:6000" is accepted as well as "tcp://10.8.0.1:6000".
      //--- Nobody types a scheme from memory, and the failure without one is a
      //--- silent ZMQ connect error - the operator sees "connected" nowhere and
      //--- "failed" nowhere either. Normalising here means every caller gets it,
      //--- rather than each EA remembering to.
      //--- Multi-Endpoint Support: if endpoint contains semicolon, parse all
      string eps[CP_MAX_CLUSTER_HUBS];
      int nEp=CopierParseEndpoints(endpoint,eps,CP_MAX_CLUSTER_HUBS);
      if(nEp<=0) return false;

      if(CheckPointer(m_sub)!=POINTER_INVALID) { delete m_sub; m_sub=NULL; }
      // MQL-06: Reset cached subscription prefixes upon ConnectHub to avoid stale replay
      m_nSubPrefixes=0;
      for(int sp=0;sp<CP_MAX_XSUB_SUBS;sp++) { m_subPrefixes[sp]=""; m_subSent[sp]=0; }
      m_sub=new Socket(m_ctx,ZMQ_XSUB);
      if(CheckPointer(m_sub)==POINTER_INVALID || !m_sub.valid()) { if(CheckPointer(m_sub)!=POINTER_INVALID) { delete m_sub; m_sub=NULL; } return false; }
      Hardening(m_sub);
      m_sub.setReceiveHighWaterMark(CP_RCVHWM);
      m_sub.setSendHighWaterMark(CP_SNDHWM);
      if(useCurve)
        {
         //--- A client needs all three: the server's public key (so it can
         //--- encrypt TO the server and verify the server), and its own
         //--- keypair (so the server can verify IT). Failing any of the three
         //--- is fatal - see the fail-closed note in BindSender.
         if(StringLen(hubPublicKey)==0) { delete m_sub; m_sub=NULL; return false; }
         uchar pub[],sec[],srv[];
         if(!CurveRaw(myPublicKey,pub) || !CurveRaw(mySecretKey,sec) ||
            !m_sub.setCurvePublicKey(pub) || !m_sub.setCurveSecretKey(sec) ||
            !CurveRaw(hubPublicKey,srv) || !m_sub.setCurveServerKey(srv))
           {
            delete m_sub; m_sub=NULL;
            return false;
           }
        }
      //--- deliberately NO \x01 here. See the note above.
      //--- Connect all parsed cluster endpoints to the same XSUB socket
      m_connectedHubs=0;
      for(int k=0;k<nEp;k++)
        {
         if(m_sub.connect(eps[k]))
            m_connectedHubs++;
        }
      if(m_connectedHubs<=0)
        {
         m_errno=CopierZmqErrno();
         delete m_sub; m_sub=NULL;
         return false;
        }
      return true;
     }

   //--- Connect an additional Hub endpoint (e.g. Standby Hub discovered at runtime)
   //--- to the existing XSUB socket, and replay all recorded subscriptions so the new pipe receives downlink.
   bool              ConnectExtraHub(const string endpoint)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      string ep=CopierNormalizeEndpoint(endpoint);
      if(StringLen(ep)==0) return false;
      if(!m_sub.connect(ep)) return false;
      m_connectedHubs++;
      // H-06: Replay all existing XSUB subscriptions over the newly connected pipe.
      //--- N-01: each replayed frame is another 0x01 the hub will count, so the
      //--- per-prefix counter has to move with it or the later Unsubscribe is
      //--- short by exactly this many.
      if(!CloseDanglingMultipart()) return false;
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(StringLen(m_subPrefixes[i])>0)
           {
            if(SendSubControlFrame(0x01,m_subPrefixes[i]))
               m_subSent[i]++;
           }
        }
      return true;
   }

   //--- Subscribe / unsubscribe one prefix. XSUB does not auto-subscribe, and
   //--- it does not auto-UNsubscribe either - a node whose sender list changed
   //--- keeps receiving the old stream until it says so.
   //---
   //--- IDEMPOTENT (N-01). The caller re-asserts its subscriptions every
   //--- heartbeat so a lost frame cannot leave it deaf; that is right, but each
   //--- 0x01 is a SEPARATE subscription as far as XPUB's reference count is
   //--- concerned, so re-sending every 5 s pushed the count into the thousands
   //--- and one 0x00 could never cancel it - Unsubscribe was dead for the life
   //--- of the socket. Sending 0x01 only when we have not already sent one for
   //--- this prefix keeps the count at 1, and libzmq replays the socket's
   //--- subscription trie onto every NEW pipe by itself, which is what actually
   //--- covers a hub restart. A socket that is rebuilt (ConnectHub) clears the
   //--- table, so the next announce re-subscribes from scratch.
   bool              Subscribe(const string prefix)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      // Record subscription for replay on new pipes (H-06)
      bool found=false;
      int  slot=-1;
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(m_subPrefixes[i]==prefix) { found=true; slot=i; break; }
        }
      if(found && m_subSent[slot]>0) return true;   // already subscribed on this socket
      if(!found && m_nSubPrefixes<CP_MAX_XSUB_SUBS)
        {
         slot=m_nSubPrefixes;
         m_subPrefixes[m_nSubPrefixes]=prefix;
         m_subSent[m_nSubPrefixes]=0;
         m_nSubPrefixes++;
        }
      if(!found && slot<0) return false;
      if(!SendSubControlFrame(0x01,prefix)) return false;
      //--- count only frames that reached the socket: a failed send is a
      //--- subscription the hub never saw, and must not need an 0x00 later
      if(slot>=0) m_subSent[slot]++;
      return true;
     }

   bool              Unsubscribe(const string prefix)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      if(!CloseDanglingMultipart()) return false;
      int sent=0;
      bool removed=false;
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(m_subPrefixes[i]!=prefix) continue;
         //--- one 0x00 per 0x01 we sent, otherwise XPUB's reference count never
         //--- reaches zero and the prefix stays live (N-01)
         int n=m_subSent[i];
         for(int k=0;k<n;k++)
           {
            if(SendSubControlFrame(0x00,prefix))
              {
               sent++;
               m_subSent[i]--;
              }
            else break;
           }
         if(m_subSent[i]<=0)
           {
            for(int j=i;j<m_nSubPrefixes-1;j++)
              {
               m_subPrefixes[j]=m_subPrefixes[j+1];
               m_subSent[j]=m_subSent[j+1];
              }
            m_nSubPrefixes--;
            m_subPrefixes[m_nSubPrefixes]="";
            m_subSent[m_nSubPrefixes]=0;
            removed=true;
           }
         break;
        }
      return (sent>0 || removed);
     }

   //--- Send a TWO-FRAME message: [topic, payload].
   //---
   //--- ZMQ matches a subscription against frame 0 only, so the topic is what
   //--- turns "broadcast to everyone" into real per-recipient delivery - and
   //--- the payload frame stays byte-identical to the single-frame form the
   //--- direct channel uses, so ONE parser serves both paths.
   //---
   //--- NH-06: Non-blocking envelope dispatch.
   //--- Both Frame 0 and Frame 1 use DONTWAIT (true) so an offline Hub or full HWM
   //--- never hangs the main EA thread under ZMQ_IMMEDIATE=1.
   bool              SendUp(const string topic,const string payload)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      //--- N56-13: @hub CONTROL frames must reach BOTH hubs.
      //---
      //--- This XSUB may hold two peers (primary + standby), and libzmq
      //--- round-robins the uplink across them: ONE send reaches exactly ONE
      //--- peer. The downstream direction broadcasts, the upstream does not -
      //--- tools/zmq_bidir_test.py measures precisely this and used to print
      //--- "status reaches only ONE sender" while still exiting green, because
      //--- it only asserted the downstream half.
      //---
      //--- Consequence: half of REG / ACK / STAT / snapshot-receipts landed on
      //--- the standby, which consumes them and never relays. The primary then
      //--- saw no ACK (command walked the whole retry ladder to `unknown`), no
      //--- STAT (node looked idle) and no receipt (sender re-sent snapshots).
      //---
      //--- Sending a control frame twice makes the round-robin land one copy on
      //--- each writable pipe. With a single pipe both copies go to the same
      //--- hub - harmless, because every @hub frame is idempotent (REG upserts,
      //--- ACK sets a terminal state, STAT refreshes a timestamp, a receipt is a
      //--- high-water mark).
      //--- R60-18 & ADR-02 / H1: Send 2 copies whenever connected to multiple hubs (HA cluster),
      //--- ensuring BOTH Primary and Standby receive every control AND data frame.
      //--- ZeroMQ XSUB uses round-robin across connected pipes for single sends, which splits
      //--- sequential frames (seq 1 -> Primary, seq 2 -> Standby, seq 3 -> Primary). A tiny jitter
      //--- on one pipe would cause Receiver to observe seq 3 before seq 2, permanently discarding
      //--- seq 2 as an expired sequence! Dual-send guarantees true active-active zero-loss replication,
      //--- with Receiver's CopierSeenRing (g_seen) and AcceptSeq handling microsecond-level deduplication.
      //--- F-18: a previous call may have left the socket mid-multipart. Try once
      //--- to close it with an empty terminator BEFORE writing anything new - that
      //--- is the only recovery ZMQ offers, and it works as soon as the pipe is
      //--- writable again. If it still fails the socket cannot be used for uplink
      //--- at all, and saying so (return false) is better than appending every
      //--- future message to a frame nobody can parse.
      if(!CloseDanglingMultipart()) return false;
      int copies=(m_connectedHubs>1) ? 2 : 1;
      int sent=0;
      for(int i=0;i<copies;i++)
        {
         if(!m_sub.sendMore(topic,true)) { m_errno=CopierZmqErrno(); continue; }
         if(!m_sub.send(payload,true))
           {
            m_errno=CopierZmqErrno();
            //--- N57-05: close the half-sent multipart WITHOUT blocking.
            //---
            //--- This used to pass false, which is ZMQ's BLOCKING mode. That call
            //--- runs on the EA thread: on a dead peer or a full pipe it simply
            //--- never returns, and the whole terminal freezes with it - charts,
            //--- trading, everything. Closing a dangling multipart is best-effort
            //--- cleanup and is never worth a wedge. If this one also fails the
            //--- frame is dropped, which is the same outcome the caller reports
            //--- anyway (return false) but without taking the terminal down.
            //--- F-18: if even THIS fails the socket stays mid-multipart; record it
            //--- so the next call closes the frame first instead of appending to it.
            //--- L-01: and STOP the copy loop. A failed terminator means the socket
            //--- is still holding an unterminated message; the next iteration's
            //--- sendMore() would append to it, producing [topic][ ][topic][payload]
            //--- - one corrupt frame the peer cannot parse - and `sent++` would then
            //--- report SUCCESS for it. Nothing may be written to this socket until
            //--- the frame is closed.
            bool closed=false;
            for(int att=0; att<3; att++)
              {
               if(m_sub.send("",true)) { closed=true; break; }
               CopierWaitMs(1);
              }
            if(!closed)
              {
               m_errno=CopierZmqErrno();
               m_midMultipart=true;
               break;
              }
            continue;
           }
         sent++;
        }
      return (sent>0 && !m_midMultipart);
     }

   //--- Drain m_sub, splitting each message into (topic, payload).
   //---
   //--- A SINGLE-FRAME message yields topic="" and the whole thing as the
   //--- payload. That is what lets the receiver run ONE parse loop over both
   //--- channels instead of two that can drift apart: on the direct channel
   //--- every message is single-frame, on the central channel every message is
   //--- two-frame, and the caller never has to know which it is on.
   //---
   //--- more() is read BEFORE the second recv on purpose: RCVMORE describes
   //--- the message just delivered, so reading it after the next recv would
   //--- describe the wrong one.
   int               DrainFrames(string &topics[],string &payloads[],
                                 const int maxMsgs)
     {
      int limit=(maxMsgs<CP_DRAIN_MAX)?maxMsgs:CP_DRAIN_MAX;
      if(ArrayIsDynamic(topics))   ArrayResize(topics,limit);
      if(ArrayIsDynamic(payloads)) ArrayResize(payloads,limit);
      if(CheckPointer(m_sub)==POINTER_INVALID)
        {
         //--- Shrink back before leaving: the arrays were sized for `limit`
         //--- above, and a caller that ever walks them by ArraySize() rather
         //--- than by the returned count would read the PREVIOUS tick's
         //--- frames. Zero-length is the only honest answer here.
         if(ArrayIsDynamic(topics))   ArrayResize(topics,0);
         if(ArrayIsDynamic(payloads)) ArrayResize(payloads,0);
         return 0;
        }

      // D5-X02: If previous tick aborted mid-multipart, drain remaining frames first
      if(m_midInboundMultipart)
        {
         bool drained=false;
         while(true)
           {
            ZmqMsg discard;
            if(!m_sub.recv(discard,true)) break;
            if(!discard.more()) { m_midInboundMultipart=false; drained=true; break; }
           }
         // P0-NET-01: If recv returned false (EAGAIN), the trailing frames are still in-flight.
         // Do NOT clear m_midInboundMultipart on momentary EAGAIN; wait for next tick.
         if(!drained)
           {
            return 0;
           }
        }

      int got=0;
      for(int i=0;i<limit;i++)
        {
         ZmqMsg m0;
         if(!m_sub.recv(m0,true)) break;          // EAGAIN -> nothing pending
         string first=m0.getData();
         string topic="",payload=first;
         if(m0.more())
           {
            ZmqMsg m1;
            //--- R1-X01: When m0.more() is true, the payload frame is already in transit.
            //--- Wait briefly (up to 20ms) for the payload frame rather than immediately
            //--- breaking on transient EAGAIN, which would invert socket frame boundaries.
            bool gotM1=false;
            for(int attempt=0; attempt<20; attempt++)
              {
               if(m_sub.recv(m1,true)) { gotM1=true; break; }
               CopierWaitMs(1);
              }
            if(!gotM1)
              {
               // R3-X01: Drain remaining multipart frames of THIS message safely without looping on m0
               bool hasMoreFrames=true;
               while(hasMoreFrames)
                 {
                  ZmqMsg extra;
                  bool gotExtra=false;
                  for(int a=0; a<5; a++)
                    {
                     if(m_sub.recv(extra,true)) { gotExtra=true; break; }
                     CopierWaitMs(1);
                    }
                  if(!gotExtra) break;
                  hasMoreFrames=extra.more();
                 }
               m_midInboundMultipart=hasMoreFrames;
               break;
              }
            topic=first;
            payload=m1.getData();
            //--- Drain and drop any unexpected additional frames (>2) to prevent
            //--- socket frame misalignment on subsequent message reads.
            bool hasMore=m1.more();
            while(hasMore)
              {
               ZmqMsg extra;
               if(!m_sub.recv(extra,true)) break;
               hasMore=extra.more();
              }
            if(hasMore)
              {
               m_midInboundMultipart=true;
               break; // R2-D5-X01: Break message loop to avoid misinterpreting remainder frames as m0
              }
            else
              {
               m_midInboundMultipart=false;
              }
           }
         if(got>=ArraySize(topics) || got>=ArraySize(payloads)) break;
         topics[got]=topic;
         payloads[got]=payload;
         got++;
        }
      if(ArrayIsDynamic(topics))   ArrayResize(topics,got);
      if(ArrayIsDynamic(payloads)) ArrayResize(payloads,got);
      return got;
     }

   //=================================================================
   // Send (non-blocking). Returns false on EAGAIN - the caller decides
   // whether it matters. For a snapshot it does not: the next one
   // supersedes it within SnapshotSeconds.
   //=================================================================
   //--- DEF-64-04: Returns true if direct publisher socket is bound and ready to send.
   //--- HasDirectSubscribers is maintained as a backward-compatible alias.
   bool              IsDirectSocketBound() const
     {
      return (CheckPointer(m_pub)!=POINTER_INVALID);
     }
   bool              HasDirectSubscribers() const
     {
      return IsDirectSocketBound();
     }

   bool              Send(const string msg)
     {
      if(CheckPointer(m_pub)==POINTER_INVALID) return false;
      if(!m_pub.send(msg,true)) { m_errno=CopierZmqErrno(); return false; }
      return true;
     }

   //=================================================================
   // Drain the socket non-blockingly. Returns the number of messages read
   // and appends them to out[], in arrival order.
   //
   // Bounded by maxMsgs so a burst can never monopolise the EA thread. The
   // caller must check whether the bound was reached - that means there is
   // more waiting, i.e. the EA is not keeping up.
   //=================================================================
   int               Drain(string &out[],const int maxMsgs)
     { return DrainSocket(m_sub,out,maxMsgs); }

   bool              SendStatus(const string msg)
     {
      //--- The receiver sends UP its own XSUB. This is the reverse
      //--- direction of the SAME socket - see the header for why that works
      //--- and what was measured before relying on it.
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      if(!CloseDanglingMultipart()) return false;
      if(!m_sub.send(msg,true)) { m_errno=CopierZmqErrno(); return false; }
      return true;
     }

   int               DrainStatus(string &out[],const int maxMsgs)
     {
      //--- The sender drains its own XPUB. Subscription bytes arrive here
      //--- too (that is how XPUB works), which is why the caller must decode
      //--- rather than assume every message is status.
      return DrainSocket(m_pub,out,maxMsgs);
     }

   //--- F-18: true when the uplink socket is stuck mid-multipart. The EA logs it
   //--- once; recovery is automatic on the next writable tick (see SendUp).
   bool              FramingCorrupted() const { return m_midMultipart; }

   bool              StatusReady() const
     {
      return (CheckPointer(m_pub)!=POINTER_INVALID
              || CheckPointer(m_sub)!=POINTER_INVALID);
     }

   //=================================================================
   // Teardown. Order matters: sockets first, context last.
   //=================================================================
   void              Close()
     {
      m_connectedHubs=0;
      m_midMultipart=false;
      m_midInboundMultipart=false;
      // MQL-04: Clear cached subscription prefixes on Close() to prevent unbounded accumulation
      m_nSubPrefixes=0;
      for(int i=0;i<CP_MAX_XSUB_SUBS;i++) { m_subPrefixes[i]=""; m_subSent[i]=0; }
      // P1-NET-04: Sockets first, context last.
      if(CheckPointer(m_pub)!=POINTER_INVALID) { m_pub.setLinger(0); delete m_pub; m_pub=NULL; }
      if(CheckPointer(m_sub)!=POINTER_INVALID) { m_sub.setLinger(0); delete m_sub; m_sub=NULL; }
      if(CheckPointer(m_ctx)!=POINTER_INVALID) { m_ctx.shutdown(); delete m_ctx; m_ctx=NULL; }
     }
  };

#endif
//+------------------------------------------------------------------+
