//+------------------------------------------------------------------+
//| CopierCurveKey.mqh - the CURVE keypair, kept in a file            |
//|                                                                   |
//| WHY THIS EXISTS                                                  |
//|                                                                   |
//| The keypair used to be produced by a separate script             |
//| (CopierKeygen) and pasted by hand into the EA's input list. That  |
//| had three failure modes, and every one of them was silent:        |
//|                                                                   |
//|   * a key pasted with a trailing space, or wrapped over two lines |
//|     by the terminal's input box, is 39 or 41 characters - and a   |
//|     CURVE handshake with a malformed key does not fail, it simply |
//|     never completes. Nothing in any log says why.                 |
//|   * the public half could be typed independently of the secret    |
//|     half, so the two could disagree. Again: no handshake, no      |
//|     message.                                                      |
//|   * running the script twice produced two keypairs, and there was |
//|     nothing on either side to say which one was live.             |
//|                                                                   |
//| So the keypair now lives in ONE FILE, in ONE DIRECTORY, and the EA|
//| is the only thing that ever writes it. The public half is always  |
//| DERIVED from the secret half (zmq_curve_public), never stored     |
//| independently and never typed, which removes the whole class of   |
//| mismatch. The operator's only remaining job is to carry the       |
//| PUBLIC key of the sender to the receiver's SenderServerKey input  |
//| - and that is one line of 40 characters, not a file to edit.      |
//|                                                                   |
//| THE FILE                                                         |
//|                                                                   |
//|   MQL\Files\copier_curve.key   (FILE_COMMON if the EA asks for it)|
//|                                                                   |
//|   copier-curve-key v1                                            |
//|   # generated 2026.10.12 23:04 on "Alpari MT4"                   |
//|   # this is THIS terminal's own keypair. To rotate it, stop the   |
//|   # EA, delete this file, and start it again.                    |
//|   PUBLIC=<40 chars>                                              |
//|   SECRET=<40 chars>                                              |
//|                                                                   |
//| The first line is a MAGIC STRING, not a comment, and it is load-  |
//| bearing: it is what lets a file left by a future build - or by a  |
//| completely different tool - be recognised as "not mine" and       |
//| replaced, instead of being parsed on a best-effort basis and      |
//| producing a handshake that never completes. The version number    |
//| sits in the same line so a future format change has somewhere to  |
//| announce itself.                                                  |
//|                                                                   |
//| REGENERATION RULES, in full, because "when does it overwrite my   |
//| key?" must not be folklore:                                      |
//|                                                                   |
//|   * file absent              -> generate, write, use it.          |
//|   * magic line wrong/missing -> treat as foreign, OVERWRITE.      |
//|   * either key not 40 chars  -> treat as damaged, OVERWRITE.      |
//|   * PUBLIC does not match the derived one  -> OVERWRITE.          |
//|   * everything checks out    -> READ it, change nothing.          |
//|                                                                   |
//| Note the asymmetry, which is deliberate: a file that merely does  |
//| not LOAD is replaced without asking, while a file that loads is   |
//| never touched. A keypair is not precious data - it has no history |
//| and no meaning outside this terminal - so the cost of getting it   |
//| wrong in the "discard" direction is one regenerated key, whereas  |
//| the cost of getting it wrong in the "keep a broken file forever"  |
//| direction is a copier that silently never connects.                |
//|                                                                   |
//| WHAT THIS DOES NOT DO                                            |
//|                                                                   |
//| It does not decide whether CURVE is on. UseCurve="false" still    |
//| means "no CURVE", and this module is then never loaded, so no key |
//| file appears for an operator who is not using the feature. That   |
//| keeps plaintext setups byte-identical to before.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_CURVE_KEY_MQH__
#define __COPIER_CURVE_KEY_MQH__

#include "CopierDefs.mqh"
#include "CopierLog.mqh"
#include <Zmq/Zmq.mqh>

//--- The filename is FIXED, and deliberately so.
//---
//--- An earlier design used one file per instance
//--- (copier_curve_<label>.key). That introduced a new input whose value
//--- had to agree with a filename on disk, and a mismatch produced no
//--- error at all - just a second keypair, and two curves talking past
//--- each other. A single fixed name cannot be misspelt, and a sender and
//--- a receiver are different installations that never share a directory,
//--- so there is nothing for the name to disambiguate.
#define CP_KEY_FILE        "copier_curve.key"
#define CP_KEY_MAGIC       "copier-curve-key"
#define CP_KEY_VERSION     "1"
#define CP_KEY_LINE_MAGIC  (CP_KEY_MAGIC+" v"+CP_KEY_VERSION)
#define CP_KEY_LEN         40

//--- Hub public key file conventions (downloaded from Web Dashboard)
#define CP_HUB_KEY_FILE       "copier_hub.key"
#define CP_HUB_KEY_MAGIC      "copier-hub-key"
#define CP_HUB_KEY_VERSION    "1"
#define CP_HUB_KEY_LINE_MAGIC (CP_HUB_KEY_MAGIC+" v"+CP_HUB_KEY_VERSION)

//--- Result of an attempt to obtain a keypair. Callers switch on this
//--- rather than on a bool, because "generated a new one" and "read an
//--- existing one" are very different events to report: the first must be
//--- shouted (the operator has a new public key to carry to the receiver)
//--- and the second should be quiet (a restart must not look like a change).
enum CP_KEY_RESULT
  {
   CP_KEY_READ     = 0,   //--- existing, valid file was loaded
   CP_KEY_CREATED  = 1,   //--- no file; a new keypair was generated
   CP_KEY_REPLACED = 2,   //--- file existed but was unusable; regenerated
   CP_KEY_FAILED   = 3    //--- could not produce a keypair at all
  };

class CopierCurveKey
  {
private:
   string            m_pub;
   string            m_sec;
   string            m_path;
   bool              m_common;    //--- looked for in MQL\Common\Files
   int               m_lastErr;   //--- last file error, for the message

   //--- A key is usable when it is EXACTLY the Z85 length. Both ends of
   //--- this check matter: a truncated paste is short, and a wrapped paste
   //--- is long. Neither is caught by "does it look like base85".
   static bool       ShapeOk(const string k)
     {
      return StringLen(k)==CP_KEY_LEN;
     }

   //--- Pull "PUBLIC=" / "SECRET=" out of a line, or return "".
   //---
   //--- Case-insensitive on the KEY because these lines are meant to be
   //--- hand-readable and may well have been retyped; case-SENSITIVE on the
   //--- VALUE, because Z85 is case-significant and lowercasing a key would
   //--- be a silent corruption - a wrong key is worse than no key.
   //---
   //--- Only the name prefix is compared, and it is compared by folding the
   //--- prefix alone, never the whole line: uppercasing the whole line to
   //--- test the prefix would touch the value as well, which is exactly the
   //--- corruption this note warns about.
   static string     Field(const string line,const string name)
     {
      int n=StringLen(name);
      if(StringLen(line)<n+1) return "";
      string head=StringSubstr(line,0,n);
      //--- In MQL4/MQL5, StringToUpper takes string& and modifies it in-place.
      //--- It returns bool (success). Never assign the return value to string!
      StringToUpper(head);
      string nm=name;
      StringToUpper(nm);
      if(head!=nm) return "";
      if(StringGetCharacter(line,n)!='=') return "";
      return CopierTrim(StringSubstr(line,n+1));
     }

   int               FileFlags(const int extra,const int rw) const
     {
      // R47-08: Add FILE_SHARE_READ and FILE_SHARE_WRITE so file isn't blocked by concurrent readers
      int flags=rw|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE|extra;
      if(m_common) flags|=FILE_COMMON;
      return flags;
     }

   bool              WriteFile(const string pub,const string sec,
                               const string why)
     {
      // R47-08: Backup existing key file to .bak before replacing
      if(FileIsExist(m_path, m_common?FILE_COMMON:0))
        {
         FileCopy(m_path, m_common?FILE_COMMON:0, m_path+".bak", m_common?FILE_COMMON:0);
        }
      FileDelete(m_path, m_common?FILE_COMMON:0);

      int h=FileOpen(m_path,FileFlags(0,FILE_WRITE));
      if(h==INVALID_HANDLE)
        {
         m_lastErr=GetLastError();
         return false;
        }

      FileWrite(h,CP_KEY_LINE_MAGIC);
      FileWrite(h,"# "+why);
      FileWrite(h,"# generated "+TimeToString(TimeLocal(),TIME_DATE|TIME_MINUTES)
                +" on \""+CopierTerminalName()+"\"");
      FileWrite(h,"#");
      FileWrite(h,"# This is THIS terminal's own keypair, used only when"
                +" UseCurve is true.");
      FileWrite(h,"# To rotate it: stop the EA, delete this file, start the EA"
                +" again.");
      FileWrite(h,"# PUBLIC is the line you copy to the OTHER side of the link.");
      FileWrite(h,"PUBLIC="+pub);
      FileWrite(h,"SECRET="+sec);
      FileFlush(h);
      FileClose(h);

      //--- Read back what was actually written. A short write on a full
      //--- disk would otherwise be discovered at handshake time, as
      //--- nothing at all.
      string p2="",s2="";
      CP_KEY_RESULT r=LoadFile(p2,s2);
      if(r!=CP_KEY_READ || p2!=pub || s2!=sec)
        {
         m_lastErr=(GetLastError()!=0)?GetLastError():1;
         return false;
        }
      return true;
     }

   CP_KEY_RESULT     LoadFile(string &pub,string &sec)
     {
      pub=""; sec="";
      int h=FileOpen(m_path,FileFlags(0,FILE_READ));
      if(h==INVALID_HANDLE) return CP_KEY_FAILED;

      string magic=FileReadString(h);
      if(CopierTrim(magic)!=CP_KEY_LINE_MAGIC)
        {
         FileClose(h);
         return CP_KEY_FAILED;          //--- foreign or ancient format
        }

      while(!FileIsEnding(h))
        {
         string line=CopierTrim(FileReadString(h));
         if(StringLen(line)==0) continue;
         if(StringGetCharacter(line,0)=='#') continue;
         string p=Field(line,"PUBLIC");
         string s=Field(line,"SECRET");
         if(StringLen(p)>0) pub=p;
         if(StringLen(s)>0) sec=s;
        }
      FileClose(h);

      if(!ShapeOk(pub) || !ShapeOk(sec)) return CP_KEY_FAILED;

      //--- The one check that matters most, and the reason PUBLIC is a
      //--- stored field at all rather than being recomputed here: if the
      //--- two halves in the file disagree, the file was edited by hand
      //--- or written by something that is not this module. Trusting the
      //--- secret half and ignoring the mismatch would produce a key
      //--- whose public side the operator has already copied to the far
      //--- end - i.e. a link that never comes up, with a key file that
      //--- looks perfectly fine.
      string derived=Z85::derivePublic(sec);
      if(StringLen(derived)==0)
        {
         // DLL derive failed (not necessarily corrupt file) - keep existing file and fail safely
         return CP_KEY_FAILED;
        }
      if(derived!=pub) return CP_KEY_FAILED;

      return CP_KEY_READ;
     }

public:
                     CopierCurveKey():m_path(CP_KEY_FILE),m_common(false),
                     m_lastErr(0) {}

   void              SetCommon(const bool common) { m_common=common; }
   string            Path()     const { return m_path; }
   string            PublicKey()const { return m_pub; }
   //--- The secret is returned by value to the one caller that installs it on
   //--- the socket, and is deliberately NOT offered as a public field: the
   //--- only place it is ever allowed to reach is zmq_setsockopt. It is never
   //--- logged, never put on the wire, and never shown in the panel - see
   //--- AnnouncePublic(), which prints the PUBLIC half only.
   string            SecretKey()const { return m_sec; }
   int               LastError()const { return m_lastErr; }

   //--- Obtain this terminal's keypair, generating or repairing the file
   //--- as needed. `log` may be NULL when the caller only wants the keys
   //--- (the self-test does this, so it can exercise the module without
   //--- a logger attached).
   CP_KEY_RESULT     Ensure(CopierLog *log)
     {
      string pub="",sec="";

      CP_KEY_RESULT r=LoadFile(pub,sec);
      if(r==CP_KEY_READ)
        {
         m_pub=pub;
         m_sec=sec;
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Info("CURVE key: reusing "+m_path+" (PUBLIC="+m_pub+")");
         return CP_KEY_READ;
        }

      // R47-08: If the file exists but could not be opened (e.g. transient lock or AV scan),
      // preserve the existing file to avoid silently regenerating and disconnecting CURVE links.
      bool existed=FileIsExist(m_path, m_common?FILE_COMMON:0);
      if(existed)
        {
         int probe=FileOpen(m_path,FileFlags(0,FILE_READ));
         if(probe==INVALID_HANDLE)
           {
            if(CheckPointer(log)!=POINTER_INVALID)
               log.Error("CURVE key: "+m_path+" exists but could not be opened (locked/busy). Preserving key file.");
            return CP_KEY_FAILED;
           }
         FileClose(probe);
        }

      if(!Z85::generateKeyPair(pub,sec))
        {
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Error("CURVE key: could not generate a keypair."
                      +" Is libzmq.dll in MQL\\Libraries, and 'Allow DLL"
                      +" imports' ticked on this EA?");
         return CP_KEY_FAILED;
        }
      if(!ShapeOk(pub) || !ShapeOk(sec))
        {
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Error("CURVE key: generated key has the wrong length"
                      +" (pub="+(string)StringLen(pub)
                      +" sec="+(string)StringLen(sec)+") - refusing to write"
                      +" it. This points at a faulty libzmq.dll.");
         return CP_KEY_FAILED;
        }

      string why=existed
                 ? "regenerated: the previous file was not a usable key file"
                 : "generated on first start";
      if(!WriteFile(pub,sec,why))
        {
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Error("CURVE key: could not write "+m_path
                      +" (err="+(string)m_lastErr+"). Set UseCurve=false, or"
                      +" give the terminal write access to MQL\\Files.");
         return CP_KEY_FAILED;
        }

      m_pub=pub;
      m_sec=sec;

      if(CheckPointer(log)!=POINTER_INVALID)
        {
         if(existed)
            log.Warn("CURVE key: "+m_path+" was present but unusable"
                     +" (wrong format, wrong length, or PUBLIC did not match"
                     +" SECRET). It has been OVERWRITTEN with a new keypair.");
         else
            log.Info("CURVE key: no "+m_path+" found - generated a new keypair.");
        }
      return existed ? CP_KEY_REPLACED : CP_KEY_CREATED;
     }

   //--- Print the public key in the one place an operator looks.
   //---
   //--- Deliberately NOT rate-limited and NOT abbreviated: this is the
   //--- single line someone copies by hand, and a truncated key in a log
   //--- is worse than none, because it looks copyable.
   void              AnnouncePublic(CopierLog *log,const string role)
     {
      if(CheckPointer(log)==POINTER_INVALID) return;
      log.Info("================= CURVE PUBLIC KEY ("+role+") =================");
      log.Info("  "+m_pub);
      log.Info("  This is THIS "+role+"'s public key. Copy it to the OTHER"
               +" side of the link:");
      if(role=="sender")
         log.Info("    -> each receiver's  SenderServerKey  input");
      else
         log.Info("    -> the sender's  receiver allow-list"
                  +"  (no receiver key input: it is derived, not typed)");
      log.Info("  The SECRET half stays in "+m_path+" and is never shown"
               +" on the wire.");
      log.Info("===============================================================");
     }
  };

//+------------------------------------------------------------------+
//| Helper to parse a single line for a key-value field             |
//+------------------------------------------------------------------+
string CopierKeyExtractField(const string line,const string name)
  {
   int n=StringLen(name);
   if(StringLen(line)<n+1) return "";
   string head=StringSubstr(line,0,n);
   //--- StringToUpper modifies the string in-place by reference in MQL4/MQL5.
   StringToUpper(head);
   string nm=name;
   StringToUpper(nm);
   if(head!=nm) return "";
   if(StringGetCharacter(line,n)!='=') return "";
   return CopierTrim(StringSubstr(line,n+1));
  }

//+------------------------------------------------------------------+
//| Read and parse a copier_hub.key file from a given handle         |
//+------------------------------------------------------------------+
string CopierParseHubKeyFileHandle(const int h)
  {
   if(h==INVALID_HANDLE) return "";
   string pub="";
   bool firstLine=true;
   while(!FileIsEnding(h))
     {
      string line=CopierTrim(FileReadString(h));
      if(StringLen(line)==0) continue;
      if(firstLine)
        {
         firstLine=false;
         // If first non-empty line matches magic header, skip to payload lines
         if(line==CP_HUB_KEY_LINE_MAGIC) continue;
         // Otherwise, allow first line to directly be a comment, PUBLIC= field, or naked 40-char key
        }
      if(StringGetCharacter(line,0)=='#') continue;
      string p=CopierKeyExtractField(line,"PUBLIC");
      if(StringLen(p)>0) pub=p;
      else if(StringLen(line)==CP_KEY_LEN) pub=line; // fallback: naked 40-char key
     }
   FileClose(h);
   if(StringLen(pub)==CP_KEY_LEN) return pub;
   return "";
  }

//+------------------------------------------------------------------+
//| Load Hub public key from file or input fallback                  |
//| Precedence:                                                      |
//| 1. Terminal-local Files\copier_hub.key                           |
//| 2. Shared Common Files\copier_hub.key (FILE_COMMON)              |
//| 3. Input parameter (HubPublicKey) fallback                       |
//+------------------------------------------------------------------+
string CopierLoadHubPublicKey(const string inputKey,CopierLog *log,string &outSource)
  {
   outSource="none";

   // 1. Check local terminal MQLx\Files\copier_hub.key
   int hLocal=FileOpen(CP_HUB_KEY_FILE,FILE_READ|FILE_TXT|FILE_ANSI);
   if(hLocal!=INVALID_HANDLE)
     {
      string k=CopierParseHubKeyFileHandle(hLocal);
      if(StringLen(k)==CP_KEY_LEN)
        {
         outSource="file:local (MQL\\Files\\"+CP_HUB_KEY_FILE+")";
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Info("Hub Public Key: loaded from "+outSource+" ("+k+")");
         return k;
        }
      else
        {
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Warn("Hub Public Key: local "+CP_HUB_KEY_FILE+" exists but is invalid (corrupt or wrong version).");
        }
     }

   // 2. Check shared Terminal\Common\Files\copier_hub.key
   int hCommon=FileOpen(CP_HUB_KEY_FILE,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(hCommon!=INVALID_HANDLE)
     {
      string k=CopierParseHubKeyFileHandle(hCommon);
      if(StringLen(k)==CP_KEY_LEN)
        {
         outSource="file:common (Terminal\\Common\\Files\\"+CP_HUB_KEY_FILE+")";
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Info("Hub Public Key: loaded from "+outSource+" ("+k+")");
         return k;
        }
      else
        {
         if(CheckPointer(log)!=POINTER_INVALID)
            log.Warn("Hub Public Key: common "+CP_HUB_KEY_FILE+" exists but is invalid (corrupt or wrong version).");
        }
     }

   // 3. Fallback to input string
   string trimmedInput=CopierTrim(inputKey);
   if(StringLen(trimmedInput)==CP_KEY_LEN)
     {
      outSource="input:HubPublicKey";
      if(CheckPointer(log)!=POINTER_INVALID)
         log.Info("Hub Public Key: using EA input parameter HubPublicKey ("+trimmedInput+")");
      return trimmedInput;
     }

   if(StringLen(trimmedInput)>0)
     {
      if(CheckPointer(log)!=POINTER_INVALID)
         log.Error("Hub Public Key: input HubPublicKey has invalid length ("+
                   (string)StringLen(trimmedInput)+", expected "+(string)CP_KEY_LEN+").");
     }

   return "";
  }

#endif
//+------------------------------------------------------------------+
