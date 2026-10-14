# Copier wire protocol v1

Delimited `key=value` text. **Not JSON** — MQL has no JSON parser, no  
regex on older builds, and a weak string API. `StringSplit` +  
`StringFind` + `StringToDouble` is realistic and fast.

## Separators

| scope                 | char | why                                            |
| --------------------- | ---- | ---------------------------------------------- |
| envelope fields       | `\|` | never appears in sanitised symbols or comments |
| payload `k=v`         | `;`  |                                                |
| repeated records      | `~`  |                                                |
| items inside a record | `,`  |                                                |

Symbols and comments are sanitised on the way in: `| ; ~ , =` are  
replaced with `_`, and the length is capped (symbol 24, comment 24).  
A broker symbol containing `#` (very common, e.g. `EURUSD#`) is left  
untouched.

## Envelope

```
V=1|SID=<sender>|SSID=<session>|SEQ=<n>|TS=<broker unix seconds>|T=<TYPE>|P=<payload>
```

`P=` is always last and is parsed by finding the **first** occurrence of  
`|P=` — the payload itself may legally contain `;`, `~` and `,`.

| field  | meaning                                                                                                                                                                                                             |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `V`    | protocol version. Mismatch => message discarded.                                                                                                                                                                    |
| `SID`  | sender id. The receiver routes on this, so one subscription can serve many senders.                                                                                                                                 |
| `SSID` | session id, regenerated on every `OnInit`. A change means the sender restarted: the receiver throws away its idea of that sender's state and resyncs from the next snapshot.                                        |
| `SEQ`  | monotonic per session. Idempotency key is `SID:SSID:SEQ`. The receiver keeps **one `last_seq` per sender** — never a shared counter, or one sender's sequence would poison another's. `SEQ <= last_seq` is dropped. |
| `TS`   | **broker server time**, never wall clock. VPS clocks drift; nothing is ever ordered by timestamp. Latency is measured by round trip instead.                                                                        |
| `T`    | message type.                                                                                                                                                                                                       |

## Message types

| T         | frequency                                                                                 | payload                                                                                                     |
| --------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `SNAP`    | every `SnapshotSeconds` (default 10), implicitly on (re)connect, and on a targeted repair | `N=<count>;R=<rec>~<rec>...;H=<8 hex>`                                                                      |
| `OPEN`    | event, immediate                                                                          | `UID=..;TKT=..;SYM=..;SIDE=..;LOTS=..;OPN=..;SL=..;TP=..;OTS=..`                                            |
| `CLOSE`   | event, immediate                                                                          | `UID=..;TKT=..;LOTS=..;PX=..`                                                                               |
| `HBT`     | every `HeartbeatSeconds` (default 1)                                                      | `BAL=..;EQ=..;MGN=..;FRM=..;NPOS=..`                                                                        |
| `PARTIAL` | reserved (P4)                                                                             |                                                                                                             |
| `MODIFY`  | event, immediate — a stop moved                                                           | `UID=..;OPN=..;SL=..;TP=..`                                                                                 |
| `STAT`    | once a minute; the receipt on every `SyncHeartbeatSeconds` (default 1)                    | `LOGIN=..;SID=..;H=..` always, plus `EQ=..;BL=..;HELD=..;LOTS=..;NSEND=..;BLOCKED=..;RISK=..` once a minute |
| `RCPT`    | hub → sender, on every receipt a receiver reports                                         | `LOGIN=..;SID=..;H=..`                                                                                      |
| `CFG`     | hub → node, on a config change and on the retry ladder                                    | `ID=..;REV=..;INI=<escaped ini>`                                                                            |
| `ACK`     | node → hub, in reply to a `CFG`                                                           | `ID=..;OK=1;REV=..;WARN=..` or `ID=..;OK=0;ERR=..`                                                          |
| `ACK`     | node → hub, in reply to a `CFG`                                                           | `ID=..;OK=1;REV=..` or `ID=..;OK=0;ERR=..`                                                                  |
| `CFGR`    | node → hub, when a node wants its config again                                            | `REQ=1;ROLE=..;ACC=..;REV=..`                                                                               |

### `CFG` / `ACK` / `CFGR` — config push

`REG` and `HBT2` carry a `REV=` — the node's own config revision, `0` when it  
has none. That is what makes the hub able to tell a node that is *behind* from  
one that has been edited by hand:

| node's `REV` | hub's rev | what the hub does                                              |
| ------------ | --------- | -------------------------------------------------------------- |
| lower        | —         | **pushes** `CFG`; this is the §7.3 self-heal path              |
| equal        | —         | nothing                                                        |
| **higher**   | —         | **`config.drift`**: logged, audited, and **not** pushed (§7.4) |

**`INI` is percent-escaped.** An ini contains `;`, `=`, `|` and newlines, every  
one of which the payload format uses as a delimiter — dropped in raw, the field  
would end at the first `;` of the first comment and the node would receive a  
truncated config. The escape is `%25 %7C %3B %7E %2C %3D %0A %0D`, applied to  
\`% | ; ~ , =

` respectively; everything else passes through. It is **not** idempotent (`%`is escaped and also appears in the output), so it is
applied exactly once on each side.`hub/src/config.rs`is the reference
implementation and`tools/hub_config_test.py\` asserts a real ini survives it  
byte for byte.

**`ID` is derived from `(node, rev)`, not a counter.** §5.4 requires a node to be  
idempotent by `ID`, and says why: under §11 primary/standby two hubs may push  
the *same* change. A counter would mint two ids for one change and the node  
would apply it twice; a content-derived id makes a retry, a resend and a second  
hub's copy the same command.

**The retry ladder is finite**: 2 s → 5 s → 15 s → 60 s, then `unknown`. The  
plan's §5.4 word is `unknown` rather than `failed` and it is the right one — an  
unacknowledged push is one whose outcome nobody knows.

**`WARN=` on a successful `ACK`** counts what the change may have orphaned (§10  
layer 2): a changed `magic`, or a changed sender set. A config that applies  
cleanly can still leave positions nothing manages any more, and that is worth  
saying in the same breath as the success.

> **State: both halves are implemented (M4a hub, M4b EA), and BOTH default to  
> off.** The hub refuses to write without `--writes on`; the receiver refuses to  
> apply without `AcceptConfigPush=true`, and answers `OK=0` when it refuses  
> rather than staying silent (silence would leave the hub walking its retry  
> ladder for a refusal it could have been told about at once).
>
> Two gates because this is the only operation in the system that can stop a  
> receiver from starting, and §19.1 makes the firewall the only trust boundary  
> on the hub port. See `hub/README.md`.

### `RCPT` — how the receipt reaches a sender in central mode

In **direct** mode the receiver's `STAT` arrives at the sender by itself and the  
receipt rides inside it. In **central** mode it does **not**, and cannot: the hub  
consumes every `@`-prefixed message, and `D13` (`doc/CENTRAL-HUB-PLAN.md`) has  
the hub keep the receiver's status rather than hand it to a sender — the  
receiver's equity and lots are a property of the *receiver*, and belong to  
whoever is watching receivers.

That is right for the monitoring figures. The receipt is not one of them: *"the  
snapshot I sent you is / is not the one you hold"* is a **delivery** signal, only  
the sender can act on it, and no other node can observe it. So the hub extracts  
`LOGIN`, `SID` and `H` from the `STAT` it consumed and relays **only those** as  
`RCPT`, addressed to `@<SID>` — the channel that already existed for hub → node  
traffic (`PONG`, `WHO`). No new topic namespace, no second identity: the `nid` a  
sender subscribes to at startup is exactly the `id=` a receiver puts in its ini.

Three consequences worth stating plainly:

- **`RCPT` is a separate `T` from `STAT` on purpose.** It carries no equity,  
  lots or risk state, so a sender that ran its status-reporting path on one  
  would print a receiver-status line full of empty numbers.
- **A `STAT` with no `SID` is not relayed.** That is an older receiver, which  
  predates the receipt: there is no sender to address it to and no hash in it.
- **`SID` is read from the `P=` payload section, never the envelope header.**  
  A receiver's `STAT` carries `SID=receiver` in the header and `SID=<sender nid>`  
  in the payload. The hub's `envelope_kv` searches only after `|P=` for exactly  
  this reason (see the `kv_does_not_read_the_envelope_header` unit test).

`H` may legitimately be **empty** in a relayed receipt — that means "no snapshot  
ingested yet", which the sender is told, because it is not the same as a wrong  
hash.

### Addressing on the central channel: `@` is the hub's, and only the hub's

A topic frame is a **prefix**, and the hub splits on one character:

| topic             | who may originate             | what the hub does                                              |
| ----------------- | ----------------------------- | -------------------------------------------------------------- |
| `@<nid>` / `@all` | **the hub, and only the hub** | consumes it as control addressed to itself; **never forwards** |
| `<nid>` (no `@`)  | any node                      | forwards byte for byte to every subscriber of that prefix      |

The `@` row is the one that bites. A node that publishes on `@<something>`  
believes it is routing; the hub reads it as control, handles the three types it  
knows (`PING`, `REG`, `HBT2`) and **drops the rest with no forward**. That is  
why `PONG`, `WHO` and `RCPT` all originate at the hub — the hub is the only  
party that can speak on that prefix at all. Measured, not assumed:  
`tools/hub_stat_path_test.py`.

The consequence for addressing one receiver is that the sender uses the  
receiver's **own NID as a data topic**, and the receiver subscribes to it:

- receiver, central setup, subscribes to `@<own nid>`, `@all`, **`<own nid>`**,  
  and one `<sender nid>` per sender it mirrors
- to reach **one** receiver, the sender publishes on `[<that receiver's nid>, …]`
- to reach **all** of them, the sender publishes on `[<its own nid>, …]`

No new namespace is involved: the same account number is already the sender's  
data topic, the receiver's ini `id=`, and the hub's node identity. And no new  
field is needed either — `CopierNid()` is a pure function of the account, so a  
sender derives a receiver's NID from the `LOGIN` it already receives.

**A `SNAP` therefore arrives on one of two topics**, and the receiver does not  
care which:

- `<sender nid>` — the periodic broadcast, and the only shape in direct mode
- `<receiver nid>` — a **targeted repair**, sent when this receiver's receipt  
  said it was behind (see below)

### Targeted repair: what it re-sends, and why it is not a fresh snapshot

When a receipt is stale past the debounce, the sender re-sends — but it re-sends  
**the exact bytes of the last broadcast**, not a snapshot built at that moment.

That looks like a shortcut and is the opposite: if the content changed since the  
broadcast, a freshly built snapshot carries a **new hash**, which moves the  
sender's own idea of "current", which makes every *other* receiver — whose  
receipts were perfectly correct — look behind too. One lagging peer would drag a  
repair out of all of them, turning a targeted fix into N full-size sends.  
Re-sending the same bytes cannot do that, because the hash does not move.

The division of labour is the point: **content changes are the periodic  
broadcast's job; a repair only fixes delivery.**


### SNAP receipt (`H`) — delivery tracking, not state comparison

A `SNAP` ends with `H=<8 lowercase hex digits>`: an **FNV-1a 32-bit hash of  
everything in the payload before `H=` itself**. The receiver does **not**  
compute this hash. It stores the value the sender sent and echoes it back in  
`STAT`, which makes the comparison a **delivery receipt** rather than a state  
comparison — there is only ever one value in flight, so a receiver whose own  
fills, rejections, or local risk blocks differ from the sender's book is  
*not* reported as a mismatch. That is the entire reason the field is safe to  
put on the wire.

`STAT` therefore has **two independent cadences sharing one message**:

- the monitoring figures (`EQ`, `BL`, `HELD`, …) — once a minute, only when  
  `StatusEnabled`. Nothing acts on them.
- the snapshot receipt (`SID`, `H`) — every `SyncHeartbeatSeconds`, and  
  **deliberately not gated by `StatusEnabled`**, because it is part of the  
  delivery path rather than a report about it. Turning monitoring off must  
  not disable delivery.

**These two cadences produce two different SHAPES, and a reader must tell them  
apart by CONTENT, not by type** — both are `T=STAT`:

```
receipt only   LOGIN=..;SID=..;H=..                       every SyncHeartbeatSeconds
full report    LOGIN=..;SID=..;H=..;EQ=..;BL=..;HELD=..;LOTS=..;NSEND=..;BLOCKED=..;RISK=..   once a minute
```

The receiver appends the whole figure block together or not at all, so the  
presence of **`EQ`** (or any one of them) identifies a full report. A sender  
must **not** treat a receipt-only `STAT` as a status report: it has no figures,  
and logging it as one produces

```
receiver X status: equity= balance= held= position(s) lots= senders= risk= blocked=
```

— a line of empty numbers that reads like a broken receiver. This was a real  
defect, measured live on 2026-10-13 in direct mode, where the receipt rides the  
`STAT` itself rather than being relayed as `RCPT`.

One `STAT` is sent **per sender mirrored**, each carrying that sender's `SID`,  
because a receiver that mirrors several senders has a different receipt for  
each and a sender must be able to tell whether a receipt is about *it*.  
A sender ignores a `SID` that is not its own; a `SID` that is absent means an  
older receiver, which in that case has only one sender to be talking about.

`H=` absent (or empty) means **no receipt**, which is what an older sender and  
a receiver that has not yet ingested any snapshot both look like. It is not a  
wrong hash and must not be counted as one.

**In central mode the sender never sees this `STAT` at all** — the hub consumes  
it (D13) and relays the receipt as `RCPT` instead. So a sender must accept a  
receipt from **either** path, and must recognise itself in **either** id: a  
direct receiver names it by its **port**, a central one by its **account  
number**. Accepting only the port silently discards every central-mode receipt.

The sender currently only **logs** a receipt that is behind (`slice A`, see  
`doc/SNAPSHOT-DEMAND-PLAN.md`); nothing is re-sent yet.

`STAT` is the only message that travels **backwards**, and it needs no extra  
socket. PUB and SUB are each strictly one-way, which makes "the receiver  
reports back" look like it requires a second socket — it does not. The  
transport uses **XPUB / XSUB**, the extended pub/sub types, which are  
**bidirectional**: an XSUB peer may send up to the XPUB and the XPUB delivers  
those messages to the application.

`tools/zmq_bidir_test.py` measures this rather than assuming it, and the  
design rests on all four results: one XPUB send still reaches **every** XSUB  
subscriber, an XSUB send arrives at the XPUB on the same socket, the  
subscription filter still works, and with one receiver attached to **several**  
senders a status message is **broadcast to all of them**.

Two consequences: **XSUB does not auto-subscribe** — the application must send  
the subscription byte (`0x01`) itself — and the XPUB therefore receives those  
subscription bytes mixed in with real status messages, so a sender must  
**decode** what it drains rather than assume every message is status.

`SID` is `receiver` on these messages and a sender must not route them by  
sender id. Nothing they carry feeds back into trading.

`MODIFY` carries a stop change as an **event**, so the common case is fast. The  
snapshot still carries `SL` and `TP` on every record and remains the  
convergence source of truth — `MODIFY` only shortens the path, exactly the  
relationship `OPEN` and `CLOSE` already have with the snapshot. A lost `MODIFY`  
therefore costs latency, never correctness: the next snapshot re-derives the  
same target.

This replaced an earlier design in which stops rode the snapshot alone. That  
was written down as acceptable **at 2 s** — `PILOT-MT4.md` states the criterion  
as "the receiver follows within ~2 s (one snapshot)" — and stopped being  
acceptable when `SnapshotSeconds` was raised to cut bandwidth. A stop's whole  
purpose is to act *at a level*; a stop that arrives late arrives wrong. Note  
that the snapshot receipt does **not** help here: a receipt reports what was  
*sent*, so it detects a **lost snapshot**, never a change that has not been sent  
yet.

The payload is `UID=..;OPN=..;SL=..;TP=..` — the same key names as `OPEN`, and  
only what the receiver cannot already know. It looks the position up by UID, so  
it knows the symbol, the side and its own entry; what it cannot know is the  
**sender's** stops and the **sender's** entry price, and it needs both, because  
a stop is mirrored as a distance from the sender's entry and re-anchored on the  
receiver's own fill.

Two rules make the two sources agree instead of fighting:

- **The event overrides the snapshot until the snapshot catches up.** A snapshot  
  built before the change is already in flight and still carries the old stop;  
  convergence re-derives the target from the snapshot on every pass, so an event  
  written into it would be reverted by the very next pass. The event is kept  
  *beside* the snapshot and wins until the two agree, at which point it is  
  dropped.
- **The receiver throttles the broker call** (`StopsThrottleSeconds`, default  
  2 s, per position). A sender-side trailing stop moves the SL on nearly every  
  scan, so without a floor one trailing stop becomes ~10 `OrderModify` calls a  
  second, which brokers rate-limit. The throttle **defers rather than drops**:  
  the desired value is held and convergence re-runs ten times a second, so the  
  newest value is applied as soon as the window opens. Dropping it would leave  
  the mirror on a stale stop until the next snapshot — the delay this path  
  exists to remove.

An earlier note here argued a `MODIFY` stream would be "far heavier than the  
snapshot it replaces". That is **not true on the wire**: a `MODIFY` is ~135  
bytes against a ~380 KB snapshot, a factor of about 2800. The real constraint is  
the receiver's broker-call rate, which is what the throttle above bounds.

Position record, positional (no keys, to keep messages short):

```
UID,TICKET,SYMBOL,SIDE,LOTS,OPENPX,SL,TP,MAGIC,OPENTIME[,KIND,PTYPE,PPRICE,PSTOP,PEXPIRE]
```

The last five are appended **only for a pending entry**, which keeps a market  
record byte-identical to what every previous build produced. The decoder  
accepts a *minimum* of ten fields and defaults the rest to "market entry", so  
one build reads records written on either side of the change. An older peer  
skips a 15-field record rather than rejecting the batch — the right outcome,  
since it could not mirror a pending order anyway.

`KIND` is `0` (market) or `1` (pending). `PTYPE` is `1..6` for buy limit,  
sell limit, buy stop, sell stop, buy stop-limit, sell stop-limit. `PPRICE` is  
the trigger price and `PSTOP` the limit price of a stop-limit (0 otherwise).  
An unknown `KIND` or `PTYPE` is **refused, not approximated** — mirroring a  
stop-limit as a plain stop would silently change the order the sender placed.

A pending order's trigger price is copied **verbatim**, unlike a stop-loss,  
which is copied as a distance. A stop's distance is the risk; a pending  
order's price *is* the trade.

`SIDE` is `1` (buy) or `-1` (sell). Prices and volumes are formatted  
with `.` as the decimal separator and 8 decimals, locale-independent.

Example:

```
V=1|SID=alpari01|SSID=a1b2c3|SEQ=17|TS=1780000000|T=SNAP|P=N=2;R=ABCD1234,9918271,EURUSD,1,0.50000000,1.08450000,1.08000000,1.09000000,0,1780000000~EFGH5678,9918275,XAUUSD,-1,0.10000000,2350.10000000,0.00000000,0.00000000,0,1780000005;H=13b2bc5c
```

`H=13b2bc5c` is the **actual** FNV-1a 32-bit hash of everything between `N=`  
and `;H=` in that line, so the example can be verified rather than taken on  
trust. Being a value the sender stamps over the bytes it is about to send, it  
is the **same** number for every receiver of that snapshot.

A `STAT` receipt for the same snapshot, sent back upwards:

```
V=1|SID=receiver|SSID=d9e8f7|SEQ=4|TS=1780000001|T=STAT|P=LOGIN=9918271;SID=alpari01;H=13b2bc5c;EQ=10042.11;BL=10000.00;HELD=2;LOTS=0.60;NSEND=1;BLOCKED=0;RISK=ok
```

## Socket topology

**One** ZeroMQ socket per process. The sender binds a single XPUB; the  
receiver connects a single XSUB. Both are bidirectional.

| socket          | port | type            | options                                                                    | carries                                        |
| --------------- | ---- | --------------- | -------------------------------------------------------------------------- | ---------------------------------------------- |
| both directions | P    | **XPUB / XSUB** | `SNDHWM=1000`, `RCVHWM=1000`, `MAXMSGSIZE=1 MB`, `LINGER=0`, `IMMEDIATE=1` | `OPEN`, `CLOSE`, `HBT`, `SNAP` down; `STAT` up |

`MAXMSGSIZE` is the inbound-size guard that matters: it is enforced by libzmq  
**during** the frame read, and an oversized frame gets the peer disconnected  
rather than buffered. `CP_MAX_MSG_LEN` enforces the same number one layer up,  
in the parser — but only after the whole frame has already been read, so on its  
own it does not bound what a hostile peer can make the process allocate.

The two streams are told apart by the envelope's `T=` field, not by the port.  
The receiver uses **one XSUB connected to every sender**; an XSUB may connect to  
many endpoints, so N senders cost one socket, not N.

### Conflation lives in the drain loop, not in the socket

A snapshot is idempotent full state, so keeping only the newest one is exactly  
right — and that is what `ZMQ_CONFLATE` is for. But **`CONFLATE` is a  
per-socket option**, and setting it on a socket that also carries events would  
silently drop trading instructions. That, and nothing else, is why there used  
to be two sockets.

The conflation is therefore done where it belongs — in the receiver's drain  
loop. Each tick drains the socket, and **every `SNAP` except the last one in  
the batch is skipped**:

```
S1  EVT_A  S2  EVT_B  S3        drained in arrival order
        ↓
      EVT_A  EVT_B  S3          only the newest snapshot is applied
```

Applying only the last is *exactly* equivalent to applying them all in order,  
because a snapshot is a full state **replacement** rather than a delta:  
`S1, S2, S3` leaves precisely the state `S3` alone would leave. Events keep  
their position relative to the snapshot that survives, which is what makes the  
ordering correct rather than merely convenient.

Two consequences worth stating:

- The guarantee no longer depends on a library option. `CONFLATE` on a PUB  
  already bit this project once — on the libzmq 4.2.0 that the binding shipped  
  at the time it delivered **empty** messages, while the same PUB without it  
  was healthy. (Both ends now run libzmq 4.3.5; the rule is kept unchanged,  
  because it was never really about the version — see the note in the  
  "why not CONFLATE" discussion.)
- A PUB **drops** when its send queue is full, and unlike the old conflated  
  snapshot socket there is no "the newest one still gets through" guarantee.  
  Hence the generous HWM, and the receiver logging when a drain hits its  
  per-tick bound — that means it is falling behind.

`snap=` in `copier.ini` is parsed but ignored, so existing configs keep  
working. The wire format is unchanged, so a sender and a receiver can be  
upgraded in either order.

A PUB socket with no connected subscriber silently discards. That is  
acceptable **only** because the snapshot converges the state anyway —  
this is the whole reason the design tolerates loss instead of trying to  
prevent it.

## Convergence (the only source of correctness)

The receiver keeps, per sender, a desired set keyed by `UID`, and diffs  
it against its own mirrored positions:

| desired | local                       | action                                                     |
| ------- | --------------------------- | ---------------------------------------------------------- |
| present | absent                      | open (or RESTORE, if this receiver opened that UID before) |
| present | present, same volume        | nothing                                                    |
| present | present, **sender smaller** | partial close of the difference                            |
| present | present, sender larger      | **not supported** — see below                              |
| absent  | present                     | close                                                      |

**Growing a position is deliberately not supported.** On MT4 an add is a new  
order with a new ticket, hence a new UID, and arrives as a fresh open. On MT5  
it would need a second position under the same UID, which breaks the  
one-UID-one-position mapping the whole design rests on.

Partial closes are rounded conservatively: the difference must be at least one  
whole lot step, the amount trimmed is rounded **down** so the receiver can  
never end up smaller than the sender, and if the remainder would fall below  
the broker's minimum lot the whole position is closed instead — a dust  
remainder cannot be managed and would be stranded forever.

The `IgnoreUids` receiver input (a UID list, comma/space separated)  
suppresses both directions for a listed position: it is neither opened nor  
closed, and it is handed to the operator entirely.

Events merely make this converge faster. **A snapshot alone converges  
from any state**, so a lost message costs a few seconds of divergence  
and nothing else.

Startup behaviour: the receiver does **not** act on a sender until it  
has received at least one snapshot (`ready=false`). Without that guard,  
a restarting receiver would see "local positions I don't know about"  
and start closing them.

## Identity

`UID` is an 8-character Crockford base32 string, generated by the  
**sender** when it first observes a position, and persisted in the  
sender's own state file keyed by ticket.

The sender is a pure observer — it cannot write a UID into the comment  
of an order it did not place (`OrderModify` on MT4 changes only SL/TP).  
So the **receiver** writes the identity into the comment of the order  
**it** opens:

```
tc|<uid>|<senderTicket>          tc|ABCD1234|9918271
```

The sender ticket is the sender's own ticket (MT4) / position identifier  
(MT5) for the position being mirrored, taken straight off the wire from  
the `TKT` field. It exists purely so a human can match the two orders by  
eye in the two terminals.

**The ordering is load-bearing.** The UID comes first because MT4 caps  
comments at 31 characters and some brokers cap them at 27, so the venue  
can truncate at any time. With the UID first, truncation costs you the  
sender ticket — a cosmetic aid — and never the UID, which every mapping  
in the system depends on. The comment is capped at 30 characters here  
(`CP_COMMENT_MAX`) so the venue's limit is never the thing that decides.

Parsing is by position: the UID is always the 8 characters right after  
`tc|`, so comments written before the ticket field existed still parse,  
and the ticket is simply absent (0).

### The comment is a hint, not the authority

**MT5 overwrites a position's comment when it is partially closed.** Anything  
that identifies a position *only* by a token in its comment therefore loses  
that identity at the first partial close.

That is not theoretical. It was observed: the position became unrecognisable,  
the converge loop concluded "the sender holds something I do not" and opened  
a **duplicate**, leaving the original orphaned — two orders, one with a  
comment and one without.

So the receiver keeps its own state file, `copier_receiver.st`, mapping the  
UID to the broker's `POSITION_IDENTIFIER`:

- `POSITION_IDENTIFIER` is server-stable and **survives a partial close**  
  (`POSITION_TICKET` does not, and neither does the comment)
- the receiver rebuilds the mapping from the account every 10 seconds and on  
  shutdown, so closed positions drop out on their own
- on lookup the comment is tried first — it is the fast path and it works  
  across a state-file loss — and the identifier record is the fallback

A position with neither a readable comment nor a record is genuinely  
unmanageable, and `ReportUnreadableOwnOrders()` says so at start-up rather  
than leaving it to be discovered later.

### The partial close must carry the comment back

The overwrite above has a second half that is easy to miss: **the comment  
that lands on the position is the comment of the closing deal.** A close  
with no comment therefore does not merely *fail* to preserve the token — it  
actively *erases* it.

`CTrade::PositionClosePartial()` calls `ClearStructures()` and never sets  
`m_request.comment`, so every partial close it performs wipes the position's  
comment. The receiver therefore builds the `MqlTradeRequest` by hand, with  
`req.comment = CopierCommentForUid(uid, senderTicket)`, so the token is  
written back unchanged and survives indefinitely.

`CTrade::PositionClosePartial()` is also guarded by `if(!IsHedging())`, so it  
is unavailable on a netting account. The hand-built request has no such  
restriction.

Filling mode is derived from `SYMBOL_FILLING_MODE`, with the candidates tried  
in order and a retry only on `TRADE_RETCODE_INVALID_FILL` — retrying on any  
other retcode would risk a double close.

MT4 partial close breaks the ticket chain (the broker closes the order  
and reopens the remainder as a new ticket with `from #<old>` in the  
comment). The sender inherits the UID across that hop so the receiver  
does not see a close+reopen.

On MT4 the comment cannot be written back at all — `OrderClose()` has no  
comment parameter and `OrderModify()` does not touch comments. The chain  
plus the identifier record is the only identity there, which is the second  
reason the record exists.

### The trim comment must carry the whole token

Passing `senderTicket = 0` to `CopierCommentForUid()` produces `tc|<uid>` —  
a *valid* comment that still resolves, so nothing fails and no test  
notices. But because the closing deal's comment is written onto the  
position, that partial close **downgrades** a fully-identified position to a  
half-identified one, and nothing ever rewrites it afterwards. The ticket is  
lost permanently.

The ticket comes from `desired.ticket` — the sender's *current* ticket, which  
changes when an MT4 sender re-tickets its remainder — falling back to  
`CopierSenderTicketFromComment()` on the local order so a field that was  
already written is never dropped.

The general lesson: when a comment is the carrier of state, **every write  
path is a chance to truncate it**, and a truncation that still parses is the  
dangerous kind.

### One UID, one position — and the copier enforces it

`LocalFindUid()`, the seen-ring and the state file all assume a UID maps to  
exactly one position. When that breaks, the extra position is **invisible to  
every loop**: `LocalFindUid()` returns the *first* match, so the duplicate is  
never closed, never trimmed and never reported. It just sits there doubling  
the exposure. That is exactly what the pilot produced — a partial close wiped  
a comment, the mirror became unrecognisable, converge opened a second one,  
and then could not see it.

So `ConvergeSender()` runs `DedupLocal()` **before** the diff. Order matters:  
if the duplicate were left in place, the first match could be the copy chosen  
for a trim while the real mirror is ignored.

The survivor is chosen by `CopierPreferSurvivor()`, in this order:

1. the volume the sender holds right now — agreement with the truth wins
2. a still-readable comment — it is the one the rest of the system can see
3. the **oldest** position — so what is removed is the copy we added
4. the smaller identifier — a tie-break, so the result never depends on the  
   order the terminal enumerates positions in

The rule is antisymmetric, which is what makes folding it over a group  
well-defined; the self-test asserts that explicitly.

Removal uses its own action kind (`CP_ACT_DEDUP`), not `CLOSE`. `PushAction()`  
guards on `(sender, kind, uid)`, so a shared kind would let a dedup removal  
silently suppress a real close for the same UID in the same tick — and that  
combination is precisely the case where the survivor is *also* no longer  
wanted.

Set `DedupDuplicates=false` to report duplicates without removing them.  
Ignored UIDs are skipped entirely — the copier does not act on them, and that  
has to include not cleaning them up.

## SL/TP mirroring

The sender's stops are copied as a **distance from the entry**, never as a  
price.

The two sides hold the same trade at different prices — a different broker,  
and a fill seconds later. Copying the sender's absolute level can therefore  
land on the wrong side of the receiver's market: a 20-pip stop on the sender  
can sit *above* the receiver's entry, which is an instant stop-out or a  
rejected modify. The distance is also the quantity that actually carries the  
risk, so under `lotmode=multiplier` the mirror's exposure scales with its  
volume in the same proportion. It is additionally immune to the two brokers  
quoting at different digit precision, because a distance in price units means  
the same thing either way.

`CopierMirrorStop()` refuses three cases rather than guessing:

- the sender has no stop (0) — nothing to mirror;
- either entry price is unknown;
- the sender's stop sits on the **wrong side of its own entry**, so the value  
  cannot be trusted as a stop at all.

The last one matters: mirroring it would place a stop that is already  
breached, and a wrong stop is worse than no stop.

### The broker's minimum distance wins

Both terminals reject a stop closer than `SYMBOL_TRADE_STOPS_LEVEL`  
(MT4 `#130` / MT5 `10016`), and **MT5 rejects the whole `OrderSend`** rather  
than just the stop — so an unclamped stop does not merely fail to protect a  
position, it can stop the position existing at all. `CopierFitStopAt()`  
widens the stop to exactly that minimum and reports that it did.

Widening is the safe direction: the position lives longer instead of being  
stopped out early. It also resolves the "already past its stop" case  
correctly — a stop the market has run through gets clamped to the closest  
distance the broker allows, so the position exits almost immediately, which  
is what the sender's position did too.

The distance is measured from the **close** price (bid for a buy, ask for a  
sell), because that is what the broker itself uses. Measuring from the entry  
side of the spread would under-state the distance by the spread and let  
through a stop the broker then rejects.

### Precedence with `EmergencySLPips`

The **sender's stop wins whenever it has one.** `EmergencySLPips` is the  
backstop for the case that setting exists for — a sender that leaves  
positions unprotected — so it applies only when the sender has no stop of its  
own. Letting it override would silently discard the sender's risk management,  
which is not what a copier is for.

### Removal propagates

A sender that clears its stop clears the mirror's. This is deliberate  
faithful convergence: the snapshot is authoritative and re-sent every 2 s, so  
a transient sender-side glitch is corrected within one period.

### The one-tick window at open

A position is opened **without** the mirrored stops and picks them up on the  
next converge pass, ~one timer tick (100 ms) later. That is deliberate: at  
open the receiver's fill price is not yet known, and a stop computed from the  
pre-fill market price would be rejected outright on MT5 if the market moved  
in between — losing the entry rather than merely delaying the stop. A failed  
`SLTP` request, by contrast, costs only the modify. `EmergencySLPips` still  
applies at open for the unprotected-sender case.

### Why MODIFY is not gated by the seen-ring

The 4096-entry TTL ring answers *"have I already performed this action?"*.  
That is a meaningful question for a **one-shot, irreversible** action — an  
open, a close, a trim to a smaller size. It is the wrong question for an  
**idempotent state assignment**, and setting stops is one.

The ring's key is the *target* state, and it remembers it for ten minutes. So  
a target that was reached once was silently dropped the next time it came  
round. Observed live on a SELL:

| time      | receiver holds     | sender wants        | outcome                               |
| --------- | ------------------ | ------------------- | ------------------------------------- |
| 17:04:18  | (158.226, 158.039) | **(none, none)**    | applied; key `…:0:0` cached           |
| 17:04:41  | (158.390, 157.712) | (158.390, **none**) | applied                               |
| ~17:04:45 | (158.390, none)    | **(none, none)**    | **suppressed — same key**             |
| 17:05:12  | (158.390, none)    | (none, 157.754)     | applied — and it carried the stop too |

The receiver kept a stop the sender no longer had. Changing the take-profit  
altered the key, which is why it looked like "touching the TP fixes it".

The correct guard for an idempotent assignment is not *"have I done this"* but  
*"does the current state differ from the target"* — which is evaluated fresh  
on every converge pass. So `CopierSeenRingApplies()` excludes `MODIFY`, and  
that comparison carries the whole burden. `TRIM` stays in the ring precisely  
because it is **not** idempotent: it only ever shrinks, so a target volume  
cannot recur.

The in-flight guard (`ActionQueued`, keyed on sender + kind + UID) is  
unaffected and still applies to every kind.

### Failed actions are parked briefly

A failed action is shifted off the queue and its key is never recorded as  
done, so converge re-derives it on the very next pass — ten times a second,  
for as long as the failure persists. A refused request therefore costs a lot  
of broker round trips and buries the log.

`g_retryAfter` parks a failed `(sender, kind, uid)` for **2 seconds**, and the  
failure log is rate-limited to once a minute per distinct failure. Two  
seconds is deliberately bounded by the snapshot period: the snapshot is what  
re-derives the action anyway, so waiting longer buys nothing and waiting less  
just repeats a refusal.

The backoff key does **not** include the target value. If the broker is  
refusing everything, retrying each distinct target once adds nothing; and for  
a close — whose key has no target — the backoff is the only thing stopping  
the storm.

## Risk switches

Circuit breakers on the receiving side. They exist because the copier  
reproduces someone else's trading and has no opinion about whether it is  
sane — a sender with a fat finger or a much larger account will happily order  
something ruinous.

| switch                                                   | measured on                         | clears                                           |
| -------------------------------------------------------- | ----------------------------------- | ------------------------------------------------ |
| `MaxLotsPerPosition`, `MaxTotalLots`, `MaxOpenPositions` | our own book                        | immediately, when the condition stops holding    |
| `DailyLossPct`                                           | equity vs the day's starting equity | at the next server day                           |
| `MaxDrawdownPct`                                         | equity vs the session peak          | only by **changing a limit** or reloading the EA |

**Changing a limit re-evaluates both latches.** This is not a detail: an  
input change reinitialises the EA but does **not** reset its globals — the  
process stays alive — so a latched trip would otherwise survive the operator  
turning the switch off, and the only way out would be to remove and re-add  
the EA. Reported from a live test: `DailyLossPct` went `0.1 → 0` and the  
receiver kept refusing new entries.

So `Configure()` clears both latches when the limits actually differ, and the  
next observation re-derives them against the new limits and the current  
equity. A switch that is now off, or no longer exceeded, clears; one that is  
still exceeded re-trips immediately. An input change that does **not** touch  
the limits leaves the latches alone — otherwise changing `LogLevel` would  
silently un-trip a breaker.

The session peak is deliberately **kept** across a reconfigure: it is a  
property of the account's equity curve, not of the configuration, and  
keeping it is what makes "raise the drawdown threshold to resume" behave  
sensibly instead of silently re-basing the drawdown to zero.

**Only `OPEN` is gated.** `TRIM`, `CLOSE`, `DEDUP` and `MODIFY` all reduce or  
preserve risk, so gating them would be backwards — and gating `CLOSE` would be  
actively dangerous. This is enforced by placing the check at the single point  
where an `OPEN` is queued, not by a policy the rest of the queue has to  
respect.

### The gate must be given held PLUS pending

A converge pass decides **several opens at once**, and none of them is a  
position yet. Checking each against the number of positions that *exist*  
means every one of them sees the same pre-open figure and every one of them  
passes. Measured on a live account: `MaxOpenPositions = 3`, four desired  
positions, **four opened**.

So the gate takes `held` and `pending` as **separate arguments** and adds  
them, and the caller reads `pending` from the live action queue — which also  
covers opens queued earlier in the same tick by a *different* sender, and a  
per-sender counter would miss those entirely. They are separate arguments  
rather than one pre-summed value precisely so that a caller cannot forget:  
passing zeros is explicit, omitting the pending work is not possible.

Only `OPEN` counts toward the projection. Crediting a queued `CLOSE` or  
`TRIM` would let the gate spend room that does not exist yet; the safe  
direction is held-plus-adding, and freed room is picked up on the next tick.

Note this was **not** a policy bug. Every cap, boundary and disabled case was  
already covered by tests — the policy was correct and simply fed stale  
numbers. A fully tested decision function still needs its *inputs* tested.

**The percentage switches measure equity, not balance**, so open positions  
count. A stop that ignored floating loss would sit quiet through exactly the  
situation it exists for.

### The day baseline must survive a restart

The obvious baseline — equity when the EA started — silently forgives the  
morning's losses if the receiver is reloaded at 3pm, which is precisely when  
the switch matters most.

Instead the baseline is `balance − realised P&L today`, derived by walking  
closed deals since the server-day boundary. That quantity is **invariant  
through the day**: as losses accumulate the balance falls by exactly the  
amount the realised total falls, so recomputing it at any moment lands on the  
same number, and a restart lands on it too. It is recomputed at most once a  
minute (it walks history) and immediately on a server-day change, where the  
cached value would be yesterday's and would mis-trip the daily switch.

### Why the drawdown switch latches

The daily switch clearing itself is expected — a new day is a new risk  
budget. The drawdown switch deliberately does not: a recovery does not clear  
it and neither does a new day. It is the "stop and look at this" switch, and  
a breaker that quietly resets itself after the market recovers is not a  
breaker.

The cost of latching is that a spurious trip — a floating-loss spike that  
recovers — leaves the receiver idle until a human notices. That is accepted  
deliberately: the trip is logged at `ERROR`, repeated once a minute while it  
holds, and the alternative failure (silently resuming) is worse.

To clear it: raise `MaxDrawdownPct` past the current drawdown, set it to 0,  
or remove and re-add the EA.

### Tripped is not the same as broken

While a switch is tripped the receiver is *deliberately* doing nothing, which  
looks identical to a silent fault from the outside. So it says so: once at  
`ERROR` when the switch trips, and once a minute while it holds.

**The messages quote figures, not just percentages.** "Down 5%" does not tell  
an operator where the line actually is, which is exactly the question they are  
asking when they read the line. So each one carries the current equity, the  
baseline it is measured against, how far down that is, and the **level** at  
which it trips:

```
daily loss limit reached: equity 9850.00, down 1.50% from the day's opening
equity 10000.00; the 1.00% limit trips at or below 9900.00. New entries
resume on the next server day
```

The quoted level comes from the same helper the switch tests against  
(`CopierLossTripLevel`), so the threshold used and the threshold quoted cannot  
drift apart.

One trap that follows from this: **the message must not be used as a  
rate-limit key.** It now contains live equity and changes on every tick, so  
keying on it would make every line look like a new one and the rate limiter  
would do nothing. The callers key on `BlockKey()` — a stable identifier — and  
print the message.

### A close is not a one-shot action

The seen-ring may only suppress an action whose key identifies a state that  
**cannot legitimately recur**. `OPEN` was already handled — converge calls  
`Forget()` the moment it sees the UID locally — but `CLOSE` and `TRIM` were  
not, and they need it for the same reason:

```
open -> close -> restore -> close
```

is an ordinary sequence. Keying the ring on `sid:CLOSE:uid` suppressed the  
**second** close for the ring's whole ten-minute TTL. Measured live: the  
sender closed two positions at 10:15:23 and the receiver did not close its  
mirrors until 10:22:19 — exactly the TTL after the *previous* close of those  
UIDs. The receiver sat on two positions the sender no longer had.

So converge now drops all three keys for a UID whenever the position is  
present locally. `TRIM` needs the prefix form (`ForgetPrefix`) because its  
key carries the target volume after the UID and cannot be named exactly;  
prefix matching is safe because UIDs are fixed-length, so no UID is a prefix  
of another.

`DEDUP` is the one kind that stays safe in the ring without this: its key  
carries the position ticket, which is unique per position and cannot recur.

## Link security (CURVE)

CURVE is **optional and per link**. There are two links and
they have **opposite roles**, which is why there are two switches rather than
one:

| link | who binds (CURVE **server**) | what the other end needs |
| --- | --- | --- |
| direct (`<nid>`) | the **sender** (`UseCurve`) | each receiver's `SenderServerKey` = the sender's public key |
| hub (`@<nid>`) | the **hub** (`--curve on`) | each node's `HubPublicKey` = the hub's public key |

Either end's own keypair lives in one file, `MQL\Files\copier_curve.key`
(`copier_hub.keys` on the hub), is generated on first use, and **the public
half is printed in the log at every start** — that printed line is the thing
that gets carried to the other side. The hub can also print it on demand with
`--curve-show`, which binds nothing and so works while the hub is already
running (reading the banner instead would need the port that hub is holding).
The secret half never leaves the machine and is never logged.

**A key is 40 Z85 characters and 32 bytes, and the two are not
interchangeable.** The file, the log and the operator all speak the 40-character
form; `zmq_setsockopt` wants the 32 raw bytes. Handing it the 40-character
*string* - which is what the MQL binding's string overload does, plus a NUL
terminator, so 41 bytes - is rejected by libzmq with `EINVAL` and the bool that
says so is easy to ignore. The failure mode is not an error message: it is a
handshake that never completes, with nothing anywhere saying why. Both ends
therefore decode Z85 explicitly and pass raw bytes, and both **fail closed** -
a key that cannot be installed aborts the connection rather than continuing in
the clear.

### The hub's allow-list is enforced at the handshake

Encryption alone accepts **any** keypair: it proves a peer holds *a* key, not
that it is *authorised*. The hub therefore keeps `curve_clients.txt` (one
40-character public key per line, `#` comments, or a lone `*` for "any
keypair") and enforces it through a **ZAP handler** (RFC 27).

That placement is the whole point. The hub's main loop only sees messages it
*receives*; a subscriber that is not on the list would still be delivered every
position the hub publishes, and the hub would never know it was there, because
publishing is libzmq's job rather than the application's. ZAP is the one place
libzmq asks the application a question **during the handshake** and obeys the
answer, so a denial means the peer never becomes a subscriber at all.

An empty allow-list with `--curve on` is a **refusal to start**, not a hub that
quietly accepts everyone.

### What CURVE does not do

It does not replace §19.1's firewall: the network-layer allow-list still
decides who can reach the port. It does not distinguish accounts — it is
link-layer, and the account-level boundary is M9's login on the HTTP side. And
key rotation (G15) is a manual procedure: the allow-list is read at startup.

## Failure behaviour

| situation                                                                                                                                    | behaviour                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sender silent > `StaleSeconds`                                                                                                               | stop new entries for that sender, **keep existing positions**, log an error. No forced close.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| sender restarts (new `SSID`)                                                                                                                 | receiver resets `last_seq`, discards the desired set, resyncs from the next snapshot                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| receiver restarts                                                                                                                            | reads the state file, rebuilds identity from order comments, then waits for a snapshot before acting                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| duplicate / reordered message                                                                                                                | dropped by the `SEQ <= last_seq` guard, plus a 4096-entry TTL ring of executed action keys                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| broker rejects a trade                                                                                                                       | parked for 2 s, then re-derived by the next snapshot; logged with the retcode, at most once a minute per distinct failure                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| symbol not offered by the receiver's broker                                                                                                  | skipped with a warning, never silently substituted                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| two positions share one UID                                                                                                                  | the extra one is removed (`DedupDuplicates`), logged with both tickets and volumes; otherwise reported only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| position carries our magic but no readable UID                                                                                               | reported at start-up, left untouched — nothing can prove what it mirrors                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| sender's stop is inside the receiver broker's minimum distance                                                                               | widened to that minimum, logged once; the mirror is **wider** than the sender's                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| sender's stop sits on the wrong side of its own entry                                                                                        | not mirrored at all — a stop already breached is worse than none                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| sender clears its stop                                                                                                                       | the mirror's stop is removed too (faithful convergence)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| a risk switch is tripped                                                                                                                     | **no new entries**; trims, closes, dedup and stop changes still work. Logged once, then once a minute while it holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **the feed is stale** (server clock not moving for 60 s)                                                                                     | **every** queued action is held, not just new entries — nothing can be priced from a clock that is not advancing. Measured with `GetTickCount()`, not wall-clock arithmetic. **This test alone is MT4-only in effect**: on MT5 `TimeCurrent()` is kept alive by the trade-server connection, so it keeps advancing through the weekly close and this gate never fires there. See the next row                                                                                                                                                                                                                                                |
| **one symbol's quotes have stopped** (its own quote time unchanged for 60 s, **or** the server clock already reads 60 s past its last quote) | **every** queued action on that symbol is held. This is the gate that actually catches a shut market on **both** platforms, because it asks about the instrument rather than the clock. It takes the *larger* of two ages: how long we have watched the quote time stand still (monotonic, needs history) and how far the server clock has already run past it (needs none). The second term is what makes it bite on the **first** pass after a re-attach instead of after a full stall window of doomed attempts. The return of the symbol's quotes is itself the signal that the market reopened, so holding costs a delay, never a trade |
| **one symbol's market is closed** (broker said `err=132` on MT4, `err=10018` on MT5)                                                         | that **symbol** is held for 60 s on both the entry and the exit path, so an entry that failed cannot be retried in a loop, and a close queued just before the close cannot either. **Both platforms' codes are recognised by one predicate** (`CopierIsMarketClosed`) — they used to be checked separately, and only the log message knew MT5's code, so on MT5 the cooldown never armed and every entry retried every 2 s for a whole weekend                                                                                                                                                                                               |

## Not in v1

Pending orders, partial closes, SL/TP mirroring, trailing stops,  
equity-relative sizing, `STAT` feedback, and the risk-limit switches.  
The message types are reserved above so adding them does not break v1  
peers.

> All of these have since been **implemented** — this section is the historical  
> v1 boundary, not the current one. It is kept because the reasoning still  
> applies to anyone running a v1 peer: none of it breaks the wire, and the  
> reserved types are why. The one type that was reserved and is now **in use** is  
> `MODIFY` (see above); `PARTIAL` remains unused, since MT5 netting cannot  
> express it.
