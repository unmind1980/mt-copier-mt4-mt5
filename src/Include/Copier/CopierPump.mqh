//+------------------------------------------------------------------+
//|                                                   CopierPump.mqh |
//| Native MQL zero-DLL high-priority event pump for sub-2ms latency |
//| Bypasses Windows WM_TIMER scheduling floor via EventChartCustom  |
//+------------------------------------------------------------------+
#property strict

#define CP_EVENT_PUMP_ID 1001

class CopierEventPump
  {
private:
   long              m_chartId;
   long              m_fastPumpUntil;
   bool              m_inFlight;

public:
                     CopierEventPump():m_chartId(0),m_fastPumpUntil(0),m_inFlight(false){}

   void              Init()
     {
      m_chartId=ChartID();
      m_fastPumpUntil=0;
      m_inFlight=false;
     }

   void              ArmFast(const int durationMs=500)
     {
      long until=CopierNowMs()+durationMs;
      if(until>m_fastPumpUntil) m_fastPumpUntil=until;
      Trigger();
     }

   void              Disarm()
     {
      m_fastPumpUntil=0;
     }

   bool              IsActive() const
     {
      return (CopierNowMs()<m_fastPumpUntil);
     }

   void              Trigger()
     {
      if(!m_inFlight && m_chartId!=0)
        {
         m_inFlight=true;
         EventChartCustom(m_chartId,CP_EVENT_PUMP_ID,0,0.0,"");
        }
     }

   bool              OnEvent(const int id)
     {
      if(id==CHARTEVENT_CUSTOM+CP_EVENT_PUMP_ID)
        {
         m_inFlight=false;
         return true;
        }
      return false;
     }
  };
