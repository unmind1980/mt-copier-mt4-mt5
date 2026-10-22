//+------------------------------------------------------------------+
//| CopierCodec.mqh - wire protocol encode / decode                  |
//|                                                                   |
//| Wire format (delimited key=value, NOT json - MQL has no json      |
//| parser and its string API is weak):                               |
//|                                                                   |
//|   V=1|SID=<sender>|SSID=<session>|SEQ=<n>|TS=<unix>|T=<TYPE>|P=.. |
//|        ^ envelope fields separated by  |                          |
//|                                                                   |
//|   payload fields separated by ';', repeated records by '~',       |
//|   items inside a record by ','.                                   |
//|                                                                   |
//|   SNAP payload:  N=2;R=<rec>~<rec>                                |
//|   rec = UID,TICKET,SYMBOL,SIDE,LOTS,OPENPX,SL,TP,MAGIC,OPENTIME   |
//|                                                                   |
//| All timestamps are BROKER SERVER TIME. Never wall clock - VPS     |
//| clocks drift and would destroy any ordering assumption.           |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_CODEC_MQH__
#define __COPIER_CODEC_MQH__

#include "CopierDefs.mqh"
#include <Zmq/Z85.mqh>

struct CopierEnv
  {
   int               v;
   string            sid;
   string            ssid;
   long              seq;
   long              ts;
   //--- Sender's MONOTONIC millisecond clock (GetTickCount), not wall time.
   //---
   //--- `ts` above is server time in SECONDS, which is far too coarse to say
   //--- anything about a link that is usually sub-millisecond. This field
   //--- rides along on messages that are being sent anyway, so it costs a few
   //--- bytes and no extra traffic.
   //---
   //--- Two machines' tick counters differ by an arbitrary constant, so this
   //--- is NOT comparable across hosts on its own - the receiver derives the
   //--- offset from the best case it has ever seen. See CopierPeers.mqh.
   long              ms;
   string            type;
   string            payload;
  };

//=====================================================================
// Envelope
//=====================================================================
string CopierEncodeEnv(const CopierEnv &e)
  {
   return "V="+(string)e.v
         +CP_SEP_FIELD+"SID="+e.sid
         +CP_SEP_FIELD+"SSID="+e.ssid
         +CP_SEP_FIELD+"SEQ="+(string)e.seq
         +CP_SEP_FIELD+"TS="+(string)e.ts
         +CP_SEP_FIELD+"MS="+(string)e.ms
         +CP_SEP_FIELD+"T="+e.type
         +CP_SEP_FIELD+"P="+e.payload;
  }

int CopierDecodeEnv(const string msg,CopierEnv &e)
  {
   if(StringLen(msg)<=0 || StringLen(msg)>CP_MAX_MSG_LEN) return CP_ERR_TRUNCATED;

   //--- payload is always last and may legally contain ';' '~' ',' but
   //--- never '|' (we sanitise symbols/comments at the edges).
   int p=StringFind(msg,CP_SEP_FIELD+"P=");
   if(p<0) return CP_ERR_BAD_ENVELOPE;

   string head=StringSubstr(msg,0,p);
   e.payload=StringSubstr(msg,p+StringLen(CP_SEP_FIELD+"P="));

   string parts[];
   int n=StringSplit(head,StringGetCharacter(CP_SEP_FIELD,0),parts);

   e.v=0; e.sid=""; e.ssid=""; e.seq=0; e.ts=0; e.ms=0; e.type="";
   for(int i=0;i<n;i++)
     {
      int eq=StringFind(parts[i],"=");
      if(eq<=0) continue;
      string k=StringSubstr(parts[i],0,eq);
      string v=StringSubstr(parts[i],eq+1);
      if(k=="V")         e.v=(int)StringToInteger(v);
      else if(k=="SID")  e.sid=v;
      else if(k=="SSID") e.ssid=v;
      else if(k=="SEQ")  e.seq=CopierParseLong(v);
      else if(k=="TS")   e.ts=CopierParseLong(v);
      //--- 64-bit parse: a tick count passes 2^31 after ~25 days of uptime and
      //--- StringToInteger would wrap on MQL4, turning the delay arithmetic
      //--- into noise on a VPS that has simply been up a long time.
      else if(k=="MS")   e.ms=CopierParseLong(v);
      else if(k=="T")    e.type=v;
     }
   if(e.v!=CP_PROTO_V) return CP_ERR_BAD_VERSION;
   if(StringLen(e.sid)==0 || StringLen(e.type)==0) return CP_ERR_BAD_ENVELOPE;
   return CP_ERR_NONE;
  }

//+------------------------------------------------------------------+
// A bare "err=1" in a log tells the reader nothing - the same lesson as
// the broker error mapping on the trade path. Name the codes.
//+------------------------------------------------------------------+
string CopierErrText(const int err)
  {
   switch(err)
     {
      case CP_ERR_NONE:         return "ok";
      case CP_ERR_TRUNCATED:    return "empty or too long";
      case CP_ERR_BAD_ENVELOPE: return "bad envelope";
      case CP_ERR_BAD_VERSION:  return "bad protocol version";
      case CP_ERR_BAD_TYPE:     return "bad message type";
      case CP_ERR_BAD_RECORD:   return "bad record";
     }
   return "unknown code";
  }

//=====================================================================
// Position record: UID,TICKET,SYMBOL,SIDE,LOTS,OPENPX,SL,TP,MAGIC,OTS
//=====================================================================
#define CP_DIGITS_PX   8
#define CP_DIGITS_LOTS 8

string CopierEncodeRec(const CopierPos &p)
  {
   string s=p.uid
         +CP_SEP_ITEM+(string)p.ticket
         +CP_SEP_ITEM+CopierSanitizeSymbol(p.sym)
         +CP_SEP_ITEM+(string)p.side
         +CP_SEP_ITEM+CopierFmtDouble(p.lots,CP_DIGITS_LOTS)
         +CP_SEP_ITEM+CopierFmtDouble(p.openPx,CP_DIGITS_PX)
         +CP_SEP_ITEM+CopierFmtDouble(p.sl,CP_DIGITS_PX)
         +CP_SEP_ITEM+CopierFmtDouble(p.tp,CP_DIGITS_PX)
         +CP_SEP_ITEM+(string)p.magic
         +CP_SEP_ITEM+(string)p.openTime;
   //--- The pending fields are appended ONLY when there are any, so a market
   //--- record stays byte-identical to what every previous build produced.
   //--- That keeps the wire compatible in both directions for everything
   //--- except the new feature itself: an older peer skips a pending record
   //--- (CopierDecodeSnapshot drops bad records rather than the batch) and
   //--- it could not mirror a pending order anyway.
   if(p.kind==CP_ORD_PENDING)
      s+=CP_SEP_ITEM+(string)p.kind
        +CP_SEP_ITEM+(string)p.ptype
        +CP_SEP_ITEM+CopierFmtDouble(p.pprice,CP_DIGITS_PX)
        +CP_SEP_ITEM+CopierFmtDouble(p.pstop,CP_DIGITS_PX)
        +CP_SEP_ITEM+(string)p.pexpire;
   return s;
  }

bool CopierDecodeRec(const string rec,CopierPos &p)
  {
   string it[];
   int n=StringSplit(rec,StringGetCharacter(CP_SEP_ITEM,0),it);
   //--- Ten fields is the original market record; a pending entry appends
   //--- five more. Accepting a MINIMUM rather than an exact count is what
   //--- lets one build read records written on either side of the change.
   if(n<10) return false;
   p.uid=it[0];
   p.ticket=CopierParseLong(it[1]);
   p.sym=it[2];
   p.side=(int)StringToInteger(it[3]);
   p.lots=StringToDouble(it[4]);
   p.openPx=StringToDouble(it[5]);
   p.sl=StringToDouble(it[6]);
   p.tp=StringToDouble(it[7]);
   p.magic=CopierParseLong(it[8]);
   p.openTime=CopierParseLong(it[9]);
   //--- absent means a market entry, which is what every older record is
   p.kind=CP_ORD_MARKET;
   p.ptype=0;
   p.pprice=0.0;
   p.pstop=0.0;
   p.pexpire=0;
   if(n>=15)
     {
      p.kind=(int)StringToInteger(it[10]);
      p.ptype=(int)StringToInteger(it[11]);
      p.pprice=StringToDouble(it[12]);
      p.pstop=StringToDouble(it[13]);
      p.pexpire=CopierParseLong(it[14]);
     }
   p.cmt="";
   p.used=true;
   if(p.side!=CP_SIDE_BUY && p.side!=CP_SIDE_SELL) return false;
   if(StringLen(p.uid)!=CP_UID_LEN) return false;
   //--- an unknown kind or pending type is REFUSED rather than guessed at:
   //--- mirroring a stop-limit as a plain stop would silently change the
   //--- order the sender placed, which is worse than skipping it.
   if(p.kind!=CP_ORD_MARKET && p.kind!=CP_ORD_PENDING) return false;
   if(p.kind==CP_ORD_PENDING && !CopierPendingTypeKnown(p.ptype)) return false;
   return true;
  }

//=====================================================================
// SNAP payload: N=<count>;R=<rec>~<rec>~...;H=<hash>
//=====================================================================
//
//--- H is an FNV-1a (32-bit) hash of the payload string UP TO BUT NOT
//--- INCLUDING the ";H=" that introduces it. It therefore covers EVERY
//--- byte of the snapshot - count, every record, every field including
//--- SL and TP - and changes whenever any of them changes.
//---
//--- WHAT THIS HASH IS, AND IS NOT.
//---
//--- It is a RECEIPT, not a checksum of the receiver's own state. The
//--- SENDER computes it; the receiver only STORES the value it was given
//--- and echoes it back in its heartbeat. So there is exactly one value
//--- end to end and nothing is ever compared across the two sides.
//---
//--- That distinction is the whole reason hashing the full record is
//--- safe. Several fields (TICKET, OPENPX, OPENTIME, MAGIC, and SYM under
//--- a symbol mapping) are NECESSARILY different on the receiver - its
//--- ticket is its own, its fill price is its own. If the receiver
//--- computed its own hash and the two were compared, those fields would
//--- mismatch forever. It does not, so they cannot.
//---
//--- What the sender learns from a returned hash is exactly one thing:
//--- "this receiver has ingested the snapshot whose bytes hashed to H".
//--- If H is not the current one, that receiver is behind - which is what
//--- triggers a targeted re-send (see doc/SNAPSHOT-DEMAND-PLAN.md).
//---
//--- FNV-1a rather than anything stronger because the job is to notice a
//--- CHANGE, not to resist an adversary. It is a few instructions per
//--- byte, deterministic across platforms (MQL and any Rust tooling agree
//--- on the same 32-bit arithmetic), and needs no library.
#define CP_FNV_OFFSET 2166136261
#define CP_FNV_PRIME  16777619

//--- Written with `long` and an explicit 32-bit mask rather than `uint`.
//---
//--- FNV-1a's definition assumes unsigned 32-bit wraparound on the multiply.
//--- MQL4's `uint` is the least reliable type to lean on for that: arithmetic
//--- on it promotes, and a promotion that keeps 64 bits silently changes the
//--- result - the hash would still "work" (it would still change when the
//--- input changes) but it would NOT be the FNV-1a value, and any non-MQL
//--- tool computing the same hash over the same bytes would disagree.
//---
//--- `long` is exact to 2^63, so `h * PRIME` for h < 2^32 cannot overflow it,
//--- and the mask restores the low 32 bits - which is precisely FNV-1a's
//--- defined result. Deterministic on both compilers, and reproducible in
//--- Python or Rust with the same two constants.
#define CP_MASK32 0xFFFFFFFF

long CopierHash32(const string s)
  {
   long h=(long)CP_FNV_OFFSET;
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      //--- StringGetCharacter gives a code unit; FNV-1a is defined on bytes
      //--- and every character in a snapshot is ASCII by construction
      //--- (symbols and comments are sanitised on the way in), so the low
      //--- byte IS the byte.
      h=h^(long)(StringGetCharacter(s,i)&0xFF);
      h=(h*(long)CP_FNV_PRIME)&CP_MASK32;
     }
   return h;
  }

//--- 8 lowercase hex digits, zero padded, so the field has a fixed width and
//--- "H=0000abcd" is distinguishable from a missing or truncated field.
string CopierHashHex(const long h)
  {
   string hex="0123456789abcdef";
   string out="";
   for(int shift=28;shift>=0;shift-=4)
      out+=StringSubstr(hex,(int)((h>>shift)&0xF),1);
   return out;
  }

//=====================================================================
// Adaptive compression for large payload fields (R=, POS=, WAITLIST=).
// Threshold: 500 bytes (~8-9 orders).
//   < 500 B: prefixed with "0:" (uncompressed raw text).
//  >= 500 B: compressed via native CryptEncode(CRYPT_ARCH_ZIP),
//            padded to multiple of 4, encoded with Z85, prefixed with "1:".
//=====================================================================
#define CP_COMPRESS_THRESHOLD 500

string CopierCompressField(const string src)
  {
   int len=StringLen(src);
   if(len<CP_COMPRESS_THRESHOLD)
     {
      return "0:"+src;
     }

   uchar data[];
   int copied=StringToCharArray(src,data,0,-1,CP_UTF8);
   if(copied<=0) return "0:"+src;
   if(copied>0 && data[copied-1]==0)
     {
      copied--;
      ArrayResize(data,copied);
     }

   uchar key[];
   ArrayResize(key,0);
   uchar comp[];
   int compLen=CryptEncode(CRYPT_ARCH_ZIP,data,key,comp);
   if(compLen<=0) return "0:"+src;

   // Z85 requires binary input size to be a multiple of 4
   int pad=(4-(compLen%4))%4;
   for(int p=0;p<pad;p++)
     {
      int sz=ArraySize(comp);
      ArrayResize(comp,sz+1);
      comp[sz]=0;
     }

   string z85Str="";
   if(!Z85::encode(z85Str,comp)) return "0:"+src;

   return "1:"+(string)pad+":"+z85Str;
  }

string CopierDecompressField(const string field)
  {
   if(StringSubstr(field,0,2)=="0:")
     {
      return StringSubstr(field,2);
     }
   if(StringSubstr(field,0,2)=="1:")
     {
      string z85Str="";
      int pad=-1;
      if(StringLen(field)>=4 && StringGetCharacter(field,3)==':')
        {
         pad=(int)StringToInteger(StringSubstr(field,2,1));
         z85Str=StringSubstr(field,4);
        }
      else
        {
         z85Str=StringSubstr(field,2);
        }
      uchar comp[];
      if(Z85::decode(z85Str,comp))
        {
         if(pad>0 && ArraySize(comp)>=pad)
           {
            ArrayResize(comp,ArraySize(comp)-pad);
           }
         uchar key[];
         ArrayResize(key,0);
         uchar decomp[];
         int decompLen=CryptDecode(CRYPT_ARCH_ZIP,comp,key,decomp);
         if(decompLen<=0 && pad<0)
           {
            // Backward-compat for legacy streams: try stripping 1..3 null padding bytes
            int totalSz=ArraySize(comp);
            for(int trim=1;trim<=3 && totalSz-trim>0;trim++)
              {
               uchar trimmed[];
               ArrayResize(trimmed,totalSz-trim);
               ArrayCopy(trimmed,comp,0,0,totalSz-trim);
               decompLen=CryptDecode(CRYPT_ARCH_ZIP,trimmed,key,decomp);
               if(decompLen>0) break;
              }
           }
         if(decompLen>0)
           {
            return CharArrayToString(decomp,0,decompLen,CP_UTF8);
           }
        }
      return "";
     }
   // Backward compatibility: un-prefixed legacy string
   return field;
  }

//=====================================================================
// A content hash for a whole config, 16 hex characters.
//
// WHY THIS EXISTS
// ===============
// A receiver used to answer the hub's 60-second WHO sweep with its ENTIRE
// effective config, escaped, inside every REG - for CP_MAX_SENDERS senders
// that is ~110 KB per receiver per minute, forever, and the hub only ever
// used it to answer one question: "is what this node runs still what I last
// saw?".
//
// So the node now answers that question in 32 bytes: `IH=<hash>`. The full
// config is sent when it CHANGES (CFGREPORT after a CFG apply) or when the
// hub explicitly asks for it (`reqcfg`). Nothing is sent at all in the steady
// state, which is the point.
//
// WHY TWO LANES
// =============
// FNV-1a over 32 bits is the same primitive `CopierUidIndex` already uses, and
// 32 bits is enough to make a *missed* change unlikely (about one chance in
// two billion per change) but it is the kind of "unlikely" that is unpleasant
// to argue about in a change detector. Two independent lanes give 64 effective
// bits for the price of a second accumulator, and both lanes stay inside
// `uint`, which is the only arithmetic that is provably identical on every
// MetaTrader build this file compiles under - a `ulong` literal big enough for
// a 64-bit FNV basis is NOT representable exactly in MQL4 (it exceeds 2^53, so
// the double it would be parsed from already lost the low bits).
//
// The definition is mirrored in hub/src/config.rs and asserted against the
// same vectors in both test suites, so the two cannot drift.
//=====================================================================
string CopierHex8(const uint v)
  {
   string out="";
   for(int i=7;i>=0;i--)
     {
      uint nib=(v>>(4*i)) & 15;
      out+=ShortToString((ushort)((nib<10)?('0'+nib):('a'+nib-10)));
     }
   return out;
  }

string CopierCfgHash(const string s)
  {
   uint a=2166136261;                 // FNV-1a offset basis
   uint b=0x9E3779B9;                 // lane 2: Knuth's golden-ratio constant
   if(StringLen(s)>0)
     {
      uchar data[];
      int got=StringToCharArray(s,data,0,-1,CP_UTF8);
      if(got>0)
        {
         int nb=(data[got-1]==0 ? got-1 : got); // exclude trailing null
         for(int i=0;i<nb;i++)
           {
            uint c=(uint)data[i];
            a=(a^c)*16777619;
            b=(b^c)*0x85EBCA6B;
           }
        }
     }
   return CopierHex8(a)+CopierHex8(b);
  }

string CopierEncodeSnapshot(const CopierPos &pos[],const int count)
  {
   string payload="N="+(string)count;
   if(count>0)
     {
      string recs="";
      for(int i=0;i<count;i++)
        {
         if(i>0) recs+=CP_SEP_REC;
         recs+=CopierEncodeRec(pos[i]);
        }
      payload+=CP_SEP_KV+"R="+CopierCompressField(recs);
     }
   //--- Hash the payload as built SO FAR, then append. Hashing after
   //--- appending would make the value depend on itself.
   payload+=CP_SEP_KV+"H="+CopierHashHex(CopierHash32(payload));
   return payload;
  }

//--- The snapshot's receipt hash, as it appeared on the wire. Returns "" when
//--- the sender did not send one - which is what an OLDER sender looks like,
//--- and must not be mistaken for a hash that happens to be wrong. A receiver
//--- that reports "" is saying "I have no receipt", and the sender treats that
//--- as "behind" only when it knows it is talking to a build that sends them.
string CopierSnapshotHash(const string payload)
  {
   string h="";
   if(!CopierKvGet(payload,"H",h)) return "";
   return h;
  }

int CopierDecodeSnapshot(const string payload,CopierPos &out[],const int maxOut)
  {
   string n="";
   if(!CopierKvGet(payload,"N",n)) return 0;
   int count=(int)StringToInteger(n);
   if(count<=0) return 0;                 // "N=0;R=" or "N=0"
   if(count>maxOut) count=maxOut;         // never trust the wire

   string recs="";
   CopierKvGet(payload,"R",recs);
   if(StringLen(recs)==0) return 0;

   recs=CopierDecompressField(recs);
   if(StringLen(recs)==0) return 0;

   string arr[];
   int got=StringSplit(recs,StringGetCharacter(CP_SEP_REC,0),arr);
   int n2=0;
   for(int i=0;i<got && n2<count;i++)
     {
      CopierPos p;
      if(CopierDecodeRec(arr[i],p))
        {
         out[n2]=p;
         n2++;
        }
     }
   return n2;
  }

//=====================================================================
// Convenience builders for the event messages
//=====================================================================
string CopierPayloadOpen(const CopierPos &p)
  {
   string s="UID="+p.uid
            +CP_SEP_KV+"TKT="+(string)p.ticket
            +CP_SEP_KV+"SYM="+CopierSanitizeSymbol(p.sym)
            +CP_SEP_KV+"SIDE="+(string)p.side
            +CP_SEP_KV+"LOTS="+CopierFmtDouble(p.lots,CP_DIGITS_LOTS)
            +CP_SEP_KV+"OPN="+CopierFmtDouble(p.openPx,CP_DIGITS_PX)
            +CP_SEP_KV+"SL="+CopierFmtDouble(p.sl,CP_DIGITS_PX)
            +CP_SEP_KV+"TP="+CopierFmtDouble(p.tp,CP_DIGITS_PX)
            +CP_SEP_KV+"OTS="+(string)p.openTime;
   //--- appended only for a pending entry, for the same reason the record
   //--- does it: a market event stays byte-identical, and k=v parsers ignore
   //--- keys they do not know.
   if(p.kind==CP_ORD_PENDING)
      s+=CP_SEP_KV+"KIND="+(string)p.kind
        +CP_SEP_KV+"PTYPE="+(string)p.ptype
        +CP_SEP_KV+"PPRICE="+CopierFmtDouble(p.pprice,CP_DIGITS_PX)
        +CP_SEP_KV+"PSTOP="+CopierFmtDouble(p.pstop,CP_DIGITS_PX)
        +CP_SEP_KV+"PEXP="+(string)p.pexpire;
   return s;
  }

bool CopierPayloadOpenParse(const string payload,CopierPos &p)
  {
   if(!CopierKvGet(payload,"UID",p.uid)) return false;
   string sym="";
   p.ticket  =CopierKvGetLong(payload,"TKT",0);
   CopierKvGet(payload,"SYM",sym);
   p.sym     =sym;
   p.side    =CopierKvGetInt(payload,"SIDE",0);
   p.lots    =CopierKvGetDouble(payload,"LOTS",0.0);
   p.openPx  =CopierKvGetDouble(payload,"OPN",0.0);
   p.sl      =CopierKvGetDouble(payload,"SL",0.0);
   p.tp      =CopierKvGetDouble(payload,"TP",0.0);
   p.openTime=CopierKvGetLong(payload,"OTS",0);
   //--- EVERY field is written, including the ones a market event does not
   //--- carry. A struct field left unset would inherit whatever was in that
   //--- memory before it - the same phantom-slot trap CopierPosTable's
   //--- constructor exists to close.
   p.kind    =CopierKvGetInt(payload,"KIND",CP_ORD_MARKET);
   p.ptype   =CopierKvGetInt(payload,"PTYPE",0);
   p.pprice  =CopierKvGetDouble(payload,"PPRICE",0.0);
   p.pstop   =CopierKvGetDouble(payload,"PSTOP",0.0);
   p.pexpire =CopierKvGetLong(payload,"PEXP",0);
   p.magic   =0;
   p.used    =true;
   if(p.side!=CP_SIDE_BUY && p.side!=CP_SIDE_SELL) return false;
   if(p.lots<=0.0) return false;
   //--- same refusal as the record decoder: never mirror a pending type we
   //--- cannot reproduce exactly
   if(p.kind!=CP_ORD_MARKET && p.kind!=CP_ORD_PENDING) return false;
   if(p.kind==CP_ORD_PENDING && !CopierPendingTypeKnown(p.ptype)) return false;
   return true;
  }

//--- One position's stops, as an EVENT rather than as part of a snapshot.
//---
//--- WHY THIS EXISTS AT ALL: a stop change used to reach the receiver only on
//--- the next snapshot, so its latency was bounded by SnapshotSeconds. That was
//--- acceptable while the snapshot went out every 2 s - it is documented as
//--- "the receiver follows within ~2 s (one snapshot)" in PILOT-MT4.md - and it
//--- stopped being acceptable the moment SnapshotSeconds was raised to cut
//--- bandwidth. A stop is the one thing whose whole purpose is to act at a
//--- level; arriving late is arriving wrong.
//---
//--- Same KEY NAMES as OPEN (`UID`, `OPN`, `SL`, `TP`) on purpose: a reader of
//--- one is a reader of the other, and the two can be logged side by side with
//--- no translation table.
//---
//--- Only what the receiver cannot already know. It looks the position up by
//--- UID, so it knows the symbol, the side and its own entry; what it cannot
//--- know is the SENDER's stops and the SENDER's entry price - and it needs
//--- both, because a stop is mirrored as a DISTANCE from the sender's entry and
//--- re-anchored on the receiver's own fill.
string CopierPayloadModify(const string uid,const double openPx,
                           const double sl,const double tp)
  {
   return "UID="+uid
          +CP_SEP_KV+"OPN="+CopierFmtDouble(openPx,CP_DIGITS_PX)
          +CP_SEP_KV+"SL="+CopierFmtDouble(sl,CP_DIGITS_PX)
          +CP_SEP_KV+"TP="+CopierFmtDouble(tp,CP_DIGITS_PX);
  }

//--- Fills only uid/openPx/sl/tp; every other field is left for the caller.
//--- Deliberately NOT CopierPayloadOpenParse - that one refuses a payload
//--- without a side or a volume, and a stop change carries neither.
bool CopierPayloadModifyParse(const string payload,CopierPos &p)
  {
   p.uid="";
   if(!CopierKvGet(payload,"UID",p.uid)) return false;
   if(StringLen(p.uid)==0) return false;
   p.openPx=CopierKvGetDouble(payload,"OPN",0.0);
   p.sl    =CopierKvGetDouble(payload,"SL",0.0);
   p.tp    =CopierKvGetDouble(payload,"TP",0.0);
   return true;
  }

string CopierPayloadClose(const string uid,const long ticket,const double lots,const double px)
  {
   return "UID="+uid
         +CP_SEP_KV+"TKT="+(string)ticket
         +CP_SEP_KV+"LOTS="+CopierFmtDouble(lots,CP_DIGITS_LOTS)
         +CP_SEP_KV+"PX="+CopierFmtDouble(px,CP_DIGITS_PX);
  }

//--- ACC is the sender's ACCOUNT NUMBER. The receiver's panel lists senders by
//--- account, and without this it only knows the routing id - which is a port
//--- number, not something an operator recognises on sight. 0 means "not
//--- supplied" so an older sender still parses.
string CopierPayloadHeartbeat(const double bal,const double eq,const double mgn,
                              const double frm,const int npos,
                              const long acc=0)
  {
   return "BAL="+CopierFmtDouble(bal,2)
         +CP_SEP_KV+"EQ="+CopierFmtDouble(eq,2)
         +CP_SEP_KV+"MGN="+CopierFmtDouble(mgn,2)
         +CP_SEP_KV+"FRM="+CopierFmtDouble(frm,2)
         +CP_SEP_KV+"NPOS="+(string)npos
         +CP_SEP_KV+"ACC="+(string)acc;
  }

//--- PING / PONG.
//---
//--- FROM is the responder's account and is ALWAYS set: it is what lets the
//--- originator attribute the echo to a peer. TO is set only when the probe
//--- was addressed, and is what stops the other receivers acting on an echo
//--- meant for someone else.
//---
//--- An earlier version carried only TO. The sender broadcasts its probe, so
//--- TO was empty, the receiver echoed it back empty, and the sender's own
//--- guard ("ignore an echo with no addressee") threw away every reply it got
//--- - the peer then never looked alive and was reported disconnected forever.
//--- Addressing a BROADCAST cannot work; identifying the RESPONDER can.
string CopierPayloadPing(const long ms,const string from)
  {
   return "MS="+(string)ms+CP_SEP_KV+"FROM="+from;
  }

string CopierPayloadPong(const long ms,const string from,const string to)
  {
   return "MS="+(string)ms+CP_SEP_KV+"FROM="+from+CP_SEP_KV+"TO="+to;
  }

//--- REG / HBT2, the central channel's "who are you" pair.
//---
//--- One shape, two builders. They answer the same question - who is this and
//--- is it still there - so the hub parses them with ONE function. The only
//--- difference is that REG carries NAME and HBT2 does not: a heartbeat
//--- repeating a name that cannot have changed is bytes for nothing, every few
//--- seconds, from every node, forever.
//---
//--- NAME is sanitised HERE rather than at the call site. It travels into the
//--- hub's registry and from there onto a web page, and a name containing ';'
//--- or '=' would silently split the payload into fields that do not exist.
//--- One place that always does it beats every caller remembering to.
//---
//--- UP is the node's own uptime in seconds, so the hub can tell "reconnected
//--- after a blip" from "has been running for a week" without keeping state
//--- across its own restarts.
string CopierPayloadReg(const string role,const long acc,const string name,
                        const long upSeconds)
  {
   return "ROLE="+role+CP_SEP_KV+"ACC="+(string)acc
          +CP_SEP_KV+"VER="+CP_NODE_VER
          +CP_SEP_KV+"NAME="+CopierSanitize(name,CP_SYM_MAXLEN)
          +CP_SEP_KV+"UP="+(string)upSeconds;
  }

string CopierPayloadHbt2(const string role,const long acc,const string name,
                        const long upSeconds)
  {
   //--- NAME IS HERE ON PURPOSE, and adding it is the fix for a real bug.
   //---
   //--- A node that only ever heartbeats is visible but ANONYMOUS, because
   //--- this message used to carry no name and REG was the only thing that
   //--- did. The EA already mitigates it by sending REG for its first
   //--- CP_REG_REPEATS announcements - but that only helps a node that has
   //--- never announced. Restart the HUB with the EAs already attached and
   //--- g_announceCount is long past CP_REG_REPEATS, so they send HBT2 only,
   //--- and the name waits for the hub's WHO sweep to make them re-REG.
   //--- Measured on a live hub: about ten to fifteen seconds of rows with a
   //--- blank Name column.
   //---
   //--- Carrying the name with the liveness evidence removes the whole class:
   //--- there is no restart order in which a visible node has no name.
   //---
   //--- Backward compatible in both directions, which is why this is safe on
   //--- a live link: an OLD hub ignores a key it does not know, and a NEW hub
   //--- reading an OLD EA's HBT2 simply gets an empty NAME and keeps whatever
   //--- REG already told it. Sanitised exactly as REG sanitises it, because
   //--- this same string reaches a web page.
   return "ROLE="+role+CP_SEP_KV+"ACC="+(string)acc
          +CP_SEP_KV+"VER="+CP_NODE_VER
          +CP_SEP_KV+"NAME="+CopierSanitize(name,CP_SYM_MAXLEN)
          +CP_SEP_KV+"UP="+(string)upSeconds;
  }


#endif
//+------------------------------------------------------------------+
