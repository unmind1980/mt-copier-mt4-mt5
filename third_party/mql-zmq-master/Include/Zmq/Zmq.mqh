//+------------------------------------------------------------------+
//| Module: Zmq.mqh                                                  |
//| This file is part of the mql-zmq project:                        |
//|     https://github.com/dingmaotu/mql-zmq                         |
//|                                                                  |
//| Copyright 2016-2017 Li Ding <dingmaotu@hotmail.com>              |
//|                                                                  |
//| Licensed under the Apache License, Version 2.0 (the "License");  |
//| you may not use this file except in compliance with the License. |
//| You may obtain a copy of the License at                          |
//|                                                                  |
//|     http://www.apache.org/licenses/LICENSE-2.0                   |
//|                                                                  |
//| Unless required by applicable law or agreed to in writing,       |
//| software distributed under the License is distributed on an      |
//| "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,     |
//| either express or implied.                                       |
//| See the License for the specific language governing permissions  |
//| and limitations under the License.                               |
//|                                                                  |
//| Updated to ZeroMQ 4.3.5 / libsodium 1.0.22.                      |
//| See CHANGELOG.md for the list of changes.                        |
//+------------------------------------------------------------------+
#property strict

#include <Mql/Lang/Native.mqh>
#include "AtomicCounter.mqh"
#include "Z85.mqh"
#include "Socket.mqh"
//+------------------------------------------------------------------+
//| Definitions from zmq.h                                           |
//+------------------------------------------------------------------+
//--- Version of ZeroMQ this binding is written against.
//--- Use Zmq::getVersion() to query the version of the loaded DLL.
#define ZMQ_VERSION_MAJOR 4
#define ZMQ_VERSION_MINOR 3
#define ZMQ_VERSION_PATCH 5

//--- Version of this binding (source), not of the DLL
#define ZMQ_BINDING_VERSION_MAJOR 2
#define ZMQ_BINDING_VERSION_MINOR 0
#define ZMQ_BINDING_VERSION_PATCH 0

#define ZMQ_HAS_CAPABILITIES 1

#import "libzmq.dll"
// Error code
int zmq_errno(void);
// Resolves system errors and 0MQ errors to human-readable string
intptr_t zmq_strerror(int errnum);
// Run-time API version detection
void zmq_version(int &major,int &minor,int &patch);
// Probe library capabilities
int zmq_has(const uchar &capability[]);
#import
//+------------------------------------------------------------------+
//| ZMQ global utilities                                             |
//+------------------------------------------------------------------+
class Zmq
  {
protected:
   static bool       has(string cap);
public:
   //--- Capabilities (transports)
   static bool       hasIpc() {return has("ipc");}    // ipc - the library supports the ipc:// protocol
   static bool       hasPgm() {return has("pgm");}    // pgm - the library supports the pgm:// protocol
   static bool       hasTipc() {return has("tipc");}; // tipc - the library supports the tipc:// protocol
   static bool       hasNorm() {return has("norm");}; // norm - the library supports the norm:// protocol
   static bool       hasWs() {return has("ws");};     // ws - the library supports the ws:// protocol
   static bool       hasWss() {return has("wss");};   // wss - the library supports the wss:// protocol
   //--- Capabilities (security mechanisms)
   static bool       hasCurve() {return has("curve");};   // curve - the library supports the CURVE security mechanism
   static bool       hasGssApi() {return has("gssapi");}; // gssapi - the library supports the GSSAPI security mechanism

   //--- Error handling
   static int        errorNumber() {return zmq_errno();}
   static string     errorMessage(int error=0);

   //--- Version of the loaded libzmq.dll
   static string     getVersion();
   static int        major();
   static int        minor();
   static int        patch();
   //--- Compare the runtime version with a required one
   static bool       isAtLeast(int required_major,int required_minor,int required_patch);
   //--- Version of this MQL binding
   static string     getBindingVersion();
  };
//+------------------------------------------------------------------+
//| Wrap zmq_has                                                     |
//+------------------------------------------------------------------+
bool Zmq::has(string cap)
  {
   uchar capstr[];
   StringToUtf8(cap,capstr);
   bool res=(ZMQ_HAS_CAPABILITIES==zmq_has(capstr));
   ArrayFree(capstr);
   return res;
  }
//+------------------------------------------------------------------+
//| Wraps zmq_strerror                                               |
//+------------------------------------------------------------------+
string Zmq::errorMessage(int error)
  {
   intptr_t ref=error>0?zmq_strerror(error):zmq_strerror(zmq_errno());
   return StringFromUtf8Pointer(ref);
  }
//+------------------------------------------------------------------+
//| Get version string of current zmq                                |
//+------------------------------------------------------------------+
string Zmq::getVersion(void)
  {
   int major,minor,patch;
   zmq_version(major,minor,patch);
   return StringFormat("%d.%d.%d", major, minor, patch);
  }
//+------------------------------------------------------------------+
//| Major version of the loaded libzmq.dll                           |
//+------------------------------------------------------------------+
int Zmq::major(void)
  {
   int major,minor,patch;
   zmq_version(major,minor,patch);
   return major;
  }
//+------------------------------------------------------------------+
//| Minor version of the loaded libzmq.dll                           |
//+------------------------------------------------------------------+
int Zmq::minor(void)
  {
   int major,minor,patch;
   zmq_version(major,minor,patch);
   return minor;
  }
//+------------------------------------------------------------------+
//| Patch version of the loaded libzmq.dll                           |
//+------------------------------------------------------------------+
int Zmq::patch(void)
  {
   int major,minor,patch;
   zmq_version(major,minor,patch);
   return patch;
  }
//+------------------------------------------------------------------+
//| Check that the loaded DLL is at least the required version.      |
//| Useful when the DLL is replaced without recompiling.             |
//+------------------------------------------------------------------+
bool Zmq::isAtLeast(int required_major,int required_minor,int required_patch)
  {
   int ma,mi,pa;
   zmq_version(ma,mi,pa);
   if(ma!=required_major) return ma>required_major;
   if(mi!=required_minor) return mi>required_minor;
   return pa>=required_patch;
  }
//+------------------------------------------------------------------+
//| Version of this MQL binding                                      |
//+------------------------------------------------------------------+
string Zmq::getBindingVersion(void)
  {
   return StringFormat("%d.%d.%d",
                       ZMQ_BINDING_VERSION_MAJOR,
                       ZMQ_BINDING_VERSION_MINOR,
                       ZMQ_BINDING_VERSION_PATCH);
  }
//+------------------------------------------------------------------+
