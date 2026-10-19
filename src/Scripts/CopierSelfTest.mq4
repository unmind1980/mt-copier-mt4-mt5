//+------------------------------------------------------------------+
//|                                              CopierSelfTest.mq4  |
//|                                                                   |
//| Pure logic regression test. Touches no broker, places no trade,   |
//| needs no second account and no network. Run it after every change |
//| to the codec / state / sizing layers - those are where a silent   |
//| bug costs real money.                                             |
//|                                                                   |
//| Output goes to the Experts log (and to copier_selftest.log).      |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <Copier/CopierDefs.mqh>
#include <Copier/CopierCodec.mqh>
#include <Copier/CopierState.mqh>
#include <Copier/CopierModel.mqh>
#include <Copier/CopierSizing.mqh>
#include <Copier/CopierConfig.mqh>
#include <Copier/CopierFilter.mqh>
#include <Copier/CopierIgnore.mqh>
#include <Copier/CopierRisk.mqh>
#include <Copier/CopierPeers.mqh>
#include <Copier/CopierSymbol.mqh>

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

//--- Assertions that report the ACTUAL value on failure. A bare
//--- "FAIL x == 1" tells you nothing about why; these do, which matters
//--- a lot when the only way to debug is to ask someone to re-run the
//--- script and paste the log.
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

void OkDbl(const string name,const double actual,const double expected,const double tol)
  {
   bool cond=(MathAbs(actual-expected)<=tol);
   string line=(cond?"PASS  ":"FAIL  ")+name
               +"  (got "+DoubleToString(actual,8)+", want "
               +DoubleToString(expected,8)+")";
   if(cond) g_pass++; else g_fail++;
   Print(line);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,line); FileFlush(g_log); }
  }

void Note(const string s)
  {
   Print("      "+s);
   if(g_log!=INVALID_HANDLE) { FileWrite(g_log,"      "+s); FileFlush(g_log); }
  }

CopierPos MakePos(const string uid,const long tkt,const string sym,const int side,
                  const double lots,const double px,const double sl,const double tp,
                  const long magic,const long ots)
  {
   CopierPos p;
   p.uid=uid; p.ticket=tkt; p.sym=sym; p.cmt=""; p.side=side;
   p.lots=lots; p.openPx=px; p.sl=sl; p.tp=tp; p.magic=magic; p.openTime=ots;
   p.used=true;
   return p;
  }

//+------------------------------------------------------------------+
void TestEnvelope()
  {
   CopierEnv e;
   e.v=CP_PROTO_V; e.sid="alpari01"; e.ssid="a1b2c3"; e.seq=42;
   e.ts=1780000000; e.type=CP_T_OPEN;
   e.payload=CopierPayloadOpen(MakePos("ABCD1234",991,  "EURUSD",CP_SIDE_BUY,0.5,1.0845,1.08,1.09,0,1780000000));

   string wire=CopierEncodeEnv(e);
   CopierEnv d;
   int err=CopierDecodeEnv(wire,d);

   Ok("envelope: decode succeeds",err==CP_ERR_NONE);
   Ok("envelope: version",d.v==CP_PROTO_V);
   Ok("envelope: sender id",d.sid=="alpari01");
   Ok("envelope: session id",d.ssid=="a1b2c3");
   Ok("envelope: sequence",d.seq==42);
   Ok("envelope: timestamp",d.ts==1780000000);
   Ok("envelope: type",d.type==CP_T_OPEN);
   Ok("envelope: payload survives",d.payload==e.payload);
   Note("wire = "+wire);

   //--- payload contains ';' and ',' and '=' - the parser must not be
   //--- confused by them
   CopierPos p;
   bool ok=CopierPayloadOpenParse(d.payload,p);
   Ok("open payload: parses",ok);
   Ok("open payload: symbol",p.sym=="EURUSD");
   Ok("open payload: side",p.side==CP_SIDE_BUY);
   Ok("open payload: lots",MathAbs(p.lots-0.5)<0.0001);
   Ok("open payload: price",MathAbs(p.openPx-1.0845)<0.00001);
  }

void TestSanitize()
  {
   Ok("sanitize: strips field separator",CopierSanitizeSymbol("EU|RUSD")=="EU_RUSD");
   Ok("sanitize: strips record separator",CopierSanitizeSymbol("EU~RUSD")=="EU_RUSD");
   Ok("sanitize: strips equals",CopierSanitizeSymbol("EU=RUSD")=="EU_RUSD");
   Ok("sanitize: truncates",StringLen(CopierSanitizeSymbol("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"))==CP_SYM_MAXLEN);
   //--- a broker symbol with a '#' (very common) must survive untouched
   Ok("sanitize: hash survives",CopierSanitizeSymbol("EURUSD#")=="EURUSD#");
  }

void TestSnapshot()
  {
   CopierPos arr[3];
   arr[0]=MakePos("AAAA1111",1,"EURUSD",CP_SIDE_BUY, 0.50,1.08450,1.08000,1.09000,0,1780000000);
   arr[1]=MakePos("BBBB2222",2,"XAUUSD",CP_SIDE_SELL,0.10,2350.10,2360.00,0.0,0,1780000005);
   arr[2]=MakePos("CCCC3333",3,"US30",  CP_SIDE_BUY, 1.00,35000.5,34900.0,35200.0,7,1780000010);

   string payload=CopierEncodeSnapshot(arr,3);
   Note("snap = "+payload);

   CopierPos out[];
   ArrayResize(out,CP_MAX_POSITIONS);
   int n=CopierDecodeSnapshot(payload,out,CP_MAX_POSITIONS);

   Ok("snapshot: count",n==3);
   Ok("snapshot: rec0 uid",out[0].uid=="AAAA1111");
   Ok("snapshot: rec1 symbol",out[1].sym=="XAUUSD");
   Ok("snapshot: rec1 side",out[1].side==CP_SIDE_SELL);
   Ok("snapshot: rec2 lots",MathAbs(out[2].lots-1.0)<0.0001);
   Ok("snapshot: rec2 magic",out[2].magic==7);
   Ok("snapshot: rec2 open price",MathAbs(out[2].openPx-35000.5)<0.01);

   //--- empty snapshot is the "close everything" signal; it must decode
   //--- to zero positions without error
   string empty=CopierEncodeSnapshot(arr,0);
   int n0=CopierDecodeSnapshot(empty,out,CP_MAX_POSITIONS);
   Ok("snapshot: empty encodes to N=0",StringFind(empty,"N=0")==0);
   Ok("snapshot: empty decodes to 0",n0==0);

   //--- never trust the wire: a huge N must not overrun the buffer
   CopierPos small[];
   ArrayResize(small,2);
   int n2=CopierDecodeSnapshot("N=9999;R="+CopierEncodeRec(arr[0])+"~"+CopierEncodeRec(arr[1]),small,2);
   Ok("snapshot: clamps to buffer size",n2==2);

   //--- 10KB threshold adaptive compression test
   CopierPos bigArr[];
   ArrayResize(bigArr,300);
   for(int i=0;i<300;i++)
     {
      bigArr[i]=MakePos("U"+IntegerToString(10000000+i),i+1,"EURUSD",CP_SIDE_BUY,0.01,1.085,0,0,0,1780000000+i);
     }
   string bigPayload=CopierEncodeSnapshot(bigArr,300);
   Ok("snapshot: big payload uses compression prefix R=1:",StringFind(bigPayload,";R=1:")>0);
   CopierPos bigOut[];
   ArrayResize(bigOut,CP_MAX_POSITIONS);
   int bigN=CopierDecodeSnapshot(bigPayload,bigOut,CP_MAX_POSITIONS);
   Ok("snapshot: big payload decodes all 300 positions",bigN==300);
   Ok("snapshot: big payload ticket 1 matches",bigOut[0].ticket==1);
   Ok("snapshot: big payload ticket 300 matches",bigOut[299].ticket==300);
  }

void TestUid()
  {
   string uid=CopierNewUid();
   Ok("uid: length",StringLen(uid)==CP_UID_LEN);
   bool alpha=true;
   for(int i=0;i<StringLen(uid);i++)
     {
      if(StringFind(CP_UID_ALPHA,StringSubstr(uid,i,1))<0) alpha=false;
     }
   Ok("uid: alphabet",alpha);

   string cmt=CopierCommentForUid(uid);
   Ok("uid: comment roundtrip",CopierUidFromComment(cmt)==uid);
   Ok("uid: comment fits MT4 limit",StringLen(cmt)<=31);

   //--- the sender ticket is appended so the two orders can be matched by
   //--- eye in the two terminals
   string cmt2=CopierCommentForUid("ABCD1234",9918271);
   OkStr("uid: comment with sender ticket",cmt2,"tc|ABCD1234|9918271");
   Ok("uid: uid survives the ticket",CopierUidFromComment(cmt2)=="ABCD1234");
   OkInt("uid: sender ticket parsed back",CopierSenderTicketFromComment(cmt2),9918271);

   //--- backwards compatible: a comment with no ticket still parses, and
   //--- reports ticket 0 rather than garbage
   Ok("uid: old comment still parses",CopierUidFromComment("tc|ABCD1234")=="ABCD1234");
   OkInt("uid: absent ticket is 0",CopierSenderTicketFromComment("tc|ABCD1234"),0);
   OkInt("uid: ticket on a foreign comment is 0",
         CopierSenderTicketFromComment("from #12345"),0);

   //--- THE POINT OF THE ORDERING: however long the ticket gets, the
   //--- comment is capped and the UID - the functional part - is never the
   //--- thing that gets cut
   //--- 9223372036854775807 is LLONG_MAX: 19 digits, so it is one digit
   //--- longer than CP_TICKET_MAXLEN and still a legal long. Using a
   //--- longer literal here overflows and the compiler silently turns it
   //--- into a double, which defeats the point of the test.
   string cmt3=CopierCommentForUid("ABCD1234",9223372036854775807);
   Ok("uid: long ticket still capped",StringLen(cmt3)<=CP_COMMENT_MAX);
   Ok("uid: uid intact after capping",CopierUidFromComment(cmt3)=="ABCD1234");
   Ok("uid: capped comment fits MT4",StringLen(cmt3)<=31);

   //--- broker mangled / truncated comment must NOT yield a false uid
   Ok("uid: rejects foreign comment",CopierUidFromComment("from #12345")=="");
   Ok("uid: rejects truncated comment",CopierUidFromComment("tc|AB")=="");
  }

void TestNid()
  {
   //--- The node id is a PURE function of the account number, and that IS the
   //--- requirement: it is recomputed on every start, on both ends, and again
   //--- after any config the hub pushes. A value that differed between runs
   //--- would change a sender's magic and orphan every position already open
   //--- under the old one.
   Ok("nid: 8-digit accounts pass through",CopierNid(12345678)==12345678);
   Ok("nid: 9-digit accounts pass through",CopierNid(123456789)==123456789);
   Ok("nid: it is stable for the same input",
      CopierNid(1234567890)==CopierNid(1234567890));

   //--- the LAST nine, not the first: a broker's account numbers share a
   //--- leading prefix and differ in the trailing serial, so the last nine
   //--- discriminate better
   Ok("nid: a 10-digit account keeps its LAST nine",
      CopierNid(1234567890)==234567890);

   //--- THE HARD LIMIT. MT4's OrderSend takes a 32-bit SIGNED int magic, so
   //--- anything at or above 2^31 cannot be one at all. This bound is the
   //--- reason the truncation exists, so assert the bound, not just a case.
   Ok("nid: never reaches the MT4 int limit",CopierNid(9999999999)<2147483647);
   Ok("nid: the largest 10-digit account is safe",
      CopierNid(9999999999)==999999999);

   //--- ZERO IS NOT A HARMLESS RESULT HERE. Magic 0 is what a hand-placed
   //--- trade carries, so a mirror whose magic was 0 would sit in the same set
   //--- as the operator's own manual trades - and the receiver would manage
   //--- both, closing trades it was never told about.
   Ok("nid: an exact multiple of 1e9 does NOT become 0",
      CopierNid(1000000000)!=0);
   Ok("nid: ...nor does the next one",CopierNid(2000000000)!=0);
   Ok("nid: ...and the nudge is still inside the MT4 bound",
      CopierNid(1000000000)<2147483647);
  }

void TestIgnoreList()
  {
   //--- The validator is now shared between the comment parser and the
   //--- hand-typed IgnoreUids input. If the two ever disagreed, an operator
   //--- could list a uid that is accepted at startup and never matched at
   //--- runtime - the position they asked to be left alone would be managed
   //--- anyway, with nothing said. These are the boundary cases.
   Ok("uidvalid: accepts a good uid",CopierUidValid("ABCD1234"));
   Ok("uidvalid: rejects short",!CopierUidValid("ABCD123"));
   Ok("uidvalid: rejects long",!CopierUidValid("ABCD12345"));
   Ok("uidvalid: rejects empty",!CopierUidValid(""));
   //--- I, L, O and U are the four letters Crockford base32 omits, so a uid
   //--- containing one cannot have been generated by this copier. Accepting it
   //--- would promise a match that can never happen.
   Ok("uidvalid: rejects I",!CopierUidValid("ABCD123I"));
   Ok("uidvalid: rejects L",!CopierUidValid("ABCD123L"));
   Ok("uidvalid: rejects O",!CopierUidValid("ABCD123O"));
   Ok("uidvalid: rejects U",!CopierUidValid("ABCD123U"));
   Ok("uidvalid: rejects a space",!CopierUidValid("ABCD 234"));
   Ok("uidvalid: rejects lowercase",!CopierUidValid("abcd1234"));

   CopierIgnore ig;
   OkInt("ignore: empty input accepts nothing",ig.SetText(""),0);
   OkInt("ignore: empty input has no bad entries",ig.BadCount(),0);
   Ok("ignore: an unlisted uid is not ignored",!ig.Has("ABCD1234"));

   OkInt("ignore: comma separated",ig.SetText("ABCD1234,EFGH5678"),2);
   Ok("ignore: first listed",ig.Has("ABCD1234"));
   Ok("ignore: second listed",ig.Has("EFGH5678"));
   Ok("ignore: an unlisted uid stays unlisted",!ig.Has("JKMN9012"));

   //--- Case is normalised on the way in: the alphabet is uppercase and an
   //--- operator reading a uid off a chart will not reproduce it by hand.
   OkInt("ignore: lowercase accepted",ig.SetText("abcd1234"),1);
   Ok("ignore: lowercase matched as uppercase",ig.Has("ABCD1234"));

   //--- every separator an operator might paste, in one string
   OkInt("ignore: mixed separators",
         ig.SetText("ABCD1234;EFGH5678|JKMN9012 ZYXW9876"),4);
   Ok("ignore: semicolon split",ig.Has("EFGH5678"));
   Ok("ignore: pipe split",ig.Has("JKMN9012"));
   Ok("ignore: space split",ig.Has("ZYXW9876"));

   //--- a repeat is harmless and must not occupy two slots
   OkInt("ignore: duplicates collapse",ig.SetText("ABCD1234,ABCD1234"),1);

   //--- A malformed entry is COUNTED and NAMED, never dropped quietly: an
   //--- entry the operator typed and the copier ignored is the exact failure
   //--- this list exists to prevent.
   OkInt("ignore: good entry kept",ig.SetText("ABC,ABCD1234"),1);
   OkInt("ignore: bad entry counted",ig.BadCount(),1);
   OkStr("ignore: bad entry named",ig.BadList(),"\"ABC\"");
   Ok("ignore: the bad entry is not ignored",!ig.Has("ABC"));

   //--- SetText REPLACES rather than merges. The input is the only source now,
   //--- so "what is in the field" and "what the copier ignores" must be the
   //--- same set - merging would let them drift apart silently.
   ig.SetText("ABCD1234");
   ig.SetText("EFGH5678");
   OkInt("ignore: replace leaves one entry",ig.Count(),1);
   Ok("ignore: replaced entry is gone",!ig.Has("ABCD1234"));
   Ok("ignore: replacement is present",ig.Has("EFGH5678"));
   OkInt("ignore: replace resets the bad count",ig.BadCount(),0);
  }

void TestMt4FromTicket()
  {
   Ok("from#: parses",CopierMt4FromTicket("from #12345678")==12345678);
   Ok("from#: case insensitive",CopierMt4FromTicket("FROM #999")==999);
   Ok("from#: none",CopierMt4FromTicket("manual")==0);
   Ok("from#: no digits",CopierMt4FromTicket("from #")==0);
  }

void TestSeenRing()
  {
   //--- REGRESSION GUARD: a fresh ring must contain nothing. If it starts
   //--- with junk keys, Has() reports actions as already done and real
   //--- trades are silently skipped.
   CopierSeenRing freshRing;
   Ok("seen: fresh ring is empty",!freshRing.Has("anything"));

   CopierSeenRing ring;
   ring.SetTtlMs(60000);
   ring.Add("k1");
   Ok("seen: finds added key",ring.Has("k1"));
   Ok("seen: rejects unknown key",!ring.Has("k2"));
   //--- wrap the whole ring; the oldest entries fall out but the newest
   //--- must still be found, and memory must not have grown
   for(int i=0;i<CP_SEEN_RING+50;i++) ring.Add("x"+(string)i);
   Ok("seen: newest survives wrap",ring.Has("x"+(string)(CP_SEEN_RING+49)));
  }

//--- Module-scope so they are NOT stack-allocated. See the note inside.
CopierPosTable g_tFresh;
CopierPosTable g_tA;

void TestPosTable()
  {
   //--- REGRESSION GUARD: a freshly constructed table must have no
   //--- occupied slots at all. MQL does not reliably zero-initialise an
   //--- array of structs containing strings, so a constructor that does
   //--- not Clear() leaves phantom slots behind. Those phantoms made
   //--- PruneTo() report removing rows that were never written, and in
   //--- production they would be exported inside snapshots with empty
   //--- UIDs and generate bogus CLOSE signals every tick.
   //--- GLOBAL, not local. A CopierPosTable embeds CP_MAX_POSITIONS records -
   //--- ~400 KB at 2048 - and MQL's stack for locals is 512 KB, so two of
   //--- them in one function overflows it. The compiler says so out loud.
   g_tFresh.Clear();
   OkInt("table: fresh table used slots",g_tFresh.UsedCount(),0);
   CopierPos none[];
   OkInt("table: prune on fresh table removes nothing",
         g_tFresh.PruneTo(none,0),0);
   OkInt("table: fresh table count",g_tFresh.Count(),0);

   
   g_tA.Clear();
   Ok("table: starts empty",g_tA.Count()==0);

   g_tA.Upsert(MakePos("AAAA1111",1,"EURUSD",CP_SIDE_BUY,0.1,1.1,0,0,0,1));
   g_tA.Upsert(MakePos("BBBB2222",2,"GBPUSD",CP_SIDE_SELL,0.2,1.3,0,0,0,2));
   Ok("table: count 2",g_tA.Count()==2);
   Ok("table: find by uid",g_tA.Find("BBBB2222")>=0);
   Ok("table: find by ticket",g_tA.FindByTicket(1)>=0);
   Ok("table: find missing",g_tA.Find("ZZZZ9999")<0);

   //--- upsert on an existing uid updates in place, does not duplicate
   g_tA.Upsert(MakePos("AAAA1111",1,"EURUSD",CP_SIDE_BUY,0.9,1.1,0,0,0,1));
   Ok("table: upsert does not duplicate",g_tA.Count()==2);
   CopierPos q;
   g_tA.Get("AAAA1111",q);
   Ok("table: upsert updated value",MathAbs(q.lots-0.9)<0.0001);

   Ok("table: remove",g_tA.Remove("AAAA1111"));
   Ok("table: count after remove",g_tA.Count()==1);

   //--- prune keeps only what the snapshot still contains. This is the
   //--- mechanism that guarantees the table cannot grow forever.
   g_tA.Upsert(MakePos("CCCC3333",3,"USDJPY",CP_SIDE_BUY,0.3,150.0,0,0,0,3));
   OkInt("table: count after 3rd upsert",g_tA.Count(),2);
   OkInt("table: used slots after 3rd upsert",g_tA.UsedCount(),2);
   Ok("table: BBBB still present",g_tA.Find("BBBB2222")>=0);

   //--- dynamic array, not a fixed [1]: that is the idiomatic way to hand
   //--- an array of a string-bearing struct to a function in MQL, and it
   //--- keeps the test from depending on fixed-array parameter behaviour
   CopierPos keep[];
   ArrayResize(keep,1);
   keep[0]=MakePos("CCCC3333",3,"USDJPY",CP_SIDE_BUY,0.3,150.0,0,0,0,3);
   OkInt("table: keep array size",ArraySize(keep),1);
   OkStr("table: keep[0].uid is intact",keep[0].uid,"CCCC3333");

   int removed=g_tA.PruneTo(keep,1);
   OkInt("table: prune removed 1",removed,1);
   OkInt("table: prune left 1",g_tA.Count(),1);
   Ok("table: prune kept the right one",g_tA.Find("CCCC3333")>=0);
   Ok("table: prune dropped BBBB",g_tA.Find("BBBB2222")<0);

   CopierPos dense[];
   int dn=g_tA.CopyTo(dense);
   OkInt("table: copyTo count",dn,1);
  }

void TestStateFile()
  {
   string path="copier_selftest_state.st";
   CopierPos arr[2];
   arr[0]=MakePos("AAAA1111",11,"EURUSD",CP_SIDE_BUY,0.11,1.1111,1.1,1.2,0,1000);
   arr[1]=MakePos("BBBB2222",22,"XAUUSD",CP_SIDE_SELL,0.22,2222.2,0,0,5,2000);

   bool saved=CopierStateFile::Save(path,"SEQ=7;SSID=zzz",arr,2);
   Ok("state: save",saved);

   string hdr="";
   CopierPos back[];
   int n=0;
   bool loaded=CopierStateFile::Load(path,hdr,back,n);
   Ok("state: load",loaded);
   Ok("state: header",hdr=="SEQ=7;SSID=zzz");
   Ok("state: count",n==2);
   Ok("state: uid",n==2 && back[1].uid=="BBBB2222");
   Ok("state: lots",n==2 && MathAbs(back[0].lots-0.11)<0.0001);

   //--- a torn file (missing END) must be rejected so the caller can
   //--- fall back to rebuilding from order comments
   int h=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h!=INVALID_HANDLE)
     {
      FileWrite(h,CP_STATE_TAG_HDR+"SEQ=7");
      FileWrite(h,CP_STATE_TAG_POS+CopierEncodeRec(arr[0]));
      FileClose(h);
     }
   string hdr2="";
   CopierPos back2[];
   int n2=0;
   Ok("state: torn file rejected",!CopierStateFile::Load(path,hdr2,back2,n2));
   FileDelete(path);
  }

void TestSizing()
  {
   CopierSymInfo si;
   si.point=0.00001; si.digits=5;
   si.minLot=0.01; si.maxLot=50.0; si.lotStep=0.01;
   si.stopLevel=0; si.tickSize=0.00001; si.contractSize=100000;

   bool rej=false;
   double v=CopierComputeLots(0.5,CP_SIZE_MULTIPLIER,1.0,1.0,si,0,0,rej);
   Ok("sizing: multiplier 1x",!rej && MathAbs(v-0.5)<0.0001);

   v=CopierComputeLots(0.5,CP_SIZE_MULTIPLIER,0.1,1.0,si,0,0,rej);
   Ok("sizing: multiplier 0.1x",!rej && MathAbs(v-0.05)<0.0001);

   v=CopierComputeLots(9.9,CP_SIZE_FIXED,0.25,1.0,si,0,0,rej);
   Ok("sizing: fixed overrides",!rej && MathAbs(v-0.25)<0.0001);

   //--- 0.037 must snap DOWN to a valid 0.01 step, never up
   v=CopierComputeLots(0.37,CP_SIZE_MULTIPLIER,0.1,1.0,si,0,0,rej);
   Ok("sizing: snaps to lot step",!rej && MathAbs(v-0.03)<0.0001);

   //--- below broker minimum: reject, do NOT silently round up
   v=CopierComputeLots(0.5,CP_SIZE_MULTIPLIER,0.001,1.0,si,0,0,rej);
   Ok("sizing: below min is rejected",rej);

   //--- a value that rounds DOWN to zero must also be rejected, not
   //--- turned into the minimum lot
   v=CopierComputeLots(0.5,CP_SIZE_MULTIPLIER,0.000001,1.0,si,0,0,rej);
   Ok("sizing: rounding to zero is rejected",rej);

   //--- exactly at the broker minimum must be accepted
   v=CopierComputeLots(0.01,CP_SIZE_MULTIPLIER,1.0,1.0,si,0,0,rej);
   Ok("sizing: exactly min is accepted",!rej && MathAbs(v-0.01)<0.0001);

   //--- above broker maximum: clamp
   v=CopierComputeLots(999.0,CP_SIZE_MULTIPLIER,1.0,1.0,si,0,0,rej);
   OkDbl("sizing: clamps to max",v,50.0,0.0001);

   Ok("sizing: lot digits",CopierLotDigits(0.01)==2);
  }

void TestConfig()
  {
   string path="copier_selftest.ini";
   //--- FILE_WRITE alone does NOT truncate an existing file: without this
   //--- delete, a re-run overwrites the first N bytes and leaves the tail
   //--- of the previous (possibly longer) fixture behind, which then gets
   //--- parsed as extra lines. That makes the test non-deterministic
   //--- across runs, which is exactly what happened here.
   FileDelete(path);

   int h=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) { Ok("config: write fixture",false); return; }
   FileWrite(h,"; comment line");
   FileWrite(h,"[sender0]");
   FileWrite(h,"id = alpari01 ");
   FileWrite(h,"events=tcp://10.0.0.5:5555");
   FileWrite(h,"snap=tcp://10.0.0.5:5556");
   FileWrite(h,"lotmode=fixed");
   FileWrite(h,"lotparam=0.25");
   FileWrite(h,"symbol.GOLD=XAUUSD");
   FileWrite(h,"[sender1]");
   FileWrite(h,"id=icmarkets");
   FileWrite(h,"events=tcp://10.0.0.9:5555");
   FileClose(h);

   CopierIni ini;
   Ok("config: load",ini.Load(path));
   OkInt("config: sender count",ini.SenderCount(),2);
   OkStr("config: trims value",ini.Get("sender0","id"),"alpari01");
   OkStr("config: string value",ini.Get("sender0","events"),"tcp://10.0.0.5:5555");
   OkDbl("config: double value",ini.GetDouble("sender0","lotparam",0.0),0.25,0.0001);
   OkStr("config: default when absent",ini.Get("sender1","snap","none"),"none");
   //--- 8 real k=v entries in the fixture above (the comment line and the
   //--- two section headers are not entries)
   OkInt("config: total entries parsed",ini.Count(),8);

   int found=0;
   for(int k=0;k<ini.Count();k++)
     {
      if(ini.SecAt(k)!="sender0") continue;
      if(StringFind(ini.KeyAt(k),"symbol.")==0) found++;
     }
   Ok("config: enumerates symbol entries",found==1);

   FileDelete(path);
  }

//=====================================================================
// Duplicate resolution.
//
// When two positions share a UID the receiver closes one of them, so the
// selection rule decides which LIVE position dies. Getting the order wrong
// means closing the correct position and keeping the stale duplicate, which
// is worse than the bug it is fixing. Hence the coverage.
//=====================================================================
void TestDedup()
  {
   //--- a: readable comment, LARGER than the sender holds
   CopierPos a;
   a.uid="AAAA1111"; a.sym="EURUSD"; a.lots=0.20; a.openTime=100; a.ticket=11;
   a.cmt=CopierCommentForUid(a.uid,11);
   //--- b: no comment, exactly the sender's size
   CopierPos b;
   b.uid="AAAA1111"; b.sym="EURUSD"; b.lots=0.10; b.openTime=200; b.ticket=22;
   b.cmt="";

   //--- 1. agreement with the sender outranks a readable comment, so a
   //---    stale oversized duplicate loses even though it is identifiable
   Ok("dedup: volume match beats readable comment",CopierPreferSurvivor(b,a,0.10));
   Ok("dedup: volume mismatch loses",!CopierPreferSurvivor(a,b,0.10));

   //--- 2. with no usable sender volume, fall back to identifiability
   Ok("dedup: readable comment beats unreadable",CopierPreferSurvivor(a,b,-1.0));
   Ok("dedup: unreadable comment loses",!CopierPreferSurvivor(b,a,-1.0));

   //--- 3. both unreadable -> keep the original, remove the copy we added
   CopierPos c;
   c.uid="BBBB2222"; c.sym="EURUSD"; c.lots=0.10; c.openTime=500; c.ticket=33; c.cmt="";
   CopierPos d;
   d.uid="BBBB2222"; d.sym="EURUSD"; d.lots=0.10; d.openTime=900; d.ticket=44; d.cmt="";
   Ok("dedup: older position survives",CopierPreferSurvivor(c,d,-1.0));
   Ok("dedup: newer position is removed",!CopierPreferSurvivor(d,c,-1.0));

   //--- 4. same age -> decide on the identifier, so the outcome never
   //---    depends on the order the terminal enumerates positions in
   CopierPos e;
   e.uid="CCCC3333"; e.sym="EURUSD"; e.lots=0.10; e.openTime=700; e.ticket=55; e.cmt="";
   CopierPos f;
   f.uid="CCCC3333"; f.sym="EURUSD"; f.lots=0.10; f.openTime=700; f.ticket=66; f.cmt="";
   Ok("dedup: lower ticket survives",CopierPreferSurvivor(e,f,-1.0));
   Ok("dedup: higher ticket is removed",!CopierPreferSurvivor(f,e,-1.0));

   //--- 5. ANTI-SYMMETRY. The caller picks a survivor by folding this
   //---    predicate over the group, so if P(x,y) and P(y,x) could both be
   //---    true the winner would depend on iteration order.
   Ok("dedup: comment rule is antisymmetric",
      CopierPreferSurvivor(a,b,-1.0)!=CopierPreferSurvivor(b,a,-1.0));
   Ok("dedup: volume rule is antisymmetric",
      CopierPreferSurvivor(a,b,0.10)!=CopierPreferSurvivor(b,a,0.10));
   Ok("dedup: age rule is antisymmetric",
      CopierPreferSurvivor(c,d,-1.0)!=CopierPreferSurvivor(d,c,-1.0));
  }

//=====================================================================
// Which actions the "already done" ring may gate.
//
// REGRESSION GUARD. The ring answers "have I already performed this
// action?" - a meaningful question for a one-shot, irreversible action, and
// the WRONG one for an idempotent state assignment. Its key is the TARGET
// state and it remembers it for ten minutes, so returning to a stop level
// that had been reached before was suppressed. On a live SELL whose stop
// was removed, re-added and removed again, the receiver kept a stop the
// sender no longer had - and a take-profit change "fixed" it only because
// it changed the key.
//=====================================================================
void TestSeenRingGating()
  {
   Ok("gating: the ring does NOT apply to MODIFY",
      !CopierSeenRingApplies(CP_ACT_MODIFY));
   Ok("gating: the ring applies to OPEN",
      CopierSeenRingApplies(CP_ACT_OPEN));
   Ok("gating: the ring applies to CLOSE",
      CopierSeenRingApplies(CP_ACT_CLOSE));
   Ok("gating: the ring applies to TRIM",
      CopierSeenRingApplies(CP_ACT_TRIM));
   Ok("gating: the ring applies to DEDUP",
      CopierSeenRingApplies(CP_ACT_DEDUP));

   //--- The mechanism, made explicit. Had PushAction consulted the ring for
   //--- a MODIFY, this is the suppression that produced the bug: the same
   //--- target, reached once, silently dropped the second time.
   CopierSeenRing ring;
   ring.SetTtlMs(600000);
   string key="mt4demo:5:ABCD1234:0.00000000:0.00000000";
   ring.Add(key);
   Ok("gating: the ring WOULD suppress a repeated MODIFY target",
      ring.Has(key));
   Ok("gating: ...and a different target is not suppressed",
      !ring.Has("mt4demo:5:ABCD1234:158.39000000:0.00000000"));
  }

//=====================================================================
// Dropping keys from the seen-ring.
//
// REGRESSION GUARD. A close is NOT a one-shot action: open -> close ->
// restore -> close is an ordinary sequence. Keying the ring on
// "sid:CLOSE:uid" suppressed the SECOND close for the ring's whole TTL.
// Measured live: the sender closed two positions at 10:15:23 and the
// receiver did not close its mirrors until 10:22:19 - exactly ten minutes
// after the previous close of those UIDs.
//=====================================================================
void TestSeenRingForget()
  {
   CopierSeenRing ring;
   ring.SetTtlMs(600000);

   ring.Add("mt4demo:2:ABCD1234");
   Ok("forget: the ring holds a close key",ring.Has("mt4demo:2:ABCD1234"));
   ring.Forget("mt4demo:2:ABCD1234");
   Ok("forget: an exact key can be dropped",!ring.Has("mt4demo:2:ABCD1234"));

   //--- a TRIM key carries the target volume AFTER the UID, so one UID's
   //--- entries cannot be named exactly - hence the prefix form
   ring.Add("mt4demo:3:ABCD1234:0.05000000");
   ring.Add("mt4demo:3:ABCD1234:0.03000000");
   ring.Add("mt4demo:3:WXYZ9876:0.05000000");
   ring.ForgetPrefix("mt4demo:3:ABCD1234");
   Ok("forget: the prefix drops every trim for that UID",
      !ring.Has("mt4demo:3:ABCD1234:0.05000000")
      && !ring.Has("mt4demo:3:ABCD1234:0.03000000"));
   Ok("forget: the prefix leaves other UIDs alone",
      ring.Has("mt4demo:3:WXYZ9876:0.05000000"));

   //--- an empty prefix must not wipe the ring
   ring.ForgetPrefix("");
   Ok("forget: an empty prefix drops nothing",
      ring.Has("mt4demo:3:WXYZ9876:0.05000000"));
  }

//=====================================================================
// Stop mirroring.
//
// The receiver copies the sender's stops as a DISTANCE from the entry, not
// as a price, because the two sides filled at different prices. Getting
// this wrong is not cosmetic: an absolute copy can land on the wrong side
// of the receiver's market, which is an instant stop-out.
//=====================================================================
void TestMirrorStop()
  {
   //--- BUY, stop 20 pips below the sender's entry. The receiver filled 30
   //--- pips HIGHER - the case an absolute copy breaks on.
   double sl=CopierMirrorStop(1.09800,1.10000,1.10300,CP_SIDE_BUY,true);
   OkDbl("mirror: buy sl keeps the distance",sl,1.10100,0.0000001);
   Ok("mirror: buy sl is NOT the absolute price",
      MathAbs(sl-1.09800)>0.0001);

   //--- SELL, stop 20 pips above the sender's entry, receiver filled lower
   double sl2=CopierMirrorStop(1.10200,1.10000,1.09700,CP_SIDE_SELL,true);
   OkDbl("mirror: sell sl keeps the distance",sl2,1.09900,0.0000001);

   //--- take-profit sits on the opposite side of the entry
   OkDbl("mirror: buy tp keeps the distance",
         CopierMirrorStop(1.10500,1.10000,1.10300,CP_SIDE_BUY,false),
         1.10800,0.0000001);
   OkDbl("mirror: sell tp keeps the distance",
         CopierMirrorStop(1.09500,1.10000,1.09700,CP_SIDE_SELL,false),
         1.09200,0.0000001);

   //--- absent stays absent: 0 is how the caller says "the sender has none",
   //--- and it is also how removal propagates
   OkDbl("mirror: absent sl stays absent",
         CopierMirrorStop(0.0,1.10000,1.10300,CP_SIDE_BUY,true),0.0,0.0000001);
   OkDbl("mirror: unknown sender entry is refused",
         CopierMirrorStop(1.09800,0.0,1.10300,CP_SIDE_BUY,true),0.0,0.0000001);
   OkDbl("mirror: unknown local entry is refused",
         CopierMirrorStop(1.09800,1.10000,0.0,CP_SIDE_BUY,true),0.0,0.0000001);

   //--- A stop on the WRONG SIDE of the sender's own entry is REFUSED
   //--- rather than guessed at: mirroring it would place a stop that is
   //--- already breached, and a wrong stop is worse than no stop.
   OkDbl("mirror: buy sl above its own entry is refused",
         CopierMirrorStop(1.10100,1.10000,1.10300,CP_SIDE_BUY,true),0.0,0.0000001);
   OkDbl("mirror: sell sl below its own entry is refused",
         CopierMirrorStop(1.09900,1.10000,1.09700,CP_SIDE_SELL,true),0.0,0.0000001);
   OkDbl("mirror: buy tp below its own entry is refused",
         CopierMirrorStop(1.09900,1.10000,1.10300,CP_SIDE_BUY,false),0.0,0.0000001);
   OkDbl("mirror: sl exactly at the entry is refused",
         CopierMirrorStop(1.10000,1.10000,1.10300,CP_SIDE_BUY,true),0.0,0.0000001);
  }

//=====================================================================
// Clamping to the broker's minimum stop distance.
//
// A stop inside SYMBOL_TRADE_STOPS_LEVEL is rejected (MT4 #130 / MT5
// 10016), and on MT5 that rejects the whole OrderSend. Clamping widens the
// stop, which is the safe direction - so it must widen and it must say so.
//=====================================================================
void TestFitStop()
  {
   CopierSymInfo si;
   si.point=0.00001; si.digits=5; si.stopLevel=0.00010;   // 10 points
   bool cl=false;

   //--- comfortably clear of the minimum: untouched
   OkDbl("fitstop: outside the minimum is untouched",
         CopierFitStopAt(1.09800,CP_SIDE_BUY,true,1.10000,si,cl),
         1.09800,0.0000001);
   Ok("fitstop: outside reports not clamped",!cl);

   //--- inside it: widened to exactly the minimum, and it says so
   OkDbl("fitstop: too close is widened to the minimum",
         CopierFitStopAt(1.09995,CP_SIDE_BUY,true,1.10000,si,cl),
         1.09990,0.0000001);
   Ok("fitstop: too close reports clamped",cl);

   //--- Already breached. Clamping pulls it to just below the market, so
   //--- the position exits almost immediately - the same fate the sender's
   //--- position met. Leaving it above the market would be an invalid stop.
   OkDbl("fitstop: breached buy stop is pulled below the market",
         CopierFitStopAt(1.10050,CP_SIDE_BUY,true,1.10000,si,cl),
         1.09990,0.0000001);
   Ok("fitstop: breached reports clamped",cl);

   //--- a SELL's stop sits ABOVE the market, so the push goes the other way
   OkDbl("fitstop: sell stop is pushed above the market",
         CopierFitStopAt(1.10005,CP_SIDE_SELL,true,1.10000,si,cl),
         1.10010,0.0000001);

   //--- take-profit is the opposite sign to the stop-loss, both sides
   OkDbl("fitstop: buy tp is pushed above the market",
         CopierFitStopAt(1.10005,CP_SIDE_BUY,false,1.10000,si,cl),
         1.10010,0.0000001);
   OkDbl("fitstop: sell tp is pushed below the market",
         CopierFitStopAt(1.09995,CP_SIDE_SELL,false,1.10000,si,cl),
         1.09990,0.0000001);

   //--- a broker with no minimum distance leaves everything alone
   CopierSymInfo noLvl=si;
   noLvl.stopLevel=0.0;
   OkDbl("fitstop: no stops level means no clamping",
         CopierFitStopAt(1.09999,CP_SIDE_BUY,true,1.10000,noLvl,cl),
         1.09999,0.0000001);
   Ok("fitstop: no level reports not clamped",!cl);

   //--- an absent stop stays absent: there is nothing to clamp
   OkDbl("fitstop: absent stop stays absent",
         CopierFitStopAt(0.0,CP_SIDE_BUY,true,1.10000,si,cl),0.0,0.0000001);
  }

//=====================================================================
// Risk switches.
//
// These decide whether real money moves, so every boundary is exercised:
// exactly-at-the-threshold, one step either side, and each switch OFF.
// The OFF cases matter as much as the ON ones - an unconfigured receiver
// must behave exactly as it did before the switches existed.
//=====================================================================
void TestRiskThresholds()
  {
   //--- OFF means off, whatever the loss
   Ok("risk: pct 0 never trips",
      !CopierLossExceeded(1.0,10000.0,0.0));
   Ok("risk: a zero baseline never trips",
      !CopierLossExceeded(9000.0,0.0,5.0));

   //--- the boundary is inclusive, because "down 5%" must trip AT 5%
   Ok("risk: exactly at the threshold trips",
      CopierLossExceeded(9500.0,10000.0,5.0));
   Ok("risk: one unit above the threshold does not",
      !CopierLossExceeded(9501.0,10000.0,5.0));
   Ok("risk: one unit below the threshold trips",
      CopierLossExceeded(9499.0,10000.0,5.0));

   //--- The level an operator can act on. "Stop when equity is 5% down" is
   //--- abstract; "stop at or below 9500.00" is not.
   OkDbl("risk: trip level at 5% of 10000",
         CopierLossTripLevel(10000.0,5.0),9500.0,0.0000001);
   OkDbl("risk: trip level with the switch off is 0",
         CopierLossTripLevel(10000.0,0.0),0.0,0.0000001);
   OkDbl("risk: trip level with no baseline is 0",
         CopierLossTripLevel(0.0,5.0),0.0,0.0000001);
   //--- the boundary the switch USES and the boundary it QUOTES must be the
   //--- same number, which is the point of expressing one in terms of the
   //--- other rather than computing them separately
   Ok("risk: the quoted level is exactly where it trips",
      CopierLossExceeded(CopierLossTripLevel(10000.0,5.0),10000.0,5.0));
  }

//=====================================================================
// What the trip messages actually say.
//
// The whole point of the message is that an operator can see WHERE the
// line is. A percentage alone does not do that, so these pin the figures:
// the current equity, the baseline, and the level it trips at.
//=====================================================================
void TestRiskMessages()
  {
   CopierRiskLimits lim;
   lim.maxLotsPerPosition=0.0;
   lim.maxTotalLots      =0.0;
   lim.maxOpenPositions  =0;
   lim.dailyLossPct      =1.0;
   lim.maxDrawdownPct    =2.0;
   CopierRisk rk;
   rk.Configure(lim);
   rk.ObserveAt(10000.0,800,10000.0);      // peak and day opening both 10000

   //--- three DISTINCT numbers, so each assertion means something
   string d=rk.DailyWhy(9850.0);           // trip level 1% of 10000 = 9900
   Ok("risk: daily message quotes the current equity",
      StringFind(d,"9850.00")>=0);
   Ok("risk: daily message quotes the day's opening equity",
      StringFind(d,"10000.00")>=0);
   Ok("risk: daily message quotes the level it trips at",
      StringFind(d,"9900.00")>=0);

   string dd=rk.DrawdownWhy(9750.0);       // trip level 2% of 10000 = 9800
   Ok("risk: drawdown message quotes the current equity",
      StringFind(dd,"9750.00")>=0);
   Ok("risk: drawdown message quotes the session peak",
      StringFind(dd,"10000.00")>=0);
   Ok("risk: drawdown message quotes the level it trips at",
      StringFind(dd,"9800.00")>=0);

   //--- The rate-limit key must NOT be the message. The message quotes live
   //--- equity and changes every tick, so keying on it would make every line
   //--- look like a new one and the rate limiter would do nothing at all.
   rk.ObserveAt(9850.0,800,10000.0);       // -1.5%, past the 1% limit
   Ok("risk: the switch is tripped for the key test",rk.DailyTripped());
   Ok("risk: the block key is a stable id, not the message",
      rk.BlockKey()=="daily");
  }

void TestRiskCaps()
  {
   CopierRiskLimits lim;
   lim.maxLotsPerPosition=0.10;
   lim.maxTotalLots      =0.50;
   lim.maxOpenPositions  =3;
   lim.dailyLossPct      =0.0;
   lim.maxDrawdownPct    =0.0;
   string why="";

   Ok("risk: a position at the size cap is allowed",
      CopierRiskAllowsOpen(lim,0.10,0,0.00,why));
   Ok("risk: ...with no reason attached",StringLen(why)==0);
   Ok("risk: a position over the size cap is refused",
      !CopierRiskAllowsOpen(lim,0.11,0,0.00,why));
   Ok("risk: ...and it says why",StringLen(why)>0);

   Ok("risk: one below the position-count cap is allowed",
      CopierRiskAllowsOpen(lim,0.01,2,0.02,why));
   Ok("risk: AT the position-count cap is refused",
      !CopierRiskAllowsOpen(lim,0.01,3,0.03,why));

   Ok("risk: total volume exactly at the cap is allowed",
      CopierRiskAllowsOpen(lim,0.05,0,0.45,why));
   Ok("risk: total volume over the cap is refused",
      !CopierRiskAllowsOpen(lim,0.06,0,0.45,why));

   //--- everything off: no cap of any kind
   CopierRiskLimits off;
   off.maxLotsPerPosition=0.0;
   off.maxTotalLots      =0.0;
   off.maxOpenPositions  =0;
   off.dailyLossPct      =0.0;
   off.maxDrawdownPct    =0.0;
   Ok("risk: with every cap off, anything is allowed",
      CopierRiskAllowsOpen(off,100.0,99,999.0,why));
   Ok("risk: ...and nothing is reported",StringLen(why)==0);
  }

void TestRiskDailyAndDrawdown()
  {
   CopierRiskLimits rl;
   rl.maxLotsPerPosition=0.0;
   rl.maxTotalLots      =0.0;
   rl.maxOpenPositions  =0;
   rl.dailyLossPct      =5.0;
   rl.maxDrawdownPct    =0.0;
   CopierRisk rk;
   rk.Configure(rl);
   Ok("risk: reports itself enabled",rk.Enabled());

   //--- arming is not a trip
   rk.ObserveAt(10000.0,100,10000.0);
   Ok("risk: a flat first observation does not trip",!rk.DailyTripped());
   Ok("risk: arming is not reported as a trip",!rk.TakeJustTripped());

   rk.ObserveAt(9600.0,100,10000.0);          // -4%
   Ok("risk: 4% down does not trip a 5% switch",!rk.DailyTripped());

   rk.ObserveAt(9500.0,100,10000.0);          // exactly -5%
   Ok("risk: exactly 5% down trips the daily switch",rk.DailyTripped());
   Ok("risk: the trip is reported once",rk.TakeJustTripped());
   Ok("risk: ...and not a second time",!rk.TakeJustTripped());

   string why="";
   Ok("risk: a tripped switch blocks an open",
      !rk.AllowOpen(0.01,0,0.0,0,0.0,why));
   Ok("risk: ...and says why",StringLen(why)>0);

   //--- a new server day clears the DAILY switch
   rk.ObserveAt(9500.0,101,9500.0);
   Ok("risk: a new day clears the daily switch",!rk.DailyTripped());
   Ok("risk: an open is allowed again",rk.AllowOpen(0.01,0,0.0,0,0.0,why));

   //--- the DRAWDOWN switch, which must LATCH
   CopierRiskLimits dl;
   dl.maxLotsPerPosition=0.0;
   dl.maxTotalLots      =0.0;
   dl.maxOpenPositions  =0;
   dl.dailyLossPct      =0.0;
   dl.maxDrawdownPct    =5.0;
   CopierRisk rk2;
   rk2.Configure(dl);

   rk2.ObserveAt(10000.0,200,10000.0);
   rk2.ObserveAt(12000.0,200,10000.0);        // new peak
   Ok("risk: a new peak does not trip",!rk2.DrawdownTripped());

   rk2.ObserveAt(11401.0,200,10000.0);        // peak*0.95 = 11400
   Ok("risk: just above the drawdown line does not trip",
      !rk2.DrawdownTripped());
   rk2.ObserveAt(11400.0,200,10000.0);
   Ok("risk: exactly 5% off the peak trips",rk2.DrawdownTripped());

   //--- LATCHED: neither a recovery nor a new day clears it. It is the
   //--- "stop and look at this" switch, cleared by reloading the EA.
   rk2.ObserveAt(12000.0,201,12000.0);
   Ok("risk: drawdown survives a full recovery",rk2.DrawdownTripped());
   Ok("risk: drawdown survives into a new day",rk2.DrawdownTripped());
   Ok("risk: ...and still blocks an open",
      !rk2.AllowOpen(0.01,0,0.0,0,0.0,why));

   //--- A RESTORED PEAK MUST SURVIVE ARMING, AND MUST BE ABLE TO TRIP ON IT.
   //---
   //--- The peak used to live only in memory, so every terminal restart
   //--- re-based the drawdown to the equity of the moment and the switch was
   //--- silently forgiven by the event most likely to follow a bad day. The
   //--- receiver now persists it and calls SeedPeak before the first
   //--- observation - which means arming must RAISE the peak, never assign it,
   //--- and must not return before the trip checks.
   CopierRiskLimits dd2;
   dd2.maxLotsPerPosition=0.0;
   dd2.maxTotalLots      =0.0;
   dd2.maxOpenPositions  =0;
   dd2.dailyLossPct      =0.0;
   dd2.maxDrawdownPct    =10.0;

   CopierRisk rkSeed;
   rkSeed.Configure(dd2);
   rkSeed.SeedPeak(10000.0);                  // last run's peak
   rkSeed.ObserveAt(8800.0,500,8800.0);       // -12% from it
   Ok("risk: a restored peak trips on the arming observation",
      rkSeed.DrawdownTripped());
   Ok("risk: ...and arming did not overwrite it with today's equity",
      MathAbs(rkSeed.PeakEquity()-10000.0)<0.001);

   //--- ...and the control: with NO restored peak, arming at the same equity
   //--- cannot trip, so a genuinely fresh start is not blocked.
   CopierRisk rkFresh;
   rkFresh.Configure(dd2);
   rkFresh.ObserveAt(8800.0,500,8800.0);
   Ok("risk: a fresh start does not trip on arming",!rkFresh.DrawdownTripped());
   Ok("risk: ...and its peak is today's equity",
      MathAbs(rkFresh.PeakEquity()-8800.0)<0.001);

   //--- RECONFIGURING MUST RE-EVALUATE THE LATCHES.
   //---
   //--- Changing an EA's inputs reinitialises it but does NOT reset its
   //--- globals - the process stays alive - so without this a tripped switch
   //--- survived the operator turning it off, and the only way out was to
   //--- remove and re-add the EA. Reported from a live test: DailyLossPct
   //--- went 0.1 -> 0 and the receiver kept refusing new entries.
   CopierRiskLimits on;
   on.maxLotsPerPosition=0.0;
   on.maxTotalLots      =0.0;
   on.maxOpenPositions  =0;
   on.dailyLossPct      =5.0;
   on.maxDrawdownPct    =0.0;

   CopierRisk rk3;
   rk3.Configure(on);
   rk3.ObserveAt(10000.0,300,10000.0);
   rk3.ObserveAt(9000.0,300,10000.0);         // -10%
   Ok("risk: reconfigure setup tripped",rk3.DailyTripped());

   CopierRiskLimits disabled=on;
   disabled.dailyLossPct=0.0;                 // operator turns the switch OFF
   rk3.Configure(disabled);
   Ok("risk: turning the switch off clears the trip",!rk3.DailyTripped());
   Ok("risk: ...and an entry is allowed again",
      rk3.AllowOpen(0.01,0,0.0,0,0.0,why));
   rk3.ObserveAt(9000.0,300,10000.0);
   Ok("risk: ...and it stays clear on the next observation",
      !rk3.DailyTripped());

   //--- raising the threshold past the current loss clears it too, which is
   //--- what makes "raise the limit to resume" behave as the operator means
   CopierRisk rk4;
   rk4.Configure(on);
   rk4.ObserveAt(10000.0,400,10000.0);
   rk4.ObserveAt(9000.0,400,10000.0);
   Ok("risk: threshold case tripped",rk4.DailyTripped());
   CopierRiskLimits raised=on;
   raised.dailyLossPct=50.0;
   rk4.Configure(raised);
   rk4.ObserveAt(9000.0,400,10000.0);
   Ok("risk: raising the threshold clears the trip",!rk4.DailyTripped());

   //--- but an input change that does NOT touch the limits must leave the
   //--- latch alone, or changing LogLevel would silently un-trip a breaker
   CopierRisk rk5;
   rk5.Configure(on);
   rk5.ObserveAt(10000.0,500,10000.0);
   rk5.ObserveAt(9000.0,500,10000.0);
   Ok("risk: no-change case tripped",rk5.DailyTripped());
   rk5.Configure(on);                         // identical limits
   Ok("risk: an unrelated input change does not un-trip",rk5.DailyTripped());
   rk5.ObserveAt(9000.0,500,10000.0);
   Ok("risk: ...and it stays tripped afterwards",rk5.DailyTripped());
  }

//=====================================================================
// The gate must be handed what is HELD and what is PENDING separately, and
// must add them.
//
// REGRESSION GUARD. Passing only the held figures is what let
// MaxOpenPositions=3 open four positions on a live account: converge decides
// several opens in a SINGLE pass, and every one of them was checked against
// the same pre-open numbers, so all of them passed. The policy was correct
// and fully tested - it was simply fed stale inputs.
//=====================================================================
void TestRiskPendingProjection()
  {
   string why="";

   CopierRiskLimits cap;
   cap.maxLotsPerPosition=0.0;
   cap.maxTotalLots      =0.0;
   cap.maxOpenPositions  =3;
   cap.dailyLossPct      =0.0;
   cap.maxDrawdownPct    =0.0;
   CopierRisk rk;
   rk.Configure(cap);
   rk.ObserveAt(10000.0,600,10000.0);

   Ok("risk: two held of three leaves room",
      rk.AllowOpen(0.01,2,0.02,0,0.0,why));
   Ok("risk: one pending counts as the third",
      rk.AllowOpen(0.01,2,0.02,1,0.01,why));
   Ok("risk: a second pending open is refused",
      !rk.AllowOpen(0.01,2,0.02,2,0.02,why));
   //--- this is the live failure exactly: nothing held, three already
   //--- decided in this pass, and a fourth must not be let through
   Ok("risk: three pending opens already fill the cap",
      !rk.AllowOpen(0.01,0,0.0,3,0.03,why));

   CopierRiskLimits cap2;
   cap2.maxLotsPerPosition=0.0;
   cap2.maxTotalLots      =0.20;
   cap2.maxOpenPositions  =0;
   cap2.dailyLossPct      =0.0;
   cap2.maxDrawdownPct    =0.0;
   CopierRisk rk2;
   rk2.Configure(cap2);
   rk2.ObserveAt(10000.0,700,10000.0);

   Ok("risk: pending volume fits while there is room",
      rk2.AllowOpen(0.05,0,0.0,2,0.10,why));
   Ok("risk: pending volume fills the MaxTotalLots cap",
      !rk2.AllowOpen(0.05,0,0.0,4,0.20,why));
  }

//=====================================================================
// Pending orders on the wire.
//
// The compatibility rule is that a MARKET record stays byte-identical to
// what every previous build produced, so an older peer sees exactly what it
// always saw. Only a pending entry appends fields - and an older peer skips
// such a record rather than rejecting the batch, which is the right outcome
// because it could not mirror a pending order anyway.
//=====================================================================
void TestPendingCodec()
  {
   CopierPos m;
   m.uid="AAAA1111"; m.ticket=11; m.sym="EURUSD"; m.side=CP_SIDE_BUY;
   m.lots=0.10; m.openPx=1.10000; m.sl=1.09000; m.tp=1.12000;
   m.magic=770000; m.openTime=1000; m.cmt="";
   m.kind=CP_ORD_MARKET; m.ptype=0;
   m.pprice=0.0; m.pstop=0.0; m.pexpire=0; m.used=true;

   string r=CopierEncodeRec(m);
   string parts[];
   OkInt("pending: a market record is still 10 fields",
         StringSplit(r,StringGetCharacter(CP_SEP_ITEM,0),parts),10);

   CopierPos back;
   Ok("pending: a market record decodes",CopierDecodeRec(r,back));
   OkInt("pending: ...as a market entry",back.kind,CP_ORD_MARKET);
   OkDbl("pending: ...with its stops intact",back.tp,1.12000,0.0000001);

   //--- a pending entry appends five fields
   CopierPos p=m;
   p.kind=CP_ORD_PENDING;
   p.ptype=CP_PEND_BUYSTOPLIMIT;
   p.pprice=1.09500;
   p.pstop=1.09600;
   p.pexpire=1234567;
   string pr=CopierEncodeRec(p);
   string pparts[];
   OkInt("pending: a pending record is 15 fields",
         StringSplit(pr,StringGetCharacter(CP_SEP_ITEM,0),pparts),15);

   CopierPos pb;
   Ok("pending: a pending record decodes",CopierDecodeRec(pr,pb));
   OkInt("pending: ...kind survives",pb.kind,CP_ORD_PENDING);
   OkInt("pending: ...type survives",pb.ptype,CP_PEND_BUYSTOPLIMIT);
   OkDbl("pending: ...trigger price survives",pb.pprice,1.09500,0.0000001);
   OkDbl("pending: ...stop-limit price survives",pb.pstop,1.09600,0.0000001);
   OkInt("pending: ...expiry survives",pb.pexpire,1234567);

   //--- an unknown pending type is REFUSED, never approximated: mirroring a
   //--- stop-limit as a plain stop would silently change the order
   CopierPos bad=p;
   bad.ptype=99;
   CopierPos tmp;
   Ok("pending: an unknown pending type is refused",
      !CopierDecodeRec(CopierEncodeRec(bad),tmp));

   //--- the mapping helpers the platform layer depends on
   OkInt("pending: a buy limit is a buy",
         CopierPendingSide(CP_PEND_BUYLIMIT),CP_SIDE_BUY);
   OkInt("pending: a sell stop is a sell",
         CopierPendingSide(CP_PEND_SELLSTOP),CP_SIDE_SELL);
   Ok("pending: a stop-limit needs the second price",
      CopierPendingNeedsStop(CP_PEND_BUYSTOPLIMIT));
   Ok("pending: a plain limit does not",
      !CopierPendingNeedsStop(CP_PEND_BUYLIMIT));
  }

//=====================================================================
// A pending entry and the position it becomes are DIFFERENT actions.
//
// REGRESSION GUARD. MT4 has no stop-limit order type, so a stop-limit
// pending can never be placed there - but it will eventually TRIGGER on the
// sender, and a filled order is an ordinary market position that MT4 mirrors
// perfectly.
//
// An earlier version recorded the unplaceable pending as "done" in the
// seen-ring. Because both shared the key "sid:OPEN:uid", that also suppressed
// the market open that followed the fill - quietly losing the trade in order
// to keep the log quiet. The entry KIND is now part of the key, so the two
// cannot collide.
//=====================================================================
void TestKindScopedKeys()
  {
   CopierSeenRing ring;
   ring.SetTtlMs(600000);

   string pend="sender01:1:ABCD1234:1";   // OPEN, CP_ORD_PENDING
   string mkt ="sender01:1:ABCD1234:0";   // OPEN, CP_ORD_MARKET

   ring.Add(pend);
   Ok("keys: the unplaceable pending attempt is suppressed",ring.Has(pend));
   Ok("keys: ...but the market position it becomes is NOT",
      !ring.Has(mkt));
   Ok("keys: the two are genuinely different keys",pend!=mkt);
  }

void TestMagicResolve()
  {
   bool pinned=false;

   //--- an explicit magic= is used verbatim
   Ok("magic: an explicit magic= is used verbatim",
      CopierResolveMagic("880123",pinned)==880123);
   Ok("magic: ...and is reported as pinned",pinned);

   //--- ABSENT is no longer a fallback: it is a refusal. The old
   //--- MagicBase+index default silently changed a sender's magic when the
   //--- sections were reordered, orphaning every position under the old one.
   Ok("magic: a missing magic= resolves to -1, never a guess",
      CopierResolveMagic("",pinned)==-1);
   Ok("magic: ...and is reported as NOT pinned",!pinned);

   //--- "0" is a legal magic. A defaulting GetInt() cannot tell it from a
   //--- missing key, which is exactly why the raw string is passed in.
   Ok("magic: an explicit 0 is honoured, not treated as missing",
      CopierResolveMagic("0",pinned)==0);
   Ok("magic: ...and counts as pinned",pinned);
  }

void TestGuardKeyShape()
  {
   CopierSeenRing ring;
   ring.SetTtlMs(600000);

   //--- The OPEN key carries the entry kind as a SUFFIX, so that suppressing
   //--- an unplaceable pending cannot suppress the market position it becomes
   //--- when it fills. Adding that suffix silently broke the exact-match
   //--- Forget that clears the guard while the mirror is in place - and an
   //--- uncleared guard is what stops a closed mirror being restored.
   string openMkt="sender01:1:ABCD1234:0";
   string openPend="sender01:1:ABCD1234:1";
   string prefix  ="sender01:1:ABCD1234";

   ring.Add(openMkt);
   ring.Forget(prefix);          // exact match, no suffix
   Ok("guard: an exact Forget on the unsuffixed key does NOT clear a"
      +" suffixed one - this is the trap",ring.Has(openMkt));

   ring.ForgetPrefix(prefix);
   Ok("guard: a prefix Forget does clear it",!ring.Has(openMkt));

   //--- clearing the guards for a UID means ALL of them, both entry kinds
   ring.Add(openPend);
   ring.ForgetPrefix(prefix);
   Ok("guard: the prefix clears every entry kind for that UID",
      !ring.Has(openPend));
  }

void TestSnapshotCapacity()
  {
   //--- The wire limit has to be able to carry the position table's FULL
   //--- capacity. When it could not - 8192 bytes against 512 records - a
   //--- sender past roughly 100 open positions produced a snapshot that was
   //--- rejected as CP_ERR_TRUNCATED and NEVER APPLIED, so the receiver kept
   //--- converging against stale desired state behind a one-line warning.
   //---
   //--- Built as PENDING records, which carry five extra fields.
   //---
   //--- AND EVERY FIELD IS AT ITS WORST-CASE LENGTH, which is the part that
   //--- was missing. This used to fill the snapshot with "USDJPY" and a
   //--- seven-digit ticket, so it passed at 2048 records while a real sender
   //--- was already over the limit: DoubleToString(v,8) keeps all eight
   //--- decimals, a symbol may be CP_SYM_MAXLEN=24 characters, and a ticket is
   //--- a long. A capacity test built from convenient values measures the
   //--- test, not the capacity.
   CopierPos p[];
   ArrayResize(p,CP_MAX_POSITIONS);
   for(int i=0;i<CP_MAX_POSITIONS;i++)
     {
      p[i].uid="ABCD1234";                  // exactly CP_UID_LEN
      p[i].ticket=9223372036854775807;      // 19 digits - a long's ceiling
      p[i].sym="ABCDEFGHIJKLMNOPQRSTUVWX";  // exactly CP_SYM_MAXLEN
      p[i].side=0;
      p[i].lots=1000000.0;                  // widest DoubleToString(v,8)
      p[i].openPx=123456.12345678;          // 8 decimals, 6 integer digits
      p[i].sl=123456.12345678;
      p[i].tp=123456.12345678;
      p[i].magic=999999999;                 // the 9-digit magic ceiling
      p[i].openTime=1700000000;
      p[i].kind=CP_ORD_PENDING;
      p[i].ptype=2;
      p[i].pprice=123456.12345678;
      p[i].pstop=123456.12345678;
      p[i].pexpire=1700000000;
     }

   CopierEnv e;
   e.v=CP_PROTO_V;
   e.sid="sender01";
   e.ssid="4XQ92S";
   e.seq=1;
   e.ts=1700000000;
   e.type=CP_T_SNAP;
   e.payload=CopierEncodeSnapshot(p,CP_MAX_POSITIONS);

   string wire=CopierEncodeEnv(e);
   Ok("capacity: a full CP_MAX_POSITIONS snapshot fits under the wire limit",
      StringLen(wire)<=CP_MAX_MSG_LEN);
   //--- The libzmq inbound limit must never be the thing that refuses a
   //--- message the parser would have accepted. It is the same number on
   //--- purpose, and this states the REQUIREMENT even though the #define makes
   //--- it hold by construction - so that changing one to a literal later
   //--- still trips a test rather than a weekend.
   Ok("capacity: ...and under the libzmq inbound limit as well",
      StringLen(wire)<=CP_MAXMSGSIZE);
   //--- With room to spare. The failure mode when this lags is the whole
   //--- snapshot discarded, so the assertion is deliberately stricter than
   //--- "it fits": a margin eaten down to nothing is exactly how the previous
   //--- version of this test passed while being wrong.
   Ok("capacity: ...with at least 2x headroom left for future fields",
      (long)StringLen(wire)*2<=(long)CP_MAX_MSG_LEN);
   Ok("capacity: ...and decodes without being rejected",
      CopierDecodeEnv(wire,e)==CP_ERR_NONE);

   CopierPos back[];
   int n=CopierDecodeSnapshot(e.payload,back,CP_MAX_POSITIONS);
   Ok("capacity: ...with every record intact",n==CP_MAX_POSITIONS);
  }

void TestProfitTarget()
  {
   //--- 0 disables the gate, so it must pass unconditionally
   Ok("profit: 0 is off and passes a loser",CopierProfitTargetReached(-50.0,0.0));
   Ok("profit: 0 is off and passes a winner",CopierProfitTargetReached(50.0,0.0));

   //--- positive threshold: wait until that far in PROFIT
   Ok("profit: +10 not reached at +9",!CopierProfitTargetReached(9.0,10.0));
   Ok("profit: +10 reached at exactly +10",
      CopierProfitTargetReached(10.0,10.0));
   Ok("profit: +10 passed at +25",CopierProfitTargetReached(25.0,10.0));
   Ok("profit: +10 NOT satisfied by a loss",
      !CopierProfitTargetReached(-5.0,10.0));

   //--- negative threshold: wait until that far in LOSS - a pullback entry
   Ok("profit: -10 not reached at -9",!CopierProfitTargetReached(-9.0,-10.0));
   Ok("profit: -10 reached at exactly -10",
      CopierProfitTargetReached(-10.0,-10.0));
   Ok("profit: -10 passed at -25",CopierProfitTargetReached(-25.0,-10.0));

   //--- THE BUG this fixes. With a single `profitPips < threshold` test the
   //--- negative side was satisfied by ANY reading, so the gate did nothing
   //--- and the setting looked broken. It must wait.
   Ok("profit: -10 is NOT satisfied at break-even",
      !CopierProfitTargetReached(0.0,-10.0));
   Ok("profit: -10 is NOT satisfied while in profit",
      !CopierProfitTargetReached(20.0,-10.0));
  }

void TestKvSuffixCollision()
  {
   //--- "OTS" is a SUFFIX of "LOTS", so the first textual match for "OTS=" is
   //--- the wrong one. Giving up there reported OTS as ABSENT, the caller
   //--- fell back to its default, and every OPEN event decoded openTime as 0
   //--- - which silently disabled the wait and fill-timeout gates for exactly
   //--- the newly-opened positions they exist for.
   //---
   //--- Snapshot records decode by POSITION and were unaffected, so the fault
   //--- looked intermittent: old positions had a time, new ones did not.
   string payload="UID=ABCD1234;TKT=99;SYM=USDJPY;SIDE=1;LOTS=0.01"
                  +";OPN=1.1;SL=0;TP=0;OTS=1791417600";

   string ots="";
   Ok("kv: a key that is a suffix of another is still found",
      CopierKvGet(payload,"OTS",ots));
   Ok("kv: ...and yields its OWN value, not the longer key's",
      ots=="1791417600");

   //--- the longer key must still resolve
   string lots="";
   Ok("kv: the longer key still works",
      CopierKvGet(payload,"LOTS",lots) && lots=="0.01");

   //--- a key at the very start of the payload (no preceding separator)
   string uid="";
   Ok("kv: a key at the start works",
      CopierKvGet(payload,"UID",uid) && uid=="ABCD1234");

   //--- a genuinely absent key is still absent
   string none="";
   Ok("kv: an absent key reports absent",!CopierKvGet(payload,"NOPE",none));

   //--- the exact call that was broken
   Ok("kv: CopierKvGetLong reads a real OTS, not the default",
      CopierKvGetLong(payload,"OTS",0)==1791417600);
  }

void TestLotMode()
  {
   //--- There is ONE numbering now: the input dropdown's values ARE the
   //--- internal CP_SIZE_* codes. There used to be two with a mapping between
   //--- them, and the only thing that made it look safe was that both used 1
   //--- for "multiplier" - which is exactly what a cast would have got away
   //--- with while being wrong for the other two.
   //---
   //--- So these pin the NUMBERS, not just a round trip. A saved .set and the
   //--- value the central hub will push into copier.ini both carry the number,
   //--- so reordering the enum "for looks" would silently resize every mirror.
   Ok("lotmode: multiplier is 0",CP_SIZE_MULTIPLIER==0);
   Ok("lotmode: fixed is 1",CP_SIZE_FIXED==1);
   Ok("lotmode: off is 2",CP_SIZE_OFF==2);
   Ok("lotmode: the three codes are distinct",
      CP_SIZE_OFF!=CP_SIZE_MULTIPLIER && CP_SIZE_MULTIPLIER!=CP_SIZE_FIXED
      && CP_SIZE_OFF!=CP_SIZE_FIXED);

   //--- the input path is now a normalisation, not a translation
   Ok("lotmode: multiplier passes through",
      CopierLotModeInternal(CP_SIZE_MULTIPLIER)==CP_SIZE_MULTIPLIER);
   Ok("lotmode: fixed passes through",
      CopierLotModeInternal(CP_SIZE_FIXED)==CP_SIZE_FIXED);
   Ok("lotmode: off passes through",
      CopierLotModeInternal(CP_SIZE_OFF)==CP_SIZE_OFF);
   Ok("lotmode: an unknown value falls back to multiplier",
      CopierLotModeInternal(99)==CP_SIZE_MULTIPLIER);
   Ok("lotmode: ...and is reported as invalid",!CopierLotModeValid(99));
   Ok("lotmode: the three known codes are valid",
      CopierLotModeValid(CP_SIZE_MULTIPLIER) && CopierLotModeValid(CP_SIZE_FIXED)
      && CopierLotModeValid(CP_SIZE_OFF));

   //--- the ini's historical spellings must keep working
   bool ok=false;
   Ok("lotmode: ini 'off'",CopierLotModeFromText("off",ok)==CP_SIZE_OFF && ok);
   Ok("lotmode: ini 'OFF' is case-insensitive",
      CopierLotModeFromText("OFF",ok)==CP_SIZE_OFF && ok);
   Ok("lotmode: ini 'fixed'",
      CopierLotModeFromText("fixed",ok)==CP_SIZE_FIXED && ok);
   Ok("lotmode: ini 'multiplier'",
      CopierLotModeFromText("multiplier",ok)==CP_SIZE_MULTIPLIER && ok);

   //--- THE NUMBERS TOO. The hub pushes a value into copier.ini, and if only
   //--- the words were accepted a pushed "1" or "2" would fall through to
   //--- multiplier - right for "0", silently wrong for the other two.
   Ok("lotmode: ini accepts the code 0 as multiplier",
      CopierLotModeFromText("0",ok)==CP_SIZE_MULTIPLIER && ok);
   Ok("lotmode: ini accepts the code 1 as fixed",
      CopierLotModeFromText("1",ok)==CP_SIZE_FIXED && ok);
   Ok("lotmode: ini accepts the code 2 as off",
      CopierLotModeFromText("2",ok)==CP_SIZE_OFF && ok);

   //--- and an unrecognised value is REPORTED, not silently defaulted
   Ok("lotmode: ini nonsense falls back to multiplier",
      CopierLotModeFromText("banana",ok)==CP_SIZE_MULTIPLIER);
   Ok("lotmode: ...and says it did not recognise it",!ok);

   //--- the words and the codes must mean the same thing, or the ini would
   //--- behave differently depending on which form the hub happened to write
   Ok("lotmode: the words and the codes agree",
      CopierLotModeFromText("off",ok)==CopierLotModeFromText("2",ok)
      && CopierLotModeFromText("fixed",ok)==CopierLotModeFromText("1",ok)
      && CopierLotModeFromText("multiplier",ok)==CopierLotModeFromText("0",ok));
  }

void TestMarketClosedRetcode()
  {
   //--- The SAME condition has a DIFFERENT code on each platform, and that
   //--- difference already cost a weekend. The failure MESSAGE knew both, the
   //--- market-closed COOLDOWN only knew MT4's - so on MT5 the cooldown never
   //--- armed and every entry was retried every two seconds while the log
   //--- cheerfully said "market closed" the whole time.
   //---
   //--- These assertions exist so the two halves cannot drift apart again.
   Ok("mktclosed: MT4's 132 is recognised",CopierIsMarketClosed(132));
   Ok("mktclosed: MT5's 10018 is recognised",CopierIsMarketClosed(10018));

   //--- and it must NOT swallow codes that need their OWN handling.
   //--- 4109 is AutoTrading off: a local problem, with its own branch and its
   //--- own deliberate refusal to climb the backoff ladder. Folding it into
   //--- "market closed" would hide the real cause behind a wrong explanation -
   //--- which is worse than no explanation.
   Ok("mktclosed: 4109 (trade disabled) is NOT market closed",
      !CopierIsMarketClosed(4109));
   Ok("mktclosed: 10016 (invalid stops) is NOT market closed",
      !CopierIsMarketClosed(10016));
   Ok("mktclosed: 10015 (invalid price) is NOT market closed",
      !CopierIsMarketClosed(10015));
   Ok("mktclosed: 10021 (no quotes) is NOT market closed",
      !CopierIsMarketClosed(10021));
   Ok("mktclosed: success (0) is NOT market closed",!CopierIsMarketClosed(0));
  }

void TestNodeAnnounce()
  {
   //--- REG and HBT2 are the ONLY input to the hub's node table - it never
   //--- probes for nodes - so their SHAPE is a protocol contract rather than a
   //--- formatting choice, and it is worth pinning here.
   string reg=CopierPayloadReg("sender",888888,"MT5-A",3600);
   Ok("reg: carries the role",StringFind(reg,"ROLE=sender")>=0);
   Ok("reg: carries the account",StringFind(reg,"ACC=888888")>=0);
   Ok("reg: carries the protocol version",
      StringFind(reg,"VER="+CP_NODE_VER)>=0);
   Ok("reg: carries the name",StringFind(reg,"NAME=MT5-A")>=0);
   Ok("reg: carries the uptime",StringFind(reg,"UP=3600")>=0);

   string hbt=CopierPayloadHbt2("receiver",777777,"MT5-B",12);
   Ok("hbt2: carries the role and account",
      StringFind(hbt,"ROLE=receiver")>=0 && StringFind(hbt,"ACC=777777")>=0);
   Ok("hbt2: carries the uptime",StringFind(hbt,"UP=12")>=0);
   Ok("hbt2: carries the name",StringFind(hbt,"NAME=MT5-B")>=0);

   //--- THE RULE THAT REPLACED AN OLDER ONE, and worth reading both halves.
   //---
   //--- HBT2 used to carry no name AT ALL, on the grounds that a message
   //--- entitled to report a name is entitled to report an EMPTY one, and a
   //--- hub that took name-at-face-value would erase what REG had established.
   //--- That reasoning was sound about the HUB, not about the wire - and the
   //--- hub's rule is now "an empty name never blanks" (see on_hbt in
   //--- hub/src/registry.rs). So the hazard is handled where it lives.
   //---
   //--- What the old design actually cost, measured on a live hub: a node that
   //--- only heartbeats is VISIBLE but ANONYMOUS, and after a hub restart with
   //--- the EAs already attached the Name column stayed blank for ten to
   //--- fifteen seconds while the WHO sweep made them re-REG.
   //---
   //--- The hazard that is still real is a name corrupting the KEY=VALUE
   //--- structure, so that is pinned here rather than dropped: every separator
   //--- and '=' is replaced, so no name can invent or eat a field.
   Ok("hbt2: a name cannot inject a field",
      StringFind(CopierPayloadHbt2("r",1,"A;B=C",1),"NAME=A_B_C")>=0);
   Ok("hbt2: a name is length-capped",
      StringLen(CopierPayloadHbt2("r",1,"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",1))
      < 200 && StringFind(CopierPayloadHbt2("r",1,"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",1),
                          "NAME=XXXXXXXXXXXXXXXXXXXXXXXX")>=0);

   //--- M4b: the ini escape, which has a MIRROR in Rust (escape_ini in
   //--- hub/src/config.rs). Two implementations of one format is exactly the
   //--- arrangement that drifts silently, so the round trip is pinned on both
   //--- sides and the hub's end is pinned against a real ini over the wire by
   //--- tools/hub_config_test.py.
   string ini="[sender1]\nid=alpari01\nevents=5555\n; a comment with = and ;\n"
              +"lotmode=multiplier\nlotparam=2.0\nsymbol.EURUSD=EURUSD.m\n";
   string esc=CopierIniEscape(ini);
   Ok("ini escape: removes every separator",
      StringFind(esc,";")<0 && StringFind(esc,"\n")<0
      && StringFind(esc,"|")<0 && StringFind(esc,"=")<0);
   string back="";
   Ok("ini escape: unescapes back to the same bytes",
      CopierIniUnescape(esc,back) && back==ini);
   //--- Stated so nobody "fixes" it back: percent-encoding is NOT idempotent.
   //--- '%' is escaped AND appears in the output, so a second pass gives
   //--- %2525. A test asserting idempotence would be asserting something
   //--- false - which is what the Rust side's first attempt did.
   Ok("ini escape: is a layering, not a projection",
      CopierIniEscape(esc)!=esc && CopierIniUnescape(CopierIniEscape(esc),back)
      && back==esc);
   Ok("ini escape: refuses a malformed escape",
      !CopierIniUnescape("abc%zz",back) && !CopierIniUnescape("abc%",back));
   Ok("ini escape: refuses an escape it never produces",
      !CopierIniUnescape("%41",back));

   //--- The shape check, mirroring config::validate_ini on the hub. Both ends
   //--- check because both ends would otherwise have to trust the other.
   string verr="";
   Ok("ini validate: accepts a real ini",CopierIniValidate(ini,verr));
   Ok("ini validate: accepts comments and blank lines",
      CopierIniValidate("; hi\n\n[s]\nk=v\n# also\n",verr));
   Ok("ini validate: accepts a value containing =",
      CopierIniValidate("[s]\nk=a=b\n",verr));
   Ok("ini validate: rejects an empty ini",!CopierIniValidate("",verr));
   Ok("ini validate: rejects one with no section",
      !CopierIniValidate("id=a\nevents=1\n",verr));
   Ok("ini validate: rejects an unclosed section",
      !CopierIniValidate("[unclosed\nk=v\n",verr));
   Ok("ini validate: rejects a line that is neither",
      !CopierIniValidate("[s]\nno equals here\n",verr));
   Ok("ini validate: rejects an empty key",!CopierIniValidate("[s]\n=v\n",verr));

   //--- Split lines, which the validator is built on: it has to handle the
   //--- CRLF a Windows editor writes as well as the LF the hub sends.
   string lines[];
   Ok("split: LF",CopierSplitLines("a\nb\nc",lines)==3 && lines[1]=="b");
   Ok("split: CRLF",CopierSplitLines("a\r\nb\r\n",lines)==3 && lines[0]=="a"
      && lines[1]=="b");
   Ok("split: no trailing newline still yields the last line",
      CopierSplitLines("a\nb",lines)==2 && lines[1]=="b");

   //--- A name is free text from a terminal. If it can contain a separator it
   //--- can split the payload into fields that do not exist, and the hub would
   //--- read a node called "A" with a stray key "B".
   string nasty=CopierPayloadReg("sender",1,"A;B=C",0);
   Ok("reg: a name containing ';' or '=' cannot split the payload",
      StringFind(nasty,";B=")<0 && StringFind(nasty,"NAME=A_")>=0);
  }

void TestPeerLiveness()
  {
   //--- A peer that has NEVER been heard from used to read as DISCONNECTED,
   //--- because "no message yet" and "stopped sending" were the same value.
   //--- That made every hub link announce itself as broken for the second
   //--- between connecting and the first PONG coming back - on every start.
   //---
   //--- The fix is a third state, and these pin it. A -1 timeout is not a
   //--- trick: it is the only way to reach the DOWN branch without sleeping,
   //--- since `silent > -1` is true for any peer that has ever been seen.
   CopierPeerTable p;

   p.ProbeSent("fresh",CopierNowMs());
   Ok("peers: a peer we have only just probed is CONNECTING, not DOWN",
      p.StateAt(0,15000)==CP_PEER_CONNECT);

   p.Seen("fresh");
   Ok("peers: ...and once it answers it is UP",
      p.StateAt(0,15000)==CP_PEER_UP);

   Ok("peers: a peer past its timeout is DOWN",
      p.StateAt(0,-1)==CP_PEER_DOWN);

   Ok("peers: an empty slot is DOWN",
      p.StateAt(5,15000)==CP_PEER_DOWN);

   p.Forget("fresh");
   Ok("peers: forgetting a peer leaves the slot DOWN",
      p.StateAt(0,15000)==CP_PEER_DOWN);

   //--- the grace window itself, so the constant cannot be quietly set to 0
   Ok("peers: the connect grace window is longer than a LAN round trip",
      CP_PEER_GRACE_MS>=1000);
   Ok("peers: ...and short enough not to hide a dead peer for long",
      CP_PEER_GRACE_MS<=10000);
  }

void TestSymbolQuoteAge()
  {
   //--- The per-symbol freshness gate exists because the GLOBAL feed gate
   //--- cannot see a shut market on MT5: TimeCurrent() there keeps advancing
   //--- after the weekly close, while no quotes arrive. So the question has to
   //--- be asked per symbol, and answered from the monotonic clock.
   CopierSymbolQuoteReset();

   Ok("symfresh: an empty symbol name is not tracked",CopierSymbolQuoteAgeMs("")==0);
   Ok("symfresh: ...and is never reported stale",!CopierSymbolFeedStale("",60000));

   long a0=CopierSymbolQuoteAgeMs("CP_NOSUCHSYMBOL");
   Ok("symfresh: a symbol seen for the first time has no age yet",a0<20);

   //--- A symbol this terminal does not know can never produce a quote time,
   //--- so its age MUST grow. That is what proves the tracker measures elapsed
   //--- time rather than returning a constant.
   //---
   //--- The sleep is over a second because the age itself is memoised for one
   //--- second - the memo is what keeps this off the converge loop's hot path,
   //--- and it is also why a shorter wait would read the cached 0 and pass
   //--- for the wrong reason.
   Sleep(1100);
   long a1=CopierSymbolQuoteAgeMs("CP_NOSUCHSYMBOL");
   Ok("symfresh: ...and its age grows once the memo expires",a1>=1000);

   Ok("symfresh: a symbol that never quotes is held",
      CopierSymbolFeedStale("CP_NOSUCHSYMBOL",600));
   Ok("symfresh: ...but only past the threshold, not before it",
      !CopierSymbolFeedStale("CP_NOSUCHSYMBOL",60000));

   //--- reset must actually clear, or a re-attach would inherit the previous
   //--- run's timestamps and hold every symbol for a minute on arrival - which
   //--- looks exactly like a broken feed.
   CopierSymbolQuoteReset();
   Ok("symfresh: a reset clears the tracked age",
      CopierSymbolQuoteAgeMs("CP_NOSUCHSYMBOL")<20);

   //--- The CLOCK-IMPLIED age, which is what makes the gate bite on the first
   //--- pass instead of after a full stall window of doomed attempts.
   //---
   //--- Tested as a pure function because the real thing needs a shut market
   //--- on an MT5 terminal - and a test that only runs on a Sunday is a test
   //--- that never runs.
   long now=1780000000;                          // any fixed instant
   Ok("symfresh: the clock age is the gap in milliseconds",
      CopierClockAgeMs((datetime)(now-120),now)==120000);
   Ok("symfresh: a symbol quoting right now has no clock age",
      CopierClockAgeMs((datetime)now,now)==-1);
   Ok("symfresh: a quote in the FUTURE is not information, not a negative age",
      CopierClockAgeMs((datetime)(now+5),now)==-1);
   Ok("symfresh: a symbol with no quote time at all has no clock age",
      CopierClockAgeMs(0,now)==-1);
   Ok("symfresh: ...and an unmeasurable clock age does not make one stale",
      CopierSymbolFeedStale("CP_NOSUCHSYMBOL",60000)==false);
  }

void TestPingPayload()
  {
   //--- A probe is broadcast, so it carries no addressee - but it MUST name
   //--- the responder, because that is the only thing the originator can
   //--- attribute the echo by. An earlier version carried only TO, which was
   //--- empty on a broadcast, so the sender's own guard threw away every reply
   //--- it got and reported a healthy peer as permanently disconnected.
   string ping=CopierPayloadPing(123456,"252033316");

   string ms="",from="",to="";
   CopierKvGet(ping,"MS",ms);
   CopierKvGet(ping,"FROM",from);
   CopierKvGet(ping,"TO",to);
   Ok("ping: carries the probe number",CopierParseLong(ms)==123456);
   Ok("ping: names the responder",from=="252033316");
   Ok("ping: needs no addressee",to=="");

   //--- the echo: same number, responder named, addressee echoed back
   string pong=CopierPayloadPong(123456,"252034803","252033316");
   ms=""; from=""; to="";
   CopierKvGet(pong,"MS",ms);
   CopierKvGet(pong,"FROM",from);
   CopierKvGet(pong,"TO",to);
   Ok("pong: echoes the probe number",CopierParseLong(ms)==123456);
   Ok("pong: names the RESPONDER, so it can be attributed",from=="252034803");
   Ok("pong: addresses the asker, so others ignore it",to=="252033316");

   //--- the exact shape that was broken: a broadcast probe answered without
   //--- an addressee. FROM must still be present, or nothing can be matched.
   string pong2=CopierPayloadPong(99,"252034803","");
   from=""; to="";
   CopierKvGet(pong2,"FROM",from);
   CopierKvGet(pong2,"TO",to);
   Ok("pong: a broadcast probe still yields an attributable reply",
      from=="252034803" && to=="");

   //--- WHICH FIELD NAMES THE PEER. A receiver pings with FROM=itself; the
   //--- sender answers with FROM=itself, TO=the receiver. Naming the peer by
   //--- TO therefore registered the receiver under ITS OWN account, so the
   //--- panel listed itself as a second, silent "sender" beside the real one.
   //--- The peer is always the RESPONDER - FROM - and TO is only a filter.
   string us="252034803";          // the receiver asking
   string sender="252033316";      // the sender answering
   string reply=CopierPayloadPong(7,sender,us);

   from=""; to="";
   CopierKvGet(reply,"FROM",from);
   CopierKvGet(reply,"TO",to);
   Ok("peer name: comes from FROM (the responder)",from==sender);
   Ok("peer name: TO is only the filter, and is us",to==us);
   Ok("peer name: FROM and TO are genuinely different here",from!=to);
  }

void TestParseLongAndMs()
  {
   //--- StringToInteger is 32-bit on MQL4 and 64-bit on MQL5. A tick count
   //--- passes 2^31 after ~25 days of uptime, so on the narrow platform it
   //--- would wrap and the link-delay arithmetic would turn into noise on a
   //--- VPS that had simply been up a long time - looking exactly like a
   //--- network fault. The hand-rolled parse must not care.
   Ok("parse: an ordinary number",CopierParseLong("12345")==12345);
   Ok("parse: zero",CopierParseLong("0")==0);
   Ok("parse: empty is zero",CopierParseLong("")==0);
   Ok("parse: trailing junk stops the parse",CopierParseLong("42abc")==42);

   //--- 2^31 exactly: the first value a 32-bit parse gets wrong
   Ok("parse: 2147483648 does NOT wrap negative",
      CopierParseLong("2147483648")==2147483648);
   //--- a tick count from a machine up for 300 days
   Ok("parse: 25920000000 survives",
      CopierParseLong("25920000000")==25920000000);
   Ok("parse: negative is handled",CopierParseLong("-1234")==-1234);

   //--- the millisecond stamp must survive the envelope round trip, or the
   //--- delay estimate silently reads a garbage number
   CopierEnv e;
   e.v=CP_PROTO_V;
   e.sid="5555";
   e.ssid="ABC";
   e.seq=7;
   e.ts=1791417600;
   e.ms=25920000000;
   e.type=CP_T_HBT;
   e.payload="X=1";

   CopierEnv back;
   Ok("ms: the envelope decodes",CopierDecodeEnv(CopierEncodeEnv(e),back)
      ==CP_ERR_NONE);
   Ok("ms: ...with the millisecond stamp intact",back.ms==25920000000);
   Ok("ms: ...and the second stamp too",back.ts==1791417600);
   Ok("ms: ...and the type",back.type==CP_T_HBT);
  }

void TestBarCounting()
  {
   //--- M1 bar opens, newest first, exactly as the terminal reports them
   datetime t[5];
   t[0]=1000;   // the bar currently forming
   t[1]=940;
   t[2]=880;
   t[3]=820;
   t[4]=760;

   //--- a reference inside the current bar: no LATER bar has opened yet
   Ok("bars: none formed since the current bar opened",
      CopierCountBarsAfter(t,5,1000,5)==0);
   //--- a reference inside the previous bar: exactly one has opened after it
   Ok("bars: one formed since the previous bar opened",
      CopierCountBarsAfter(t,5,940,5)==1);
   Ok("bars: two formed",CopierCountBarsAfter(t,5,880,5)==2);

   //--- the cap ends the walk early, which is the whole optimisation: callers
   //--- only ever ask "has it reached N?"
   Ok("bars: a cap of 2 stops at 2",CopierCountBarsAfter(t,5,760,2)==2);

   //--- unusable inputs report 0, and callers must read that as "cannot
   //--- measure" rather than "no time has passed"
   Ok("bars: a zero reference reports 0",CopierCountBarsAfter(t,5,0,5)==0);
   Ok("bars: a zero cap reports 0",CopierCountBarsAfter(t,5,760,0)==0);

   //--- a hole in the history stops the walk instead of miscounting past it
   datetime g[3];
   g[0]=1000;
   g[1]=0;
   g[2]=880;
   Ok("bars: a missing bar time stops the walk",
      CopierCountBarsAfter(g,3,880,3)==1);
  }

void TestSecText()
  {
   //--- A duration formatter that quietly returns the wrong SCALE is worse
   //--- than none: "waiting for 2s" on a 60s setting made a working feature
   //--- look broken. These pin the scale at every boundary.
   Ok("dur: under a minute is seconds",CopierSecText(45)=="45s");
   Ok("dur: 60s rolls into minutes",CopierSecText(60)=="1m 0s");
   Ok("dur: minutes carry a seconds remainder",CopierSecText(90)=="1m 30s");
   Ok("dur: an hour rolls into hours",CopierSecText(3600)=="1h 0m");
   Ok("dur: 90000s is a day and an hour",CopierSecText(90000)=="1d 1h");
   Ok("dur: negative clamps to zero",CopierSecText(-5)=="0s");
   Ok("dur: zero is zero",CopierSecText(0)=="0s");
  }

void TestInvertedStop()
  {
   //--- sender BUY @1.1000, SL 1.0950 (50 pips against), TP 1.1100 (100 with)
   //--- our mirror is a SELL @2.0000 because the direction is inverted.
   //---
   //--- The two sides lose and gain at OPPOSITE prices, so inverting swaps
   //--- which of the sender's levels feeds which of ours.
   double feedSl,feedTp;

   //--- not inverted: the roles pass straight through
   CopierMapInvertedStops(false,1.0950,1.1100,feedSl,feedTp);
   Ok("invert: un-inverted, our stop feeds from the sender's SL",
      feedSl==1.0950 && feedTp==1.1100);

   //--- inverted: they SWAP
   CopierMapInvertedStops(true,1.0950,1.1100,feedSl,feedTp);
   Ok("invert: our stop feeds from the sender's TARGET",feedSl==1.1100);
   Ok("invert: our target feeds from the sender's STOP",feedTp==1.0950);

   //--- end to end on our own entry
   double sl=CopierMirrorStopInverted(feedSl,1.1000,2.0000,CP_SIDE_SELL,true);
   double tp=CopierMirrorStopInverted(feedTp,1.1000,2.0000,CP_SIDE_SELL,false);

   Ok("invert: a sell's stop lands ABOVE our entry",sl>2.0000);
   Ok("invert: ...at the sender's 100-pip REWARD distance",
      MathAbs((sl-2.0000)-0.0100)<0.0000001);
   Ok("invert: a sell's target lands BELOW our entry",tp<2.0000);
   Ok("invert: ...at the sender's 50-pip RISK distance",
      MathAbs((2.0000-tp)-0.0050)<0.0000001);

   //--- THE MISTAKE this pins. Without the swap our stop sits at the sender's
   //--- RISK distance instead of its reward - so the mirror is stopped out at
   //--- exactly the price where the sender banks its profit. Both numbers look
   //--- perfectly plausible on their own, which is why it survived review.
   double unswapped=CopierMirrorStopInverted(1.0950,1.1000,2.0000,
                                             CP_SIDE_SELL,true);
   Ok("invert: the UNSWAPPED stop sits at the sender's risk distance",
      MathAbs((unswapped-2.0000)-0.0050)<0.0000001);
   Ok("invert: ...and is therefore NOT what we place",unswapped!=sl);

   //--- the primitive still refuses a stop on the wrong side of its own entry,
   //--- which is why the magnitude variant exists at all
   Ok("invert: the ordinary mirror would drop such a stop entirely",
      CopierMirrorStop(1.0950,1.1000,2.0000,CP_SIDE_SELL,true)==0.0);
  }

void TestTradingTimes()
  {
   CopierTradingTimes t;

   //--- blank = no restriction at all
   t.Set("","");
   Ok("hours: blank is inactive",!t.Active());
   Ok("hours: blank allows any time",t.Allows(0));

   //--- 1970-01-01 was a Thursday, so day 0 = Thu, day 4 = Monday.
   datetime monMidnight=(datetime)(86400*4);       // Monday 00:00

   t.Set("08:00-17:00","");
   Ok("hours: a weekday window is active",t.Active());
   Ok("hours: inside the window is allowed",
      t.Allows(monMidnight+10*3600));
   Ok("hours: after the window is refused",
      !t.Allows(monMidnight+18*3600));

   //--- THE classic bug: an end before the start WRAPS past midnight. Read as
   //--- an empty range it would forbid trading during exactly the hours it was
   //--- written to permit.
   t.Set("22:00-02:00","");
   Ok("hours: a wrapping range allows late evening",
      t.Allows(monMidnight+23*3600));
   Ok("hours: ...and the small hours of the next day",
      t.Allows(monMidnight+1*3600));
   Ok("hours: ...but not the middle of the day",
      !t.Allows(monMidnight+12*3600));

   //--- 00:00-00:00 is the natural way to write "always"
   t.Set("00:00-00:00","");
   Ok("hours: an equal-start-end range means all day",
      t.Allows(monMidnight+3*3600) && t.Allows(monMidnight+21*3600));

   //--- a named day REPLACES the blanket list rather than adding to it, and
   //--- naming it with no range CLOSES that day
   t.Set("08:00-17:00","Mon=;Tue=08:00-17:00");
   Ok("hours: a named day with no range is closed",
      !t.Allows(monMidnight+10*3600));
   Ok("hours: another named day still works",
      t.Allows((datetime)(86400*5)+10*3600));    // Tuesday
   //--- a day NOT named falls back to the blanket list
   Ok("hours: an unnamed day uses the blanket list",
      t.Allows((datetime)(86400*3)+10*3600));    // Wednesday
  }

void TestCopierList()
  {
   CopierList l;

   //--- blank = no filtering. It must NOT mean "deny everything": blank is
   //--- the default, and a fresh install that mirrors nothing would look
   //--- broken in the least diagnosable way.
   l.Set("");
   Ok("filter: blank is inactive",!l.Active());
   Ok("filter: blank permits everything",l.Allows("EURUSD"));

   //--- allowlist
   l.Set("EURUSD,GBPUSD");
   Ok("filter: an allowlist admits a listed symbol",l.Allows("EURUSD"));
   Ok("filter: ...and rejects an unlisted one",!l.Allows("USDJPY"));

   //--- denylist
   l.Set("!EURUSD,GBPUSD");
   Ok("filter: '!' inverts to a denylist",!l.Allows("EURUSD"));
   Ok("filter: ...admitting everything else",l.Allows("USDJPY"));

   //--- spaces are trimmed, or " EURUSD , GBPUSD " silently matches nothing
   l.Set("  EURUSD ,  GBPUSD  ");
   Ok("filter: surrounding spaces are trimmed",l.Allows("EURUSD"));
   Ok("filter: empty items are tolerated",l.Allows("GBPUSD"));

   //--- case SENSITIVE on purpose: the terminal treats EURUSD and eurusd as
   //--- different strings, so a list that looks right must not match loosely
   l.Set("EURUSD");
   Ok("filter: matching is case-sensitive",!l.Allows("eurusd"));

   //--- "!" alone is an empty denylist, i.e. permit everything
   l.Set("!");
   Ok("filter: a lone '!' filters nothing",l.Allows("EURUSD"));

   //--- THE COMMON MISREADING: people write "!A,!B" meaning "exclude both".
   //--- Taken literally the second item is a symbol named "!B", which matches
   //--- nothing, so B is NOT excluded and nothing anywhere says so.
   l.Set("!EURUSD,!GBPUSD");
   Ok("filter: a stray '!' on an item is reported",l.StrayBangs()==1);
   Ok("filter: ...and the item still excludes what was meant",
      !l.Allows("GBPUSD"));
   Ok("filter: ...and the list is still a denylist",l.Allows("USDJPY"));

   //--- and the correct spelling reports nothing
   l.Set("!EURUSD,GBPUSD");
   Ok("filter: the correct spelling reports no stray '!'",
      l.StrayBangs()==0);
   Ok("filter: ...and excludes both",!l.Allows("EURUSD") && !l.Allows("GBPUSD"));

   //--- an accept-list with a stray '!' - also tolerated, also reported
   l.Set("EURUSD,!GBPUSD");
   Ok("filter: a stray '!' in an accept list is reported too",
      l.StrayBangs()==1);
   Ok("filter: ...and both symbols are admitted",l.Allows("EURUSD") && l.Allows("GBPUSD"));

   //--- The SAME class backs PermittedMagic, where the items are bare magic
   //--- numbers instead of symbol names. Two properties are worth pinning down
   //--- precisely because the item is a NUMBER, where both are easy to get
   //--- wrong and neither failure is visible:
   //---
   //---   * matching must be EXACT. A prefix match would let a list holding
   //---     54321 also admit 543210 - a different magic entirely, and one the
   //---     operator never wrote.
   //---   * magic 0 is a REAL magic (manual trades), not "empty". If it were
   //---     treated as absent, a list written to include manual trades would
   //---     silently exclude them.
   l.Set("54321,56789");
   Ok("magic: a listed magic is admitted",l.Allows("54321"));
   Ok("magic: an unlisted magic is rejected",!l.Allows("77889"));
   Ok("magic: matching is EXACT, not a prefix",!l.Allows("543210"));
   Ok("magic: an unlisted zero is rejected",!l.Allows("0"));
   l.Set("0,54321");
   Ok("magic: zero can be listed explicitly",l.Allows("0"));
   l.Set("!77889,998877");
   Ok("magic: '!' inverts to a denylist",!l.Allows("77889"));
   Ok("magic: ...admitting everything else",l.Allows("54321"));
   Ok("magic: ...including zero",l.Allows("0"));
  }

void TestEndpointNormalize()
  {
   //--- "host:port" must work without the scheme, and an explicit scheme must
   //--- survive untouched - overwriting it would break a future ipc:// or
   //--- inproc:// endpoint, which is the whole reason the check is "has a
   //--- scheme" rather than "starts with tcp://".
   Ok("endpoint: a bare host:port gains tcp://",
      CopierNormalizeEndpoint("10.0.0.5:5555")=="tcp://10.0.0.5:5555");
   Ok("endpoint: a bare * gains tcp://",
      CopierNormalizeEndpoint("*")=="tcp://*");
   Ok("endpoint: an explicit tcp:// is left alone",
      CopierNormalizeEndpoint("tcp://10.0.0.5:5555")=="tcp://10.0.0.5:5555");
   Ok("endpoint: another scheme is NOT rewritten",
      CopierNormalizeEndpoint("ipc:///tmp/x")=="ipc:///tmp/x");
   Ok("endpoint: surrounding spaces are trimmed",
      CopierNormalizeEndpoint("  10.0.0.5:5555  ")=="tcp://10.0.0.5:5555");
   Ok("endpoint: empty stays empty",CopierNormalizeEndpoint("")=="");
  }

void TestBackoff()
  {
   //--- The ladder is a decision, not an accident. Asserting its shape means
   //--- a later "simplification" back to one fixed retry gap has to argue
   //--- with a test rather than quietly reintroduce the request flood.
   Ok("backoff: the first refusal retries in 2s",CopierBackoffMs(1)==2000);
   Ok("backoff: it climbs to an hour by the fifth",
      CopierBackoffMs(5)==60*60*1000);
   Ok("backoff: and tops out at a day - long, but never permanent",
      CopierBackoffMs(8)==24*60*60*1000
      && CopierBackoffMs(99)==24*60*60*1000);
   Ok("backoff: every step is longer than the one before",
      CopierBackoffMs(2)>CopierBackoffMs(1)
      && CopierBackoffMs(3)>CopierBackoffMs(2)
      && CopierBackoffMs(4)>CopierBackoffMs(3)
      && CopierBackoffMs(5)>CopierBackoffMs(4)
      && CopierBackoffMs(6)>CopierBackoffMs(5)
      && CopierBackoffMs(7)>CopierBackoffMs(6)
      && CopierBackoffMs(8)>CopierBackoffMs(7));

   //--- and the state machine around it
   CopierBackoff b;
   Ok("backoff: a fresh key is not parked",!b.Blocked("k"));
   Ok("backoff: the first failure counts as one",b.Note("k")==1);
   Ok("backoff: ...and parks the key",b.Blocked("k"));
   Ok("backoff: a second failure escalates to two",b.Note("k")==2);
   b.Clear("k");
   Ok("backoff: success clears the ladder",
      !b.Blocked("k") && b.Count("k")==0);

   //--- Park: hold the key off WITHOUT climbing. For a failure that is not
   //--- the broker refusing the order - this terminal refusing to send - so
   //--- that fixing the cause takes effect immediately instead of after a
   //--- ladder that climbed to hours while the operator was away.
   CopierBackoff p;
   p.Park("x",2000);
   Ok("backoff: Park blocks the key",p.Blocked("x"));
   Ok("backoff: Park does NOT count a failure",p.Count("x")==0);
   //--- and repeatedly parking still never climbs
   p.Park("x",2000);
   p.Park("x",2000);
   Ok("backoff: repeated Park still never climbs",p.Count("x")==0);
   //--- a real failure on the same key afterwards starts from the bottom rung
   Ok("backoff: a genuine failure after Park starts at rung 1",
      p.Note("x")==1);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   //--- FILE_WRITE does not truncate, so clear it explicitly; otherwise a
   //--- re-run overwrites the head and leaves the previous tail behind,
   //--- which is unreadable and hides the current run's result.
   FileDelete("copier_selftest.log");
   g_log=FileOpen("copier_selftest.log",FILE_WRITE|FILE_TXT|FILE_ANSI);

   Print("=========== CopierSelfTest ===========");
   TestEnvelope();
   TestSanitize();
   TestSnapshot();
   TestUid();
   TestNid();
   TestIgnoreList();
   TestMt4FromTicket();
   TestSeenRing();
   TestPosTable();
   TestStateFile();
   TestSizing();
   TestConfig();
   TestDedup();
   TestSeenRingGating();
   TestSeenRingForget();
   TestMirrorStop();
   TestFitStop();
   TestRiskThresholds();
   TestRiskMessages();
   TestRiskCaps();
   TestRiskPendingProjection();
   TestRiskDailyAndDrawdown();
   TestPendingCodec();
   TestKindScopedKeys();
   TestMagicResolve();
   TestGuardKeyShape();
   TestSnapshotCapacity();
   TestBackoff();
   TestEndpointNormalize();
   TestCopierList();
   TestInvertedStop();
   TestSecText();
   TestBarCounting();
   TestParseLongAndMs();
   TestMarketClosedRetcode();
   TestNodeAnnounce();
   TestPeerLiveness();
   TestSymbolQuoteAge();
   TestPingPayload();
   TestLotMode();
   TestKvSuffixCollision();
   TestProfitTarget();
   TestTradingTimes();

   string summary="=========== "+ (g_fail==0 ? "ALL PASS" : "FAILURES") +"  pass="
                  +(string)g_pass+" fail="+(string)g_fail+" ===========";
   Print(summary);
   if(g_log!=INVALID_HANDLE)
     {
      FileWrite(g_log,summary);
      FileClose(g_log);
     }
  }
//+------------------------------------------------------------------+
