# MT4 / MT5 Trade Copier over ZeroMQ

A self-hosted replacement for FX Blue Personal Trade Copier.

The motivating problem was not throughput — it was that the FX Blue copier  
grows in memory until the terminal has to be restarted, and that its one-to-many  
and many-to-one setups are painful to configure.

**Swapping the transport for ZeroMQ only fixes latency and reconnects. The  
memory growth is a state-management problem, and that is what this design  
attacks head-on.**

---

## Design in one screen

| decision    | choice                                                                              | why                                                                                                                                                                                                              |
| ----------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| topology    | pure EA-to-EA, no middle process                                                    | simplest to deploy; the protocol leaves room for a hub later                                                                                                                                                     |
| consistency | event stream + periodic **full snapshot**                                           | the snapshot is authoritative, events are only a latency optimisation. A lost message costs a few seconds, never correctness                                                                                     |
| identity    | `UID` written into the **receiver's** order comment, as `tc\|<uid>\|<senderTicket>` | the sender is a pure observer and cannot write comments on orders it did not place; the UID goes first so venue truncation can only ever cost the cosmetic ticket                                                |
| many-to-one | each sender tracked **independently**                                               | own sequence counter, own magic number, own desired-position set — two senders can hold opposing positions on one symbol                                                                                         |
| transport   | ZeroMQ **XPUB/XSUB**, one socket, both directions                                   | events and snapshots share a port; `CONFLATE` is a per-socket option so it cannot be used here — the conflation is done in the receiver's drain loop instead, by applying only the newest snapshot of each batch |
| disconnect  | stop new entries, **keep existing positions**, alert                                | never force-closes at an unknown price                                                                                                                                                                           |

### Why the snapshot matters more than the events

A receiver that misses a `CLOSE` event is wrong until the next snapshot — a few  
seconds. A receiver that misses a `CLOSE` and has no snapshot is wrong forever.  
That single property is why this design does not need reliable delivery, ACKs,  
replay logs, or an ordered transport, and why it stays small.

---

## Repository layout

```
src/Include/Copier/     the library (platform-neutral except CopierDefs/CopierModel)
  CopierDefs.mqh          constants, normalised position struct, platform shims
  CopierCodec.mqh         wire protocol encode/decode
  CopierLog.mqh           size-rotated, rate-limited logger
  CopierState.mqh         fixed-size tables + state file
  CopierModel.mqh         THE ONLY place with #ifdef __MQL5__
  CopierSymbol.mqh        per-sender symbol translation
  CopierSizing.mqh        lot conversion and normalisation
  CopierConfig.mqh        copier.ini reader
  CopierIgnore.mqh        the IgnoreUids list (per-position opt-out)
  CopierRisk.mqh          risk switches (circuit breakers)
  CopierTransport.mqh     ZeroMQ plumbing
  CopierCurveKey.mqh      the CURVE keypair file (auto-generated per terminal)
src/Experts/            CopierSender, CopierReceiver
src/Scripts/            CopierSelfTest, CopierZmqProbe
tools/                  copier.bat   <- the Windows entry point for all of these
                        status.sh, lib.sh, targets.conf, fetch-deps.sh,
                        patch-zmq.py, deploy.sh, compile.sh, build.sh,
                        clean.sh,
                        pilot-setup.sh, phase2-setup.sh, phase3-setup.sh,
                        logcheck.sh, logcheck.py, logcheck.bat,
                        sniff.sh, sniff.bat, zmq_sniff.py,
                        tests.sh, tests.bat <- every contract suite, no broker
                                                and no terminal (see Layer 1.6)
                        zmq_fanout_test.py, zmq_conflate_size_test.py,
                        zmq_topic_test.py,
                        snapshot_receipt_test.py  <- hash + receipt contracts,
                                                      incl. the PROTOCOL.md example
                        snapshot_repair_test.py   <- debounce / rate-limit model
                        modify_event_test.py      <- MODIFY payload, override,
                                                      throttle semantics
                        hub_stat_path_test.py     <- receipt relay + log volume
                        hub_positions_test.py     <- M3 view, and byte-for-byte
                                                      forwarding preserved
                        hub_api_test.py           <- M8/M10/M7: read endpoints,
                                                      dashboard, WS handshake,
                                                      audit log, http defaults
                        hub_config_test.py        <- M4a: the config store, the
                                                      write gate, CFG/ACK/CFGR
                        hub_commands_test.py       <- M5a: the command engine,
                                                      CMD wire frame, op validation
                        hub_proto.py, hub_proto_test.py, hub.sh, hub.bat,
                        hubrs.bat    <- run the RUST hub (see hub/)
                        hublog.bat   <- run the hub with stdout also going to
                                      hub.log, so the log is readable afterwards
                        inputcheck.py  <- input labels must fit the dialog;
                                          run by build.sh before deploying
hub/                    the Rust hub (Phase 1 routing + Phase 2 registry +
                        M3 read-only position view + M7 audit + M8/M10
                        REST/WS API and its self-contained dashboard)
                        Cargo.toml, src/, build.sh, README.md
third_party/zmq-prefix/ the EAs' own libzmq 4.3.5, prepared for Rust linking
                        (include/zmq.h, lib/libzmq.a, lib/libzmq.dll)
config/                 copier.ini.example, copier.loopback.ini,
                        copier.mt4receiver.ini, copier.mt4to4.ini,
                        copier.mt5receiver.2senders.ini
doc/PROTOCOL.md         full wire format
doc/PILOT.md            end-to-end acceptance test (MT5 pair), step by step
doc/PILOT-MT4.md        P2: putting MT4 in the loop, in three phases
doc/CENTRAL-HUB-PLAN.md central-hub architecture plan (TIER 2: the
                        transparent-proxy hub + registry + M3 position view +
                        M7 audit + the REST/WS API and its dashboard are BUILT
                        and running; the WRITE half (M4 config push, M5
                        commands) is implemented behind the `--writes on` gate -
                        see hub/README.md. EA-side M5b (acting on OP=) is still
                        pending)
doc/PHASE1-DESIGN.md    Phase 1 transparent-proxy design (BUILT: EAs + hub/)
```

`src/Experts/CopierSender.mq4` and the deployed `.mq5` are **the same file**.  
One source tree, two targets — `tools/deploy.sh` renames on copy. There is no  
second copy of the logic to keep in sync.

---

## Install

```bash
./tools/status.sh            # FIRST: what terminals exist, where, and what's deployed
./tools/fetch-deps.sh        # download mql-zmq into third_party/
./tools/build.sh             # deploy THEN compile - the normal one command
```

`deploy.sh` and `compile.sh` are the two halves, and **the order matters**:  
`compile.sh` compiles whatever source is *already* in each terminal's folder,  
so it never reads `src/`. Running it first builds the previous revision, and  
`deploy.sh` then copies the new sources in without recompiling — every  
terminal ends up one revision old while still reporting `4/4 compiled`.  
`build.sh` is just those two in the right order; use it unless you need one  
half on its own. `status.sh` reports `FRESH=no` when this has happened.

```bash
./tools/deploy.sh            # patch mql-zmq + copy sources and DLLs to the targets
./tools/compile.sh           # compile there and print the compiler logs
```

**On Windows, use `tools\copier.bat` instead** — the tools are shell scripts and  
`cmd` cannot run them directly:

```cmd
tools\copier.bat status
tools\copier.bat build       :: deploy then compile (preferred)
tools\copier.bat deploy
tools\copier.bat compile
tools\copier.bat phase2      :: or: pilot / logcheck / sniff / clean / deps
```

It finds bash, forwards the sub-command to the matching script, and passes  
any extra arguments through. `logcheck` and `sniff` are Python and do not  
need bash, but they are reachable from the same place so there is one  
command to remember. `tools\copier.bat help` lists everything.

**Run `status.sh` first, every time something "doesn't show up in MetaTrader".**

### Which terminal gets the files

MetaTrader keeps its **data** in `%APPDATA%\MetaQuotes\Terminal\<32-hex-id>`,  
and that id is derived from the **install path** — so two installations of  
the same platform have two completely separate data folders. Deploying into  
the wrong one looks like it worked: the files are on disk, in a folder no  
running terminal ever reads. On this machine there are two MT5 installs  
(`C:\Program Files\MetaTrader 5` and `E:\MetaTrader 5`) and eight MT4 ones.

`tools/targets.conf` is where you list the terminal ids you actually use.  
If it lists nothing, every terminal found is used. `status.sh --all` prints  
everything installed, with install paths, so you can copy the right ids in.

```
  TERMINAL ID                        PLAT   SOURCES   DLLS    COMPILED
  287469DEA9630EA94D0715D755974F1B   MQL4   ok        ok      4/4 ex4
  D0E8209F77C8CF37AD8BF550E51FF075   MQL5   ok        ok      4/4 ex5
```

`SOURCES=STALE` means the deployed copy differs from `src/` — run  
`deploy.sh` then `compile.sh`. `DLLS=MISSING` means `libzmq.dll` is not in  
that terminal's `Libraries` folder and the EAs will fail at load with  
"DLL not found". (`libsodium.dll` is no longer needed — it is linked  
statically into `libzmq.dll` as of the 4.3.5 upgrade.)


### Portable installs

A **portable** install (`terminal64.exe /portable`, often shipped with a  
`Mt5-Portable.bat`) keeps its data **next to the executable**, not in  
`%APPDATA%`. `%APPDATA%` can still hold an older, **stale** folder for the  
same installation, and which one is live depends on how the terminal was  
launched. Deploying into the stale one is silent — files on disk, compiler  
happy, nothing running ever reads them.

Two things make this visible and survivable:

- the `LAST USED` column in `status.sh`. The live folder is the one with a  
  recent timestamp; on this machine that immediately separated  
  `E:\MetaTrader 5` (today) from `%APPDATA%\...\6F9C869F...` (months ago).
- a target may be given as an **absolute path** in `targets.conf`, which is  
  how you name a portable data folder:
  ```
  /e/MetaTrader 5
  ```

`compile.sh` also handles portable targets automatically.

MetaEditor has one hard rule that a portable install breaks: **it will only  
compile a source that lives under the standard  
`%APPDATA%\MetaQuotes\Terminal` root.** Point `/compile:` at a `.mq5` in a  
portable data folder and it produces no log, no binary and **no error** — it  
silently does nothing. It cannot even read `/include:` from there.

So for a portable target the sources are staged under the terminal root,  
compiled there, and the `.ex5`/`.ex4` copied back. The staging folder is a  
persistent **build cache**: the `Include` tree is copied once, only our own  
headers and sources are refreshed each run, and nothing is ever recursively  
deleted (`./tools/clean.sh` removes it if you want the space back).

`compile.sh` additionally tries every MetaEditor it can find for the  
platform until one actually produces a compiler log, and falls back to  
telling you to press F7 only if none does. In practice the staging fix alone  
is sufficient — the editor that appeared to be broken compiles the staged  
source perfectly.

Then, in each terminal:

1. Enable **Allow DLL imports** in the EA properties (Tools → Options →  
   Expert Advisors only sets the default for *newly added* EAs).
2. Turn **AutoTrading** on, and tick "Allow live trading" on the receiver.

No Visual C++ runtime is needed: since the 4.3.5 upgrade `libzmq.dll` is a  
MinGW-w64 build that imports only system DLLs, and it has no separate  
`libsodium.dll`.

### Sender

Attach `CopierSender` to one chart on the account you want to copy **from**.  
It never trades, so it can run on a read-only *investor* password.

Key inputs: `BindAddress`, `EventsPort`, `SnapshotSeconds`, `CurveSecretKey`  
(when `UseCurve` is on).

There is **no `SenderId`**: the sender's identity is its `EventsPort`. A port  
cannot be bound twice on one machine, so it is already unique there, and both  
ends derive the same string from it — one less input, and no way to mistype one  
side into silence (a receiver ignores an SID it does not recognise, without  
saying so). On a multi-host setup, where two senders may legitimately share a  
port, give them different ports or use `copier.ini`, which still accepts an  
explicit `id=` per sender.

`EventsPort` is the **only** port bound — events and snapshots share it, so  
there is no second port to set. (An older build had a `SnapPort` input for a  
separate snapshot socket. Once both streams moved onto one socket it became a  
dead field that only produced a startup note, and it has now been removed  
outright rather than kept as decoration.)

> **Input comments start with the variable name — keep it that way.**  
> MetaTrader's input dialog shows the *comment* instead of the variable name  
> whenever one is present. A comment like `// 0 = off. Cap on concurrent
> positions` therefore appears with no clue which input it belongs to, and  
> five risk switches all reading `0 = off.` is exactly what that produces.  
> `// MaxOpenPositions - 0 = off. Cap on concurrent positions` is readable.

### Receiver

1. Copy `config/copier.ini.example` to `<terminal>\MQL4\Files\copier.ini`  
   (or `MQL5\Files\`).
2. Fill in one `[senderN]` section per sender: `id`, `events`, `snap`,  
   optional `serverkey`, `lotmode`/`lotparam`, `magic`, and any  
   `symbol.SenderName=YourName` mappings.
3. Attach `CopierReceiver` to one chart. **One instance handles all senders.**

Three behaviours worth knowing before you go live:

- **A partial close on the sender trims the mirror** and rewrites the order  
  comment with the full identity (`tc|<uid>|<senderTicket>`). MT5 writes the  
  *closing deal's* comment back onto the position, so the receiver builds the  
  close request by hand to carry it — a close with no comment would otherwise  
  erase the token rather than merely fail to update it.
- **One UID maps to one position, and the receiver enforces it.** If two  
  positions ever end up sharing a UID, the extra one is invisible to every  
  other loop, so it is removed rather than left doubling the exposure.  
  `DedupDuplicates` (default `true`) turns the removal off, leaving a warning.  
  The survivor is the one matching the sender's volume, else the one whose  
  comment is still readable, else the older one.
- **SL/TP is mirrored as a distance from the entry**, not as a price, and  
  removal propagates. `MirrorStops` (default `true`) turns it off entirely.  
  See *How SL/TP is mirrored* below for the consequences.

### CURVE keys

CURVE is a **two-sided** handshake, and the two sides are not symmetrical. The  
sender is the **server**; every receiver is a **client**.

**The keypair is automatic.** Each EA generates its own on first start and  
reuses it from then on. There is nothing to paste, no script to run, and no  
`CurveSecretKey`/`MySecretKey` input to get wrong.

| side         | keypair comes from                          | the one key you configure                                      |
| ------------ | ------------------------------------------- | -------------------------------------------------------------- |
| **sender**   | generated into `MQL\Files\copier_curve.key` | *nothing*                                                      |
| **receiver** | generated into `MQL\Files\copier_curve.key` | `SenderServerKey` = the **sender's** public key (from its log) |

So the whole setup is:

1. Put `UseCurve=true` on both sides.
2. Start the sender. Its Experts log prints:
   ```
   ================= CURVE PUBLIC KEY (sender) =================
     <40-char public key>
     This is THIS sender's public key. Copy it to the OTHER side:
       -> each receiver's  SenderServerKey  input
   ```
3. Copy that one line into each receiver's `SenderServerKey` input. Done.

**Why only the sender's key is configured.** The receiver's own keypair is not  
something anyone else needs in advance: the client sends its public key in the  
CURVE HELLO, and the server encrypts its reply to it. So the receiver can  
generate its key locally at any time without any coordination — which is  
exactly what makes the receiver side fully automatic. The sender's public key  
is the only value that *belongs to the other machine* and therefore has to be  
carried across by hand.

**Rotating a key.** Stop the EA, delete `MQL\Files\copier_curve.key`, start it  
again. A new keypair is generated and the new public key is printed.

- Rotating a **receiver**'s key is entirely local — nothing on the sender or in  
  any `copier.ini` has to change (the receiver's `serverkey=` holds the  
  *sender's* key, which did not change).
- Rotating a **sender**'s key means re-copying its new public key into every  
  receiver's `SenderServerKey`.

**When the file is replaced without asking.** A key file that merely fails to  
load is overwritten with a fresh keypair, and the replacement is logged at WARN  
level. That covers: wrong or missing magic line, a key that is not exactly 40  
characters, and a `PUBLIC` that does not match what `SECRET` derives. A file  
that loads is never touched. (A keypair has no history and no meaning outside  
its terminal, so discarding an unreadable one costs a regenerated key, whereas  
keeping a broken one costs a copier that silently never connects.)

**Why the file at all.** A 40-character secret that is copied by hand can be  
truncated, wrapped over two lines, or given a trailing space — and a malformed  
CURVE key does not fail, it simply never completes a handshake, with nothing in  
any log to say why. The file also lets `PUBLIC` always be *derived* from  
`SECRET` (`zmq_curve_public`) and the two cross-checked, so the two halves can  
never disagree.

> **What CURVE does NOT do here: the sender does not check WHO is connecting.**  
> The client verifies the server; the server accepts any client that knows its  
> public key, because the copier installs no ZAP handler and no client  
> allow-list. So CURVE gives you confidentiality and a guarantee that you  
> reached the right sender — not authorisation of the peer.
>
> That is why the sender still needs an **IP allow-list on its VPS**. The two  
> are complementary, not alternatives: CURVE protects the payload, the  
> allow-list decides who may open the connection.

> **Hub mode has no CURVE yet.** The central channel is opened with CURVE off  
> on both sides by design (Phase 1). A hub link across a public network is  
> therefore plaintext for now — put it on a private network or a VPN.

---

## Hardening: what bounds a hostile peer

Both the sender and the hub **bind an inbound port**, so both can be reached by  
anything that can route to them. Four controls, in the order a bad packet meets  
them:

| layer                           | control                     | what it stops                                                                                                           |
| ------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| firewall / cloud security group | **IP allow-list**           | the connection never forms. This is the primary control — see the plan's §19.1                                          |
| libzmq                          | **`ZMQ_MAXMSGSIZE` = 1 MB** | a peer announcing an oversized frame is **disconnected during the frame read**, before libzmq allocates anything for it |
| libzmq                          | **`RCVHWM` = 1000**         | a peer that floods messages fills a bounded queue and then blocks or drops; nothing grows without limit                 |
| parser                          | **`CP_MAX_MSG_LEN` = 1 MB** | a frame that got through is rejected rather than parsed                                                                 |


**`ZMQ_MAXMSGSIZE` is the one that is easy to leave out, and the one people  
usually mean.** A length check in the application feels like the same thing, but  
it is not: the app sees the message only *after* libzmq has read the whole frame  
off the wire and buffered it. By then the allocation has already happened, and  
the attacker's goal was the allocation. The transport-level option is the only  
one that acts early enough, and it disconnects rather than buffers.

`ZMQ_MAXMSGSIZE` and `CP_MAX_MSG_LEN` are deliberately **the same number**  
(`CP_MAXMSGSIZE`), so the transport can never refuse a frame the parser would  
have accepted, and the two cannot drift apart.

> **On the hub, this matters more than on a node.** A hub is a fan-out: one  
> oversized frame it accepted would be copied to every subscriber, so the cost  
> of a missing limit is multiplied by the number of connected nodes.

Not set, and available if you want them: `ZMQ_HANDSHAKE_IVL` (how long a peer  
may take to complete the ZMTP handshake — the default 30 s already bounds it)  
and `ZMQ_BACKLOG` (the listen backlog, default 100). Neither is a substitute  
for the allow-list.

---

## Monitoring: the hub dashboard and the audit log

If you run the central hub, it also serves a **read-only** dashboard and a REST
API on `--http`, default **`http://127.0.0.1:6010/`**:

```bash
tools\hublog.bat        # starts the hub, and ALSO writes its output to hub.log
# then open http://127.0.0.1:6010/
```

It shows the nodes (state, name, held positions), the per-sender position view
the hub derives from `SNAP`, and the topology — including the **mirror edges**,
which the hub learns as a by-product of relaying snapshot receipts.

| Method | Path | Answers |
|---|---|---|
| GET | `/` | the dashboard — one self-contained HTML file, compiled into the binary |
| GET | `/api/v1/nodes` · `/nodes/{id}` | nodes, and one node with its positions |
| GET | `/api/v1/topology` | senders, receivers, and the edges between them |
| GET | `/api/v1/positions` | the M3 position view as data |
| GET | `/api/v1/audit` | the append-only audit log, bounded (`?limit=&since=`) |
| GET · PUT | `/api/v1/config` · `/nodes/{id}/config` | the config version store; **PUT is 403 unless `--writes on`** |
| POST | `/api/v1/nodes/{id}/commands` | operational command (`pause`/`resume`/`closeall`/`reload`) → **202** + `command_id`; **403 unless `--writes on`**, **400** for unknown op |
| GET | `/healthz` · `/readyz` | liveness, and "is there anyone here yet" |
| WS | `/api/v1/stream` | a full snapshot on connect, and one per change |

**The audit log is `audit.jsonl`** — one JSON object per line, in the plan's §15
`audit` shape (`seq, ts, actor, ip, action, node, before, after, result`).
Append-only is the whole design, and three consequences are worth knowing: it is
greppable and `tail -f`-able by hand; every record carries a monotonic `seq` so a
*missing* one is detectable; and if it cannot be opened the hub **refuses to
start** rather than run unaudited — `--audit none` is the explicit way to turn it
off. (SQLite is M11: `rusqlite` does not build here yet, and the audit needs the
property, not the engine — see `hub/README.md`.)

> **The default `--http` is loopback while the ZMQ port's is not, and that
> difference is the whole point.** The hub's `--port` binds `0.0.0.0` and the
> plan's §19.1 makes the firewall its trust boundary. This port exposes **every
> position the hub has seen**, so it must not inherit that default: reaching it
> from another machine is the explicit `--http 0.0.0.0:6010`, and
> `--http none` turns it off.

**The write endpoints there are, take two keys, and both default to off.**
`PUT /api/v1/nodes/{id}/config` records a config revision and pushes it as
`CFG`; `POST /api/v1/nodes/{id}/commands` issues an operational command and
pushes it as `CMD`. Both share one command engine (issue → retry → ack, same
`202` + `command_id` semantics, same audit trail) — see `hub/README.md` and
`doc/CENTRAL-HUB-PLAN.md` §5.4.

| side | gate | default |
|---|---|---|
| hub | `--writes off` | answers **403**, never emits a `CFG`/`CMD` |
| receiver | `AcceptConfigPush = false` | ACKs `OK=0`, does not touch the file |

Two keys rather than one, because config push is the only operation in the system
that can stop a receiver from starting — and §19.1 makes the firewall the *only*
trust boundary on the hub port, with no token. Until M9 (users and roles) exists,
the honest position is that the hub and the EA *can* do this and are *not* doing
it. Commands (M5a, hub side) are issued and audited behind the same gate; the
receiver side that *acts* on `OP=` (M5b) is not built yet, so a `CMD` is today
acknowledged but not yet obeyed by the node.

**These are the only write endpoints, deliberately.** Config push and commands are
M4/M5, with their `202` + `command_id` semantics and their audit trail; the
audit log landed first (M7) so that those have somewhere to be recorded, and
the config store landed next (M4a) so that they have something to act on. See `hub/README.md`, and `tools/hub_api_test.py` plus `tools/hub_config_test.py` /
`tools/hub_commands_test.py` for what is asserted about all of the above (the API
suite plus 54 + 37 checks, against the real binary).

---

## Two findings about mql-zmq you need to know

`mql-zmq` is the right building block, but as published it **does not compile  
on current MetaTrader builds**. Both problems are handled by  
`tools/patch-zmq.py`, which `deploy.sh` runs automatically:

1. **`char` vs `uchar`.** Modern MQL made these distinct, and  
   `StringToUtf8` / `StringFromUtf8` now take `uchar[]`. The binding is  
   full of `char[]` and fails with `error 246: parameter convertion type
   'char[]' to 'uchar[] &' is not allowed`. 20 mechanical replacements.
2. **`Debug` is a macro.** `Mql/Lang/Mql.mqh` does  
   `#define Debug(msg) PrintFormat(...)`. Any `something.Debug(x)` call in a  
   translation unit that includes the binding gets macro-expanded into  
   garbage. The logger method here is therefore called `Verbose()` — do not  
   rename it back.

Also worth knowing: `FileMove` could not be resolved to a stable parameter  
count on either compiler tested (2-arg and 3-arg both rejected), so the code  
never calls it. See "Deviations" below.

1. **The DLL folders are `Library/MT4` and `Library/MT5`, not  
   `Library/MQL4`/`Library/MQL5`.** `deploy.sh` originally built the path  
   from the platform folder name (`MQL5`), which does not exist — so the  
   guard failed, nothing was copied, and it was silent: the EA compiles  
   perfectly and only breaks at load time with "DLL not found". `status.sh`  
   now reports the DLL state per terminal so this cannot hide again.

---

## One more MQL4/MQL5 divergence

`StringTrimLeft` / `StringTrimRight` do **not** behave the same on both  
platforms. One trims in place through a `string&` parameter; the other  
returns the trimmed value and leaves the argument alone. Calling them and  
discarding the result therefore works on MT5 and is a silent no-op on MT4.

The damage was subtle and one-sided: a config line written as  
`id = alpari01` (spaces around the `=`) produced the key `"id "` with a  
trailing space on MT4, so every lookup of that key missed — while  
`id=alpari01` worked fine, and MT5 was unaffected. Exactly one assertion  
in the self-test failed, on exactly one platform.

`CopierTrim()` in `CopierDefs.mqh` now does the trimming by hand with  
`StringGetCharacter`, and nothing in this codebase calls the built-ins.

---

## Bugs the self-test caught (kept here as a warning)

`CopierSelfTest` is not decoration. Two real defects in this codebase were  
found by running it, not by reading it.

### 1. Phantom slots — MQL does not reliably zero-initialise struct arrays

`CopierPosTable` originally had a constructor of the form  
`CopierPosTable():m_n(0) {}` — it set the counter and never touched the  
512-element `m_p[]` array. `CopierPos` contains `string` members, and MQL  
does **not** reliably zero-initialise an array of structs that contain  
strings. The table therefore started life with slots that reported  
`used == true` while holding an empty UID.

The symptoms were misleading. `PruneTo()` walked all 512 slots, found the  
phantoms, saw that their (empty) UIDs were not in the desired set, and  
"removed" them — so it reported removing far more rows than were ever  
written, and the count came out wrong, while `Find()` and `CopyTo()` looked  
perfectly healthy. It took a Python re-implementation of the exact algorithm  
to prove the logic was correct and that the difference had to be MQL's  
initialisation behaviour.

In production this was worse than a failing test: phantom slots would have  
been exported by `CopyTo()` into every SNAP message as positions with an  
empty identity, and the sender's close-detection loop would have emitted a  
CLOSE for an empty UID on every tick.

**The fix is one line** — call `Clear()` from the constructor — plus making  
occupancy mean `used && uid is well-formed` everywhere rather than trusting  
`used` alone. `CopierSeenRing` had the same defect and the same fix; there,  
junk keys would have made `Has()` report real trade actions as already done  
and silently skip them.

**Rule: any MQL class holding an array of structs (or of strings) must  
`Clear()` it in the constructor. Never assume zero-initialisation.**

### 2. `CopierNormalizeLot` clamped away the information it needed

The function snapped a volume to the broker's lot step and then clamped it  
up to `MINLOT`. That made "below the broker minimum" and "exactly the  
broker minimum" indistinguishable to the caller, so a signal that should  
have been rejected was instead placed at the minimum lot — silently  
multiplying risk on a small account. The minimum-lot decision now lives  
solely in `CopierComputeLots()`, which can still see the shortfall.

### 3. Log rotation driven by restarts, not by size

`CopierLog::Init` used to pick "the generation after the newest one that  
exists" and then delete it. The intent was to recycle the oldest generation  
when the log filled up; the effect was to **destroy one generation of history  
on every EA restart**, however small it was.

Measured on the first MT4 pilot: the receiver's log became three disjoint  
time windows with an **11-minute hole**, and a genuine divergence became  
indistinguishable from missing history. Chasing that cost more time than the  
bug itself.

Rotation must be driven by **size**, never by process restarts — otherwise  
the moment you most need the evidence (a restart-heavy debugging session) is  
exactly when it is thrown away. The current generation is now tracked in a  
`copier_<tag>.gen` sidecar and restarts **append**; only a size-driven  
rotation recycles.

### 4. Silent skipping hides unmanageable orders — and a wrong conclusion

`LocalForSender()` requires an order to carry one of our magic numbers **and**  
to yield a UID from its comment. Anything else is skipped with a bare  
`continue` — no log line. That is a genuine blind spot, and  
`ReportUnreadableOwnOrders()` now runs at start-up and reports each such order  
at ERROR level **including the raw comment**, so an invisible failure becomes  
a one-line answer.

**But this is also the story of a wrong diagnosis, which is the more useful  
part.** Chasing what looked like orphaned positions on the MT4 pilot, two  
orders were identified as opened-and-never-closed. The evidence seemed solid:  
across two receiver sessions, in which the receiver correctly closed 13 other  
orders, it never once *attempted* to touch those two.

The conclusion was wrong, and the reason matters:

> **The copier's log records only what the copier did.** A position closed by  
> hand, by another EA, or by the broker leaves **no line** — correctly. The  
> MT4 **Journal** (`<terminal>\logs\YYYYMMDD.log`) is the complete record.

Reconciling the two settled it instantly: the Journal had **59** closes, the  
copier's log **53**, and the six missing ones had all been closed by hand (the  
Journal even shows `one click trading has been enabled` three seconds before  
the first). There were never any orphans.

Two rules come out of this:

- When reconciling a copier against an account, use the **copier's log to  
  attribute** and the **terminal Journal to establish what happened**. Never  
  infer "the copier failed to close X" from the copier's log alone.
- **Never run two copiers on one account.** FX Blue's receiver was loaded on  
  the same chart during this pilot; two copiers will each treat the other's  
  positions as things to close or open, producing a stream of orders neither  
  can explain.

### 5. `ZMQ_CONFLATE` on a PUB socket, on the libzmq the binding ships

The snapshot socket was `PUB + SNDHWM=10 + CONFLATE=1`. A protocol sniffer  
showed its messages arriving at the subscriber **completely empty** — five  
snapshot messages in ten seconds, every one of them zero-length — while the  
events socket (same PUB, no CONFLATE) was perfectly healthy.

What made this expensive to find is that it does not reproduce on a modern  
libzmq. Ruled out, each with an actual experiment rather than reasoning:

| hypothesis                                    | test                                              | result                              |
| --------------------------------------------- | ------------------------------------------------- | ----------------------------------- |
| CONFLATE breaks fan-out to the 2nd subscriber | `zmq_fanout_test.py`                              | 40/40 to both — **innocent**        |
| CONFLATE corrupts larger payloads             | `zmq_conflate_size_test.py`, 16 B / 1.2 KB / 8 KB | intact at every size — **innocent** |
| non-blocking send interacts badly             | same test with `ZMQ_DONTWAIT`                     | intact — **innocent**               |
| the binding's `StringToUtf8` truncates        | read the source                                   | fine for ASCII — **innocent**       |

`mql-zmq` shipped **libzmq 4.2.0** from 2016 at the time of this  
investigation; the tests above ran on **4.3.5**. The remaining difference was  
the library, not the topology.

> **Update:** both sides now run **libzmq 4.3.5** (see `hub/README.md`), so the  
> 4.2.0-vs-4.3.5 skew described here no longer exists. The conclusion still  
> stands and is deliberately kept: CONFLATE is still not set on the PUB, because  
> it buys nothing there — the properties that matter are applied at the  
> subscriber, which is where the unbounded queue actually lives.


**The fix is to not use CONFLATE on the PUB at all.** It buys nothing there:  
the "keep only the newest snapshot" semantics that matter are applied at the  
**subscriber**, which is where the queue that could grow without bound  
actually lives. Removing it from the sender costs nothing.

Confirmed by the same sniffer afterwards — snapshots decode normally:

```
[snapshot] T=SNAP  sid=sender01  seq=190  positions=9
[snapshot] T=SNAP  sid=sender01  seq=194  positions=10
snapshots are flowing - a silent receiver is not a publishing problem
```

That capture also independently confirms the per-stream sequence watermark  
above: the snapshot's sequence number is frequently **lower** than events  
already received (`190` after `191`, `194` after `195`, `202` after `203`).  
Under the old shared watermark every one of those events would have been  
discarded as a duplicate.

**Final resolution: CONFLATE is gone from the project entirely.** The only  
reason the two streams had separate sockets was that `CONFLATE` is a  
per-socket option and would have dropped events from a shared one. Once the  
conflation moved into the receiver's drain loop — apply only the newest  
snapshot of each batch — the second socket bought nothing, so there is now  
**one socket per process**. See *Socket topology* in `doc/PROTOCOL.md`.

That also retires the whole class of problem above: the guarantee no longer  
depends on a library option that behaves differently on the libzmq version  
the binding happens to ship.

### 6. A silent receiver is indistinguishable from a broken one

A receiver does **nothing** until it has seen a snapshot (`ready`). So a  
snapshot stream that is broken — wrong port, dropped, or arriving empty —  
makes the EA look idle while heartbeats keep arriving and the log stays  
clean. That is precisely how the CONFLATE bug above presented itself.

`OnTimer` now detects "events are arriving but no usable snapshot ever has"  
and raises an ERROR after ten seconds. The same idea is what the sniffer  
reports from the wire side, and between them the question "is it the sender  
or the receiver" is answerable in one run instead of a long afternoon.

### 7. The seen-ring suppressed legitimate re-opens for ten minutes

`CopierSeenRing` guards against queueing the same action repeatedly in the  
window between "we sent the order" and "the terminal reports the position".  
Its TTL is ten minutes.

That TTL was being applied to the whole lifetime of the action, not just the  
in-flight window. So if you closed a **mirrored** position by hand while the  
sender still held the original, the copier would silently refuse to restore  
it for up to ten minutes — instead of the couple of seconds the snapshot model  
promises.

`CopierSeenRing::Forget()` now clears the key the moment converge sees the UID  
present locally, so the guard covers only the in-flight window.

### And a test-harness bug

`FILE_WRITE` does **not** truncate an existing file. The config fixture was  
opened with `FILE_WRITE` and never deleted, so a second run overwrote the  
head of the previous file and left its tail behind to be parsed as extra  
lines. Every write path in this project now deletes first.

The assertions were also rewritten to print the **actual** value on failure  
(`OkInt` / `OkStr` / `OkDbl`). When the only way to debug is to ask someone  
to re-run a script and paste a log, "FAIL x == 1" is worthless.

---

## Anti-bloat contract

Every container has a fixed bound. There is no map, no dictionary, and no  
array that grows with time:

| structure              | bound                                                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| open-position table    | 512, slots reused immediately                                                                                                                                     |
| dedup ring             | 4096 keys, TTL-expired                                                                                                                                            |
| per-sender desired set | 512 × `CP_MAX_SENDERS`                                                                                                                                            |
| action queue           | 256                                                                                                                                                               |
| log files              | 1 MB × 3, oldest recycled                                                                                                                                         |
| state file             | 256 lines, rewritten whole, never appended                                                                                                                        |
| ZeroMQ queues          | explicit HWMs (1000 each way), **no `CONFLATE` anywhere** — the newest snapshot of each batch is kept in the drain loop instead                                   |
| ZeroMQ message size    | `ZMQ_MAXMSGSIZE` = `CP_MAX_MSG_LEN` = 1 MB. A peer announcing a larger frame is **disconnected mid-read**, before the buffer is allocated — see *Hardening* below |
| wire message           | `CP_MAX_MSG_LEN` 1 MB, checked by the parser. A full `CP_MAX_POSITIONS` snapshot at worst-case field widths is ~378 KB, so this leaves ~2.7× headroom             |

Two rules that matter more than the table:

- **Sockets are created in `OnInit` and destroyed in `OnDeinit`.** Creating  
  them per tick is the single most common way to make an EA leak.
- **`ZMQ_LINGER=0` always.** A non-zero linger blocks `zmq_ctx_term` and the  
  terminal hangs on shutdown or EA reload.

### The log-volume trap, found the hard way

The rate limiter inside `CopierLog` collapses *identical messages arriving  
within one second*. That is not enough, and the gap is not obvious.

A condition like "the receiver's broker does not offer this symbol" is true  
on **every timer tick** until a human fixes it. The converge loop runs at  
~10 Hz, so the message repeats about ten times a second, forever. Measured on  
the first real pilot run: **2542 lines / 264 KB in 21 minutes from one  
warning.** Rotation keeps the disk usage bounded, but the log stops being  
readable — the same unbounded-noise failure this codebase exists to avoid,  
reached by a different route.

Anything that can repeat indefinitely now goes through `CopierOnceLog`,  
which emits a key once and then at most once per re-warn interval, evicting  
the least recently used key when its 64 slots are full. `logcheck.sh` also  
watches for the symptom directly: it flags any single message that accounts  
for more than 200 log lines.

The same trap existed on the **trade-failure** path, and it was worse than a  
log problem. A failed action is shifted off the queue and its key is never  
recorded as done, so converge re-derived it on the very next pass — ten  
broker round trips a second, for as long as the broker kept refusing. A  
failed `(sender, kind, uid)` is now parked for **2 seconds** (`g_retryAfter`)  
and the failure log is rate-limited to once a minute per distinct failure.  
Two seconds is bounded by the snapshot period on purpose: the snapshot is  
what re-derives the action anyway, so waiting longer buys nothing.

### Log levels, and what each one costs

Set `LogLevel` knowingly — the difference between 2 and 3 is a per-second  
line versus a per-minute one.

| `LogLevel`      | adds                                                                         | steady-state volume                                       |
| --------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------- |
| `0`             | errors only                                                                  | near zero                                                 |
| `1`             | conditions (symbol unavailable, volume drift) — throttled to once per 10 min | near zero                                                 |
| `2` **default** | start-up, open, close, resync, silence, recovery                             | bounded by trading activity: a handful of lines per trade |
| `3`             | the heartbeat tick — throttled to once per **minute**                        | ~1 line/min/sender, ~40 KB/day                            |

`3` is for diagnosing "is the link alive at all". Do not leave it on: at one  
line per second it produced 28 lines in 27 seconds on a real run and buried  
the open/close lines that DEBUG was turned on to see.

**Everything that passes the level filter goes to both places** — the file log  
*and* the terminal's Experts tab. Only errors used to reach the Experts tab,  
which made a perfectly healthy EA look dead: the tab stayed empty while the  
file filled up normally, and "no log output" reads as "broken".

The file log is **opened shareable** (`FILE_SHARE_READ|FILE_SHARE_WRITE`).  
MQL's default is exclusive, so without it nothing else can read the log while  
the EA runs — not `tail`, not `logcheck`, not an editor — which is precisely  
the moment you want to look at it. If the file cannot be opened at all (a  
stale handle from a killed instance, an editor, a virus scanner) the logger  
walks the other generations before giving up, and says so in the Experts tab  
if it really cannot log to a file.

Two message classes are **expected** even though they look alarming:

- `silent for >15s: new entries stopped, existing positions kept` — logged at  
  ERROR level, but it is pilot check 3.5 working correctly. `logcheck.sh`  
  counts it separately and does not treat it as a failure.
- `symbol X -> Y not offered by this broker` — the receiver's broker does not  
  have that symbol; the copier retries every tick and reports at most once  
  per 10 minutes.

---

## Testing

### Layer 1 — logic (no broker, no network)


`CopierSelfTest` is a pure-logic regression suite: codec round-trips,  
snapshot convergence, table behaviour, lot normalisation, config parsing,  
torn-state-file rejection, and duplicate-survivor selection (including an  
antisymmetry check, because the caller folds that predicate over a group).  
Run it as a script after any change to those layers. It writes  
`copier_selftest.log` and prints a pass/fail summary; it should end with  
`ALL PASS` on **both** platforms — currently **452 assertion call sites**
(counted with `grep -c 'Ok(' src/Scripts/CopierSelfTest.mq4`-style, so it is
checkable rather than remembered).

Every assertion reports the actual value on failure (`OkInt` / `OkStr` /  
`OkDbl`), because the only debug loop available in MQL is "re-run it and  
paste the log" — a bare boolean wastes a round trip every time.


### Layer 1.5 — read the logs like a test result

```bash
./tools/logcheck.sh          # every configured terminal
./tools/logcheck.sh --json   # machine-readable
```

The failures worth catching in the pilot are mostly the **absence** of a  
line — a restart that should not have re-opened anything, a disconnect that  
should have kept a position. Nobody notices absence by eye. `logcheck.sh`  
reads every copier log it finds and reports:

- the per-UID lifecycle table, with the sender ticket, so it can be matched  
  against the order comment
- any UID opened more than once → would be a duplicate position
- any close with no matching open → would be an orphan close
- positions still open at the end → expected, or a leak
- unexpected ERROR / WARNING lines (the pilot's own markers such as  
  `silent for >15s` are expected and counted separately)
- **a log-volume guard**: if one message accounts for hundreds of lines, the  
  copier's rate limiting is not holding

It reads the **state files** as well as the logs, and prefers them, because  
they are snapshots rather than diffs and therefore survive log rotation:

| file                    | answers                             |
| ----------------------- | ----------------------------------- |
| `copier_sender_<id>.st` | what a sender *should* have open    |
| `copier_receiver.st`    | what a receiver *actually* has open |

The divergence check compares those two. Both must come from a state file for  
a disagreement to be reported as a hard failure; if either side is  
log-derived it is only a warning, because a rotated-away generation can drop  
the closes and make already-closed positions look stranded. A state file that  
parsed but lists nothing means "flat", which is a real answer and is reported  
as such rather than as a missing file.

That last check is not hypothetical. On the first real pilot run one warning  
produced **2542 lines / 264 KB in 21 minutes** — see the note on  
`CopierOnceLog` below.

### Layer 1.6 — contract tests, no broker and no terminal

The logic that is easiest to get subtly wrong is also the logic nobody can see
from a terminal: the hash and receipt semantics, the repair debounce, the
`MODIFY` payload and its throttle, and the hub's relay / position view. Those
live in Python and run in seconds:

```bash
./tools/tests.sh           # every contract suite
./tools/tests.sh --all     # + hub unit tests + the four-terminal EA build
```

| suite | what it pins down |
|---|---|
| `snapshot_receipt_test.py` | hash coverage, receipt semantics, and `PROTOCOL.md`'s worked example |
| `snapshot_repair_test.py` | debounce + rate-limit, including the cascade failure both rules exist to stop |
| `modify_event_test.py` | `MODIFY` payload, snapshot override, throttle = delay not drop |
| `hub_stat_path_test.py` | receipt relay, D13, and log volume |
| `hub_positions_test.py` | M3 view + byte-for-byte forwarding |

> **Do not `python tools/...` them directly.** `python` *is* on `PATH` here, but
> it is the **base** interpreter, and pyzmq is only in the isolated venv — so the
> direct command dies with `ModuleNotFoundError`, which reads like a broken test
> rather than a broken command. `tests.sh` tries the venv first for that reason;
> `sniff.sh` has the same job for the sniffer.

Two of these are unusual on purpose. `snapshot_receipt_test.py` reads
`doc/PROTOCOL.md` and asserts its example hash is the **real** one — a
placeholder in a protocol example sends a reader hunting in the code for a bug
that is in the documentation. And `hub_positions_test.py` asserts that the hub
still forwards a snapshot **byte for byte** after parsing it read-only; if that
ever stops holding, the hub is no longer a transparent proxy and everything
else it guarantees is void.

`hub_stat_path_test.py` carries the log-volume assertions in both directions:
a burst of routine `STAT` must write **zero** lines, and an unrecognised
control type must still write one, so widening the suppression list can never
silently become a mode. Run it after any change to the hub's logging rule.

`bash hub/build.sh --test` runs the 67 hub unit tests. Not `cargo test` — Rust
lives in an **isolated** toolchain and is not on `PATH`, so a bare `cargo` is
just `command not found`; `hub/build.sh` sets `RUSTUP_HOME` / `CARGO_HOME` /
`LIBZMQ_PREFIX` / `PATH` in one place. Its header explains why that is
deliberate — the alternative is a README that drifts, which is what this
section keeps having to correct.

### Sniffing the wire

The copier's own logs answer "what did the receiver **do**" — never "what did  
the sender **put on the wire**". When a receiver looks silent, that is the  
first question, and there was no way to answer it:

```bash
# from cmd / double-click - finds Python and installs pyzmq if needed
tools\sniff.bat --seconds 120

# from Git Bash
./tools/sniff.sh --seconds 120
```

`zmq_sniff.py` is a Python script, so it cannot be run by typing its name in  
`cmd` — use one of the wrappers above, or invoke it with a full interpreter  
path.

It is a passive subscriber: it connects to the sender's one port, prints the  
decoded stream, and tells you outright if no `SNAP` messages are arriving  
(without a snapshot a receiver never sets `ready`, so it will do nothing at  
all). `--snap` is accepted but ignored, so older command lines still run.

`zmq_fanout_test.py` answers the complementary question — whether a PUB with  
`CONFLATE` and two subscribers actually delivers to both. It does; that was  
worth proving rather than assuming while chasing a fan-out bug that turned out  
not to exist. The project no longer sets `CONFLATE` at all, but the test is  
kept because the question comes up again every time someone proposes using it.

### Layer 2 — end-to-end (two terminals)

`doc/PILOT.md` is the step-by-step acceptance test: mirroring, losing an  
event, restarting either side, and a disconnect longer than `StaleSeconds`.

This machine has two MT5 installs, which is enough to run the pilot entirely  
on loopback — no second VPS, no firewall, no CURVE:

```bash
./tools/pilot-setup.sh    # enables both MT5s, deploys, compiles, writes copier.ini
```

Then follow `doc/PILOT.md`. The five checks are, in order:

1. open / close on the sender → mirrors within one snapshot period
2. stop the sender, close on the sender, restart it → the receiver converges  
   from the **snapshot**, not from the event it never received
3. restart the receiver with a position open → it must do **nothing** (no  
   duplicate, no spurious close)
4. restart the sender → receiver logs `new session ... -> resync`, converges
5. disconnect for longer than `StaleSeconds` → receiver stops new entries,  
   **keeps** positions, recovers on reconnect

> **Re-attach the EA after every build.** MetaTrader does **not** reload an EA  
> whose `.ex4`/`.ex5` was replaced by an external compiler — which is exactly  
> what `compile.sh` does. The running instance keeps the old code, and nothing  
> says so; a new feature simply appears not to work. This has cost real time  
> twice here: two MT4 receivers with no state file (a build from before the  
> write existed), and an MT5 receiver that ran an eleven-hour-old build all  
> night.
>
> To check, compare the binary's mtime against the terminal Journal's last  
> `loaded successfully` for that EA (`<terminal>/logs/YYYYMMDD.log`). Or just  
> read the stamp the EA prints at startup — `build=2026.10.06 10:19` — which  
> is what it is for.
>
> Note the MT5 journal is **UTF-16LE**: a plain `grep` over it returns nothing,  
> which is easily mistaken for "the EA never loaded". Use  
> `iconv -f UTF-16LE -t UTF-8` first.

---

## What is deliberately NOT in this build

Reserved in the protocol (`PARTIAL`) so adding it will not break v1 peers:

- **growing** a position — an add is a new order on MT4 (new ticket, new UID,  
  arrives as a fresh open) and would need a second position under one UID on  
  MT5, which breaks the mapping. **Shrinking IS supported**: a partial close  
  on the sender trims the receiver, rounded down to a whole lot step so it can  
  never overshoot, and closed outright if the remainder would fall below the  
  broker's minimum lot.
- equity-relative / risk-based sizing (`HBT` already carries balance and  
  equity, so the data is on the wire)
- `EmergencySLPips` / `EmergencyTPPips` exist but default to 0

**Pending orders, the STAT channel, `MODIFY` and the risk switches ARE
supported** — see below.

> **MODIFY is no longer reserved.** Stop-loss changes to a position that
> already exists now travel as their own event, so the mirror does not have to
> wait for the next snapshot. Measured live on the pilot pair: **0.44–0.61 s**
> from the sender detecting the change to the receiver's broker call, against
> 3.4–5.8 s through the snapshot path. The snapshot is still the only
> authority — a lost `MODIFY` costs latency, never correctness — and the
> receiver rate-limits per position (`StopsThrottleSeconds`, default 2 s,
> which **delays** rather than drops) so a sender dragging a trailing stop
> cannot turn into a stream of broker calls. See `doc/PROTOCOL.md` §SL/TP
> mirroring, and slice D in `doc/SNAPSHOT-DEMAND-PLAN.md`.

### Pending orders

All six types are mirrored — buy/sell limit, buy/sell stop, and buy/sell  
stop-limit — on both platforms. They travel the *same* path as market  
positions: the same table, the same desired set, the same record. A working  
order is the same mirroring problem (create it, size it, remove it when the  
sender removes it), so giving it a parallel universe would only mean a second  
converge loop to keep correct.


Three things worth knowing:

- **The trigger price is copied verbatim, not distance-adjusted.** That is the  
  opposite of the stop-loss rule, deliberately: a stop's *distance* is the  
  risk, but a pending order's *price* IS the trade — a buy limit 50 pips below  
  is a different trade from one 20 pips below. If the price is not valid at  
  the receiver's broker the broker rejects it and the log says so.
- **MT4 has no stop-limit order type.** A stop-limit entry is skipped with a  
  warning on an MT4 receiver rather than approximated as a plain stop.
- **The UID survives activation.** MT4 keeps an order's ticket when it fills,  
  and MT5 sets a filled position's `POSITION_IDENTIFIER` to the ticket of the  
  order that opened it — so the same identity carries across and activation is  
  not a close-and-reopen. If one side fills before the other, the receiver  
  notices the *kind* mismatch, cancels its working order and re-opens at  
  market rather than mirroring a pending order against a live position.


### STAT channel

The receiver reports its status — login, equity, balance, positions held,  
total lots, sender count, risk state, and how many entries a risk switch  
refused since the last report — and the sender logs it.

**It costs no extra socket and no extra port.** That is worth stating because  
the obvious reasoning says otherwise: PUB and SUB are each strictly one-way,  
so a receiver reporting *back* appears to need a socket of its own. It does  
not — the transport uses **XPUB / XSUB**, the extended pub/sub types, which  
are **bidirectional**. An XSUB peer can send up to the XPUB, and the XPUB  
delivers those messages to the application.

`tools/zmq_bidir_test.py` measures this rather than assuming it, and the  
design rests on all four results:

- one XPUB send still reaches **every** XSUB subscriber (fan-out is intact)
- an XSUB send arrives at the XPUB on the same socket
- the subscription filter still works
- with one receiver attached to **several** senders, a status message is  
  **broadcast to all of them**

Two details that follow from XPUB/XSUB and are easy to get wrong:  
**XSUB does not auto-subscribe** (the receiver sends the `0x01` subscription  
byte itself), and the XPUB therefore sees those subscription bytes mixed with  
real status messages, so the sender decodes what it drains instead of  
assuming every message is status.

`StatusEnabled` (default `true` on both ends) turns it off. Nothing it carries  
feeds back into trading — a lost status message costs a log line and nothing  
else. The sender logs on the *account* and *risk state*, not on the figures,  
so a steady receiver does not fill the log with identical lines every minute.

**Risk switches ARE supported** — see below — which is the last thing that  
stood between this and being safe to leave unattended.


### Risk switches

The copier reproduces *someone else's* trading and has no opinion about
whether it is sane. A sender with a fat finger, a broken lot calculation, or
simply a much larger account will happily order something ruinous, and this
receiver would faithfully do it. These are the circuit breakers.

| input | default | meaning |
|---|---|---|
| `MaxLotsPerPosition` | `0` (off) | cap on **one** mirrored position |
| `MaxTotalLots` | `0` (off) | cap on **total** mirrored volume |
| `MaxOpenPositions` | `0` (off) | cap on concurrent mirrored positions |
| `DailyLossPct` | `0` (off) | stop for the day after this % loss |
| `MaxDrawdownPct` | `0` (off) | stop until reload after this % fall from the peak |
| `RiskCloseAllOnTrip` | `false` | also close what we hold when a % switch trips |

**Every switch defaults to OFF**, so an unconfigured receiver behaves exactly
as it did before they existed.

They are global EA inputs rather than per-sender `copier.ini` keys because
they protect the **account**, and the account is the thing at risk — one
receiver serving four senders has one equity curve and one book, not four.
The per-sender config still owns everything that is genuinely per-sender:
endpoint, sizing, magic, symbol mapping.

Four things worth knowing:

* **Only OPENING is gated.** A trim, a close, a dedup removal or a stop
  adjustment all reduce or preserve risk — blocking a CLOSE would be
  actively dangerous, not conservative.
* **The caps count what is held PLUS what is already queued.** A converge
  pass decides several opens at once and none of them is a position yet, so
  checking each against the number of positions that *exist* lets all of
  them through. That was a real failure: `MaxOpenPositions = 3`, four
  desired positions, four opened.
* **The two percentage switches measure EQUITY, not balance**, so open
  positions count. A stop that ignored floating loss would sit quiet through
  exactly the situation it exists for.
* **They behave differently on purpose.** The daily switch clears itself at
  the next server day. The drawdown switch **latches** — a recovery does not
  clear it, and neither does a new day. That is the "stop and look at this"
  switch, and it should not quietly un-trip itself. To clear it, raise
  `MaxDrawdownPct` past the current drawdown, set it to `0`, or remove and
  re-add the EA.
* **Changing a limit re-evaluates the latches.** MetaTrader reinitialises an
  EA when its inputs change but does **not** reset its globals, so without
  this a tripped switch would survive you turning it off — the only way out
  being to remove and re-add the EA. Changing a limit now clears the latch
  and the next observation re-derives it against the new limit and the
  current equity. Changing an *unrelated* input leaves the latch alone, so
  editing `LogLevel` cannot silently un-trip a breaker.
* **The day baseline survives a restart.** It is derived as
  `balance − realised P&L today`, not "equity when the EA started" — the
  latter silently forgives the morning's losses if you reload at 3pm, which
  is precisely when the switch matters most.

While a switch is tripped the receiver logs an `ERROR` once, then a line a
minute saying it is *still* blocked and why. Without that, "blocked by risk"
and "silently broken" are the same log.

**SL/TP mirroring IS supported** — see below — which also means a sender-side
**trailing stop works implicitly**: it moves `SL` on every tick, the snapshot
carries the new value, and the receiver follows it. There is no separate
trailing-stop feature to configure, and no second mechanism to keep in sync.

### How SL/TP is mirrored

Stops are copied as a **distance from the entry**, not as a price. The two
sides filled at different prices, so an absolute level can land on the wrong
side of the receiver's market — a 20-pip stop on the sender can sit *above*
the receiver's entry, i.e. an instant stop-out. The distance is also what
actually carries the risk, so under `lotmode=multiplier` the mirror's
exposure scales with its volume in the same proportion.

Consequences worth knowing before you rely on it:

* a stop closer than the receiver broker's minimum distance is **widened** to
  that minimum and logged — the mirror is then wider than the sender's
* a sender that **clears** its stop clears the mirror's too — *unless*
  `EmergencySLPips` is configured, in which case the backstop takes its place
* `EmergencySLPips` applies **only when the sender has no stop of its own**;
  the sender's stop always wins
* a new position picks up its stops on the next converge pass (~100 ms), not
  in the opening request — see `doc/PROTOCOL.md` for why that trade-off is
  deliberate

On that last point: the agreed behaviour on sender disconnect is *stop new
entries, keep existing positions*. With mirroring on, those positions keep
the last stop the sender published, so they are not naked. `EmergencySLPips`
remains the valve for a sender that never published one.

Two different latencies, and only one of them used to be short: a **new**
position picks up its stops on the next converge pass (~100 ms), while a
**change to an existing** stop used to wait for the next snapshot — which was
fine at `SnapshotSeconds=2`, and stopped being fine the moment that number was
raised to cut bandwidth. That change now travels as its own event
(`MODIFY`), so the two are no longer coupled: see the note under
"What is deliberately NOT in this build" above.

---

## Deviations from the original plan

| planned | actual | reason |
|---|---|---|
| state file written to `.tmp` then renamed | written in place after delete | `FileMove` does not compile consistently across builds. Mitigated by the trailing `END:<n>` marker: a torn file is rejected and the caller rebuilds identity from order comments. The state file is a cache, not the source of truth. |
| log rotation by renaming generations | rotation over a fixed set of generation files | same `FileMove` problem; file count stays constant either way |
| `StringReplace` for sanitisation | explicit substring splice | `StringReplace(str, pos, sub)` replaces a span the length of the **replacement**, not of the text being replaced — it silently corrupts when the two differ |
| `MODIFY` reserved, stops propagated by snapshot only | `MODIFY` **implemented** (slice D) | the snapshot bound on stop latency *was* `SnapshotSeconds`, and that number was raised to cut bandwidth — which silently made stop propagation 5× slower. Measured 3.4–5.8 s before, 0.44–0.61 s after. The snapshot is still the authority; the event only removes the wait |

---

## Compile status

Verified on this machine, both platforms, **0 errors / 0 warnings**:

| file | MT4 (.ex4) | MT5 (.ex5) |
|---|---|---|
| CopierSender | ok | ok |
| CopierReceiver | ok | ok |
| CopierSelfTest | ok | ok |

Compiled against the MT4 build in `C:\Program Files (x86)\Alpari MT4` and the
MT5 build in `C:\Program Files\MetaTrader 5`.

`tools/compile.sh` bakes in two hard-won details: MetaEditor resolves
`<Angle/Bracket.mqh>` includes against **its own** data folder (so `/include:`
is mandatory when the editor and the terminal are different installs), and
`/log:` needs an explicit file path.
