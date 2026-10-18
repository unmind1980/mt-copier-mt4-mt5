//+------------------------------------------------------------------+
//| CopierIgnore.mqh - "leave this one alone" list                   |
//|                                                                   |
//| WHY THIS EXISTS                                                  |
//|                                                                   |
//| The receiver converges BOTH ways: it closes what the sender no    |
//| longer holds, and it OPENS what the sender holds and the receiver |
//| does not. That symmetry is what makes it self-healing - a         |
//| receiver restart, a broker rejection, a message lost in a         |
//| reconnect all repair themselves from the next snapshot.           |
//|                                                                   |
//| The cost is that closing a mirrored position BY HAND looks exactly |
//| like "the receiver is missing a position the sender has", so it is |
//| faithfully restored a couple of seconds later. FX Blue does not do |
//| this because its convergence is one-directional - it only ever     |
//| closes, never re-opens - which is why a manual close sticks there, |
//| and also why it cannot recover from a missed entry.               |
//|                                                                   |
//| Turning the re-open off globally would throw away the recovery, so |
//| it is an opt-out PER POSITION instead, which is the same shape as  |
//| FX Blue's IgnoreExitSignalsForTicketIds.                          |
//|                                                                   |
//| WHY AN INPUT AND NOT A FILE                                      |
//|                                                                   |
//| This list used to live in MQL\Files\copier.ignore, re-read every   |
//| five seconds. That bought hot editing, and cost three things:      |
//|                                                                   |
//|   * a file the operator had to find, on the machine running the    |
//|     terminal - which is not the machine they are usually sitting   |
//|     in front of;                                                  |
//|   * a silent failure mode. A uid typed with the wrong case, or     |
//|     with a stray character, simply never matched, and nothing      |
//|     anywhere said so - the position was managed anyway;            |
//|   * a second configuration surface to keep in sync with the        |
//|     inputs, for a list that is almost always empty.                |
//|                                                                   |
//| It is now the IgnoreUids input. Changing an input re-runs OnInit,  |
//| so an edit still takes effect without touching the chart - which   |
//| was the only thing the file was actually buying.                   |
//|                                                                   |
//| FORMAT                                                            |
//|                                                                   |
//|     IgnoreUids = "ABCD1234,EFGH5678"                              |
//|                                                                   |
//| Comma, semicolon, pipe or whitespace separated - all four work, so |
//| a list pasted from anywhere lands correctly. Case is ignored (the  |
//| alphabet is uppercase and it is uppercased on the way in).         |
//|                                                                   |
//| The UID is the 8 characters after "tc|" in the receiver's order    |
//| comment, and it is also in every "exec open" line of the log.      |
//|                                                                   |
//| Anything that is NOT a well-formed uid is REJECTED AND COUNTED     |
//| rather than ignored, so the caller can say so at startup. A uid    |
//| the operator typed and the copier silently dropped is the exact    |
//| failure this list exists to prevent.                               |
//|                                                                   |
//| A listed position is neither opened nor closed by the copier; it   |
//| is yours to manage.                                                |
//+------------------------------------------------------------------+
#property strict
#ifndef __COPIER_IGNORE_MQH__
#define __COPIER_IGNORE_MQH__

#include "CopierDefs.mqh"

//--- How many rejected entries are NAMED in the startup warning before it
//--- collapses the rest into "and N more". The count is always complete.
#define CP_IGNORE_BAD_SHOW 4

class CopierIgnore
  {
private:
   string            m_uid[CP_MAX_IGNORE];
   int               m_n;
   string            m_bad[CP_IGNORE_BAD_SHOW];  // malformed entries, first few
   int               m_badN;                     // malformed entries, total
   int               m_badShow;                  // how many of m_bad are filled
   int               m_overN;                    // well-formed, but the list was full

   bool              IsSep(const string ch) const
     {
      if(ch=="," || ch==";" || ch=="|") return true;
      if(ch==" " || ch=="\t" || ch=="\r" || ch=="\n") return true;
      return false;
     }

   void              NoteBad(const string tok)
     {
      m_badN++;
      if(m_badShow<CP_IGNORE_BAD_SHOW)
        {
         m_bad[m_badShow]=tok;
         m_badShow++;
        }
     }

   void              AddToken(const string raw)
     {
      string u=CopierTrim(raw);
      if(StringLen(u)==0) return;          // tolerate "A,,B" and a trailing separator

      //--- Uppercase FIRST. The alphabet is uppercase and an operator reading a
      //--- uid off a chart or out of the log will not reliably reproduce the
      //--- case. Rejecting a correctly-spelled uid over case would be pure
      //--- friction, and there is nothing to be ambiguous about.
      //---
      //--- StringToUpper modifies the string in-place by reference in MQL4/MQL5.
      StringToUpper(u);

      if(!CopierUidValid(u))
        {
         NoteBad(u);
         return;
        }
      for(int i=0;i<m_n;i++)
        {
         if(m_uid[i]==u) return;           // a repeat is harmless; do not double-count
        }
      if(m_n>=CP_MAX_IGNORE)
        {
         //--- Well-formed, but there is no room. Counted separately from a
         //--- malformed entry because the fix is different (shorten the list,
         //--- not correct a typo), and both must be reported - a dropped entry
         //--- is a position that will be managed when it was not meant to be.
         m_overN++;
         return;
        }
      m_uid[m_n]=u;
      m_n++;
     }

public:
                     CopierIgnore():m_n(0),m_badN(0),m_badShow(0),m_overN(0)
     {
      for(int i=0;i<CP_IGNORE_BAD_SHOW;i++) m_bad[i]="";
     }

   int               Count()      const { return m_n; }
   int               BadCount()   const { return m_badN; }
   int               OverCount()  const { return m_overN; }

   //--- The rejected entries, named, for the caller to print. Names only the
   //--- first CP_IGNORE_BAD_SHOW and then says how many more there were, so a
   //--- pasted wall of garbage cannot produce an unbounded log line.
   string            BadList() const
     {
      string s="";
      for(int i=0;i<m_badShow;i++)
        {
         if(StringLen(s)>0) s+=", ";
         s+="\""+m_bad[i]+"\"";
        }
      if(m_badN>m_badShow)
         s+=" and "+(string)(m_badN-m_badShow)+" more";
      return s;
     }

   bool              Has(const string uid) const
     {
      if(StringLen(uid)==0) return false;
      for(int i=0;i<m_n;i++)
        {
         if(m_uid[i]==uid) return true;
        }
      return false;
     }

   //--- Parse the input text. Returns the number of uids accepted.
   //---
   //--- Replaces the whole list rather than merging: the input is the only
   //--- source now, so "what is in the field" and "what the copier ignores"
   //--- must be the same set. Merging would make them diverge silently.
   int               SetText(const string text)
     {
      m_n=0;
      m_badN=0;
      m_badShow=0;
      m_overN=0;
      for(int i=0;i<CP_IGNORE_BAD_SHOW;i++) m_bad[i]="";

      string cur="";
      int len=StringLen(text);
      for(int i=0;i<len;i++)
        {
         string ch=StringSubstr(text,i,1);
         if(IsSep(ch))
           {
            AddToken(cur);
            cur="";
            continue;
           }
         cur+=ch;
        }
      AddToken(cur);                       // the last token has no separator after it
      return m_n;
     }
  };

#endif
//+------------------------------------------------------------------+
