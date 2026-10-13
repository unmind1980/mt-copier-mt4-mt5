# P2 pilot — MT4 in the loop

The MT4 code path compiles, but **none of it has ever run**. MT4 is a
different trade model from MT5 (orders, not positions) and its ZMQ DLL is a
different binary (32-bit), so "it compiled" says very little here.

## Why these three phases, in this order

| phase | sender | receiver | what it isolates |
|---|---|---|---|
| **1** | MT5 (proven) | **MT4** | the MT4 **execution** path: `OrderSend` / `OrderClose` / `OrderSelect`, the order-based model, the 31-char comment limit |
| **2** | **MT4** | MT5 (proven) | the MT4 **observation** path: `OnTimer` polling of `OrdersTotal`/`OrderSelect`, UID assignment, `from #N` ticket-chain inheritance |
| **3** | MT4 | MT4 | both at once, and MT4→MT4 symbol/comment handling with no MT5 in the middle |

Phase 1 first on purpose: the MT5 side is already known good, so **anything
that goes wrong is unambiguously MT4's fault**. Running two unproven sides
at once just makes the failure ambiguous.

## Your terminals

| role | terminal | data folder |
|---|---|---|
| MT4 **A** | `C:\Program Files (x86)\Alpari MT4` | `%APPDATA%\...\287469DEA9630EA94D0715D755974F1B` |
| MT4 **B** | `C:\Program Files (x86)\Alpari MT4-2` | `%APPDATA%\...\311584BE9969960C78E0200E53528ECB` |
| MT5 sender | `E:\MetaTrader 5` (portable) | `E:\MetaTrader 5\MQL5` |
| MT5 receiver | `C:\Program Files\MetaTrader 5` | `%APPDATA%\...\D0E8209F77C8CF37AD8BF550E51FF075` |

Two MT4 terminals means **all three phases are runnable**, including
MT4 → MT4 — which is the shape you would actually deploy.

## Before you start

* A **demo** account logged into the MT4 terminal you intend to use.
* In the EA's Common tab: **Allow DLL imports**.
* The receiver also needs **Allow live trading**; both need **AutoTrading** on.
* Nothing else. **No Visual C++ runtime is required**: since the libzmq 4.3.5
  upgrade `libzmq.dll` is a MinGW-w64 build that imports only system DLLs, and
  `libsodium` is linked statically into it. (Before the upgrade this line said
  the **32-bit** VC++ 2015 runtime was needed — that is no longer true.)

Confirm the build landed:

```bash
./tools/status.sh            # the MT4 target should read ok / ok / 4/4 ex4
```

---

## Phase 1 — MT5 sender → MT4 receiver

Leave the MT5 sender running exactly as it is. It already holds
`127.0.0.1:5555`, so nothing new is bound.

1. Copy `config/copier.mt4receiver.ini` to
   `<MT4 terminal>\MQL4\Files\copier.ini`.

   (It is the same shape as the loopback config; the only thing that
   matters is `id = sender01`, matching the sender's `SenderId`.)

2. Drag `CopierReceiver` onto any chart in the **MT4** terminal.

3. Inputs: `ConfigFile` = `copier.ini`, `LogLevel` = `2`.

4. Expected in the MT4 Experts log and in
   `MQL4\Files\copier_receiver.0.log`:

   ```
   receiver up, 1 sender(s), magic base=770000
   ```

   If that line never appears, the receiver never got through `OnInit` —
   most likely the DLL or `copier.ini`.

5. Open a trade on the **MT5 sender** account. Within ~2 s the MT4 receiver
   should open the same symbol, direction and volume.

### What to check specifically on MT4

* **The comment.** It should read `tc|<uid>|<senderTkt>`, e.g.
  `tc|ABCD1234|9918271`. MT4 caps comments at 31 characters and some
  brokers cap them at 27 — check the actual order in the Terminal tab, not
  just the log. **The 8-character UID must be intact**; a truncated sender
  ticket is harmless, a truncated UID is not.
* **The magic number** is `770000`, so the copier's orders are
  distinguishable from your own EAs.
* **Closing mirrors.** Close on the sender → the MT4 order closes.
* **Your other EAs keep working.** The receiver only touches orders whose
  magic is its own; it must not close or modify anything of yours.

### The MT4-specific behaviours worth watching for

* **Requote (error 138).** MT4 instant-execution brokers requote. The
  copier does not retry in a tight loop: it drops the action and lets the
  next snapshot re-derive it, so a requote shows up as a `trade failed`
  warning followed by a successful retry a moment later. That is the design
  working, not a fault.
* **Partial close.** On MT4 a partial close makes the broker **close the
  original order and reopen the remainder under a new ticket**, with
  `from #<old>` in the comment. The sender detects that and inherits the
  UID, so the receiver does *not* see a close+reopen. You will see one
  `volume changed ... (partial close not propagated)` warning — that is
  expected in this build and is throttled to once per 10 minutes.

---

## Phase 2 — MT4 sender → MT5 receiver

```bash
./tools/phase2-setup.sh      # writes the two-sender copier.ini and prints the rest
```

The MT4 sender needs its **own port**, because the MT5 sender already
holds 5555 on this machine:

| | port |
|---|---|
| MT5 sender (already running) | 5555 |
| **MT4 sender** | **5565** |

Each sender binds exactly one port; events and snapshots share it.

1. In the **MT4** terminal (`Alpari MT4-2`), drag `CopierSender` onto a chart.
   * `SenderId` = `mt4demo`
   * `BindAddress` = `tcp://127.0.0.1`
   * `EventsPort` = `5565` — the only port bound
   * `UseCurve` = `false`, `LogLevel` = `2`

   > CURVE needs no key inputs any more — each EA generates its own keypair
   > into `MQL4\Files\copier_curve.key` and prints the public key in the
   > Experts log. See *CURVE keys* in the README.

2. The **MT5 receiver's** `MQL5\Files\copier.ini` now has a second section:

   ```ini
   [sender1]
   id        = mt4demo
   events    = tcp://127.0.0.1:5565
   snap      = tcp://127.0.0.1:5566
   lotmode   = multiplier
   lotparam  = 1.0
   magic     = 770001
   ```

   **`magic` must differ from sender0's** (770000) — that is what keeps the
   two senders' positions apart on the same receiving account.

3. Restart the MT5 receiver (remove and re-add the EA so it re-reads the
   config). It should log `receiver up, 2 sender(s)`.

4. Open a trade on the **MT4** account → it mirrors on the MT5 receiver.
   The existing MT5 sender keeps working at the same time.

### What this phase actually proves

* the MT4 **observation** path: `OnTimer` polling of `OrdersTotal` /
  `OrderSelect`, UID assignment, and the state file that stops a sender
  restart from re-announcing positions
* **per-sender routing** on one receiver — a second `SID` appearing in the
  log means each sender keeps its own sequence counter, magic and desired
  set, which is the many-to-one capability
* the **`from #N` ticket chain**: partially close a position on the MT4
  account. MT4's broker closes the original order and reopens the remainder
  under a **new ticket**, with `from #<old>` in the comment. The sender
  inherits the UID across that hop, so the receiver must **not** see a
  close followed by a reopen. You should see exactly one throttled
  `volume changed ...` warning and nothing else.

> The MT4 sender broadcasts **every** position on that account that passes
> its filters — including anything your other EAs opened. Use
> `IncludeSymbols` / `IncludeMagicNumbers` on the sender if you only want
> some of them copied.

**This phase also exercises one receiver serving two senders**, which is the
N:M capability you wanted from the start — two senders, each with its own
sequence counter, magic and desired-position set.

### What to check specifically on the MT4 sender

* `MQL4\Files\copier_sender_mt4demo.0.log` contains
  `sender mt4demo listening on port 5565 ssid=...`
* `open <uid> tkt=<n> <sym> side=<n> lots=<n>` — the ticket here is the MT4
  order ticket, and it is what the receiver writes into its comment, so the
  two should match.
* `restored N position(s) from state` on a restart — that is what stops a
  sender restart from re-announcing positions and duplicating them.

---

## Phase 3 — MT4 A → MT4 B

This is the configuration you would actually deploy, and with two MT4
terminals it is the natural place to end up.

`./tools/phase3-setup.sh` does the mechanical part — writes the receiver's
`copier.ini`, checks the ports, and prints the full checklist including what
to look for in the logs. The rest of this section is the reference for what
that config means and why.

* **sender**: MT4 **B** (`Alpari MT4-2`), `SenderId` = `mt4demo`,
  `BindAddress` = `tcp://127.0.0.1`, ports **5565** / **5566**
* **receiver**: MT4 **A** (`Alpari MT4`), `MQL4\Files\copier.ini`:

  ```ini
  [sender0]
  id       = mt4demo
  events   = tcp://127.0.0.1:5565
  snap     = tcp://127.0.0.1:5566
  lotmode  = multiplier
  lotparam = 1.0
  magic    = 770000
  suffix   =
  ```

Stop the MT5 sender first if you want this clean — otherwise it keeps
broadcasting on 5555 and MT4 A will ignore it (its config names only
`mt4demo`), which is itself a useful check that unknown senders are ignored
rather than mis-handled.

Everything MT4-specific to watch for is the same list as phase 1.

### Phase 3 result — PASSED

Verified on this machine, both terminals MT4, `Alpari MT4` receiving from
`Alpari MT4-2`:

| what | evidence |
|---|---|
| partial close propagates | sender `partial close on J62PEQT9 0.04 -> 0.03`, receiver `exec partial-close mt4demo J62PEQT9 senderTkt=1323061034 lots=0.01` — ~1.5 s |
| the receiver's own re-ticket survives | Journal: `remainder of order #1323061326 was opened : #1323061417 sell 0.03` — identity held across it, no `unmanageable order(s)`, no duplicate |
| the comment carries the sender's CURRENT ticket | the open wrote `senderTkt=1323060983`; after the sender re-ticketed, the partial close wrote `senderTkt=1323061034`. A stale ticket here would mean the wrong field was being read |
| no duplicates | `no UID was opened twice` |
| identity store is live | `identity store copier_receiver.st written` at startup, file mtime moving every 10 s |
| clean end state | sender state file `END:0`, receiver state file `END:N=0` — both accounts flat and agreeing |

The three `RESTORING` lines in the middle of the session are the self-healing
path working: positions closed by something other than the copier (the EA log
has **no** `exec close` for them, so it was not the copier) were re-opened
against the sender's still-open set. `logcheck` flags these as "opened more
than once — check these are legitimate recoveries", which is the right
question to ask and the Journal is what answers it.

### Reading the phase-3 logs

`logcheck.py` now prefers **both** state files over anything derived from
logs. That matters here more than anywhere else: on MT4 a partial close
re-tickets the receiver's order and overwrites its comment with `from #<old>`,
so the log is a diff that rotation can cut in half, while the state file is a
snapshot. Five positions whose closes had rolled out of a log generation were
being reported as stranded — against the state file they are simply gone.

### Verifying SL/TP mirroring

Independent of the phases above, and worth doing on whichever pair you have
running. Set a stop-loss and a take-profit on the sender, then:

| what | expected |
|---|---|
| mirror carries both | receiver `exec set-stops <sid> <uid> <sym> sl=.. tp=..` |
| the value is a **distance**, not a price | the mirror's stop is the same number of points from **its own** entry, which will be a different absolute price |
| the sender moves its stop | the receiver follows within ~2 s (one snapshot) |
| the sender **removes** its stop | the receiver removes its own too — faithful convergence, not a bug |
| the stop is inside this broker's minimum distance | one warning that it was widened; the mirror is **wider** than the sender's |
| timing at open | the mirror appears ~100 ms after the position, not with it |

Three things to check in the terminal rather than the log, because the log
cannot show them:

* the mirrored order really does have both SL and TP set, at the expected
  prices
* a stop that is close to the broker's minimum is still **valid** (the broker
  would reject it otherwise, and on MT5 that rejects the whole open)
* on MT5, `POSITION_SL`/`POSITION_TP` are per-position, so a hedging account
  with two opposing positions on one symbol gets two independent pairs

A quiet receiver log after the first modify is the correct result — the
receiver only queues a change when the value actually differs, so "no line"
means "already in sync".

---

## Reading MT4 evidence — two traps that cost real time

### 1. The EA log does not record closes it did not initiate

The copier's log is a record of **what the copier did**. If an order is closed
by hand, by another EA, or by the broker, there is **no line** — correctly,
since the copier had nothing to do with it. The MT4 **Journal**
(`<terminal>\logs\YYYYMMDD.log`) is the complete record, and it logs *every*
order operation regardless of who triggered it.

Reconcile the two before concluding anything:

```bash
# terminal Journal: every close that actually happened
grep -c "close order #" "<terminal>/logs/20261005.log"
# the copier's own log: only the closes it initiated
grep -c "close #" "<terminal>/MQL4/Logs/20261005.log"
```

On the first MT4 pilot these read **59 vs 53**. The 6-line difference looked
exactly like orphaned positions — orders the copier had opened but never
closed. It was nothing of the sort: the six had been closed by hand (the
Journal even records `one click trading has been enabled` immediately
beforehand). An "orphan" inferred from the EA log alone is not evidence.

The Journal cannot tell you *who* initiated a close either — an EA close and a
manual close look identical. So when reconciling, use the EA log to attribute
and the Journal to establish what happened.

### 2. Never run two copiers on the same account

`FX Blue - TradeCopy Receiver` was loaded on the same chart during this pilot.
Two copiers on one account will fight: each sees the other's positions as
things to close or to open, and the result is a stream of orders neither of
them can explain. Remove one before testing the other.

### And one behaviour to expect: a hand-closed mirror comes back

Close a **mirrored** position by hand while the sender still holds the
original, and the copier **restores it within a couple of seconds** — and says
so:

```
RESTORING ABCD1234 EURUSD - the sender still holds it and this account does
not (closed by hand, by another EA, or by a stop-out). To leave it alone,
add ABCD1234 to the IgnoreUids input
```

That is not a fault, it is the symmetry of the convergence: "a position I
opened is missing" is indistinguishable from "a position I should have opened
but failed to".

FX Blue does not behave this way because its convergence is
**one-directional** — it only ever closes, never re-opens. A manual close
sticks there, and so does a genuinely missed entry, which it can never
recover from. Disabling the re-open here would throw that recovery away, so
the opt-out is **per position**:

```bash
# in the CopierReceiver inputs:
IgnoreUids = ABCD1234,EFGH5678,JKMN9012
```

The UID is the 8 characters after `tc|` in the receiver's order comment, and
it appears in every `exec open` and `RESTORING` line of the log. A listed UID
is neither opened nor closed by the copier. Separators may be commas,
semicolons, pipes or spaces and case does not matter, so a list pasted from
the log lands correctly. Changing the input re-runs `OnInit`, so an edit takes
effect without touching the chart. Anything that is not a well-formed 8-character
UID is **rejected and reported** at startup rather than ignored silently.

## Reading the result

```bash
./tools/logcheck.sh
```

It picks up the MT4 logs too (`<MT4 terminal>\MQL4\Files\copier_*.log`).
For each phase, the verdict you want is:

```
ok   no UID was opened twice (no duplicate positions)
ok   no orphan closes
ok   no double closes
ok   no unexpected ERROR lines
ok   no failed trade attempts
```

`no failed trade attempts` is the one to watch on MT4 — a requote or an
invalid-stop rejection shows up there.

## If it does not work

| symptom | likely cause |
|---|---|
| EA terminates immediately, nothing in the log | **Allow DLL imports** is off (no VC++ runtime is needed any more — see above) |
| `cannot bind ... errno=48` | port already in use — the MT5 sender holds 5555 |
| `receiver up` never appears | `copier.ini` is not in that terminal's `MQL4\Files`, or it is malformed |
| nothing mirrors, no errors at all | the receiver ignores messages whose `SID` it does not recognise, silently — check that `id=` matches the sender's `SenderId` exactly |
| `not offered by this broker` | the MT4 broker does not list that symbol name — add a `symbol.` mapping or a `suffix` |
| orders open but the comment looks wrong | MT4 caps comments at 31 chars, some brokers at 27; check the UID is intact |
