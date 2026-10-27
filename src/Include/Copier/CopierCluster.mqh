//+------------------------------------------------------------------+
//| CopierCluster.mqh - HA Cluster Topology & Local Disk Persistence |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_CLUSTER_MQH__
#define __COPIER_CLUSTER_MQH__

#include "CopierDefs.mqh"
#include "CopierLog.mqh"

#define CP_CLUSTER_STATE_FILE "copier_hub_cluster.st"

struct CopierClusterState
  {
   string   primary;
   string   standby;
   long     epoch;
   long     updated;
  };

class CopierClusterCache
  {
public:
   static bool Load(CopierClusterState &outState)
     {
      outState.primary="";
      outState.standby="";
      outState.epoch=0;
      outState.updated=0;

      int h=FileOpen(CP_CLUSTER_STATE_FILE,FILE_READ|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;

      while(!FileIsEnding(h))
        {
         string line=FileReadString(h);
         line=CopierTrim(line);
         if(StringLen(line)==0 || StringGetCharacter(line,0)=='#') continue;
         int eq=StringFind(line,"=");
         if(eq<=0) continue;
         string k=CopierTrim(StringSubstr(line,0,eq));
         string v=CopierTrim(StringSubstr(line,eq+1));
         if(k=="primary")      outState.primary=v;
         else if(k=="standby") outState.standby=v;
         else if(k=="epoch")   outState.epoch=CopierParseLong(v);
         else if(k=="updated") outState.updated=CopierParseLong(v);
        }
      FileClose(h);
      return (StringLen(outState.primary)>0 || StringLen(outState.standby)>0);
     }

   static bool Save(const string primary,const string standby,const long epoch)
     {
      string tmpFile=CP_CLUSTER_STATE_FILE+".tmp";
      FileDelete(tmpFile); // P3-1: Clean truncation defense before opening write handle
      int h=FileOpen(tmpFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;

      FileWriteString(h,"# mt-copier HA cluster topology cache\n");
      FileWriteString(h,"primary="+primary+"\n");
      FileWriteString(h,"standby="+standby+"\n");
      FileWriteString(h,"epoch="+(string)epoch+"\n");
      FileWriteString(h,"updated="+(string)CopierServerTime()+"\n");
      FileFlush(h);
      FileClose(h);
      FileDelete(CP_CLUSTER_STATE_FILE);
      return FileMove(tmpFile,0,CP_CLUSTER_STATE_FILE,FILE_REWRITE);
     }
  };

#endif
