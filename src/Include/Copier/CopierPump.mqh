//+------------------------------------------------------------------+
//|                                                   CopierPump.mqh |
//| Native MQL zero-DLL bounded event pump (A + B circuit breaker)   |
//| Bypasses WM_TIMER floor with max burst cap & hard timeout        |
//+------------------------------------------------------------------+
#property strict

#define CP_EVENT_PUMP_ID   1001
#define CP_PUMP_BURST_MAX  500  // Generous burst ceiling so loopback PONG (0.4-1.2ms) is never truncated prematurely
#define CP_PUMP_TIMEOUT_MS 15   // Hard time ceiling in ms (15ms every 5s = max 0.3% CPU even if all packets dropped)

class CopierEventPump
  {
private:
   long              m_chartId;
   long              m_fastPumpUntil;
   int               m_burstCount;
   bool              m_inFlight;

public:
                     CopierEventPump():m_chartId(0),m_fastPumpUntil(0),m_burstCount(0),m_inFlight(false){}

   void              Init()
     {
      m_chartId=ChartID();
      m_fastPumpUntil=0;
      m_burstCount=0;
      m_inFlight=false;
     }

   //--- Arm a short-lived fast burst (capped at CP_PUMP_TIMEOUT_MS)
   void              ArmFast(const int timeoutMs=CP_PUMP_TIMEOUT_MS)
     {
      int effectiveTimeout=timeoutMs;
      if(effectiveTimeout<=0 || effectiveTimeout>CP_PUMP_TIMEOUT_MS)
         effectiveTimeout=CP_PUMP_TIMEOUT_MS;
      long until=CopierNowMs()+effectiveTimeout;
      if(until>m_fastPumpUntil) m_fastPumpUntil=until;
      m_burstCount=0; // Reset burst counter for new intent
      Trigger();
     }

   void              Disarm()
     {
      m_fastPumpUntil=0;
      m_burstCount=0;
     }

   bool              IsActive() const
     {
      return (CopierNowMs()<m_fastPumpUntil && m_burstCount<CP_PUMP_BURST_MAX);
     }

   void              Trigger()
     {
      if(!m_inFlight && m_chartId!=0 && IsActive())
        {
         m_inFlight=true;
         m_burstCount++;
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
