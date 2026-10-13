# mql-zmq (updated for libzmq 4.3.5 / libsodium 1.0.22)

ZMQ binding for the MQL language (both 32bit MT4 and 64bit MT5)

* [1. Introduction](#introduction)
* [2. What changed in this release](#what-changed-in-this-release)
* [3. Files and Installation](#files-and-installation)
* [4. About string encoding](#about-string-encoding)
* [5. Notes on context creation](#notes-on-context-creation)
* [6. Usage](#usage)
* [7. Building the DLLs yourself](#building-the-dlls-yourself)
* [8. TODO](#todo)
* [9. Changes](#changes)
* [10. Credits and License](#credits-and-license)

## Introduction

This is a complete binding of the [ZeroMQ](http://zeromq.org/) library
for the MQL4/5 language provided by MetaTrader4/5.

Traders with programming abilities have always wanted a messaging solution like
ZeroMQ, simple and powerful, far better than the PIPE trick as suggested by the
official articles. However, bindings for MQL were either outdated or not
complete (mostly toy projects and only basic features are implemented).

This is an updated fork of [dingmaotu/mql-zmq](https://github.com/dingmaotu/mql-zmq).
The upstream project was frozen at ZeroMQ 4.2.0 / libsodium 1.0.11. This version
rebases the binding on:

| component  | upstream version | this version |
|------------|------------------|--------------|
| libzmq     | 4.2.0            | **4.3.5**    |
| libsodium  | 1.0.11           | **1.0.22**   |

The MQL source is kept source compatible with the 1.5 release: code written
against the old binding compiles unchanged.

This binding tries to remain compatible between MQL4/5. Users of both versions
can use this binding, with a single set of headers. MQL4 and MQL5 are basically
the same in that they are merged in recent versions. The difference is in the
runtime environment (MetaTrader5 is 64bit by default, while MetaTrader4 is
32bit). The trading system is also different, but it is no concern of this
binding.

## What changed in this release

1. **New DLLs.** `Library/MT4/libzmq.dll` (32bit) and `Library/MT5/libzmq.dll`
   (64bit) are built from the official libzmq 4.3.5 and libsodium 1.0.22
   sources with MinGW-w64. libsodium is linked **statically**, so there is no
   second DLL to deploy and **no Visual C++ runtime is required** any more.

2. **DRAFT API enabled, CURVE enabled.** The shipped DLLs are configured with
   `--enable-drafts` (exposes the 4.3.x draft socket types `ZMQ_SERVER`,
   `ZMQ_CLIENT`, `ZMQ_RADIO`, `ZMQ_DISH`, `ZMQ_SCATTER`, `ZMQ_GATHER`,
   `ZMQ_DGRAM`, `ZMQ_PEER`, `ZMQ_CHANNEL` and the draft socket options) and
   `--enable-curve --with-libsodium` (CURVE security). Draft options are marked
   as such in `Include/Zmq/SocketOptions.mqh`. Note that draft *declarations*
   are hidden behind `#define ZMQ_BUILD_DRAFT_API` for C consumers of `zmq.h`;
   `build/smoke-test.c` shows how.

   `--enable-drafts` only affects which symbols are exported. A draft socket
   type will still return `EINVAL` if the library was built without draft
   support, so check `Zmq::isAtLeast()` and `Zmq::hasCurve()` at startup.

3. **New API in the binding.**
   * `zmq_socket_monitor_versioned` -> `Socket::monitorVersioned(addr, events,
     version, type)`. **Careful:** the C prototype takes **five** parameters,
     not four — `(void *s, const char *addr, uint64_t events, int
     event_version, int type)`. The trailing `type` is the monitor socket type
     (`0` = `ZMQ_PAIR`, which is what `zmq_socket_monitor` uses). A four
     argument call compiles but returns `EINVAL` at runtime.
   * `Zmq::hasWs()`, `Zmq::hasWss()`, `Zmq::major()/minor()/patch()`,
     `Zmq::isAtLeast(...)`, `Zmq::getBindingVersion()`
   * `Context::getMsgTSize()`, `Context::setThreadNamePrefix(...)`,
     `Context::addThreadAffinity(...)`, `Context::removeThreadAffinity(...)`
   * New socket option constants 90-124 and their typed wrappers
     (`setHelloMessage`, `setDisconnectMessage`, `setPriority`,
     `setBusyPoll`, `setInBatchSize`, `setOutBatchSize`, `setReconnectStop`,
     `setRouterNotify`, `setSocksUsername`, `setSocksPassword`,
     `setOnlyFirstSubscribe`, `setZapEnforceDomain`, `getTopicsCount`, ...)
   * `ZMQ_ROUTING_ID` / `ZMQ_CONNECT_ROUTING_ID` (4.3.x names) next to the
     deprecated `ZMQ_IDENTITY` / `ZMQ_CONNECT_RID` aliases
   * New monitor events `ZMQ_EVENT_HANDSHAKE_FAILED_*`,
     `ZMQ_EVENT_HANDSHAKE_SUCCEEDED`, `ZMQ_EVENT_PIPES_STATS`

4. **Housekeeping.** All include files are now UTF-8 with BOM (they used to be
   a mix of UTF-16LE and UTF-8), so they diff and merge properly on GitHub.

## Files and Installation

This binding contains three sets of files:

1. The binding itself is in the `Include/Zmq` directory. *Note* that there is a
   `Mql` directory in `Include`, which is part of
   the [mql4-lib](https://github.com/dingmaotu/mql4-lib). Previous `Common.mqh`
   and `GlobalHandle.mqh` are actually from this library. At release 1.4, this
   becomes a direct reference, with mql4-lib content copied here verbatim. It is
   recommended you install the full mql4-lib, as it contains a lot other
   features. But for those who want to use mql-zmq alone, it is OK to deploy
   only the small subset included here.

2. The testing scripts and zmq guide examples are in `Scripts` directory. The
   script files are mq4 by default, but you can change the extension to mq5 to
   use them in MetaTrader5.

3. Precompiled DLLs of both 64bit (`Library/MT5`) and 32bit (`Library/MT4`)
   ZeroMQ (4.3.5) are provided. Copy the corresponding DLLs to the `Libraries`
   folder of your MetaTrader terminal data folder, that is:

   ```
   <Terminal data folder>/MQL4/Libraries/     (MT4, 32bit)
   <Terminal data folder>/MQL5/Libraries/     (MT5, 64bit)
   ```

   If you are using **MT5 32bit**, use the 32bit version from `Library/MT4`.

   *Note* that if you are using **MT5 32bit**, you need to comment out the
   `__X64__` macro definition at the top of the `Include/Mql/Lang/Native.mqh`. I
   assume MT5 is 64 bit, since there is no way to detect 32 bit by native
   macros, and to define pointer related values a macro like this is required.

   *Note* that these DLLs are compiled from official sources, without any
   modification. You can compile your own if you don't trust these binaries, see
   [Building the DLLs yourself](#building-the-dlls-yourself). If you want to
   support security mechanisms other than curve, or transports like OpenPGM or
   NORM, you need to compile your own DLL.

   *Note* for WINE users: the old binaries required the VC++ 2015 runtime. The
   new ones are MinGW-w64 builds that only depend on system DLLs
   (`kernel32`, `ws2_32`, `iphlpapi`, `advapi32`, `netapi32`), so they should
   behave better under WINE. The `Library/VC2010` directory of the original
   project has been removed.

## About string encoding

MQL strings are Win32 UNICODE strings (basically 2-byte UTF-16). In this binding
all strings are converted to utf-8 strings before sending to the dll layer. The
ZmqMsg supports a constructor from MQL strings, the default is _NOT_
null-terminated.

## Notes on context creation

In the official guide:

> You should create and use exactly one context in your process. Technically,
> the context is the container for all sockets in a single process, and acts as
> the transport for inproc sockets, which are the fastest way to connect threads
> in one process. If at runtime a process has two contexts, these are like
> separate ZeroMQ instances.

In MetaTrader, every Script and Expert Advisor has its own thread, but they all
share a process, that is the Terminal. So it is advised to use a single global
context on all your MQL programs. The `shared` parameter of `Context` is used
for synchronization of context creation and destruction. It is better named
globally, and in a manner not easily recognized by humans, for example:
`__3kewducdxhkd__`

## Usage

You can find a simple test script in `Scripts/Test`, and you can find examples
of the official guide in Scripts/ZeroMQGuideExamples. Here is a sample from
`HelloWorldServer.mq4`:

```c++
#include <Zmq/Zmq.mqh>
//+------------------------------------------------------------------+
//| Hello World server in MQL                                        |
//| Binds REP socket to tcp://*:5555                                 |
//| Expects "Hello" from client, replies with "World"                |
//+------------------------------------------------------------------+
void OnStart()
  {
   Context context("helloworld");
   Socket socket(context,ZMQ_REP);

   socket.bind("tcp://*:5555");

   while(true)
     {
      ZmqMsg request;

      // Wait for next request from client

      // MetaTrader note: this will block the script thread
      // and if you try to terminate this script, MetaTrader
      // will hang (and crash if you force closing it)
      socket.recv(request);
      Print("Receive Hello");

      Sleep(1000);

      ZmqMsg reply("World");
      // Send reply back to client
      socket.send(reply);
     }
  }
```

## Building the DLLs yourself

`build/build-mingw.sh` rebuilds both DLLs from the official tarballs with
MSYS2 + MinGW-w64:

```bash
# 1. install MSYS2 (https://www.msys2.org/), then once:
pacman -S --needed mingw-w64-i686-gcc mingw-w64-x86_64-gcc make

# 2. build (from the repository root)
MSYSTEM=MINGW64 bash build/build-mingw.sh x64   # -> Library/MT5/libzmq.dll
MSYSTEM=MINGW32 bash build/build-mingw.sh x86   # -> Library/MT4/libzmq.dll
MSYSTEM=MINGW64 bash build/build-mingw.sh all   # both, needs both toolchains
```

The script downloads `zeromq-4.3.5.tar.gz` and `libsodium-1.0.22.tar.gz` into
`build/dl`, unpacks them into `build/src`, and builds into `build/work` and
`build/dist`. Nothing is installed system wide.

Two details matter for MetaTrader:

* The 32bit build links with `-Wl,--kill-at` so that the DLL exports plain,
  undecorated names (`zmq_socket`). MQL resolves imports by exact name and
  would not find `_zmq_socket` or `zmq_socket@8`.
* `libsodium` is built `--disable-shared --enable-static` and linked into
  `libzmq.dll`, so the result is a single DLL with no extra runtime
  dependency.

### Verifying the DLLs

`build/smoke-test.py` loads the 64bit DLL through ctypes and exercises the calls
mql-zmq actually uses:

```
python build/smoke-test.py
# RESULT: PASS
```

`build/smoke-test.c` is the same check compiled twice (32bit and 64bit), which
also verifies the export names and the 32bit WOW64 path:

```
i686-w64-mingw32-gcc   -o smoke32.exe build/smoke-test.c \
    -Ibuild/src/zeromq-4.3.5/include -Ibuild/dist/x86/include \
    -LLibrary/MT4 -l:libzmq.dll
x86_64-w64-mingw32-gcc -o smoke64.exe build/smoke-test.c \
    -Ibuild/src/zeromq-4.3.5/include -Ibuild/dist/x64/include \
    -LLibrary/MT5 -l:libzmq.dll
```

`zmq_ctx_term()` intentionally blocks while the IO threads drain (normal 0MQ
behaviour, see the ZGuide), so the tests use `zmq_ctx_shutdown()` instead and
do not assert on `zmq_ctx_term`.

`build/msys-shim/bin/rm` exists because some sandboxes deny `rm -r` inside the
MSYS2 coreutils, which breaks `configure` (`rm -r conftest.dir`). Delete it if
you do not need it.

## TODO

1. Write more tests.
2. Add more examples from the official ZMQ guide.
3. More documentation
4. High level API for common patterns

## Changes

* 2026-xx-xx: Released 2.0: rebased on libzmq 4.3.5 and libsodium 1.0.22;
  MinGW-w64 builds with statically linked libsodium (no VC++ runtime needed);
  drafts enabled; added `zmq_socket_monitor_versioned`, the 4.3.x socket
  options, the new monitor events and the version helpers; includes converted
  to UTF-8 with BOM.
* 2017-10-28: Released 1.5: Important: API change for `Socket.send`; Remove
  PollItem duplicate API (#11); Fix compiler warning (#10) and compile failure
  (#12); Add RTReq example from ZMQ Guide Chapter 3.
* 2017-08-18: Released 1.4: Fix ZmqMsg setData bug; Change License to Apache
  2.0; Include mql4-lib dependencies directly.
* 2017-07-18: Released 1.3: Refactored poll support; Add Chapter 2 examples from
  the official ZMQ guide.
* 2017-06-08: Released 1.2: Fix GlobalHandle bug; Add rebuild method to ZmqMsg;
  Complete all examples in ZMQ Guide Chapter 1.
* 2017-05-26: Released 1.1: add the ability to share a ZMQ context globally in a terminal
* 2016-12-27: Released 1.0.

## Credits and License

Original binding by Li Ding (<dingmaotu@hotmail.com>), released under the
Apache License 2.0 (see `LICENSE`). This fork keeps the original copyright
notices and adds the 4.3.5 update.

ZeroMQ is copyright (c) 2007-2024 Contributors as noted in the AUTHORS file,
distributed under the LGPL-3.0. libsodium is copyright (c) 2013-2025 Frank
Denis, distributed under the ISC License.
