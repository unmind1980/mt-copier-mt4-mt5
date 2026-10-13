//+------------------------------------------------------------------+
//|                                              CopierZmqProbe.mq4  |
//|                                                                   |
//| Does mql-zmq carry a TWO-FRAME message?                            |
//|                                                                   |
//| WHY THIS EXISTS                                                    |
//|                                                                    |
//| The central hub addresses one node by publishing [topic, envelope]. |
//| ZMQ matches a subscription against FRAME 0 only, so the topic frame |
//| is what turns "broadcast to everyone" into real per-node delivery.  |
//| The copier's v1 envelope starts with "V=1|", so subscribing to an   |
//| account number matches NOTHING - tools/zmq_topic_test.py proves     |
//| that on the pyzmq side, and proves the topic frame fixes it.        |
//|                                                                    |
//| What pyzmq cannot tell us is whether MQL can do the same thing, and |
//| that is the whole question here. The binding LOOKED like it could   |
//| not: ZmqMsg has no getPart(), and Socket::send() takes no SNDMORE.  |
//| That reading was WRONG, and this is how it was caught - Socket.mqh  |
//| has had sendMore() / more() / isReceiveMore() all along.            |
//|                                                                    |
//| So the probe is not "does it work" so much as "prove it, on THIS    |
//| build, before a single line of the hub is written".                 |
//|                                                                    |
//| SELF-CONTAINED ON PURPOSE                                           |
//|                                                                    |
//| It binds its own XPUB, connects its own XSUB to it, and talks to    |
//| itself. No hub, no second machine, no terminal settings. Drag it on |
//| any chart and read the Experts log.                                 |
//|                                                                    |
//| Output goes to the Experts log (and to copier_zmq_probe.log).       |
//+------------------------------------------------------------------+
#property strict

#include <Zmq/Zmq.mqh>

//--- any free local port. Nothing else in the copier uses this one.
//--- If the bind fails, the log says so - change it and re-run.
#define CP_PROBE_PORT 5781

int g_pass=0;
int g_fail=0;
int g_log=INVALID_HANDLE;

void Ok(const string name,const bool cond)
  {
   string line=(cond?"PASS  ":"FAIL  ")+name;
   if(cond) g_pass++; else g_fail++;
   Print(line);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,line); FileFlush(g_log); }
  }

void OkInt(const string name,const long actual,const long expected)
  {
   bool cond=(actual==expected);
   string line=(cond?"PASS  ":"FAIL  ")+name
               +"  (got "+(string)actual+", want "+(string)expected+")";
   if(cond) g_pass++; else g_fail++;
   Print(line);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,line); FileFlush(g_log); }
  }

void OkStr(const string name,const string actual,const string expected)
  {
   bool cond=(actual==expected);
   string line=(cond?"PASS  ":"FAIL  ")+name
               +"  (got ["+actual+"], want ["+expected+"])";
   if(cond) g_pass++; else g_fail++;
   Print(line);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,line); FileFlush(g_log); }
  }

void Note(const string s)
  {
   Print("      "+s);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,"      "+s); FileFlush(g_log); }
  }

//--- Drain whatever is pending, discarding it. Used to swallow the
//--- subscription notifications an XPUB receives: they are NOT data, and
//--- leaving them queued would make the next recv read the wrong thing.
//---
//--- A FRESH ZmqMsg per iteration on purpose. zmq_msg_recv() re-initialises
//--- the message it is given, and reusing one across calls is exactly the
//--- kind of thing that works until it does not.
int DrainAll(Socket *s)
  {
   int n=0;
   while(true)
     {
      ZmqMsg m;
      if(!s.recv(m,true)) break;
      n++;
      if(n>1000) break;              // paranoia: never spin forever
     }
   return n;
  }

//--- Receive ONE message and report its frames.
//---
//--- more() is read from frame 0 BEFORE frame 1 is received: RCVMORE
//--- describes the message just delivered, so reading it after the next
//--- recv would describe the wrong message. That ordering IS the test.
bool RecvFrames(Socket *s,string &f0,string &f1,int &nFrames,const int waitMs)
  {
   f0=""; f1=""; nFrames=0;
   int waited=0;
   while(waited<waitMs)
     {
      ZmqMsg m0;
      if(!s.recv(m0,true))
        {
         Sleep(20);
         waited+=20;
         continue;
        }
      f0=m0.getData();
      nFrames=1;
      if(!m0.more()) return true;    // a single-frame message
      ZmqMsg m1;
      if(s.recv(m1,true))
        {
         f1=m1.getData();
         nFrames=2;
        }
      return true;
     }
   return false;                     // nothing arrived within waitMs
  }

//--- Wait until the XPUB has actually RECEIVED a subscription change,
//--- instead of sleeping a guessed interval.
//---
//--- A fixed Sleep() here is a RACE, and it is the one that made this probe
//--- report a failure on the 32-bit MT4 builds while passing on 64-bit MT5.
//--- Publishing before the unsubscribe had landed left the old filter in
//--- place, so the "unsubscribed" message was still delivered - and the test
//--- blamed the library for what was really its own impatience.
//---
//--- The fix is to wait for the event rather than for a duration: the XPUB
//--- emits one notification per subscribe/unsubscribe, so its arrival IS the
//--- signal that the filter has been updated.
//--- Returns the milliseconds waited, or -1 if nothing arrived in maxMs.
int WaitForSubEvent(Socket *pub,const int maxMs)
  {
   int waited=0;
   while(waited<maxMs)
     {
      ZmqMsg m;
      if(pub.recv(m,true)) return waited;
      Sleep(20);
      waited+=20;
     }
   return -1;
  }

void OnStart()
  {
   FileDelete("copier_zmq_probe.log");
   g_log=FileOpen("copier_zmq_probe.log",FILE_WRITE|FILE_TXT|FILE_ANSI);

   Print("=== mql-zmq multipart probe ===");
   if(g_log!=INVALID_HANDLE) FileWrite(g_log,"=== mql-zmq multipart probe ===");

   //--- a NAMED context, so this cannot disturb a running copier instance
   Context *ctx=new Context("__copier_zmq_probe_ctx__");
   string ep="tcp://127.0.0.1:"+(string)CP_PROBE_PORT;

   Socket *pub=new Socket(ctx,ZMQ_XPUB);
   pub.setLinger(0);
   if(!pub.bind(ep))
     {
      Ok("XPUB binds "+ep,false);
      Note("port "+IntegerToString(CP_PROBE_PORT)+" is busy - change"
           +" CP_PROBE_PORT at the top of the script and re-run");
      delete pub;
      delete ctx;
      if(g_log!=INVALID_HANDLE) FileClose(g_log);
      return;
     }
   Ok("XPUB binds "+ep,true);

   Socket *sub=new Socket(ctx,ZMQ_XSUB);
   sub.setLinger(0);
   sub.connect(ep);

   //--- XSUB does NOT auto-subscribe; the application must send the byte.
   sub.send("\x01"+"888888");
   WaitForSubEvent(pub,3000);         // wait for the filter to be applied
   DrainAll(pub);                     // ...then clear anything else

   //=================================================================
   // 1. THE QUESTION: can we SEND a two-frame message?
   //    sendMore() sets SNDMORE, send() ends the message.
   //=================================================================
   bool s0=pub.sendMore("888888");
   bool s1=pub.send("V=1|SID=888888|SSID=a1|SEQ=1|T=SNAP|P=x");
   Ok("sendMore() accepted the topic frame",s0);
   Ok("send() accepted the payload frame",s1);

   string f0,f1;
   int nf=0;
   bool got=RecvFrames(sub,f0,f1,nf,2000);
   Ok("the two-frame message arrived",got);
   OkInt("...with exactly two frames",nf,2);
   OkStr("...frame 0 is the topic",f0,"888888");
   OkStr("...frame 1 is the v1 envelope, byte-identical",
         f1,"V=1|SID=888888|SSID=a1|SEQ=1|T=SNAP|P=x");

   //=================================================================
   // 2. does more() actually report the frame boundary?
   //    This is the API the whole receive path would depend on.
   //=================================================================
   pub.sendMore("888888");
   pub.send("PAYLOAD2");
   int waited=0;
   bool ranMore=false;
   while(waited<2000)
     {
      ZmqMsg m0;
      if(!sub.recv(m0,true)) { Sleep(20); waited+=20; continue; }
      bool moreOnFirst=m0.more();     // must be TRUE: another frame follows
      ZmqMsg m1;
      bool got1=sub.recv(m1,true);
      bool moreOnLast=true;
      if(got1) moreOnLast=m1.more();  // must be FALSE: that was the end
      Ok("more() is TRUE on frame 0",moreOnFirst);
      Ok("more() is FALSE on the last frame",!moreOnLast);
      ranMore=true;
      break;
     }
   if(!ranMore) Ok("the more() probe received a message",false);

   //=================================================================
   // 3. the filter is on FRAME 0 - a different topic must NOT arrive
   //=================================================================
   pub.sendMore("999999");
   pub.send("SHOULD-NOT-ARRIVE");
   string g0,g1; int gn=0;
   bool leaked=RecvFrames(sub,g0,g1,gn,400);
   Ok("a different topic is NOT delivered to this subscriber",!leaked);

   //=================================================================
   // 4. a second prefix on the SAME socket - a receiver mirrors N senders
   //    and also wants control addressed to itself
   //=================================================================
   sub.send("\x01"+"999999");
   int wAdd=WaitForSubEvent(pub,3000);
   Ok("the XPUB saw the new subscription",wAdd>=0);
   if(wAdd>=0) Note("...applied after "+IntegerToString(wAdd)+" ms");
   DrainAll(pub);
   pub.sendMore("999999");
   pub.send("SECOND-PREFIX");
   bool got2=RecvFrames(sub,g0,g1,gn,1000);
   Ok("a second prefix can be added to the same XSUB",got2);
   OkStr("...and it delivers the right topic",g0,"999999");

   //=================================================================
   // 5. UNSUBSCRIBE - needed when a receiver's sender list changes,
   //    otherwise it keeps receiving a stream it no longer mirrors
   //
   //    NOTE: wait for the event, do not sleep a guess. See WaitForSubEvent.
   //
   //    NOTE 2 - DrainAll(sub), and why it is here:
   //    the block above read ONE message back off sub (SECOND-PREFIX). If
   //    any residue was still queued on sub's INBOUND pipe, it would be
   //    read by the loop below and counted as AFTER-UNSUB - i.e. the probe
   //    would blame the library for a message the library never sent.
   //    Clearing sub first makes the loop see only what is sent AFTER the
   //    unsubscribe. DrainAll(pub) was already done; this is its mirror.
   //=================================================================
   sub.send("\x00"+"999999");
   int wDrop=WaitForSubEvent(pub,3000);
   Ok("the XPUB saw the unsubscribe",wDrop>=0);
   if(wDrop>=0) Note("...applied after "+IntegerToString(wDrop)+" ms");
   DrainAll(pub);
   int preSub=DrainAll(sub);           // <-- the fix: clear sub's inbox too
   if(preSub>0)
      Note("discarded "+IntegerToString(preSub)+" stale message(s) left on sub"
           +" by the previous block (not sent after the unsubscribe)");

   pub.sendMore("999999");
   pub.send("AFTER-UNSUB");
   pub.sendMore("888888");
   pub.send("STILL-SUBSCRIBED");
   bool sawDropped=false, sawKept=false;
   string seenTopics="";
   for(int i=0;i<20;i++)
     {
      string a,b; int n2=0;
      if(!RecvFrames(sub,a,b,n2,200)) continue;
      if(StringLen(seenTopics)<120) seenTopics+="["+a+"]";
      if(a=="999999") sawDropped=true;
      if(a=="888888") sawKept=true;
     }
   //--- report what actually arrived, so a failure names its own evidence
   //--- instead of forcing a re-run to find out.
   Note("topics seen after the unsubscribe: "
        +(StringLen(seenTopics)>0 ? seenTopics : "(none)"));
   Ok("an unsubscribed prefix stops being delivered",!sawDropped);
   Ok("...while the other prefix keeps working",sawKept);

   //=================================================================
   Print("");
   Print("=== result ===");
   Print("  pass="+(string)g_pass+"  fail="+(string)g_fail);
   if(g_log!=INVALID_HANDLE)
     {
      FileWrite(g_log,"");
      FileWrite(g_log,"=== result ===");
      FileWrite(g_log,"  pass="+(string)g_pass+"  fail="+(string)g_fail);
     }

   Print("");
   if(g_fail==0)
     {
      Print("  VERDICT: mql-zmq carries two-frame messages in BOTH");
      Print("           directions, so the topic frame needs NO binding");
      Print("           patch - sendMore() / more() are already there.");
      Print("           Plan B (topic frame + prefix subscription) is GO.");
     }
   else
     {
      Print("  VERDICT: multipart does NOT work as needed on this build.");
      Print("           Fall back to plan A (in-payload TO= filtering).");
     }

   sub.setLinger(0);
   pub.setLinger(0);
   delete sub;
   delete pub;
   delete ctx;
   if(g_log!=INVALID_HANDLE) { FileFlush(g_log); FileClose(g_log); }
   Print("probe finished - log: MQL\\Files\\copier_zmq_probe.log");
  }
//+------------------------------------------------------------------+
