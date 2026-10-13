# Changelog

## 2.0.0 - libzmq 4.3.5 / libsodium 1.0.22

### Binaries

* Rebuilt `Library/MT4/libzmq.dll` (i686) and `Library/MT5/libzmq.dll`
  (x86_64) from the official `zeromq-4.3.5.tar.gz` and
  `libsodium-1.0.22.tar.gz` releases (was 4.2.0 / 1.0.11).
* Toolchain changed from MSVC 2015 to MinGW-w64 (GCC). Consequences:
  * no dependency on the Visual C++ 2015-2022 runtime any more;
  * `libsodium` is linked **statically** into `libzmq.dll`, so
    `libsodium.dll` is no longer shipped or required;
  * the 32bit build links with `-Wl,--kill-at` so the exports stay plain
    (`zmq_socket`), which is what MQL looks up.
* `Library/VC2010` removed (the new MinGW builds cover the same WINE use case).
* libzmq configured with `--enable-drafts` and `--enable-curve
  --with-libsodium`, so the 4.3.x draft socket types, socket options and CURVE
  security are available.

### Binding (`Include/Zmq`)

* `Zmq.mqh`
  * `ZMQ_VERSION_MINOR` 2 -> 3, `ZMQ_VERSION_PATCH` 0 -> 5.
  * new `Zmq::hasWs()`, `Zmq::hasWss()`.
  * new `Zmq::major()`, `Zmq::minor()`, `Zmq::patch()`,
    `Zmq::isAtLeast(major,minor,patch)`, `Zmq::getBindingVersion()`.
  * new `ZMQ_BINDING_VERSION_MAJOR/MINOR/PATCH` (2.0.0).
* `Socket.mqh`
  * imported `zmq_socket_monitor_versioned`, exposed as
    `Socket::monitorVersioned(addr, events, version, type)`. The C prototype
    takes **five** parameters (the last one is the monitor socket type, use
    `ZMQ_MONITOR_PAIR` = 0); a four argument call returns `EINVAL`.
  * new `ZMQ_CURRENT_EVENT_VERSION` / `ZMQ_CURRENT_EVENT_VERSION_DRAFT` and
    `ZMQ_MONITOR_PAIR` / `ZMQ_MONITOR_PUB`.
  * new socket types `ZMQ_SERVER`..`ZMQ_CHANNEL` (12-20, draft build only),
    plus the deprecated aliases `ZMQ_XREQ` / `ZMQ_XREP`.
  * new monitor events `ZMQ_EVENT_HANDSHAKE_FAILED_NO_DETAIL` (0x0800),
    `ZMQ_EVENT_HANDSHAKE_SUCCEEDED` (0x1000),
    `ZMQ_EVENT_HANDSHAKE_FAILED_PROTOCOL` (0x2000),
    `ZMQ_EVENT_HANDSHAKE_FAILED_AUTH` (0x4000),
    `ZMQ_EVENT_PIPES_STATS` (0x10000, draft).
* `SocketOptions.mqh`
  * `ZMQ_ROUTING_ID` (5) / `ZMQ_CONNECT_ROUTING_ID` (61) are the 4.3.x names;
    `ZMQ_IDENTITY` / `ZMQ_CONNECT_RID` kept as aliases.
  * new stable options `ZMQ_GSSAPI_PRINCIPAL_NAMETYPE` (90),
    `ZMQ_GSSAPI_SERVICE_PRINCIPAL_NAMETYPE` (91), `ZMQ_BINDTODEVICE` (92).
  * new draft options 93-124 (`ZMQ_ZAP_ENFORCE_DOMAIN`, `ZMQ_LOOPBACK_FASTPATH`,
    `ZMQ_METADATA`, `ZMQ_MULTICAST_LOOP`, `ZMQ_ROUTER_NOTIFY`,
    `ZMQ_XPUB_MANUAL_LAST_VALUE`, `ZMQ_SOCKS_USERNAME`, `ZMQ_SOCKS_PASSWORD`,
    `ZMQ_IN_BATCH_SIZE`, `ZMQ_OUT_BATCH_SIZE`, `ZMQ_WSS_*`,
    `ZMQ_ONLY_FIRST_SUBSCRIBE`, `ZMQ_RECONNECT_STOP`, `ZMQ_HELLO_MSG`,
    `ZMQ_DISCONNECT_MSG`, `ZMQ_PRIORITY`, `ZMQ_BUSY_POLL`, `ZMQ_HICCUP_MSG`,
    `ZMQ_XSUB_VERBOSE_UNSUBSCRIBE`, `ZMQ_TOPICS_COUNT`, `ZMQ_NORM_*`).
  * flag values `ZMQ_NOTIFY_CONNECT`, `ZMQ_NOTIFY_DISCONNECT`,
    `ZMQ_RECONNECT_STOP_*`.
  * typed wrappers for all of the above.
  * deprecated `ZMQ_TCP_ACCEPT_FILTER`, `ZMQ_IPC_FILTER_*`, `ZMQ_IPV4ONLY`
    constants restored for source compatibility.
* `Context.mqh`
  * new context options `ZMQ_MSG_T_SIZE` (6),
    `ZMQ_THREAD_AFFINITY_CPU_ADD` (7), `ZMQ_THREAD_AFFINITY_CPU_REMOVE` (8),
    `ZMQ_THREAD_NAME_PREFIX` (9), `ZMQ_ZERO_COPY_RECV` (10, draft).
  * new `getMsgTSize()`, `setThreadNamePrefix()`, `addThreadAffinity()`,
    `removeThreadAffinity()`.
* `Errno.mqh` - unchanged: no 0MQ error number changed between 4.2 and 4.3.5.
* `ZmqMsg.mqh` - `zmq_msg_t` stays a 64 byte blob. 4.3.5 only needs
  `ZMQ_MSG_T_SIZE` (6) pointers, i.e. 24 bytes on 32bit and 48 bytes on 64bit,
  so the struct still has headroom. Documented, with `Context::getMsgTSize()`
  to check it at runtime.

### Housekeeping

* All `.mqh` files converted to UTF-8 with BOM (they were a mix of UTF-16LE and
  UTF-8, which made GitHub diffs unreadable).
* Added `build/build-mingw.sh` to rebuild the DLLs from source.

## 1.5.0 - 2017-10-28

* Important: API change for `Socket.send`; Remove PollItem duplicate API (#11);
  Fix compiler warning (#10) and compile failure (#12); Add RTReq example from
  ZMQ Guide Chapter 3.

## 1.4.0 - 2017-08-18

* Fix ZmqMsg setData bug; Change License to Apache 2.0; Include mql4-lib
  dependencies directly.

## 1.3.0 - 2017-07-18

* Refactored poll support; Add Chapter 2 examples from the official ZMQ guide.

## 1.2.0 - 2017-06-08

* Fix GlobalHandle bug; Add rebuild method to ZmqMsg; Complete all examples in
  ZMQ Guide Chapter 1.

## 1.1.0 - 2017-05-26

* Add the ability to share a ZMQ context globally in a terminal.

## 1.0.0 - 2016-12-27

* First release.
