# P1 pilot — end-to-end on one machine

The logic layer is covered by `CopierSelfTest`. This is the other half: the
ZeroMQ transport, the snapshot convergence, and the restart/disconnect
behaviour, against two real terminals.

This machine has **two MT5 installations**, which makes a loopback pilot
possible with no second VPS, no firewall rule and no CURVE keys:

| role | terminal | live data folder | bind/connect |
|---|---|---|---|
| **sender** | `E:\MetaTrader 5` — **portable** | `E:\MetaTrader 5\MQL5` | binds `tcp://127.0.0.1:5555` (one socket, both streams) |
| **receiver** | `C:\Program Files\MetaTrader 5` | `%APPDATA%\...\D0E8209F77C8CF37AD8BF550E51FF075` | connects to the above |

Log each terminal into a **demo** account. Two different demo logins is ideal;
one login for both works too but makes the duplicate-detection harder to read.

> **Why the sender's data folder is a path, not a 32-hex id.**
> `E:\MetaTrader 5` is a portable install (`Mt5-Portable.bat` runs
> `terminal64.exe /portable`), so its live data sits next to the executable.
> `%APPDATA%\MetaQuotes\Terminal\6F9C869F...` **also** exists for that same
> install — but it was last touched months ago and is dead weight. Deploying
> into it looks like it worked and reaches nothing.
>
> `./tools/status.sh --all` prints a `LAST USED` column precisely so the two
> can be told apart: the live folder is the one with today's timestamp.

---

## 0. Prepare

```bash
./tools/status.sh          # both MT5 terminals should show ok / ok / 4/4
./tools/pilot-setup.sh     # enables the 2nd MT5, deploys, compiles, writes copier.ini
```

`pilot-setup.sh` does three things you would otherwise do by hand:

* un-comments the second MT5 install in `tools/targets.conf`
* deploys + compiles the copier into **both** MT5 terminals
* writes `config/copier.loopback.ini` to
  `<receiver>\MQL5\Files\copier.ini`

---

## 1. Sender

In the **E:\MetaTrader 5** terminal:

1. Open any chart (symbol does not matter — the sender reads the account, not
   the chart).
2. Drag `CopierSender` from the Navigator onto the chart.
3. In the Common tab tick **Allow DLL imports**.
4. Inputs — only the first two actually need changing:
   * `SenderId` = `sender01` (the default; **must match `id=` in the
     receiver's `copier.ini`** — it is the routing key, and a receiver
     ignores any message whose SID it does not recognise, silently)
   * `BindAddress` = `tcp://127.0.0.1`  ← loopback only; `tcp://*` exposes it
   * `EventsPort` = `5555` — the only port bound
   * `UseCurve` = `false` (default)
   * `LogLevel` = `2` (the default; INFO level is event-driven — startup,
     open, close — not per-tick, so it is safe to leave on)

   > If you turn `UseCurve` on, there is no key to paste: this EA generates
   > its own keypair into `MQL5\Files\copier_curve.key` on first start and
   > prints the public key in the Experts log, ready to copy into the
   > receiver's `SenderServerKey`. See *CURVE keys* in the README.
5. Make sure **AutoTrading** is on.

Expected in the Experts log **and** in `MQL5\Files\copier_sender_sender01.0.log`:

```
sender sender01 listening on port 5555 ssid=XXXXXX
```

If that file stays empty, `LogLevel` is still 1 (warnings only) and the
startup line is being filtered out — the sender may be running perfectly.

If you see `cannot bind ... errno=48`, something already holds port 5555.

---

## 2. Receiver

In the **C:\Program Files\MetaTrader 5** terminal:

1. Drag `CopierReceiver` onto any chart.
2. Common tab → **Allow DLL imports**.
3. Tick **Allow live trading** (the receiver places orders).
4. Make sure **AutoTrading** is on.
5. Inputs: `ConfigFile` = `copier.ini`, `LogLevel` = `2`.

Expected in the Experts log:

```
receiver up, 1 sender(s), magic base=770000
```

The receiver does **nothing** until it has seen a snapshot — that guard is
deliberate, so a restarting receiver never closes positions it simply has not
heard about yet.

---

## 3. The five checks

Run them in order. After each, look at the receiver's
`MQL5\Files\copier_receiver.*.log` (and the Experts log).

### 3.1 Mirror

Open one market order manually on the **sender** account.

* within ~2 s the receiver opens the same symbol, direction and volume
* the receiver's order comment reads `tc|<uid>|<senderTicket>`, e.g.
  `tc|ABCD1234|9918271`. **The last number is the sender's own ticket** —
  find that ticket in the sender terminal and you are looking at the same
  position. That is what the field is for: matching the two orders by eye.
* the receiver's order magic is `770000`

Close it on the sender → the receiver closes within ~2 s.

### 3.2 Event loss is harmless

While a position is open, **stop the sender EA** (remove it from the chart),
then close the position manually on the sender account, then start the sender
EA again.

The receiver should close its mirror shortly after the sender comes back —
not because it saw the close event (it was down) but because the new snapshot
does not contain that position. **This is the whole reason the design does not
need reliable delivery.**

### 3.3 Receiver restart

With a position open, remove the receiver EA from the chart and put it back.

Expected: **nothing happens.** It must not re-open a duplicate, and must not
close anything. The receiver rebuilds its identity from the order comments,
then waits for the first snapshot.

### 3.4 Sender restart

Remove and re-add the sender EA while a position is open.

Expected: the receiver logs `new session ... -> resync`, then converges. No
duplicates.

### 3.5 Disconnect

Leave a position open and stop the receiver (or unplug the network) for
longer than `StaleSeconds` (15 s).

Expected on reconnect: the receiver logs
`sender pilot silent for >15s: new entries stopped, existing positions kept`
and **keeps the position**. It does not force-close at an unknown price — that
is the agreed behaviour. The `EmergencySLPips` input exists if you later want
a local stop attached at open time.

---

## 4. Read the logs like a test result

Do not eyeball the logs for these checks. The failures that matter are
usually the **absence** of a line, which is exactly what the eye skips.
Run:

```bash
./tools/logcheck.sh
```

It reads every copier log on the configured terminals and prints a verdict:
per-UID lifecycle with the sender ticket, any UID opened twice, any close
without a matching open, positions still open, unexpected errors, and a
log-volume guard.

What each check looks like when it passed:

| check | marker in the receiver log |
|---|---|
| 3.1 mirror | `exec open <sid> <uid> senderTkt=<n> <sym> lots=<l>` |
| 3.2 event loss | a `new session` after the sender restarts, then no duplicate opens |
| 3.3 receiver restart | an extra `receiver up, ...` with **no** new opens for positions already held |
| 3.4 sender restart | `sender <sid> new session <ssid> -> resync` |
| 3.5 disconnect | `sender <sid> silent for >15s: new entries stopped, existing positions kept`, then `sender <sid> is back` |

`silent for >15s` is logged at **ERROR** level, but it is a *marker*, not a
failure — it is check 3.5 doing its job. `logcheck.sh` knows that and counts
it separately.

## 5. What to check in the logs

| what | where | healthy |
|---|---|---|
| sender bound its ports | sender Experts log | `listening on port 5555` |
| receiver connected | receiver Experts log | `receiver up, 1 sender(s)` |
| snapshots flowing | receiver `copier_receiver.*.log`, level 3 | periodic entries |
| mirroring | both logs | `open <uid> <sym>` / `exec open ...` |
| sizing rejected | receiver log | `lot sizing rejected ...` means the volume converted below the broker minimum — expected on a tiny account |

Set `LogLevel = 3` (debug) on the receiver to also see heartbeats. Do not
leave it there: the logger rate-limits repeats, but debug on a busy account is
still noise.

---

## 6. If nothing happens

| symptom | likely cause |
|---|---|
| `DLL not found` at load | `libzmq.dll` is not in that terminal's `Libraries` folder (or **Allow DLL imports** is off). No VC++ runtime is needed — as of libzmq 4.3.5 the DLL is MinGW-w64 built and self-contained, with libsodium linked statically |
| EA terminates immediately | **Allow DLL imports** is off — check the Experts log for the reason code |
| `cannot bind ... errno=48` | port 5555 already in use |
| receiver never logs anything | wrong `copier.ini` location, or the receiver is in the *other* MT5 install — run `./tools/status.sh` |
| sender binds fine, receiver silent | the two terminals are different installs, so `127.0.0.1` is still the same machine — check the receiver's `events=`/`snap=` lines |
| order placed but not mirrored | symbol not offered by the receiver's broker → look for `... not offered by this broker; skipped` |

`./tools/status.sh` answers the "which terminal am I actually in" question,
which is the most common way to lose ten minutes here.
