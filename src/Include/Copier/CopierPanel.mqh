//+------------------------------------------------------------------+
// CopierPanel.mqh - the on-chart status panel
//
// Why a filled rectangle and not just text: the chart underneath has candles,
// grid lines, indicators and often a coloured background of its own. Text
// drawn straight onto it is unreadable in exactly the situation the panel
// exists for - a quick glance at a busy chart. OBJ_RECTANGLE_LABEL is the one
// chart object that carries its own FILL (OBJPROP_BGCOLOR), so the panel is
// opaque by construction rather than by hoping the chart is quiet.
//
// The rectangle is also drawn in the FOREGROUND (OBJPROP_BACK=false) so the
// candles cannot paint over the text.
//
// Everything is fixed-size and reused: the objects are created once and their
// text is rewritten in place. Creating objects on every tick is the classic
// way to make a terminal crawl, and deleting/recreating them makes the panel
// flicker.
//+------------------------------------------------------------------+
#ifndef __COPIER_PANEL_MQH__
#define __COPIER_PANEL_MQH__

#include <Copier/CopierDefs.mqh>

#define CP_PANEL_MAX_ROWS 24

//--- How many orphaned positions are listed by name before the panel
//--- collapses the rest into "and N more". The count itself is always
//--- shown; this only bounds the detail lines so a bad config cannot push
//--- the panel past CP_PANEL_MAX_ROWS and silently drop the rows BELOW it
//--- (the peer list, the risk line) - which are the ones that explain why.
#define CP_PANEL_ORPHAN_SHOW 5
//--- How many peer rows are printed in detail before the rest collapse.
//--- With CP_MAX_SENDERS at 100 the peer list can be 100 rows, and the panel
//--- is a rectangle on a chart: Begin() clamps to CP_PANEL_MAX_ROWS, so rows
//--- past it were dropped with nothing on screen to say so. EIGHT keeps the
//--- block readable while the "Peers connected: N" line above stays the truth,
//--- and the counterpart summary line names the rest. A truncated list is only
//--- a problem when it is SILENT - that is the thing this fixes.
#define CP_PANEL_PEER_SHOW 8

class CopierPanel
  {
private:
   string            m_pfx;
   int               m_x,m_y,m_w;
   int               m_rowH;
   int               m_rows;      // rows currently in use
   int               m_made;      // rows whose objects exist
   bool              m_ready;

   string            BgName() const { return m_pfx+"_bg"; }
   string            RowName(const int i) const { return m_pfx+"_r"+(string)i; }

   void              MakeRow(const int i)
     {
      string nm=RowName(i);
      if(ObjectFind(0,nm)<0)
        {
         ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
         //--- Give it text IMMEDIATELY. A freshly created OBJ_LABEL carries
         //--- the default description, and MT5 RENDERS that default - so a row
         //--- that exists but has not been written yet shows the literal word
         //--- "Label" on the chart. MT4 does not, which is why this only ever
         //--- appeared on one platform. A single space is invisible and is not
         //--- the default, so it is safe in both.
         ObjectSetString(0,nm,OBJPROP_TEXT," ");
        }
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,m_x+10);
      ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,m_y+8+i*m_rowH);
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);
     }

public:
                     CopierPanel():m_x(10),m_y(20),m_w(430),m_rowH(15),
                                   m_rows(0),m_made(0),m_ready(false) {}

   bool              Ready() const { return m_ready; }

   //--- Called once. Creates the background; rows are created lazily as the
   //--- caller asks for them, so a panel that grows does not pay for rows it
   //--- never uses.
   void              Init(const string prefix,const int x,const int y,
                          const int width)
     {
      m_pfx=prefix;
      m_x=x;
      m_y=y;
      m_w=width;
      m_ready=true;
     }

   void              Destroy()
     {
      // P2-17: Guard against empty m_pfx deleting all chart objects on uninitialized Destroy()
      if(m_ready && StringLen(m_pfx)>0)
        {
         ObjectsDeleteAll(0,m_pfx);
        }
      m_made=0;
      m_rows=0;
      m_ready=false;
     }

   //--- Start a frame: `rows` is how many the caller is about to write.
   void              Begin(const int rows)
     {
      if(!m_ready) return;
      m_rows=(rows>CP_PANEL_MAX_ROWS)?CP_PANEL_MAX_ROWS:rows;

      //--- grow the background to fit, and keep it behind every row
      int h=16+m_rows*m_rowH;
      string bg=BgName();
      if(ObjectFind(0,bg)<0)
         ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,m_x);
      ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,m_y);
      ObjectSetInteger(0,bg,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,CP_PANEL_BG);
      ObjectSetInteger(0,bg,OBJPROP_COLOR,CP_PANEL_BORDER);
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,bg,OBJPROP_BACK,false);
     }

   //--- One row. `c` is the text colour - used to make a stale link red
   //--- without needing a separate status column.
   void              Row(const int i,const string text,const color c)
     {
      if(!m_ready || i<0 || i>=m_rows) return;
      while(m_made<=i)
        {
         MakeRow(m_made);
         m_made++;
        }
      string nm=RowName(i);
      ObjectSetString(0,nm,OBJPROP_TEXT,text);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
     }

   //--- Hide rows left over from a frame that had more of them.
   void              End()
     {
      if(!m_ready) return;
      for(int i=m_rows;i<m_made;i++)
        {
         string nm=RowName(i);
         //--- a SPACE, never an empty string: MT5 falls back to the object's
         //--- default description ("Label") when the text is empty, so
         //--- "clearing" a row would put the word back on the chart.
         if(ObjectFind(0,nm)>=0) ObjectSetString(0,nm,OBJPROP_TEXT," ");
        }
      ChartRedraw(0);
     }
  };

#endif
//+------------------------------------------------------------------+
