//+------------------------------------------------------------------+
//| CopierConfig.mqh - copier.ini reader                             |
//|                                                                   |
//| Why a file and not EA inputs: with N senders each carrying an     |
//| endpoint, a CURVE key, a symbol table and a sizing mode, the input|
//| list explodes and becomes impossible to review. A file also lets  |
//| several receiver instances share one config (FILE_COMMON).        |
//|                                                                   |
//| Format (sections are "sender0", "sender1", ...):                  |
//|                                                                   |
//|   [common]                                                        |
//|   loglevel=2                                                      |
//|   [sender0]                                                       |
//|   id=alpari01                                                     |
//|   events=tcp://10.0.0.5:5555                                      |
//|   snap=tcp://10.0.0.5:5556                                        |
//|   serverkey=Z85 40-char public key of that sender                 |
//|   lotmode=multiplier                                              |
//|   lotparam=1.0                                                    |
//|   suffix=m                                                        |
//|   symbol.EURUSD=EURUSD.m                                          |
//|   symbol.GOLD=XAUUSD                                              |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_CONFIG_MQH__
#define __COPIER_CONFIG_MQH__

#include "CopierDefs.mqh"

//--- Rows the parser holds. 12288, not 2048. MEASURED, by hub_config_test.py,
//--- which builds a full CP_MAX_SENDERS config: ~5,000 rows with the hub's key
//--- set and ~7,400 with the receiver's own serializer (~74 keys per
//--- [senderN], ~44 in [common]). 2048 was already short of SIXTEEN senders
//--- once symbol maps are added, and at 100 it fails the load outright - a
//--- loud, correct failure, but one that would block the documented capacity.
//--- Memory: three arrays of 12288 string members, ~600 KB worst case.
//---
//--- This, CP_INI_MAX_BYTES and the hub's MAX_INI_BYTES are ONE decision split
//--- across two languages; hub_config_test.py asserts the byte bounds match.
#define CP_INI_MAX 12288
//--- Distinct section BLOCKS the section-range index can hold. A config for
//--- CP_MAX_SENDERS senders is [common] + one block per sender, so the sender
//--- ceiling plus slack. Past it the index keeps the first blocks and their
//--- lookups stay correct; a name beyond the bound scans no range and reads as
//--- absent, which the overflow message in Load() covers.
#define CP_INI_SECTIONS (CP_MAX_SENDERS+32)

class CopierIni
  {
private:
   string            m_sec[CP_INI_MAX];
   string            m_key[CP_INI_MAX];
   string            m_val[CP_INI_MAX];
   int               m_n;

   //--- delegates to CopierTrim: StringTrimLeft/Right cannot be used here
   //--- because their semantics differ between MQL4 and MQL5 (see the
   //--- note on CopierTrim in CopierDefs.mqh)
   static string     Trim(const string s) { return CopierTrim(s); }

public:
                     CopierIni():m_n(0) {}

   int               Count() const { return m_n; }

   //--- Section RANGES, built once after the rows are in.
   //---
   //--- Every lookup here used to scan all m_n rows, which is quadratic in
   //--- practice: a config load reads ~74 keys per sender, so 100 senders is
   //--- ~7,400 Get() calls over ~7,400 rows - ~55 million string compares on
   //--- EVERY load, including every CFG push from the hub, which stalls the
   //--- EA for seconds. Grouping the rows by their (consecutive) section makes
   //--- a lookup scan that section's ~74 rows instead of the whole file.
   //---
   //--- Ranges, not a name->range map, on purpose: the same section name may
   //--- legitimately appear twice (a duplicated [sender3]), and a range list
   //--- keeps both reachable. The number of blocks is capped, so the scan over
   //--- ranges stays bounded however many rows there are.
   string            m_secName[CP_INI_SECTIONS];
   int               m_secStart[CP_INI_SECTIONS];
   int               m_secLen[CP_INI_SECTIONS];
   int               m_nSec;

   bool              BuildSections()
     {
      m_nSec=0;
      int i=0;
      bool overflow=false;
      while(i<m_n)
        {
         int start=i;
         while(i<m_n && StringCompare(m_sec[i],m_sec[start],false)==0) i++;
         if(m_nSec<CP_INI_SECTIONS)
           {
            m_secName[m_nSec] =m_sec[start];
            m_secStart[m_nSec]=start;
            m_secLen[m_nSec]  =i-start;
            m_nSec++;
           }
         else
           {
            overflow=true;
           }
        }
      return !overflow;
     }

   bool              Load(const string path)
     {
      m_n=0;
      int h=FileOpen(path,FILE_READ|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;

      string section="";
      bool overflow=false;
      while(!FileIsEnding(h))
        {
         if(m_n>=CP_INI_MAX)
           {
            overflow=true;
            break;
           }
         string line=Trim(FileReadString(h));
         if(StringLen(line)==0) continue;
         string first=StringSubstr(line,0,1);
         if(first==";" || first=="#" || first=="[") {}
         if(first=="[" )                      // section header
           {
            int e=StringFind(line,"]");
            if(e>1) section=Trim(StringSubstr(line,1,e-1));
            continue;
           }
         if(first==";" || first=="#") continue;   // comment

         int eq=StringFind(line,"=");
         if(eq<=0) continue;
         string k=Trim(StringSubstr(line,0,eq));
         string v=Trim(StringSubstr(line,eq+1));
         if(StringLen(k)==0) continue;

         m_sec[m_n]=section;
         m_key[m_n]=k;
         m_val[m_n]=v;
         m_n++;
        }
      FileClose(h);
      if(overflow)
        {
         Print("CopierIni: ERROR - ",path," exceeded CP_INI_MAX (",CP_INI_MAX," lines)! Config truncated.");
         return false;
        }
      if(!BuildSections())
        {
         Print("CopierIni: ERROR - ",path," exceeded CP_INI_SECTIONS (",CP_INI_SECTIONS," blocks)! Config rejected.");
         return false;
        }
      return true;
     }

   bool              HasSection(const string section) const
     {
      for(int s=0;s<m_nSec;s++)
         if(StringCompare(m_secName[s],section,false)==0) return true;
      return false;
     }

   bool              Has(const string section,const string key) const
     {
      for(int s=0;s<m_nSec;s++)
        {
         if(StringCompare(m_secName[s],section,false)!=0) continue;
         int e=m_secStart[s]+m_secLen[s];
         for(int i=m_secStart[s];i<e;i++)
            if(StringCompare(m_key[i],key,false)==0) return true;
        }
      return false;
     }

   string            Get(const string section,const string key,const string deflt="") const
     {
      for(int s=0;s<m_nSec;s++)
        {
         if(StringCompare(m_secName[s],section,false)!=0) continue;
         int e=m_secStart[s]+m_secLen[s];
         for(int i=m_secStart[s];i<e;i++)
            if(StringCompare(m_key[i],key,false)==0) return m_val[i];
        }
      return deflt;
     }

   double            GetDouble(const string section,const string key,const double deflt) const
     {
      string v=Get(section,key,"");
      if(StringLen(v)==0) return deflt;
      return StringToDouble(v);
     }

   int               GetInt(const string section,const string key,const int deflt) const
     {
      string v=Get(section,key,"");
      if(StringLen(v)==0) return deflt;
      return (int)StringToInteger(v);
     }

   bool              GetBool(const string section,const string key,const bool deflt) const
     {
      string v=Get(section,key,"");
      if(StringLen(v)==0) return deflt;
      //--- StringToLower modifies the string in-place by reference in MQL4/MQL5.
      StringToLower(v);
      return (v=="1" || v=="true" || v=="yes" || v=="on");
     }

   //--- number of CONSECUTIVE [senderN] sections present, from sender0 up.
   //--- Stops at the first gap: [sender0][sender2] reads as ONE sender, which
   //--- is deliberate (position in the file IS the identity) and must be
   //--- reported rather than discovered from a mirror that never appears.
   int               SenderCount() const
     {
      int n=0;
      for(int i=0;i<CP_MAX_SENDERS;i++)
        {
         if(StringLen(Get("sender"+(string)i,"id",""))>0) n=i+1;
         else break;
        }
      return n;
     }

   //--- The HIGHEST `senderN` index the file actually declares, gaps included,
   //--- or -1 when there is no sender<N> section at all.
   //---
   //--- Exists so the caller can tell apart three situations that all used to
   //--- look like "fewer senders than I configured":
   //---    every section present            -> declared+1 == SenderCount()
   //---    a gap truncates the count         -> declared+1 >  SenderCount()
   //---    more sections than the build holds -> declared  >=  CP_MAX_SENDERS
   //--- Scans the section list rather than the rows, so it is O(blocks) and
   //--- does not inherit the cost of Get().
   int               SenderDeclaredMax() const
     {
      int maxN=-1;
      for(int s=0;s<m_nSec;s++)
        {
         string nm=m_secName[s];
         int n=StringLen(nm);
         if(n<7) continue;                       // "sender" + >= 1 digit
         if(StringFind(nm,"sender")!=0) continue;
         bool digits=true;
         for(int c=6;c<n;c++)
           {
            int ch=StringGetCharacter(nm,c);
            if(ch<'0' || ch>'9') { digits=false; break; }
           }
         if(!digits) continue;
         int idx=(int)StringToInteger(StringSubstr(nm,6));
         if(idx>maxN) maxN=idx;
        }
      return maxN;
     }

   //--- raw enumeration, so callers can walk "symbol.X=Y" entries
   //--- without this module needing to know about symbol maps
   string            SecAt(const int i)  const { return (i>=0 && i<m_n)?m_sec[i]:""; }
   string            KeyAt(const int i)  const { return (i>=0 && i<m_n)?m_key[i]:""; }
   string            ValAt(const int i)  const { return (i>=0 && i<m_n)?m_val[i]:""; }
  };

//+------------------------------------------------------------------+
// Which magic number does sender <idx> use?
//
// An explicit magic= in copier.ini is authoritative. When it is absent the
// magic falls back to MagicBase+idx, which is DERIVED FROM THE SECTION'S
// POSITION IN THE FILE.
//
// That default is why reordering [senderN] sections is destructive: move a
// sender to a different index and it silently gets a different magic. The
// receiver finds a sender's positions by magic alone, so everything already
// open under the old one becomes invisible - never matched, never closed -
// while the sender's live positions get mirrored again under the new magic.
// A duplicate beside an orphan, with nothing logged.
//
// `pinned` reports whether the value came from the ini, which is what lets
// startup warn about senders still exposed to a reorder. Passing the RAW
// string (not a parsed int) is deliberate: a defaulting GetInt() cannot
// distinguish "absent" from "explicitly set to the default value", and that
// distinction is the whole point here.
//+------------------------------------------------------------------+
long CopierResolveMagic(const string rawIniValue,bool &pinned)
  {
   if(StringLen(rawIniValue)>0)
     {
      pinned=true;
      return (long)StringToInteger(rawIniValue);
     }
   //--- MISSING. There is no fallback any more, deliberately.
   //---
   //--- The old fallback was MagicBase+idx, derived from the section's
   //--- POSITION in the file, so reordering [senderN] silently moved a sender
   //--- onto a different magic and orphaned every position already open
   //--- under the old one. A default that is only safe while nobody edits the
   //--- file is not a default, it is a trap - so the caller now refuses to
   //--- start instead of guessing.
   pinned=false;
   return -1;
  }

//=====================================================================
// M4b: receiving a config from the hub.
//
// This is the half that can BRICK A RECEIVER, so the whole section is
// written around one rule: **copier.ini must never be left in a state the
// receiver cannot start from.**
//
// The state file elsewhere in this project is written "in place after
// delete" and that is fine there, because it is a cache and losing it costs
// a rebuild. copier.ini is a STARTUP DEPENDENCY. Deleting it and then
// failing to write leaves a receiver that cannot run at all.
//
// The sequence used here instead:
//
//   1. read the current file into memory        <- the backup
//   2. write a .bak copy for a human to restore by hand
//   3. delete + write the new content
//   4. READ IT BACK AND PARSE IT
//   5. if it does not parse, write the old content back and report failure
//
// Step 4 is the one that matters and the one a naive implementation skips.
// Writing a file and believing it is how you ship a truncated config.
//
// AND THE WORST CASE IS ALREADY SURVIVABLE, which is what makes this safe to
// do at all: if power is lost between the delete and the write, the receiver
// starts with an unparseable ini, `LoadConfigForHub` reports zero senders and
// WAITS - and it reports REV=0, so the hub sees it behind and pushes again.
// The recovery path is the same one a fresh receiver uses.
//=====================================================================

//--- The paths live HERE rather than in the receiver, because the file
//--- helpers below need them and an include cannot see a .mq4's defines. That
//--- is not a style point: it was a compile error, and the fix is to give the
//--- include ownership of the paths it operates on.
//---
//--- #ifndef guards so the receiver can keep its own definition without a
//--- redefinition error - the two are the same string by construction, and a
//--- duplicated literal is a smaller problem than an include that cannot
//--- compile on its own.
#ifndef CP_INI_PATH
#define CP_INI_PATH "copier.ini"
#endif
#ifndef CP_INI_BAK_PATH
#define CP_INI_BAK_PATH "copier.ini.bak"
#endif
#ifndef CP_CFG_REV_PATH
#define CP_CFG_REV_PATH "copier_cfg.rev"
#endif
//--- Mirrors MAX_INI_BYTES in hub/src/config.rs, and MUST stay equal to it:
//--- the hub validates at the door and the node validates again, and a node
//--- limit BELOW the hub's accepts a config the receiver then refuses. The
//--- reverse is worse - the hub would reject what it just wrote itself.
//--- 512 KB is ~2x the ~270 KB a full 100-sender config can reach, and far
//--- under CP_MAX_MSG_LEN, so the escaped CFG payload still fits one frame.
#define CP_INI_MAX_BYTES 524288

int CopierHexVal(const int ch)
  {
   if(ch>='0' && ch<='9') return ch-'0';
   if(ch>='a' && ch<='f') return ch-'a'+10;
   if(ch>='A' && ch<='F') return ch-'A'+10;
   return -1;
  }

//--- Mirror of escape_ini in hub/src/config.rs. Both directions live here so
//--- CopierSelfTest can round-trip them in MQL - which is the only way to
//--- know the two implementations agree.
string CopierIniEscape(const string s)
  {
   string out="";
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c=='%')      out+="%25";
      else if(c=='|') out+="%7C";
      else if(c==';') out+="%3B";
      else if(c=='~') out+="%7E";
      else if(c==',') out+="%2C";
      else if(c=='=') out+="%3D";
      else if(c=='\n') out+="%0A";
      else if(c=='\r') out+="%0D";
      else            out+=ShortToString((ushort)c);
     }
   return out;
  }

bool CopierIniUnescape(const string s,string &out)
  {
   out="";
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c!='%')
        {
         out+=ShortToString((ushort)c);
         continue;
        }
      if(i+2>=n) return false;                 // a trailing '%' is malformed
      int h1=CopierHexVal(StringGetCharacter(s,i+1));
      int h2=CopierHexVal(StringGetCharacter(s,i+2));
      if(h1<0 || h2<0) return false;
      int code=h1*16+h2;
      //--- Only the eight escapes the encoder produces are accepted. A
      //--- decoder that passed any %XX through would turn a corrupt payload
      //--- into a plausible-looking ini, which is worse than refusing it.
      if(code!='%' && code!='|' && code!=';' && code!='~' && code!=',' &&
         code!='=' && code!='\n' && code!='\r')
         return false;
      out+=ShortToString((ushort)code);
      i+=2;
     }
   return true;
  }

//--- Shape check, mirroring config::validate_ini on the hub. Deliberately
//--- the same rules: the hub refuses a bad ini at the door, and the node
//--- refuses it again, because the node is the one that would have to run it.
bool CopierIniValidate(const string ini,string &err)
  {
   err="";
   if(StringLen(CopierTrim(ini))==0) { err="empty"; return false; }
   if(StringLen(ini)>CP_INI_MAX_BYTES)
     {
      err="too large: "+(string)StringLen(ini)+" bytes";
      return false;
     }
   int sections=0;
   string lines[];
   int n=CopierSplitLines(ini,lines);
   for(int i=0;i<n;i++)
     {
      string line=CopierTrim(lines[i]);
      if(StringLen(line)==0) continue;
      if(StringGetCharacter(line,0)==';' || StringGetCharacter(line,0)=='#')
         continue;
      if(StringGetCharacter(line,0)=='[')
        {
         if(StringGetCharacter(line,StringLen(line)-1)!=']' || StringLen(line)<3)
           {
            err="line "+(string)(i+1)+": malformed section header";
            return false;
           }
         sections++;
         continue;
        }
      int eq=StringFind(line,"=");
      if(eq<=0)
        {
         err="line "+(string)(i+1)+": not a section or key=value";
         return false;
        }
     }
   if(sections==0) { err="no [section] - this is not a copier.ini"; return false; }
   return true;
  }

//--- Split on newlines. Written by hand rather than with StringSplit because
//--- StringSplit needs a single-character separator and cannot express "\r\n
//--- or \n", which is exactly the difference between a file written on
//--- Windows and one the hub sent.
int CopierSplitLines(const string s,string &out[])
  {
   ArrayResize(out,0);
   string cur="";
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      int c=StringGetCharacter(s,i);
      if(c=='\n')
        {
         int m=ArraySize(out);
         ArrayResize(out,m+1);
         out[m]=cur;
         cur="";
         continue;
      }
      if(c=='\r') continue;                    // handled by the \n that follows
      cur+=ShortToString((ushort)c);
     }
   int m=ArraySize(out);
   ArrayResize(out,m+1);
   out[m]=cur;
   return ArraySize(out);
  }

bool CopierIniReadAll(const string path,string &out)
  {
   out="";
   if(!FileIsExist(path)) return false;
   int h=FileOpen(path,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return false;
   bool first=true;
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      if(!first) out+="\n";
      out+=line;
      first=false;
     }
   FileClose(h);
   return true;
  }

bool CopierIniWriteAll(const string path,const string text)
  {
   FileDelete(path);
   int h=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return false;
   //--- FileWriteString, NOT FileWrite: FileWrite appends a newline of its
   //--- own, and the ini already has them.
   FileWriteString(h,text);
   FileClose(h);
   return true;
  }

//--- Does this file parse as an ini? The check that makes step 4 real.
bool CopierIniParses(const string path)
  {
   CopierIni probe;
   return probe.Load(path);
  }

//--- See the block comment above for why the order is what it is.
bool CopierIniWriteAtomic(const string ini,string &err)
  {
   err="";
   string old="";
   bool had=CopierIniReadAll(CP_INI_PATH,old);

   //--- 2. a .bak for a human. Best effort: failing to write it must not stop
   //--- the push, because the in-memory copy above is the one that matters.
   if(had && StringLen(old)>0) CopierIniWriteAll(CP_INI_BAK_PATH,old);

   //--- 3.
   if(!CopierIniWriteAll(CP_INI_PATH,ini))
     {
      err="cannot write "+CP_INI_PATH;
      return false;
     }

   //--- 4. the step that is easy to skip and expensive to skip.
   if(CopierIniParses(CP_INI_PATH)) return true;

   //--- 5. put the old one back. If there was none, remove the broken file
   //--- rather than leave a half-written one behind: "no ini" has a defined
   //--- recovery (wait for a re-push), "unparseable ini" looks the same but
   //--- leaves junk on disk for a human to puzzle over.
   err="the written file does not parse";
   if(had && StringLen(old)>0)
     {
      CopierIniWriteAll(CP_INI_PATH,old);
      if(CopierIniParses(CP_INI_PATH)) err+=" - previous config restored";
      else                              err+=" - AND THE RESTORE FAILED";
     }
   else
     {
      FileDelete(CP_INI_PATH);
      err+=" - removed (there was no previous config)";
     }
   return false;
  }

//--- The applied revision, kept on disk so a restart reports the right REV
//--- instead of claiming 0 and being pushed a config it already has.
//--- Small enough that a torn file is not worth a marker: a failed parse
//--- yields rev 0, which is the safe direction (the hub re-pushes).
bool CopierCfgRevLoad(string &id,long &rev)
  {
   id="";
   rev=0;
   string text="";
   if(!CopierIniReadAll(CP_CFG_REV_PATH,text)) return false;
   string lines[];
   int n=CopierSplitLines(text,lines);
   for(int i=0;i<n;i++)
     {
      string line=CopierTrim(lines[i]);
      string v="";
      if(CopierKvGet(line,"ID",v))  id=v;
      if(CopierKvGet(line,"REV",v)) rev=(long)StringToInteger(v);
     }
   return true;
  }

bool CopierCfgRevSave(const string id,const long rev)
  {
   return CopierIniWriteAll(CP_CFG_REV_PATH,"ID="+id+"\nREV="+(string)rev);
  }

#endif
//+------------------------------------------------------------------+
