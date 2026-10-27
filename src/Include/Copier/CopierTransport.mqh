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
#define CP_SNDHWM 256
#define CP_RCVHWM 256

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
   int               m_nSubPrefixes;

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
      if(CheckPointer(s)==POINTER_INVALID) return;
      //--- must be 0: otherwise shutdown blocks
      s.setLinger(0);
      s.setReconnectInterval(100);
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
      if(StringLen(z85)!=CP_CURVE_KEY_LEN) return false;
      if(!Z85::decode(z85,raw)) return false;
      if(ArraySize(raw)!=CP_CURVE_KEY_BYTES) return false;
      return true;
     }

public:
                     CopierTransport():m_ctx(NULL),m_pub(NULL),m_sub(NULL),
                     m_errno(0),m_nSubPrefixes(0) {}

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
      if(CheckPointer(m_pub)==POINTER_INVALID) return false;
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
      m_sub=new Socket(m_ctx,ZMQ_XSUB);
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
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
      //--- XSUB DOES NOT AUTO-SUBSCRIBE, unlike SUB. The application must
      //--- send the subscription itself: one byte, 0x01 for "everything",
      //--- 0x00 to unsubscribe. setsockopt(ZMQ_SUBSCRIBE) is documented for
      //--- SUB only, so it is not used here.
      m_sub.send("\x01",true);
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
               delete m_sub; m_sub=NULL;
               return false;
              }
            uchar sk[];
            if(!CurveRaw(serverKeys[i],sk) || !m_sub.setCurveServerKey(sk))
              {
               delete m_sub; m_sub=NULL;
               return false;
              }
           }
         m_sub.connect(endpoints[i]);
        }
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
      m_sub=new Socket(m_ctx,ZMQ_XSUB);
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
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
      for(int k=0;k<nEp;k++)
        {
         m_sub.connect(eps[k]);
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
      // H-06: Replay all existing XSUB subscriptions over the newly connected pipe
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(StringLen(m_subPrefixes[i])>0)
           {
            m_sub.send("\x01"+m_subPrefixes[i],true);
           }
        }
      return true;
     }

   //--- Subscribe / unsubscribe one prefix. XSUB does not auto-subscribe, and
   //--- it does not auto-UNsubscribe either - a node whose sender list changed
   //--- keeps receiving the old stream until it says so.
   bool              Subscribe(const string prefix)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      // Record subscription for replay on new pipes (H-06)
      bool found=false;
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(m_subPrefixes[i]==prefix) { found=true; break; }
        }
      if(!found && m_nSubPrefixes<CP_MAX_XSUB_SUBS)
        {
         m_subPrefixes[m_nSubPrefixes++]=prefix;
        }
      return m_sub.send("\x01"+prefix,true);
     }

   bool              Unsubscribe(const string prefix)
     {
      if(CheckPointer(m_sub)==POINTER_INVALID) return false;
      for(int i=0;i<m_nSubPrefixes;i++)
        {
         if(m_subPrefixes[i]==prefix)
           {
            for(int j=i;j<m_nSubPrefixes-1;j++) m_subPrefixes[j]=m_subPrefixes[j+1];
            m_nSubPrefixes--;
            break;
           }
        }
      return m_sub.send("\x00"+prefix,true);
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
      //--- high-water mark). Data frames stay single-send: the standby forwards
      //--- them, so they are not lost either way, and duplicating them would
      //--- only add traffic.
      int copies=(StringLen(topic)>0 && StringSubstr(topic,0,1)=="@") ? 2 : 1;
      for(int i=0;i<copies;i++)
        {
         if(!m_sub.sendMore(topic,true)) { m_errno=CopierZmqErrno(); return false; }
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
            m_sub.send("",true);
            return false;
           }
        }
      return true;
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
            //--- a first frame that promised more but delivered nothing is a
            //--- torn message: drop it rather than act on half of one
            if(!m_sub.recv(m1,true)) break;
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
   bool              HasDirectSubscribers() const
     {
      return (CheckPointer(m_pub)!=POINTER_INVALID);
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
      if(CheckPointer(m_pub)!=POINTER_INVALID) { delete m_pub; m_pub=NULL; }
      if(CheckPointer(m_sub)!=POINTER_INVALID) { delete m_sub; m_sub=NULL; }
      if(CheckPointer(m_ctx)!=POINTER_INVALID) { delete m_ctx; m_ctx=NULL; }
     }
  };

#endif
//+------------------------------------------------------------------+
