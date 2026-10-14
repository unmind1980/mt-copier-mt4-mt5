# hub/ — the Phase 1 hub, in Rust

A faithful port of `tools/hub_proto.py`. Same two-frame forwarding, same `@`
handling, same PONG, same stats format — and the same routing suite passes
against both binaries.

```
    python tools/hub_proto_test.py                                  13/13 PASS
    python tools/hub_proto_test.py --hub hub/target/release/copier-hub.exe
                                                                    13/13 PASS
```

That is the whole claim of Step 5: *"the Rust version is an alignment, not a
redesign"*. Two green runs against one suite is a measurement; a code review is
an opinion.

The Python prototype is **not** obsolete. It is the reference — the Rust binary
is correct only in so far as it agrees with it. Keep both runnable.

---

## Build

```bash
bash hub/build.sh --release     # -> hub/target/release/copier-hub.exe
bash hub/build.sh --test        # the unit tests
bash hub/build.sh               # debug build
```

```cmd
tools\hubrs.bat --build         :: build, then run
tools\hubrs.bat --selftest      :: the routing contract, against the Rust hub
tools\copier.bat hubrstest      :: the same thing through the usual entry point
```

**Do not run `cargo build` directly.** Three things have to be set up first and
none of them announce themselves — `hub/build.sh` exists to hold them in one
place instead of a README that drifts:

1. **Rust lives in an isolated location**, not on `PATH`. `RUSTUP_HOME` and
   `CARGO_HOME` must point at `~/.workbuddy-ai/binaries/rust/…` or rustup looks
   in `~/.rustup` and finds nothing.
2. **`LIBZMQ_PREFIX` must be set**, or `zmq-sys` falls back to `pkg-config`
   (not installed here) and fails with a bare *"Unable to locate libzmq"*.
3. **`dlltool` must be on `PATH`** for the `windows-gnu` target. Nothing says
   so; you discover it as `CreateProcess` from a build script you did not write.

---

## Two decisions

### 1. `zmq` is pinned to 0.9.2 — the only version that can build here

`zmq` 0.10 pulls `zmq-sys` 0.12, whose build script **unconditionally vendors
libzmq from source** (`zeromq_src::Build::new().build()`). That needs `cmake`
and a C++ compiler, and — worse for this project — it would link a *different*
libzmq from the one the EAs use, which is exactly what the plan's §14 says must
not happen.

`zmq-sys` 0.11 (used by `zmq` 0.9.2) makes `vendored` an **optional** feature.
With it off, the build script looks for a system libzmq via
`LIBZMQ_PREFIX` / `LIBZMQ_LIB_DIR` / `LIBZMQ_INCLUDE_DIR`. That is the path used
here.

Before pinning, every symbol `zmq` 0.9.2 references was checked against the
DLL's export table. All present. The 24 symbols the DLL does **not** export are
exactly the 4.3-era additions (`zmq_poller_*`, `zmq_timers_*`,
`zmq_msg_routing_id`, `zmq_join`/`zmq_leave`) — and 0.9.2 uses none of them.
The pin is a consequence of a check, not a guess.

### 2. No `ctrlc` crate — the signal handler is ~20 lines of FFI

**This one is a choice, not a constraint, and it used to be written up as a
constraint.** The old text here said `ctrlc` pulls `windows-sys`, that
`windows-sys` cannot build on this machine, and that installing a full
mingw-w64 would be ~100 MB for one signal handler. The middle claim was wrong:
`windows-sys` builds fine once `hub/build.sh` supplies a complete-enough
binutils, and M8/M10 depends on that fix. See "A build note for what comes
next" at the end of this file.

So the honest reason is now the plain one: `src/main.rs::sig` is ~20 lines, it
does exactly the one thing needed — set a flag so the final stats line still
prints — and a crate plus a platform layer is not worth pulling in for that.
The dependency list stays short because it is *kept* short, not because it has
to be.

---

## `third_party/zmq-prefix/` — the EAs' own libzmq, prepared for linking

The plan's §14 requires the hub to use **the same libzmq as the EA side**, or
CURVE and HWM behaviour can differ between the two ends of one link. So this
links the DLL already shipped in `third_party/mql-zmq-master/Library/MT5/` —
**libzmq 4.3.5**, the exact build the EAs load.

```
third_party/zmq-prefix/
  include/zmq.h      libzmq header (matches the DLL's ABI)
  lib/libzmq.a       a LINKER SCRIPT: INPUT(libzmq.dll)
  lib/libzmq.dll     the EAs' DLL - what the script resolves to
  lib/libzmq.def     the export list the script was derived from (96 exports)
```

There is **no `libsodium.dll`** and there must not be one. Up to libzmq 4.2.x
libsodium was a separate runtime DLL; the 4.3.5 build links libsodium 1.0.22
**statically**, so adding one back would be a stale file that no longer matches
the library. As a consequence the MT4 DLL grew from 336 KB to 3.65 MB — that is
the price of the single self-contained DLL.

**Why `libzmq.a` is a text file.** `zmq-sys` emits `-lzmq`, so something called
`libzmq.a` has to exist in the search path. Generating a real import library
needs `dlltool`, which cannot run here (see above). But GNU `ld` **links
directly against a DLL** and reads its export table — so the "import library"
is a one-line linker script that points `ld` at the DLL. Verified end to end:
the resulting binary runs and reports `libzmq 4.3.5`.

**Why the export list mattered this time.** All 70 `zmq_*` symbols that
`zmq-sys` 0.11 declares are present among the new DLL's 96 exports. The DLL this
prefix carried before (61 exports, libzmq 4.2.1) was missing nine of them —
`zmq_timers_new/add/reset/cancel/destroy/set_interval/timeout`,
`zmq_timers_execute` and `zmq_stopwatch_intermediate` — so any future code path
reaching for timers would have failed to link. The upgrade closed that gap as a
side effect.

`libzmq.def` is kept because it is how the export list was obtained: this box
has no `gendef`/`nm`, so PE export-table parsing was used to read the DLL's own
export directory. Regenerate with any of the usual tools if you ever need to.

**The DLL must sit next to whatever binary runs.** It is linked *by name* and
resolved at run time, so `build.sh` copies it into `target/<profile>/` **and**
`target/debug/deps/` — without that, the test harness dies with a bare
`STATUS_DLL_NOT_FOUND` that names no missing file.

---

## What it does

```
bind XPUB on --port (default 6000); every EA connects an XSUB to it.

loop:
    parts = recv_multipart()
    if parts.len() < 2:  ignore          # subscription byte, not data
    topic, payload = parts[0], parts[1]
    if !payload.starts_with(b"V="):      drop + count
    if topic.starts_with(b"@"):          consume
    else:                                republish
```

Frame 1 is forwarded **byte for byte**. The hub never re-encodes, never touches
`SEQ`/`SSID`/`TS`. That is what makes it structurally incapable of corrupting a
trade instruction, and it is why the receiver needed no change to its
convergence logic.

That loop is the whole of Phase 1 and it is still the only thing on the
forwarding path. Since then three read-only layers have been added around it,
none of which can change a byte that goes out:

* **M2, the registry** — who is connected, from `REG`/`HBT2` only. The hub
  never probes for nodes, so a silent node stays invisible.
* **M3, the position view** — `SNAP` parsed read-only, **after** the forward.
* **M8/M10, the API and its dashboard** — HTTP + WebSocket over the same
  state. See "The API (M8/M10)" below.

Deliberately **not** here: config, ini, ACK tracking, conflation, persistence,
auth, and any write path. If the hub ever needs to know *which nodes exist*
beyond `REG`, that is Phase 3 leaking in.

### The one shape rule: two frames, or nothing

**The central channel is two frames. The direct channel is one.** The hub can
only route the first kind — a single frame has no topic to route *by*, and to an
XPUB it looks like a subscription byte, which is how XPUB tells the two apart.

A node that sends its uplink the direct way therefore produces a message the hub
reads, matches against the subscription shape, finds is not one, and drops.
Until recently that happened **with no log line, no counter and no trace**, and
it was doing real damage: the receiver's `STAT` and `PONG` were single-frame, so
every one of them was being thrown away. Phase 2's `STAT`-consumption did not
work; it merely looked like it might.

Two things came out of that:

* **the receiver now sends its uplink as `@hub`, two frames**, in central mode;
* **the hub counts unroutable single frames** and reports them in the stats line,
  because *a silent discard is the worst possible treatment for a protocol
  mismatch*.

And one thing that did **not** change: in central mode the receiver no longer
answers `PING` at all. A reply has to reach the *sender*, and the hub consumes
every `@` topic rather than routing it — so the reply cannot arrive. Sending it
anyway would be worse than silence, because it makes the sender's peer table
look maintained when it is not.

### Logging: only the unusual

Routine traffic is **counted, not printed**. `PING` fires every 2 s per sender
and `HBT2` every 5 s per node; printing them buries everything that is *not*
routine, and an operator who cannot see the signal stops reading the log
altogether. Both still appear in the stats line and under `--verbose`.

**`STAT` belongs on that list too, and the reason is a trap worth naming.** It
was a once-a-minute report and was correctly *not* routine when this rule was
written. It now also carries the snapshot receipt every `SyncHeartbeatSeconds`
(default 1) **per mirrored sender**, so a receiver mirroring two senders emits
two a second and the rate grows with receivers × senders — exactly the axis a
hub grows along. Found by reading a live `hub.log`: 1612 identical lines in
390 s, and the line carried nothing, because `control_note` returns `""` for
`STAT`. Suppressing it lost no information: the per-type totals stay on the
stats line and the relay is counted separately as `receipts`.

**The general lesson: when a message's cadence changes, the log rule for it
does not follow automatically.** Anything newly on a sub-second timer needs the
same check, and `hub_stat_path_test.py` asserts the aggregate both ways — 20
routine `STAT` uplinks must write zero lines, an unrecognised type must still
write one.

Events — `REG`, `ACK`, `CFGR`, and anything unrecognised — always print. The
rule is that **the value of a log line is that it is unusual**; a line that
appears every second is not information, it is background.

The stats line breaks **both** directions down by type — forwarded *and*
control. That symmetry was missing for a while, and its absence is why a
runaway went unnoticed: `control 201` was visible, `of what` was not, and the
first thing anyone does with a rate they cannot explain is guess. (Guessed
wrong, too — the culprit was not the message type that looked busiest.)

### A warning about fixing silent drops

Making the receiver's uplink two-frame was correct — the hub could not route a
single frame, and every `STAT` was being thrown away. But it **turned a harmless
noise into a harmful one**: the receiver's own peer-probe had also been going
out as a single frame, and while it was being silently discarded that was merely
useless. Once it arrived, it was 2 messages a second of control traffic the hub
consumed and answered pointlessly — half the entire control rate.

The probe is now skipped in central mode, because a round trip to a sender is
impossible through a hub that consumes every `@` topic.

> **Before fixing a silent drop, ask who was relying on the silence.**

The one message it originates is a **PONG**. Not scope creep: ZMQ `connect()`
succeeds immediately whether or not anything is listening, so without an echo a
node cannot tell a live hub link from a dead one — the sender's panel would read
"connected" forever. It needs no state: the node's own millisecond value is
echoed straight back, so `(now - echoed)` is a true round trip with no clocks
involved.

## Options

```
--bind IFACE        interface to bind (default 0.0.0.0)
--port N            port to bind (default 6000)
--http ADDR:PORT    address for the dashboard + REST API
                    (default 127.0.0.1:6010 — LOOPBACK, unlike --bind, and
                     on purpose: this port exposes every position the hub
                     has seen. `--http none` turns it off.)
--config PATH       config revision log (default config_revisions.jsonl)
--commands PATH     command journal — in-flight CFG/CMD commands (default commands.jsonl; `none` = off, commands forgotten on restart)
--writes on|off     may this hub change a node's config? (default ON since
                    2026-10-14, the owner's test-period setting; `off` refuses
                    PUT/POST with 403 and never emits a CFG/CMD)
--users PATH        user table (default users.json; `none` disables the login
                    entirely - every request is treated as an anonymous
                    viewer, for throwaway local runs only)
--curve on|off      is the ZMQ link encrypted and machine-authenticated?
                    (default OFF). ON makes this hub the CURVE server: the
                    link is encrypted and every node must present a keypair
                    on the allow-list. A coordinated change - a node without
                    the hub's public key cannot connect at all.
--curve-keys PATH   this hub's CURVE keypair, Z85 (default curve_hub.keys;
                    generated on first start when --curve on)
--curve-clients P   the client allow-list (default curve_clients.txt): one
                    40-char Z85 PUBLIC key per line, # comments, or a lone *
                    for "any authenticated keypair". An EMPTY list with
                    --curve on refuses to start.
--curve-show        print this hub's CURVE public key (and the allow-list's
                    state) and exit WITHOUT binding anything. This is how you
                    read the key while a hub is already running - `--curve on`
                    would need the port that hub is holding.
--audit PATH        append-only audit log (default audit.jsonl; `none` = off)
--verbose           log every message, not just events and stats
--stats-every SECS  seconds between stats lines (default 30, 0 = never)
--duration SECS     exit after this many seconds (0 = run until Ctrl-C)
```

## Hardening

| layer | control | effect |
|---|---|---|
| `ZMQ_MAXMSGSIZE` | 1 MB, same as the EAs' `CP_MAXMSGSIZE` | a peer announcing a bigger frame is **disconnected during the frame read**, before libzmq allocates anything |
| `SNDHWM` / `RCVHWM` | 1000, same as the EAs | a flooding peer fills a bounded queue; nothing grows without limit |
| `LINGER` | 0 | shutdown returns instead of waiting on messages a hub has no reason to hold |

The hub is the internet-facing end, so `MAXMSGSIZE` matters more here than on a
node — and a hub is a fan-out, so one oversized frame it accepted would be
copied to every subscriber.

None of this replaces the **IP allow-list** on the host. The firewall decides
who may connect; these decide what a connection that got through can cost.

## CURVE — the link's cryptographic boundary (§19.1)

§19.1 decided the ZMQ port's trust boundary is the firewall, and said in the
same breath that CURVE "can be turned on independently". This is that switch.
It is **off by default on the hub**, because turning it on is a coordinated
change: a node that has not been given the hub's public key cannot connect at
all. (The EA side of that coordination is already done for this test campaign
— `HubUseCurve` ships true with this hub's key in `HubPublicKey` — so the
only thing still to switch is the hub itself, and the order below.)

`--curve on` makes the hub the **CURVE server**:

* the link is encrypted with a key neither end ever sends;
* every node must present a keypair (proving it is *a* machine, not *which*);
* and the hub enforces a **client allow-list** — `curve_clients.txt`, one
  40-character Z85 public key per line — which is what turns "has a keypair"
  into "is a machine we authorised".

**The allow-list is enforced by a ZAP handler (RFC 27), and that choice is the
whole design.** The hub's main loop only ever sees messages it *receives*; a
subscriber that completed a handshake but is not on the list would still be
delivered every position the hub publishes, and the hub would never learn it
was there, because publishing is libzmq's job rather than the application's.
Checking incoming messages would therefore protect the hub from forged data
while leaving the position stream readable — the half of §19.1's exposure that
matters most. ZAP is the one place libzmq asks the application a question it
then obeys, *during the handshake*, before the connection exists: a DENY means
the peer never becomes a subscriber.

An **empty allow-list with `--curve on` is a refusal to start**, not a hub that
quietly accepts everyone. The only way to say "any keypair" is to write a lone
`*`, and writing it is a decision somebody has to make on purpose. The hub
prints each handshake as `ZAP ALLOW <key>` / `ZAP DENY` — the key in the log is
the same 40-character spelling that goes in the allow-list, so an operator can
copy it straight across.

### Turning it on, in order

1. **Read the hub's public key.** Run `copier-hub.exe --curve-show`. It
   creates `curve_hub.keys` if it does not exist and prints the **public**
   key. It binds nothing, so it works while a hub is already running —
   which matters, because the alternative (start with `--curve on` and read
   the banner) needs port 6000, i.e. exactly the port the running hub holds.
   The same key is printed in the startup banner whenever the hub does run
   with `--curve on`, and it lives on the `PUBLIC=` line of
   `curve_hub.keys`.
2. **Get the key to the nodes.** The EAs' `HubPublicKey` input currently
   ships with this hub's key already in it (2026-10-15, the owner's test
   campaign), so a node attached from a fresh chart needs nothing typed —
   check it in the dialog if the chart has been attached before, because MQL
   remembers per-chart input values. Set `HubUseCurve=true` if it is not
   already (it is the shipped default).
3. **Collect the nodes' keys.** Restart each EA and copy the public key it
   prints in its Experts log into `curve_clients.txt`, one per line.
4. **Restart the hub with `--curve on`** (the list is read at startup). If
   you needed a placeholder to get this far, delete the `*` now.

> **The order is not a suggestion.** `HubUseCurve=true` makes the hub link
> *require* CURVE, and in central mode the hub is a receiver's only feed — so
> a node re-attached while the hub is still `--curve off` completes no
> handshake and goes blind. Bring the hub up with CURVE first (a `*`
> allow-list is the intended placeholder for exactly this window), then
> attach the nodes, then tighten the list.

`HubUseCurve` is separate from the EAs' `UseCurve`: on the **direct** channel
the sender is the CURVE server and receivers hold its key, while on the **hub**
link the hub is the server and nodes hold *its* key. Different roles, so
different switches — a deployment can encrypt one link and not the other.

## Phase 2 — the registry (M2)

Phase 1 was adamant that the hub must not know which nodes exist. Phase 2 is
exactly that knowledge, so the rule was replaced by a narrower one:

> **the hub knows ONLY what nodes tell it.**

It never probes for nodes, never discovers them, and never writes to one. A node
that stays silent stays invisible — silence is not a claim.

| message | direction | topic | what it does |
|---|---|---|---|
| `REG` | node → hub | `@hub` | *here I am* — carries `ROLE`, `ACC`, `VER`, `NAME`, `UP` |
| `HBT2` | node → hub | `@hub` | *still here* — same minus `NAME` |
| `WHO` | hub → all | `@all` | *re-register, I lost my table* |

Three details worth knowing, each of which is a bug if you get it wrong:

* **`HBT2` must not blank a name.** It carries no `NAME`, so an unconditional
  assignment would erase every node's name ten seconds after it registered.
  The same applies to a re-`REG` that arrives without one. Both are unit-tested.
* **A node introduced by its HEARTBEAT must be reported, not counted silently.**
  See "the lost REG" below — this is not a corner case, it is the *normal* path
  on a cold start, and getting it wrong made a working hub look broken.
* **`WHO` is sent fast while the table is empty, then slowly forever.** Fast,
  because the first ask may go out before a node has finished reconnecting.
  Slowly forever, because a node whose `REG` was dropped would otherwise stay
  anonymous for the rest of its life.
* **A node answering `WHO` sends ONE `REG` and must then SETTLE.** The reply
  must not re-arm the node's "first *N* announces are `REG`" counter. Because
  the sweep is unconditional and runs every 60 s for as long as the hub lives,
  re-arming it is a ratchet: the node is re-armed every minute and never
  settles into `HBT2`. Measured on a 300 s run — **19 `REG` where 3 is
  correct**, and every extra one carried a `NAME`. The safety argument for
  re-arming ("if this reply is lost, the next few are `REG` too") is
  unnecessary: a lost reply is recovered by the *next* sweep, which arrives
  whether or not anyone answered.
* **The hub has no persistence and does not want any.** A table restored from
  disk is a table of nodes that may have died while the hub was down. It is
  rebuilt from `REG`s, which is what `WHO` is for.

`REG` is a **startup** message, not a heartbeat, so the hub warns when its rate
stops looking like one:

```
[hub]   WARNING REG is doing 5.0 msg/s. REG is a STARTUP message - a settled
        node sends HBT2. A steady REG stream means a node is re-announcing
        instead of settling (check the WHO reply path in the EAs), and each
        one carries a NAME.
```

This warning exists because the failure is otherwise **invisible**: the hub
logs a node only the first time it appears, so a node re-announcing forever
prints nothing at all. The legitimate steady-state rate is one reply per 60 s
sweep (~0.017/s), so the bar sits at 1.0/s.

### The lost REG, and why it is the normal case

**The startup `REG` is routinely discarded.** The EAs open their socket with
`ZMQ_IMMEDIATE`, so a send made before the TCP connection completes is dropped
rather than queued — and the first thing a node sends is a `REG` fired
immediately after `connect()`.

The node is still *visible*: `HBT2` creates it. But it is **anonymous**, because
only `REG` carries a `NAME`. So the hub counted nodes and explained none of
them:

```
[hub] nodes online 2  stale 0  offline 0  (total 2)
```

...with no `+node` line anywhere. That reads as a broken hub. It was not — it
was a working hub with a logging hole on the more common of its two paths.

Three things fix it, and all three are needed:

1. **Report a node however it arrived**, and say which way:
   `+node sender:555001  -  ver 2.0 up 41s  (from HBT2 - no NAME yet, its REG was lost)`
2. **The node repeats its `REG`** for the first `CP_REG_REPEATS` (3)
   announcements, which closes the race inside 10 s for the cost of two extra
   messages. `REG` is idempotent, so a repeat that lands after the first is
   ignored.
3. **Say when the race resolves** — `named sender:555001  REG-NODE`. "A node
   with no name" and "a node that has just been identified" are very different
   things to be looking at.

> The general lesson, which cost more time than the bug: **a system that only
> logs on its happy path renders "working" and "broken" identically.** The
> `REG` branch was instrumented and the `HBT2` branch was not, and `HBT2` is
> what actually happens first.

Liveness: `online` → `stale` after **15 s** → `offline` after **60 s**, evicted
after 30 min. The 15 s matches the EAs' own `CP_PEER_TIMEOUT_MS`, so a hub and
an EA looking at the same node draw the same conclusion at the same moment.

**Everything here is read-only with respect to the trade path.** Phase 2's
promise is that the hub can be stopped, or be wrong, without affecting a single
order — which is why the write path (`CFG`/`ACK`/`CFGR`) is **Phase 3**, the
highest-risk step, and is deliberately not in this file.

## The API (M8/M10) — the read half

`copier-hub` now also serves HTTP + WebSocket on **`--http`**, default
**`127.0.0.1:6010`**. Run `tools\hublog.bat` and open
<http://127.0.0.1:6010/>.

**Everything is read-only, and that is the boundary that matters more than the
feature.** There is no POST, PUT or DELETE. Adding one needs the plan's M4/M5 —
config push and commands, with their `202` + `command_id` semantics and their
audit trail. A write endpoint before that could only act *locally*, and a hub
that appears able to change a node while being unable to is worse than a hub
that never offered.

| Method | Path | Answers |
|---|---|---|
| GET | `/` | the dashboard (one HTML file, compiled in) |
| POST | `/api/v1/login` | `{id, password}` → session cookie; the ONLY unauthenticated endpoint besides the health probes |
| POST | `/api/v1/logout` | kills the caller's session |
| POST | `/api/v1/password` | `{old, new}` — change YOUR OWN password (any role; the old one is required); ends the caller's other sessions |
| GET | `/api/v1/whoami` | the caller's id and role |
| GET | `/api/v1/nodes` | every node, with liveness derived from the registry's own rules |
| GET | `/api/v1/nodes/{id}` | one node (`ROLE:ACC`), plus its positions if a sender |
| GET | `/api/v1/topology` | senders, receivers, **and the edges** |
| GET | `/api/v1/positions` | the M3 view as data |
| GET | `/api/v1/alerts` | the M6 alert ring |
| GET | `/healthz` `/readyz` | liveness, and "is there anyone here yet" |
| WS | `/api/v1/stream` | a full snapshot on connect and on every change (session cookie required) |

**Everything except `/`, the health probes and `/login` requires a session**
(M9). A missing or expired one answers **401**; a logged-in role below the
endpoint's requirement answers **403** and the denial is audited. The first
hub start with an empty user table bootstraps user `admin` and prints its
password **once** — it is stored only as a salted hash; log in and change it.

**The edges in `/topology` are not free, and they are the interesting part.**
The hub only knows "this receiver mirrors this sender" because relaying a
snapshot receipt requires reading the target sender's `SID` out of the
receiver's `STAT`. That is information the hub always had and used to throw
away. Note it comes from the **payload**, never the envelope header: a receiver
sets its header `SID` to the literal string `"receiver"` on purpose — the node's
identity is `LOGIN` — so a hub that archived by header would draw one giant
node called "receiver".

**`/http` default is loopback while `--bind` is not, deliberately.** The ZMQ
port's trust boundary is the firewall (§19.1). That reasoning does not transfer
to a port that exposes every position the hub has ever seen: binding it to
something reachable is an operator's explicit choice, and `--http none` turns it
off entirely. `tools/hub_api_test.py` asserts all three — `none`, the default,
and the banner.

**One deviation from the plan, stated where it will be found.** §18 asks for "a
full snapshot on connect, increments after". The stream sends the **whole**
snapshot on every change. At this scale that is a few tens of kilobytes a few
times a second, and it keeps one serialization path that the REST endpoints and
the WebSocket share. The number that changes the decision: a hundred senders
changing several times a second to a hundred dashboards. Then send the changed
field only.

### Why a second thread rather than tokio around the socket

§14's sketch is one runtime, the ZMQ socket inside it, and an inproc PAIR as a
wake channel. Not used. The ZMQ loop is a single blocking thread with a poll
timeout, 42 tests behind it, and a forwarding path proven byte-for-byte against
real EAs; the API needs *state*, and the state is already plain data. So the
bridge is an `Arc<Mutex<Shared>>` plus a `broadcast` channel, the API thread
only ever reads, and the mutex is held for microseconds at a message rate
measured in tens per second. `hub/src/api.rs` carries the full argument.

One rule that came out of it: **never hold the lock across a `println!`**.
stdout to a pipe can block — a reader that stops reading — and a blocked stdout
is a held lock, which is a stalled API. That is what `Shared::clone_view()`
exists for; `print_positions` copies under the lock and prints without it.

## Config push (M4)

The hub stores each receiver's ini, versions it, serves it over REST, and emits
`CFG`; the receiver applies it and `ACK`s. **Both halves exist** — M4a is the
hub, M4b is the EA.

The two halves are gated separately, on purpose. **Both shipped defaulting to
off as inputs; on 2026-10-14 the owner flipped both ON and then removed the
receiver ones from the inputs dialog entirely** (MQL charts remember per-chart
input values, so the old false kept resurfacing and read as "the default did
not change" — they are hard-coded globals now). The refusal behavior is
unchanged, only the resting position moved:

| side | gate | state (since 2026-10-14) | with it off / false |
|---|---|---|---|
| hub | `--writes` | default **on** | refuses PUT with 403, never emits a `CFG` |
| receiver | `AcceptConfigPush` | **hard-coded on** | would ACK `OK=0`, not touch the file |

Two keys rather than one, because this is the only operation in the system that
can stop a receiver from starting. The plan's §19.1 makes the firewall the
*only* trust boundary on the hub port and there is no token — so anything that
can reach it can publish a `CFG`, and a forged one would let it replace a
receiver's configuration. That is strictly worse than pushing fake trades, and
it is the reason the defaults go back to off before the hub faces anything but
the owner's own test bench.

### The write gate

`--writes off` refuses: PUT answers **403** and no `CFG` is ever emitted. The
plan's §19 asks for role checks on the write path, and **M9 now provides
them** (2026-10-14): on top of the flag there is the §17.2 role matrix —
401 without a session, 403 with one that is too junior (`viewer` is
read-only, `operator` may command and configure, `admin` manages users and
reads the audit log). The default is currently ON (the owner's call,
2026-10-14 — every session from here on is a test session), so the honest
framing is: the hub *can* do this, the login now sits between the network
and the buttons, and every change and every denial is audited.

`tools/hub_config_test.py` asserts BOTH ends of that: the **default** (a hub
started with no `--writes` argument reports writes enabled) and the
**refusal** (an explicit `--writes off` 403s with the reason). Flip the
default back and the test's assertion flips with it — it cannot happen
silently.

| Method | Path | Answers |
|---|---|---|
| GET | `/api/v1/config` | every managed node, and whether each is in step |
| GET | `/api/v1/nodes/{id}/config` | the current revision, its history, the command state |
| PUT | `/api/v1/nodes/{id}/config` | body = the whole ini → **202** + `command_id` |
| POST | `/api/v1/nodes/{id}/config/rollback/{rev}` | → **202** + `command_id` |
| GET | `/api/v1/commands` · `/commands/{id}` | the polling fallback §16 asks for |
| GET | `/api/v1/alerts` | **M6 — the alert ring**: the engine's recent fired alerts, newest first, bounded in memory; the durable record is the `alert.*` entries in the audit log |

### Five decisions worth knowing

**The revision file is append-only, and a rollback APPENDS.** Rolling back to
rev 3 writes a *new* revision whose body equals rev 3's. The history keeps both,
so "we went to 7 and then back to 3" stays readable. A config store that can
rewrite its own history cannot answer *"what was it running when it broke"* —
which is the question it exists for.

**The current config is simply the last revision.** There is no separate
"current" record to fall out of step with the history.

**The command id is derived from `(node, rev)`, not a counter.** §5.4 requires a
node to be idempotent by `ID` and says why: in the §11 primary/standby
arrangement two hubs may push the *same* change. A hub-local counter would mint
two different ids for one change and the node would apply it twice.
Content-derived ids make a retry, a resend and a second hub's copy the same
command.

**The hub's first revision continues the node's own numbering.** A node running
its own rev 7 gets rev 8, not rev 1 — otherwise the node would look permanently
*ahead* of the hub, i.e. drifted, when in fact the hub had just taken over.

**The ini is escaped, and not with base64.** An ini contains every character the
payload uses as a separator: `;` starts a comment, `=` splits a key, `|` splits
envelope fields, and there are newlines between every line. Dropped in raw, the
field would end at the first `;` of the first comment and the node would receive
a **truncated config** — the kind of failure that looks like a successful push
until the receiver restarts. So it is percent-escaped (`%3B`, `%0A`, …). Base64
was the alternative and was rejected on the EA side: **MQL4 has no
`CryptEncode`** (that is MQL5 only), so the mirror would mean hand-rolling an
encoder *and* a decoder.

One honest note the tests forced: **percent-encoding is NOT idempotent.** `%` is
both escaped and present in the output, so encoding twice gives `%2525`. An
earlier comment in `config.rs` claimed the alphabet was closed and a test
asserted it; both were wrong and are now corrected. The property that matters —
and the one tested — is the round trip, byte for byte, over a real ini.

### Drift is reported, never silently overwritten

§7.4 is explicit and the implementation follows it. When a node reports a rev
**higher** than the hub issued, the hub logs a warning, audits `config.drift`,
and **does not push**. The hub being the source of truth does not make an
unexplained difference something to erase — it makes it something to look at.
The mirror case (node behind) is the self-heal path and does push.

### Validation happens at the door, on both sides

A bad ini is a **400 to the operator**, not a stored revision that gets re-pushed
forever. A node that refuses a config answers `OK=0`, and by then the hub holds
it and every REG comparison sees the node behind — so a mistake would become a
permanent condition instead of one somebody corrects. The check is shape-only
(`[section]`, `key=value`, a size cap); it cannot know whether an account exists,
and does not pretend to.

The receiver runs the same check again, because it is the one that would have to
live with the result.

### The EA half (M4b): the file is verified before anything is torn down

This is the half that can brick a receiver, so the order is the design:

1. read the current `copier.ini` into memory — that is the backup
2. write a `.bak` copy for a human
3. delete + write the new content
4. **read it back and parse it**
5. if it does not parse, write the old content back and ACK `OK=0`

**Step 4 is the one a naive implementation skips**, and writing a file and
believing it is how you ship a truncated config.

The state file elsewhere in this project is written "in place after delete" and
that is fine there — it is a cache, and losing it costs a rebuild. `copier.ini`
is a **startup dependency**: deleting it and failing to write leaves a receiver
that cannot run.

And the worst case is already survivable, which is what makes this safe at all:
lose power between the delete and the write and the receiver starts with an
unparseable ini, `LoadConfigForHub` reports **zero senders and waits**, and it
reports `REV=0` — so the hub sees it behind and pushes again. **The recovery path
is the same one a fresh receiver uses**, and it was already written before M4b
existed.

Reload also re-subscribes: senders added to the config get a new subscription,
senders removed get an `Unsubscribe`. A removed sender that kept streaming would
look like data the receiver ignores and a link that never goes quiet.

**Idempotency by `ID`** (§5.4 rule 2): a repeated `ID` re-sends the same `ACK`
and does **not** re-apply. Under §11 primary/standby two hubs can push one
change, and the second copy must be a no-op rather than a second reload.

## Commands (M5) — the same engine, a different payload

Operational commands (`pause` / `resume` / `closeall` / `reload`) ride the
**exact same command engine as `CFG`** — see `hub/src/commands.rs`. One
implementation of issue → retry → acknowledge, one append-only journal, one
`2 s → 5 s → 15 s → 60 s → unknown` ladder. The only things `M5` adds over `M4`
are the `CMD` wire frame and the `POST /api/v1/nodes/{id}/commands` endpoint.

### Why one module and not two

M4 built the whole "mint an id, watch for an `ACK`, walk the backoff ladder,
give up as `unknown`" machinery for `CFG`. M5's commands are the same problem
with a different payload, so the honest thing is to move that machinery into
`commands.rs` and have both callers use it — not to write a second copy that
drifts. A second ladder would be a second definition of "gave up", and the two
would disagree the first time somebody tuned one of them.

### The id: content-derived vs sequence-derived

This is the one real design point, and the two kinds need *opposite* properties
from §5.4 rule 2 (a node must be idempotent by `ID`):

* **A retry must carry the same id as the original** — or a lost `ACK` makes the
  node apply the same intent twice.
* **Two distinct intents must carry different ids** — or "pause, resume, pause"
  collapses: the third command looks like the first, the node answers "already
  did that" while it is actually running.

A config revision satisfies both for free (`(node, rev)` *is* the identity of the
thing being applied). A command has no such content — `pause` is `pause` — so it
needs a sequence, per node, continuing across a restart (same rule revisions
follow). **The sequence is hub-local**: under §11 primary/standby two hubs would
mint different ids for one operator intent, exactly as the plan warns; the config
path only escapes that once the store is replicated, and §11's replication is not
built. What makes it acceptable meanwhile is §5.4 rule 2 at the node plus the
fact that all four ops are idempotent (`pause` twice is `pause`, and a second
`closeall` finds nothing left to close).

| kind | id | example |
|---|---|---|
| `config` | `command_id_cfg(node, rev)` = `<node>R<rev>` | `receiver-252034803R1` |
| `op` | `command_id_op(node, op, seq)` = `<node>-<op>-<seq>` | `receiver-252034803-pause-1` |

### The wire frame

```
[@<nid>] CMD ID=..;OP=..[;ARGS=..]      hub → node, on the retry ladder
[@hub]   ACK ID=..;OK=1;REV=0            node → hub, same frame CFG uses
```

`ACK` is the same frame for both kinds; the hub finds the command by the `ID` it
quotes and suffixes the audit action with `config.*` or `command.*` accordingly.
When an `ACK` quotes an id the hub never issued, the kind is genuinely unknown —
but the id shape still tells (`<node>R<rev>` → `config`, `<node>-<op>-<seq>` →
`command`), so `unknown_ack` lands in the right bucket rather than always
guessing `config`.

### The closed op set

`OPS = ["pause", "resume", "closeall", "reload"]`, validated at the door
`(is_known_op`, case-sensitive). A typo'd op is a **400 with the known list**,
not a command sitting on the ladder forever — see `tools/hub_commands_test.py`.

### State: both halves done; the gate defaults ON for testing

The hub half issues, retries, tracks and audits `CMD`s exactly as it does `CFG`s,
behind the same write gate (default ON since 2026-10-14, `--writes off` refuses).
The receiver half (M5b, `HandleCmd` in
`CopierReceiver.mq4`) now acts on `OP=` — the receiver's `AcceptCommands` gate
is hard-coded ON — and: `pause` stops new mirrors (management of
existing ones never stops), `resume` clears it, `closeall` pauses AND queues a
close for every position this receiver owns, and `reload` re-reads `copier.ini`.
The receiver answers `OK=0` when it refuses, the same way it does for `CFG`.

Two properties worth knowing before reaching for the button:

* **`closeall` implies `pause`**, deliberately: converge runs on every snapshot,
  so a flatten that leaves the sender's desired set mirrored would re-open
  everything within seconds. `resume` is the way back.
* **The pause survives a restart.** It is persisted (`copier_cmd<instance>.st`,
  the same pattern as the config revision) together with the last command id and
  its ACK, so a hub retry that outruns a crash gets the same ACK rather than a
  second execution (§5.4 rule 2 held across the restart). The four ops are
  idempotent by nature, which bounds what a crash-window repeat can do anyway.

The same endpoint is wired into the hub dashboard (`hub/src/assets/dashboard.html`):
every **receiver** row now carries `pause` / `resume` / `close all` / `reload`
buttons that POST here and show the returned `command_id` (and poll URL) inline;
the footer reflects whether this hub was started with `--writes on`.

| Method | Path | Answers |
|---|---|---|
| POST | `/api/v1/nodes/{id}/commands` | body `{"op":"pause"}` or the bare word `pause` → **202** + `command_id` + a poll URL; **403** with `--writes off`, **400** for a non-receiver or an unknown op |
| POST | `/api/v1/commands` (no node id) | **G10 — the global button**: issues one command per *known receiver*, each with its own id, ladder and audit entry → **202** + `{count, issued:[{node, command_id, poll}]}`; same **403** with `--writes off`, same **400** door |

### The global button is N commands, not one broadcast (G10)

`POST /api/v1/commands` with no node id is what the dashboard's **Global
operations** strip calls. It looks like a broadcast and is deliberately *not*:
the hub mints one `issue_op` per receiver, so each node gets its own id
(§5.4 rule 1 — two receivers are two distinct commands), walks its own ladder,
and is audited individually. One shared broadcast frame would put N nodes on
one id, which is exactly the idempotency model the write path is built on. The
response lists every minted command; the dashboard confirms `closeall` before
sending, because that one queues a close for every mirrored position on every
receiver.

## Alerts (M6)

`hub/src/alerts.rs` evaluates five rules every **5 s** — a cadence of its own,
not `--stats-every`, because a dead node is worth noticing in five seconds
rather than thirty. Each rule fires an alert that is written to BOTH surfaces:

* the M7 audit log, as `alert.<kind>` with actor `hub` — durable, greppable;
* a bounded in-memory ring, read by `GET /api/v1/alerts`, pushed in every
  WebSocket snapshot, and drawn as a red bar at the top of the dashboard.

| kind | fires when | severity |
|---|---|---|
| `node.offline` | a node has been quiet for 60 s (the registry's offline threshold) | critical |
| `node.clock.drift` | the node's own `TS` sits ≥300 s from the hub's clock | warning |
| `risk.blocked` | the receiver's STAT reports `BLOCKED>`0 — entries its risk gates are holding | warning |
| `risk.tripped` | the receiver's STAT reports `RISK=<trip key>` — a limit tripped | critical |
| `command.unknown` | a command exhausted the 2/5/15/60 ladder unanswered (including journalled ones re-seen after a hub restart) | warning |

The two rules that make it usable: **dedup with a silence window** (one
`node.offline` per incident, not per evaluation) and **re-arm** (a node that
comes back and dies AGAIN is a second incident and fires immediately — the
window covers repetition during one outage, never across outages). Orphan
positions stay the receiver panel's job (§10 layer 2): the hub cannot see a
receiver's mirror table, and pretending otherwise would be the kind of
confident wrongness this project keeps un-learning.

`tools/hub_alerts_test.py` fires drift, blocked, tripped, offline and the
silence window against the real binary.

## The audit log (M7)

`copier-hub` appends to **`audit.jsonl`** — one JSON object per line, in the
plan's §15 `audit` shape (`seq, ts, actor, ip, action, node, before, after,result`). `GET /api/v1/audit?limit=&since=` reads it, bounded.

**A file, not SQLite, and the reason was measured.** The plan's §15 puts
`audit` in SQLite and that is still where it should end up. It is not what it
is built on today: `rusqlite` with `bundled` fails in `libsqlite3-sys`'s build
script with

```
Compiler family detection failed: ToolNotFound: failed to find "gcc.exe"
```

The `cc` crate wants a plain `gcc.exe`; the Rust GNU toolchain ships
`x86_64-w64-mingw32-gcc.exe` and no unprefixed alias, and adding MSYS2's whole
`mingw64/bin` would shadow Rust's `ld`/`gcc` — the `ld: cannot find crt2.o`
failure `build.sh` section 2 documents. So SQLite is real work and it belongs
with **M11**, which is where the plan already puts the storage layer.

What is needed now is the *property*, not the engine. An audit log's defining
property is that records are **appended and never rewritten**, and a file
opened in append mode gives that more directly than a database does — there is
no `UPDATE` statement to be talked into. It is also greppable and `tail -f`-able
by hand, which matters for something whose job is to be evidence.

### Three properties, each with a test

1. **Append-only.** Opened `append`, never seeked, never truncated.
   `a_record_only_ever_appends` reads the bytes, appends, reads again, and
   requires the second to be the first plus a suffix.
2. **No silent gaps.** Every record carries a monotonic `seq`, continuing
   across a restart. Without it, a lost line is indistinguishable from an event
   that never happened — which is the difference between evidence and a log.
   For the same reason a restart writes a `hub.started` record, so a gap has an
   explanation rather than looking like tampering.
3. **A write failure is loud.** Counted and printed, never swallowed. An audit
   that quietly stopped recording an hour ago looks exactly like proof that
   nothing happened.

A **torn last line** (a crash mid-append) is skipped and counted as `torn`; a
bad line in the *middle* is counted separately as `skipped`, because in an
append-only file that should be impossible and "impossible" deserves its own
number.

**If the audit cannot be opened, the hub refuses to start.** That is the one
place here where refusing is right: everywhere else the hub degrades and says
so, but an audit that is silently off produces the same output as a hub where
nothing happened. `--audit none` is the explicit way to turn it off, and it
prints that it is off.

### What is recorded today, and what is not

Recorded: `hub.started`, `hub.stopped`, `node.registered` (including the
lost-REG case), `node.named`, `node.offline`, `node.online`, `node.evicted`,
`node.malformed`, `snapshot.mismatch`.

**Recorded now include the operator actions.** With M4/M5 the write path exists,
so `config.changed`, `config.rolled_back`, `config.acked`, `config.rejected`,
`config.unknown_ack`, `config.drift`, `config.timeout`, and the `command.*`
equivalents (`command.issued/acked/rejected/unknown_ack/timeout`) are written into
the same log. The schema was the plan's §15 row precisely so those could land in
the same file rather than starting a second one. **M9 adds its own families**:
`user.bootstrap` (first admin), `user.upsert`, `user.delete`, `auth.login`,
`auth.logout`, `auth.denied` (a logged-in role below the endpoint's bar —
the 401s are not audited: an unauthenticated hit is noise, an authenticated
denial is intent), and `alert.*` from M6.

Only *transitions* are recorded, never states — `node.offline` fires once when
a node goes down, not every two seconds while it stays down. A log that repeats
itself is a log nobody reads, and then a log nobody checks.

## Not yet

- **Key ROTATION is manual (the plan's G15).** CURVE itself is implemented -
  see below - but rotating a client key is "stop that node, delete its
  `copier_curve.key`, restart it, put the new public key in
  `curve_clients.txt`, restart the hub". The allow-list is read once at
  startup; there is no reload. Deliberately P2: a key is not a credential
  that leaks on a schedule, and a hub link on a private network is not
  attacked by key theft.
- **No orphan-position alert from the hub (the rest of M6 is done).** The
  receiver's panel owns that view (§10 layer 2); the hub cannot see a
  receiver's mirror table. Offline / clock drift / risk / command-unknown all
  fire — see Alerts (M6) above.
- **No SQLite.** The operational state (registry, positions) is deliberately
  in-memory; the audit, config revisions, command journal and now the user
  table are JSON/JSONL files, which §15 calls the Phase-1 shape. SQLite is M11.
- **No CURVE.** The EAs open the central channel with CURVE off (Phase 1). A
  hub link across a public network is therefore plaintext — put it on a private
  network or a VPN.
- **The position view (M3) reads `SNAP`.** This is the one place the hub parses a
  payload rather than moving it, so the boundary is worth stating: the parse is
  **read-only**, it happens **after** the forward, and it produces a **separate**
  structure. Nothing on the forward path consults it, and the bytes that go out
  are the bytes that came in — `tools/hub_positions_test.py` asserts that
  byte-for-byte, because if it ever stops being true every other guarantee here
  is void. The view is keyed by the envelope's `SID`, never by the topic: a
  targeted repair is published on the *receiver's* nid, so keying by topic would
  file that receiver as a sender holding somebody else's book.

## A build note for what comes next

**It builds. `tokio` + `axum` compile and link here.** If you were told
otherwise, that was a wrong conclusion, corrected on 2026-10-13 — this section
used to say "tokio does not build on this machine", and it was believed for a
while because the failure looks identical whichever crate pulls `windows-sys`.

What was actually true: the Rust GNU toolchain ships its own `dlltool` **but
not the assembler that `dlltool` calls**. Any crate that generates a Windows
import library died with a message that named nothing useful:

```
dlltool.exe: CreateProcess
```

The chain is not about any particular framework — `tokio → mio → windows-sys`
and `rust-embed → walkdir → same-file → winapi-util → windows-sys` both end at
the same wall, which is why the error was misread as "async cannot build here".

**The fix, and the two ways to get it wrong** — see `hub/build.sh` section 2,
which vendors `third_party/binutils/` and documents them:

1. A **complete** set is needed: `dlltool` **and** `as` **and** `ar`. `as` on
   `PATH` alone still leaves `dlltool` unable to finish.
2. The **PATH order** is load-bearing. `third_party/binutils` must come *before*
   Rust's `self-contained`. Inverted — or by putting the whole mingw64 tree
   first — the hub fails with `ld: cannot find crt2.o`, because that also
   shadows Rust's `ld` and `gcc`, which know where the CRT objects live. Hence
   a directory of exactly three tools and nothing else.

The hub keeps its hand-rolled signal handler (no `ctrlc` crate) — that was a
separate, deliberate choice, not a consequence of the above.

`sqlx` was never tested here; if it is wanted, check it the same way before
believing any verdict about it.

