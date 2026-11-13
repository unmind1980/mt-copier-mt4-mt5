//+------------------------------------------------------------------+
//| RecvHubCtl.mqh                                                   |
//| Part of CopierReceiver.mq4 - not a standalone header.            |
//+------------------------------------------------------------------+
//--- Hub control plane: CFG apply/ack, TOPOLOGY, CMD.
//--- Included at a fixed point inside CopierReceiver.mq4 and relies on
//--- the globals, inputs and helpers declared above that point. Moved
//--- verbatim out of the EA; do not include it from anywhere else.
#ifndef __COPIER_RECVHUBCTL_MQH__
#define __COPIER_RECVHUBCTL_MQH__

// M4b: applying a config the hub pushed.
//
// THE ORDER OF THESE STEPS IS THE WHOLE DESIGN. In particular the config is
// WRITTEN AND VERIFIED BEFORE anything is torn down, so a push that turns out
// to be unusable leaves a receiver that is still running the old one.
//=====================================================================

void SendCfgAck(const string body)
  {
   //--- The same upward path STAT uses: @hub, this node's identity, the
   //--- shared status sequence. A second counter would only make the numbers
   //--- on the wire harder to read.
   CopierSendStatus(CP_T_ACK,body);
  }

//--- Subscribe to the senders we now mirror, and drop the ones we no longer
//--- do. Returns the number of topics added.
int ResubscribeSenders(const string &before[],const int beforeN)
  {
   int added=0;
   for(int i=0;i<g_nSenders;i++)
     {
      bool had=false;
      for(int j=0;j<beforeN;j++)
         if(before[j]==g_sid[i]) { had=true; break; }
      if(!had && StringLen(g_sid[i])>0)
        {
         g_tp.Subscribe(g_sid[i]);
         added++;
        }
     }
   //--- Unsubscribing matters as much as subscribing: a sender that was
   //--- removed from the config would otherwise keep streaming snapshots at a
   //--- receiver that no longer has a slot for it, which reads as data the
   //--- receiver ignores and a hub link that never goes quiet.
   for(int j=0;j<beforeN;j++)
     {
      if(StringLen(before[j])==0) continue;
      // BUG-04 & OPT-10: Never unsubscribe receiver's own identity topic (g_nid or raw login),
      // which receives targeted slice-B snapshot repairs from senders.
      if(before[j]==(string)g_nid || before[j]==(string)CopierAccountLogin()) continue;
      bool still=false;
      for(int i=0;i<g_nSenders;i++)
         if(g_sid[i]==before[j]) { still=true; break; }
      if(!still) g_tp.Unsubscribe(before[j]);
     }
   return added;
  }

void HandleTopology(const CopierEnv &e)
  {
   string prim="", sec="", epStr="", actStr="";
   CopierKvGet(e.payload,"PRIMARY",prim);
   CopierKvGet(e.payload,"STANDBY",sec);
   CopierKvGet(e.payload,"EPOCH",epStr);
   CopierKvGet(e.payload,"ACTIVE",actStr);

   if(StringLen(prim)==0 && StringLen(sec)==0) return;
   if(StringLen(prim)>0) prim=CopierNormalizeEndpoint(prim);
   if(StringLen(sec)>0)  sec=CopierNormalizeEndpoint(sec);
   long epoch=CopierParseLong(epStr);

   CopierClusterState curCs;
   bool hasCache=CopierClusterCache::Load(curCs);
   if(hasCache && epoch>0 && epoch<curCs.epoch) return; // P2-24: Ignore stale topology frame with older epoch
   if(StringLen(prim)==0 && hasCache) prim=curCs.primary;
   if(StringLen(sec)==0 && hasCache)  sec=curCs.standby;
   if(epoch==0 && hasCache)           epoch=curCs.epoch;

   //--- Connect whichever of the two hubs is missing - PRIMARY as well as
   //--- STANDBY.
   //---
   //--- Only the standby used to be handled here, so a node whose ini named
   //--- the standby alone (or that came up while the primary was being
   //--- serviced) stayed connected to the standby forever. It shows as online
   //--- in the hub's node list, and every CFG and CMD the primary pushes is
   //--- addressed to a link that does not exist - "the node is up but never
   //--- picks up its configuration", with nothing on either side saying why.
   //---
   //--- PRIMARY is tried first, so g_connectedEps keeps PRIMARY/STANDBY order
   //--- after whatever the ini already connected. When the two entries name
   //--- the same hub, the second pass finds it already in the list and does
   //--- nothing, which is what the old `sec!=prim` guard did.
   string wantEp[2];
   wantEp[0]=prim;
   wantEp[1]=sec;
   for(int w=0;w<2;w++)
     {
      string ep=wantEp[w];
      if(StringLen(ep)==0) continue;
      bool already=false;
      for(int k=0;k<g_connectedEpCount;k++)
        {
         if(g_connectedEps[k]==ep) { already=true; break; }
        }
      if(already || g_connectedEpCount>=CP_MAX_CLUSTER_HUBS) continue;
      if(g_tp.ConnectExtraHub(ep))
        {
         g_connectedEps[g_connectedEpCount++]=ep;
         g_hubEp="";
         for(int k=0;k<g_connectedEpCount;k++) g_hubEp+=(k>0?";":"")+g_connectedEps[k];
         g_announceCount=0; // Reset announcement burst to register on new Hub across handshake!
         g_log.Info("central channel: dynamically connected to "
                    +((w==0)?"primary":"standby")+" hub at "+ep
                    +" via TOPOLOGY (re-registration armed)");
        }
     }

   // Persist topology cache to disk only when changed
   if(!hasCache || prim!=curCs.primary || sec!=curCs.standby || epoch!=curCs.epoch)
     {
      CopierClusterCache::Save(prim,sec,epoch);
     }
  }

void HandleCfg(const CopierEnv &e)
  {
   string id="",revs="",iniEsc="";
   CopierKvGet(e.payload,"ID",id);
   CopierKvGet(e.payload,"REV",revs);
   CopierKvGet(e.payload,"INI",iniEsc);
   //--- 64-bit, like every other numeric parse on the wire: MQL4's
   //--- StringToInteger is 32-bit and wraps past 2.1 billion, which would make
   //--- this receiver report a revision that goes BACKWARDS and invite the hub
   //--- to re-push forever.
   long rev=CopierParseLong(revs);

   //--- No ID means there is nothing to acknowledge against, and the hub would
   //--- retry forever against a node that cannot answer. Reported, not ignored.
   if(StringLen(id)==0)
     {
      g_log.Error("CFG with no ID - cannot acknowledge it, so the hub will"
                  +" retry. Ignoring.");
      return;
     }

   string pto="";
   CopierKvGet(e.payload,"TO",pto);
   if(StringLen(pto)>0 && pto!=(string)g_nid && pto!=(string)CopierAccountLogin())
     {
      g_log.Warn("CFG "+id+" addressed to TO="+pto+" (not our NID "+(string)g_nid+"). Discarded.");
      return;
     }

   //--- THE GATE. Answering at all is deliberate: silence would leave the hub
   //--- walking its retry ladder for a refusal it could have been told about
   //--- immediately.
   if(!AcceptConfigPush)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=config push disabled on this receiver");
      if(g_once.ShouldEmit("cfg|off"))
         g_log.Warn("the hub pushed a config (id="+id+") but AcceptConfigPush"
                    +" is false, so it was NOT applied. That switch exists"
                    +" because a CFG rewrites copier.ini and reloads - and"
                    +" until there is authentication on the hub link, anything"
                    +" that can reach it can send one.");
      return;
     }
   if(!g_hubOn)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=not in central mode");
      return;
     }

   //--- IDEMPOTENCY, the plan's §5.4 rule 2. A repeated ID re-sends the SAME
   //--- answer and does not re-apply. Under §11 primary/standby two hubs can
   //--- push one change, and the second copy must be a no-op rather than a
   //--- second reload.
   if(StringLen(g_cfgId)>0 && id==g_cfgId && StringLen(g_cfgAck)>0)
     {
      SendCfgAck(g_cfgAck);
      g_log.Info("CFG "+id+" is a repeat - re-sent the same ACK, not re-applied");
      return;
     }

   string ini="";
   if(!CopierIniUnescape(iniEsc,ini))
     {
      SendCfgAck("ID="+id+";OK=0;ERR=malformed escape in INI");
      g_log.Error("CFG "+id+": the INI field is not validly escaped. Refused.");
      return;
     }

   string err="";
   if(!CopierIniValidate(ini,err))
     {
      SendCfgAck("ID="+id+";OK=0;ERR="+err);
      g_log.Error("CFG "+id+": refused before touching the file - "+err);
      return;
     }

   //--- Monotonicity check: a lagging or split-brain hub must not roll back our config
   if(rev>0 && g_cfgRev>0 && rev<g_cfgRev)
     {
      g_cfgId=id;
      g_cfgAck="ID="+id+";OK=0;ERR=stale rev "+(string)rev+" < "+(string)g_cfgRev;
      SendCfgAck(g_cfgAck);
      g_log.Warn("CFG "+id+" rev "+(string)rev+" is OLDER than running rev "
                 +(string)g_cfgRev+" - refused (a lagging hub must not roll us back)");
      return;
     }

   //--- What is about to change, captured BEFORE the reload so the ACK can
   //--- report it. §10 layer 2: a magic change orphans whatever is open under
   //--- the old one, and that is worth saying out loud rather than leaving to
   //--- be discovered from the panel.
   string beforeSid[CP_MAX_SENDERS];
   long   beforeMagic[CP_MAX_SENDERS];
   //--- ArrayInitialize rather than a hand-written loop. MQL warns about
   //--- "possible use of uninitialised variable" and it is right: with zero
   //--- senders the fill loop below never runs, and the comparison further
   //--- down would read whatever was on the stack - a stale magic read as "the
   //--- previous magic" would invent an orphan warning out of nothing.
   //---
   //--- ArrayInitialize is used rather than a `for` loop because the analyser
   //--- recognises it and does not recognise the loop, so the loop silences
   //--- nothing.
   ArrayInitialize(beforeMagic,0);
   for(int z=0;z<CP_MAX_SENDERS;z++) beforeSid[z]="";
   int    beforeN=g_nSenders;
   for(int i=0;i<beforeN;i++)
     {
      beforeSid[i]=g_sid[i];
      beforeMagic[i]=g_magic[i];
     }

   if(!CopierIniWriteAtomic(ini,err))
     {
      SendCfgAck("ID="+id+";OK=0;ERR="+err);
      g_log.Error("CFG "+id+": "+err+". The receiver is still running the"
                  +" previous configuration.");
      return;
     }

   //--- The file is written and verified. NOW reload.
   if(!LoadConfig())
     {
      //--- The new ini parses as a FILE but the config is not usable - a
      //--- missing magic=, a bad id=. Put the old one back: a config that
      //--- cannot load is worse than the one that could.
      string old="";
      if(CopierIniReadAll(CP_INI_BAK_PATH,old) && StringLen(old)>0)
        {
         bool wOk=CopierIniWriteAll(CP_INI_PATH,old);
         bool lOk=wOk && LoadConfig();
         if(wOk && lOk)
           {
            g_cfgId=id;
            g_cfgAck="ID="+id+";OK=0;ERR=config rejected by LoadConfig; previous config restored";
            SendCfgAck(g_cfgAck);
            g_log.Error("CFG "+id+" rejected by LoadConfig - restored "+CP_INI_BAK_PATH);
           }
         else
           {
            g_cfgId=id;
            g_cfgAck="ID="+id+";OK=0;ERR=config rejected and failed to restore backup";
            SendCfgAck(g_cfgAck);
            g_log.Error("CFG "+id+" rejected by LoadConfig and failed to restore "+CP_INI_BAK_PATH);
           }
        }
      else
        {
         g_cfgId=id;
         g_cfgAck="ID="+id+";OK=0;ERR=config rejected and no backup to restore";
         SendCfgAck(g_cfgAck);
         g_log.Error("CFG "+id+" rejected by LoadConfig and there is no backup");
        }
      return;
     }

   int added=ResubscribeSenders(beforeSid,beforeN);
   ClearQueueExceptRiskReducing();
   RemapQueueSenders(beforeSid,beforeN);
   //--- P3: the magic/symbol mapping just changed, so every sender's mirror set
   //--- is stale. Reconcile everything on the next tick, not on the next sweep.
   g_convergeDirtyAll=true;
   for(int ci=0;ci<CP_MAX_SENDERS;ci++) g_convergeDirty[ci]=true;

   //--- Warnings, counted the way §10 asks: a magic change orphans positions.
   int warnings=0;
   for(int i=0;i<g_nSenders;i++)
     {
      long was=0;
      for(int j=0;j<beforeN;j++)
         if(beforeSid[j]==g_sid[i]) { was=beforeMagic[j]; break; }
      if(was!=0 && was!=g_magic[i]) warnings++;
     }
   if(beforeN!=g_nSenders) warnings++;

   g_cfgId=id;
   g_cfgRev=rev;
   g_cfgAck="ID="+id+";OK=1;REV="+(string)rev+";WARN="+(string)warnings;
   CopierCfgRevSave(id,rev);
   SendCfgAck(g_cfgAck);
   SendCurrentConfigReport();

   g_log.Info("CFG "+id+" applied: rev "+(string)rev+", "
              +IntegerToString(beforeN)+" -> "+IntegerToString(g_nSenders)
              +" sender(s), "+IntegerToString(added)+" new subscription(s), "
              +IntegerToString(warnings)+" warning(s)");
   if(warnings>0)
      g_log.Warn("CFG "+id+": "+IntegerToString(warnings)+" warning(s) - a magic"
                 +" or sender-set change leaves positions that are no longer"
                 +" managed. Check the panel's orphan rows.");
  }

// M5b: acting on an operational command the hub pushed.
//
// The skeleton is HandleCfg's ON PURPOSE: gate, then idempotency, then act,
// then answer - on the same upward path, with the same ACK frame. The one
// structural difference is what gets PERSISTED. HandleCfg records the id and
// the answer because a config must not be applied twice; here only the PAUSE
// flag is, because the four ops are idempotent by nature (pause twice is
// pause, a second closeall finds nothing left to close, a reload re-reads
// the same file) - which is exactly the fallback the plan's §5.4 rule 1
// leans on for the crash window. A repeated OLD id answered after a restart
// re-executes the op; for these four that is bounded and harmless, and it
// still never leaves the hub without an answer.
//
// OK=0 refusals at the GATE are deliberately NOT recorded (like HandleCfg):
// the operator may flip the switch on and the hub's retry should then
// succeed without anyone re-issuing the command. Refusals from the op
// itself (a failed reload) ARE recorded, so the hub sees the same answer
// on every retry instead of a fresh failure each time.
void HandleCmd(const CopierEnv &e)
  {
   string id="",op="",args="";
   CopierKvGet(e.payload,"ID",id);
   CopierKvGet(e.payload,"OP",op);
   CopierKvGet(e.payload,"ARGS",args);

   //--- No ID means there is nothing to acknowledge against, and the hub
   //--- would retry forever against a node that cannot answer.
   if(StringLen(id)==0)
     {
      g_log.Error("CMD with no ID - cannot acknowledge it, so the hub will"
                  +" retry. Ignoring.");
      return;
     }

   string pto="";
   CopierKvGet(e.payload,"TO",pto);
   if(StringLen(pto)>0 && pto!=(string)g_nid && pto!=(string)CopierAccountLogin())
     {
      g_log.Warn("CMD "+id+" addressed to TO="+pto+" (not our NID "+(string)g_nid+"). Discarded.");
      return;
     }

   //--- THE GATE, the twin of AcceptConfigPush in HandleCfg.
   if(!AcceptCommands)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=commands disabled on this receiver");
      if(g_once.ShouldEmit("cmd|off"))
         g_log.Warn("the hub sent a command (id="+id+", op="
                    +(StringLen(op)>0?op:"(none)")
                    +") but AcceptCommands is false, so it was NOT acted on."
                    +" That switch exists because a CMD can pause this"
                    +" receiver and close every mirror it holds - and until"
                    +" there is authentication on the hub link, anything that"
                    +" can reach it can send one.");
      return;
     }
   if(!g_hubOn)
     {
      SendCfgAck("ID="+id+";OK=0;ERR=not in central mode");
      return;
     }

   //--- IDEMPOTENCY, the plan's §5.4 rule 2 - same as HandleCfg.
   if(StringLen(g_cmdId)>0 && id==g_cmdId && StringLen(g_cmdAck)>0)
     {
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+" is a repeat - re-sent the same ACK, not re-applied");
      return;
     }

   if(StringLen(op)==0)
     {
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=0;ERR=no OP in command";
      SendCfgAck(g_cmdAck);
      g_log.Error("CMD "+id+": no OP field. Refused.");
      return;
     }

   if(op=="pause")
     {
      g_cmdPaused=true;
      CmdStateSave();
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Warn("CMD "+id+": PAUSED by the hub - no new mirrors will be"
                 +" opened. Existing positions are still managed normally"
                 +" (stops, trims, sender closes). RESUME clears this.");
      return;
     }

   if(op=="resume")
     {
      bool was=g_cmdPaused;
      g_cmdPaused=false;
      CmdStateSave();
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      if(was) g_log.Info("CMD "+id+": RESUMED by the hub - new mirrors are"
                         +" opened again");
      else    g_log.Info("CMD "+id+": RESUME - the receiver was not paused");
      return;
     }

   if(op=="closeall")
     {
      //--- Pause FIRST, and save it, because converge runs on every snapshot:
      //--- a flatten that leaves the sender's desired set mirrored re-opens
      //--- everything within seconds, and the operator would watch closeall
      //--- undo itself. Pausing is also what makes closeall and pause two
      //--- buttons the operator can reason about: closeall is "stop AND
      //--- flatten", resume is the way back.
      g_cmdPaused=true;
      CmdStateSave();
      int failed=0, total=0;
      int n=CloseAllOurs("CMD "+id+": CLOSEALL from the hub",failed,total);
      g_cmdId=id;
      if(total>0)
        {
         // BUG-03: Keep g_cmdCloseAllActive true until all matching positions are confirmed closed
         g_cmdCloseAllActive=true;
         g_cmdCloseAllId=id;
         if(failed==0)
           {
            g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
            g_log.Warn("CMD "+id+": closeall queued "+(string)n+" close(s); receiver paused. RESUME re-enables opening.");
           }
         else
           {
            g_cmdAck="ID="+id+";OK=0;REASON=queue_full_queued_"+(string)n+"_of_"+(string)total+";REV="+(string)g_cfgRev;
            g_log.Error("CMD "+id+": closeall queued "+(string)n+" of "+(string)total+" ("+(string)failed+" queue full) - continuing background retry");
           }
        }
      else
        {
         g_cmdCloseAllActive=false;
         g_cmdCloseAllId="";
         g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev+";NOTE=no_positions_held";
         g_log.Info("CMD "+id+": closeall called but receiver holds 0 positions.");
        }
      SendCfgAck(g_cmdAck);
      return;
     }

   if(op=="close")
     {
      // MQL-BUG-01: Parse 64-bit ticket using CopierParseLong to prevent 32-bit integer overflow
      long targetTicket=0;
      string tstr="";
      if(CopierKvGet(args,"ticket",tstr) || CopierKvGet(args,"TICKET",tstr))
         targetTicket=CopierParseLong(tstr);
      else
         targetTicket=CopierParseLong(args);
      if(targetTicket<=0)
        {
         g_cmdId=id;
         g_cmdAck="ID="+id+";OK=0;ERR=invalid ticket in close command";
         SendCfgAck(g_cmdAck);
         g_log.Error("CMD "+id+": close failed - invalid ticket \""+args+"\"");
         return;
        }

      int an=CopierReadPositions(g_scanScratch,CP_MAX_POSITIONS);
      int foundIdx=-1;
      for(int i=0;i<an;i++)
        {
         if(g_scanScratch[i].ticket==targetTicket)
           {
            foundIdx=i;
            break;
           }
        }

      if(foundIdx<0)
        {
         g_cmdId=id;
         g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev+";NOTE=ticket_not_found_or_already_closed";
         SendCfgAck(g_cmdAck);
         g_log.Warn("CMD "+id+": ticket #"+(string)targetTicket+" not found or already closed.");
         return;
        }

      CopierPos targetPos=g_scanScratch[foundIdx];
      int si=MagicToSender(targetPos.magic);
      string uid=ResolveUid(targetPos);
      if(StringLen(uid)==0)
         uid="#t"+(string)targetPos.ticket;

      string sname=(si>=0 && si<CP_MAX_SENDERS && StringLen(g_sid[si])>0) ? g_sid[si] : "manual";

      // N84-02 & MQL-BUG-04: Only add to g_manualClosed if trade belongs to an active configured sender.
      // Pure manual trades (si < 0) are never part of any sender's snapshot and cannot be re-opened by copier.
      if(si>=0 && si<g_nSenders)
        {
         g_manualClosed.Add(uid,targetPos.ticket,sname);
         CmdStateSave(); // N83-02: Persist manual closed UID immediately
        }

      string actKey=sname+":"+(string)CP_ACT_CLOSE+":"+uid;
      g_seen.Forget(actKey);
      g_backoff.Clear(actKey);

      bool alreadyQueued=ActionQueued(si,CP_ACT_CLOSE,uid,"");
      bool queued=false;
      if(alreadyQueued)
        {
         queued=true;
        }
      else
        {
         queued=PushAction(si,CP_ACT_CLOSE,uid,targetPos.sym,targetPos.side,targetPos.lots,
                           targetPos.ticket,0,"",0.0,0.0,targetPos.kind);
        }

      g_cmdId=id;
      if(queued)
        {
         string note="";
         bool stale=CopierSymbolFeedStale(targetPos.sym,CP_SYM_STALL_MS);
         if(stale)
            note=";NOTE=market_closed";
         else if(alreadyQueued)
            note=";NOTE=already_queued";
         g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev+note;
         g_log.Warn("CMD "+id+": manual close "+(alreadyQueued?"already queued":"queued")+" for ticket #"+(string)targetTicket+" ("+targetPos.sym+" "+DoubleToString(targetPos.lots,2)+") UID="+uid+(StringLen(note)>0?" ("+note+")":""));
         g_forcePosReport=true;
        }
      else
        {
         //--- N-10: name the actual refusal. "queue_full" for a duplicate
         //--- click or a 1s CLOSE backoff sent the hub (and the operator) after
         //--- a throughput problem that was not there.
         string why=(StringLen(g_pushReject)>0)?g_pushReject:"not_queueable";
         g_cmdAck="ID="+id+";OK=0;ERR="+why+";REV="+(string)g_cfgRev;
         g_log.Error("CMD "+id+": manual close not queued for ticket #"
                     +(string)targetTicket+" ("+why+")");
        }
      SendCfgAck(g_cmdAck);
      return;
     }

   if(op=="reload")
     {
      //--- The file is NOT rewritten (that is CFG's job): reload re-reads
      //--- whatever copier.ini says NOW. The sender set is captured first so
      //--- the log can say what the reload changed, the way HandleCfg does.
      //--- No backup/restore dance either: the file on disk is the one
      //--- already running, and LoadConfig failing leaves it untouched.
      string beforeSid[CP_MAX_SENDERS];
      long   beforeMagic[CP_MAX_SENDERS];
      ArrayInitialize(beforeMagic,0);
      for(int z=0;z<CP_MAX_SENDERS;z++) beforeSid[z]="";
      int beforeN=g_nSenders;
      for(int i=0;i<beforeN;i++)
        {
         beforeSid[i]=g_sid[i];
         beforeMagic[i]=g_magic[i];
        }
      if(!LoadConfig())
        {
         g_cmdId=id;
         g_cmdAck="ID="+id+";OK=0;ERR=config reload failed";
         SendCfgAck(g_cmdAck);
         g_log.Error("CMD "+id+": reload failed - the receiver keeps running"
                     +" the configuration it had");
         return;
        }
      int added=ResubscribeSenders(beforeSid,beforeN);
      //--- F-03: preserve risk-reducing actions (CLOSE/TRIM) across reload
      ClearQueueExceptRiskReducing();
      RemapQueueSenders(beforeSid,beforeN);
      // BUG-11: Trigger immediate reconvergence on reload
      g_convergeDirtyAll=true;

      int warnings=0;
      for(int i=0;i<g_nSenders;i++)
        {
         long was=0;
         for(int j=0;j<beforeN;j++)
            if(beforeSid[j]==g_sid[i]) { was=beforeMagic[j]; break; }
         if(was!=0 && was!=g_magic[i]) warnings++;
        }
      if(beforeN!=g_nSenders) warnings++;

      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev+";WARN="+(string)warnings;
      SendCfgAck(g_cmdAck);
      SendCurrentConfigReport();
      g_log.Info("CMD "+id+": reload applied - "
                 +IntegerToString(beforeN)+" -> "+IntegerToString(g_nSenders)
                 +" sender(s), "+IntegerToString(added)+" new subscription(s), "
                 +IntegerToString(warnings)+" warning(s)");
      if(warnings>0)
         g_log.Warn("CMD "+id+": "+IntegerToString(warnings)+" warning(s) - a magic"
                    +" or sender-set change leaves positions that are no longer"
                    +" managed. Check the panel's orphan rows.");
      return;
     }

   if(op=="reqpos" || op=="refreshpos" || op=="refresh")
     {
      g_forcePosReport=true;
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+": position table update requested by WebUI");
      return;
     }

   //--- reqcfg: the hub wants the full current config, because the hash it
   //--- was sent on REG does not match what it holds (or it holds nothing -
   //--- it just restarted). This is the pull half of the `IH=` scheme: REG
   //--- answers "has anything changed" in 32 bytes, and only a mismatch costs
   //--- the ~100 KB transfer.
   //---
   //--- CFGREPORT is the existing answer, so this adds no new message type -
   //--- and it is the same report a CFG apply already sends, which means the
   //--- hub's store stays correct no matter which door the config arrives by.
   if(op=="reqcfg" || op=="cfgrefresh")
     {
      g_forceCfgReport=true;
      g_cmdId=id;
      g_cmdAck="ID="+id+";OK=1;REV="+(string)g_cfgRev;
      SendCfgAck(g_cmdAck);
      g_log.Info("CMD "+id+": current config requested by the hub - reporting it");
      return;
     }

   //--- The hub validates OP at the door, so reaching this line means a hub
   //--- a version apart, or a hand-crafted frame. Answer rather than leave
   //--- the ladder running against an op that will never become known.
   g_cmdId=id;
   g_cmdAck="ID="+id+";OK=0;ERR=unknown op "+op;
   SendCfgAck(g_cmdAck);
   g_log.Error("CMD "+id+": unknown op \""+op+"\". Refused.");
  }

#endif // __COPIER_RECVHUBCTL_MQH__
