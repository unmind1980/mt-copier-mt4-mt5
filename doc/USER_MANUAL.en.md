# MT-Copier Full-Stack User Manual & Production Guide

This manual is written for institutional traders, asset managers, and trading operations teams using **MT-Copier** — the ultra-low-latency, cross-platform MetaTrader 4 / MetaTrader 5 trade replication and risk management platform powered by ZeroMQ and Rust.

This guide provides exhaustive operating instructions for both **Direct Mode (P2P)** and **Central Hub Mode**, detailed parameter-by-parameter references for every Input in `CopierSender` and `CopierReceiver`, sizing and risk management models, symbol mapping rules, and high-availability operational best practices.

---

## Table of Contents
1. [Architecture & Deployment Topologies](#1-architecture--deployment-topologies)
2. [5-Minute Quickstart: Direct Mode (P2P)](#2-5-minute-quickstart-direct-mode-p2p)
3. [5-Minute Quickstart: Central Hub Mode](#3-5-minute-quickstart-central-hub-mode)
4. [Sender (`CopierSender`) Input Parameter Reference](#4-sender-copiersender-input-parameter-reference)
5. [Receiver (`CopierReceiver`) Input Parameter Reference](#5-receiver-copierreceiver-input-parameter-reference)
6. [Lot Sizing Models & Risk Management Matrix](#6-lot-sizing-models--risk-management-matrix)
7. [Cross-Broker Symbol & Suffix Mapping Guide](#7-cross-broker-symbol--suffix-mapping-guide)
8. [Reverse Copying (Inverted Trades) Specification](#8-reverse-copying-inverted-trades-specification)
9. [24/7 VPS Production Operations & Maintenance](#9-247-vps-production-operations--maintenance)
10. [Troubleshooting & Frequently Asked Questions (FAQ)](#10-troubleshooting--frequently-asked-questions-faq)

---

## 1. Architecture & Deployment Topologies

| Dimension | Direct P2P Mode (`mt-copier-direct`) | Central Hub Mode (`mt-copier-hub-suite`) |
| :--- | :--- | :--- |
| **Architecture** | Sender broadcasts directly over ZeroMQ; Receiver connects via local TCP loopback. | Senders and Receivers connect upstream to a central asynchronous Rust Hub daemon. |
| **Best For** | • Single PC or single VPS hosting Master and Slave terminals<br>• 1 Master copying to 1–5 Slaves<br>• Zero background processes, zero external dependencies | • Fleet management across multiple cloud VPS and data centers<br>• Many-to-many matrix replication (dozens of accounts)<br>• Web Cockpit dashboard, mobile push alerts, dual-active HA clustering |
| **Prerequisites** | MetaTrader 4 / 5 terminals and included native DLLs. **No Rust, Python, or external runtime required.** | Background execution of `copier-hub.exe` on a server or VPS (can run as a native Windows Service). |
| **Latency** | **< 2 ms** (Local in-memory loopback transport) | **< 10 ms** (Sub-millisecond hub routing + physical WAN transit) |

---

## 2. 5-Minute Quickstart: Direct Mode (P2P)

Use Direct Mode when both Master and Slave MetaTrader accounts are running on the **same machine or VPS**.

### Step 1: Copy Binaries to MetaTrader Data Folders
1. Open your Master and Slave MetaTrader terminals.
2. Click **File** -> **Open Data Folder** in each terminal:
   - **For MT4 Terminals**:
     - Copy `CopierSender.ex4` and `CopierReceiver.ex4` into `MQL4\Experts\`
     - Copy the 32-bit `libzmq.dll` into `MQL4\Libraries\`
   - **For MT5 Terminals**:
     - Copy `CopierSender.ex5` and `CopierReceiver.ex5` into `MQL5\Experts\`
     - Copy the 64-bit `libzmq.dll` into `MQL5\Libraries\`
3. *(Alternative: Simply double-click `install_direct.bat` inside the release package to automatically detect and deploy files to all local terminals).*

### Step 2: Grant Permissions (Mandatory)
In **every** terminal (both Master and Slave):
1. Navigate to **Tools** -> **Options** -> **Expert Advisors** (or `Charts / EAs`).
2. Check **Allow automated trading** (or **Allow Algo Trading**).
3. Check **Allow DLL imports**.
4. Click **OK**. Ensure the top toolbar button **AutoTrading / Algo Trading** is green.

### Step 3: Attach EAs and Begin Copying
1. **On the Master Account (Sender)**:
   - Open any single chart (e.g. `EURUSD M1`).
   - Drag `CopierSender` from the Navigator onto the chart.
   - **Leave all inputs at default** (`HubEndpoint` left blank enables Direct Mode; port is automatically assigned).
   - Click **OK**. A status HUD appears on the chart showing `Listening on port: 5000` (or similar).
2. **On the Slave Account (Receiver)**:
   - Open any single chart.
   - Drag `CopierReceiver` onto the chart.
   - In the **Inputs** tab:
     - `SenderIP`: Keep `127.0.0.1` (local loopback).
     - `SenderPort`: Set to the port displayed on the Sender chart (e.g. `5000`).
     - `SenderLotMode`: Select your desired lot sizing mode (default: `LOT_MULTIPLIER`).
     - `SenderLotParam`: Set your multiplier or fixed size (e.g. `1.0` for 1:1 matching, or `0.5` for half size).
   - Click **OK**.
3. **Done!** Open, modify, or close an order on the Master account. The trade will synchronize to the Slave account in under 2 milliseconds.

---

## 3. 5-Minute Quickstart: Central Hub Mode

Use Hub Mode when accounts are distributed across different VPS providers, or when you require Web Cockpit monitoring, REST API control, and high availability.

### Step 1: Start the Central Hub Server
1. Extract `mt-copier-hub-suite-v1.1.0.zip` on your central server/VPS.
2. **Foreground Console Mode (Testing)**:
   - Double-click `start_hub.bat`.
3. **Background Service Mode (Production, Recommended)**:
   - Right-click `install_service.bat` -> Select **Run as Administrator**.
   - The Hub registers as a native Windows Service with auto-restart on system boot or failure.
4. Open your browser and navigate to:
   ```text
   http://127.0.0.1:6010
   ```
5. Log in using the admin password printed on initial launch (or set via `MTC_ADMIN_PASSWORD`).

### Step 2: Configure Client Terminals to Connect to Hub
1. Install EA binaries and `libzmq.dll` to each terminal as in Direct Mode.
2. **On the Master Terminal (Sender)**:
   - Set `HubEndpoint` = `127.0.0.1:6000` (or your Hub server's public IP/domain, e.g. `198.51.100.25:6000`).
3. **On the Slave Terminal (Receiver)**:
   - Set `HubEndpoint` = `127.0.0.1:6000` (same as Sender).
   - `SenderIP` and `SenderPort` are ignored in Hub Mode.
4. Refresh the Web Cockpit. You will immediately see live node status cards, measured round-trip latencies, and real-time open positions.

---

## 4. Sender (`CopierSender`) Input Parameter Reference

`CopierSender` runs on the Master trading terminal, capturing order events, tick changes, and state snapshots, and broadcasting them downstream.

### 1. Connectivity & Mode
| Parameter | Default | Allowed Values | Description & Recommended Usage |
| :--- | :---: | :--- | :--- |
| **`HubEndpoint`** | *(empty)* | `IP:Port` (e.g. `127.0.0.1:6000`) | **Central Hub Address**.<br>• **Empty**: Direct P2P mode (listens locally for incoming Receivers).<br>• **Set**: Hub Mode (connects upstream to central Rust server). |
| **`BindAddress`** | `*` | `*` or specific IP (e.g. `127.0.0.1`) | **Local Network Bind Address**.<br>• `*`: Binds to all available network interfaces (`0.0.0.0`). Recommended.<br>• Specific IP: Restricts listening interface on multi-NIC machines. |
| **`EventsPort`** | *(empty)* | Empty or `1024 - 49151` | **Direct Mode Listening Port**.<br>• **Empty (Recommended)**: Automatically derived as `5000 + (AccountNumber % 1000)` to eliminate multi-account port collisions.<br>• Explicit integer: Binds to the designated port. |
| **`UseCurve`** | `false` | `true` / `false` | **ZeroMQ Curve25519 256-bit Encryption**.<br>Set to `true` when broadcasting over untrusted public WAN networks without VPN/tunneling. |

### 2. Cadence & Performance
| Parameter | Default | Allowed Values | Description & Recommended Usage |
| :--- | :---: | :--- | :--- |
| **`SnapshotSeconds`** | `15` | `0 - 3600` (seconds) | **Authoritative State Snapshot Interval**.<br>In addition to real-time event pushes, full position state is broadcast every N seconds to guarantee self-healing convergence after network blips. (0 disables periodic snapshots; not recommended). |
| **`HeartbeatSeconds`** | `5` | `1 - 60` (seconds) | **Heartbeat Telemetry Interval**.<br>Broadcasts account equity, balance, floating PnL, and node health. |
| **`PollMs`** | `5` | `1 - 100` (ms) | **Underlying Polling Loop Cadence**.<br>5ms provides sub-millisecond order detection with negligible CPU usage (<0.5%). |

### 3. Order Filters
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`IncludeSymbols`** | *(empty)* | **Symbol Whitelist / Blacklist Filter**.<br>• **Empty**: Broadcasts all symbols.<br>• **Whitelist**: Comma-separated list (e.g. `EURUSD,GBPUSD,XAUUSD`).<br>• **Blacklist**: Prefix with `!` (e.g. `!BTCUSD,!ETHUSD`) to copy all symbols except crypto. |
| **`IncludeMagicNumbers`** | *(empty)* | **Magic Number Filter**.<br>• **Empty**: Replicates all trades (manual trades + all EAs).<br>• `0`: **Replicates manual trades only** (ignores all automated EAs).<br>• `1001,1002`: Replicates trades matching specified EA magic numbers only. |

### 4. Sizing Hints
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`FixedLotSize`** | `0.0` | **Sender-Enforced Lot Size Override**.<br>If > 0, overrides the broadcast lot size with this constant (0 retains real open lot size). |
| **`LotSizeMultiplier`** | `0.0` | **Sender Lot Multiplier**.<br>Pre-scales original lot size before broadcast if `FixedLotSize=0` (0 = no modification). |

### 5. System & Display
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`LogLevel`** | `2` | Diagnostic verbosity: `0`=Errors only, `1`=Warnings, `2`=Info (Recommended), `3`=Debug. |
| **`StatusEnabled`** | `true` | Enables inbound ACK and STAT telemetry handling from connected Receivers. |
| **`ShowPanel`** | `true` | Renders the on-chart visual HUD showing connection count, latency, and uptime. |

---

## 5. Receiver (`CopierReceiver`) Input Parameter Reference

`CopierReceiver` runs on the Slave terminal, receiving trade signals and executing orders governed by local risk policies and sizing rules.

### 1. Connectivity & Mode
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`HubEndpoint`** | *(empty)* | Central Hub address (`IP:Port`). Leave empty for Direct P2P mode. |
| **`SenderIP`** | `127.0.0.1` | Master terminal IP address in Direct mode (`127.0.0.1` for local loopback). |
| **`SenderPort`** | `5555` | Master terminal listening port in Direct mode (must match Sender port). |
| **`UseCurve`** | `false` | Enable Curve25519 encryption (must match Sender configuration). |
| **`SenderServerKey`** | *(empty)* | Z85 public key of the Sender when `UseCurve=true`. |
| **`InpMagic`** | *(empty)* | **Local EA Magic Number**.<br>Leave empty for automatic generation based on Sender port; or set explicitly (e.g. `888888`) to identify copied orders. |

### 2. Sizing & Symbol Mapping
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`SenderLotMode`** | `LOT_MULTIPLIER` | **Lot Sizing Calculation Engine**:<br>• `LOT_MULTIPLIER` (0): Multiplier mode (`Receiver Lots = Master Lots * SenderLotParam`).<br>• `LOT_FIXED` (1): Fixed volume (`Receiver Lots = SenderLotParam`).<br>• `LOT_OFF` (2): Pass sender volume through directly 1:1 without scaling by SenderLotParam (to observe telemetry without placing trades, set `InpIgnoreNewEntrySignals=true`).<br>• `LOT_EQUITY_RATIO` (3): Proportional equity auto-scaling. |
| **`SenderLotParam`** | `1.0` | **Lot Sizing Parameter**.<br>In multiplier mode, `1.0` = 1:1 copy, `0.5` = half size. In fixed mode, `0.05` = 0.05 lots per order. |
| **`SenderSuffix`** | *(empty)* | **Broker Symbol Suffix**.<br>If Master uses `EURUSD` and Slave broker uses `EURUSD.pro`, set to `pro` (leading period is optional; handled automatically). |
| **`SenderSymbolMap`** | *(empty)* | **Explicit Symbol Translation Map**.<br>Comma-separated `Source=Target` pairs. E.g. `GOLD=XAUUSD,USOIL=WTI`. |

### 3. Risk Management & Circuit Breakers
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpMaxLotsPerPosition`** | `0.0` | **Maximum Lot Size per Single Trade**.<br>Caps individual order volume (e.g. `2.0` prevents any trade from exceeding 2.0 lots; 0 = unlimited). |
| **`InpMaxTotalLots`** | `0.0` | **Maximum Aggregate Portfolio Lots**.<br>Rejects new entries when sum of all open copied lots reaches this ceiling (0 = unlimited). |
| **`InpMaxOpenPositions`** | `0` | **Maximum Open Positions Count**.<br>Caps total concurrent open copied positions (e.g. `10` stops opening after 10 active trades; 0 = unlimited). |
| **`InpDailyLossPct`** | `0.0` | **Daily Equity Loss Circuit Breaker (%)**.<br>Calculated against 00:00 server equity baseline. E.g. `5.0` halts copying if daily drawdown reaches 5%. |
| **`InpMaxDrawdownPct`** | `0.0` | **Maximum High-Water Mark Drawdown (%)**.<br>Emergency shutdown if account drawdown from all-time peak exceeds threshold. |
| **`InpRiskCloseAllOnTrip`** | `false` | **Emergency Liquidation on Circuit Breaker Trip**.<br>• `false`: Stop taking new trades; allow existing positions to exit normally.<br>• `true`: Instantly close all open copied positions at market (emergency evacuation). |

### 4. Execution & Stop Management
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpDeviationPoints`** | `30` | **Maximum Allowed Slippage (Points)**.<br>Rejects market orders if execution slippage exceeds 30 points (3 pips). |
| **`InpEmergencySLPips`** | `0.0` | **Local Emergency Stop-Loss (Pips)**.<br>Mandatory hard stop distance attached immediately on fill, protecting against network disconnects (0 = disabled). |
| **`InpEmergencyTPPips`** | `0.0` | **Local Emergency Take-Profit (Pips)**.<br>Hard take-profit distance attached on fill (0 = disabled). |
| **`InpMirrorStops`** | `true` | **Mirror Master SL/TP Levels** (Recommended `true`).<br>Uses relative distance re-anchoring to eliminate pricing discrepancy issues between brokers. |
| **`InpInvertTrades`** | `false` | **Reverse Copying Toggle**.<br>Inverts trade direction (Buy ➔ Sell, Sell ➔ Buy) and flips SL/TP roles automatically. |
| **`InpReopenClosedMirrors`** | `false` | Re-open positions closed manually on Slave while Master still holds them.<br>**Strongly recommend `false`** to respect manual operator intervention. |
| **`InpDedupDuplicates`** | `true` | **Duplicate Order Shield**.<br>Prevents duplicate execution caused by network packet retries. |
| **`InpStopsThrottleSeconds`** | `2` | **Stop Modification Rate Limiter (Seconds)**.<br>Prevents broker `10027` API bans during rapid trailing stop updates by rate-limiting modifications to once every 2 seconds per ticket. |
| **`InpMarketOpenDelayMinutes`** | `5` | **Monday Market Open Freeze (Minutes)**.<br>Suspends new entries during the first 5 minutes of Monday market opening to avoid extreme spread spikes. |
| **`InpMaxSpreadMultiplier`** | `2.5` | **Spread Spike Filter**.<br>Rejects new entries when current spread exceeds 2.5x the symbol's normal average spread. |

### 5. Filters & Trading Direction
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpPermittedSymbols`** | *(empty)* | Local whitelist of symbols to replicate (supports `!` prefix for blacklisting). |
| **`InpPermittedMagic`** | *(empty)* | Local whitelist of Master EA magic numbers to replicate. |
| **`InpMinSenderLotSize`** | `0.0` | Minimum Master lot size threshold (ignores micro test orders like 0.01). |
| **`InpMaxSenderLotSize`** | `0.0` | Maximum Master lot size threshold. |
| **`InpIgnoreUids`** | *(empty)* | Comma-separated blacklist of specific 8-character trade UIDs to exclude. |
| **`InpNoBuy`** | `false` | When `true`, completely blocks all Buy (Long) orders. |
| **`InpNoSell`** | `false` | When `true`, completely blocks all Sell (Short) orders. |
| **`InpIgnoreNewEntrySignals`**| `false` | **Close-Only Mode**.<br>Replicates position exits, but rejects all new entries (ideal for winding down strategies). |
| **`InpIgnoreAllExitSignals`** | `false` | Replicates entries only, ignoring Master exits (positions managed entirely on Slave). |

### 6. Anti-Stacking & Entry Timing
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpCheckForExistingPosition`**| `EXIST_OFF` | **Position Stacking Protection**:<br>• `EXIST_OFF` (0): No restriction on adding positions.<br>• `EXIST_SYMBOL` (1): Disallow opening if Slave already holds any trade on this symbol.<br>• `EXIST_DIRECTION` (2): Disallow opening if Slave already holds a trade in the same direction on this symbol. |
| **`InpWaitForSeconds`** | `0` | Delay N seconds after Master entry before placing the order locally (avoids news spike slippage). |
| **`InpWaitForProfitPips`** | `0.0` | **Price Action Filter**.<br>Positive value: Wait for Master to gain N pips of profit before joining.<br>Negative value: Wait for Master to draw down N pips before entering (pullback entry). |
| **`InpPendingFillGraceSeconds`** | `1.5` | Grace period (seconds) for pending order fill confirmation. |

### 7. Trading Schedule & Timeout
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpIncludeTradingTimes`** | *(empty)* | Permitted daily trading hours (broker time), e.g. `08:00-12:00,14:00-22:00`. Entries outside this window are discarded. |
| **`InpDayTradingTimes`** | *(empty)* | Per-day schedules, e.g. `Mon=09:00-17:00;Fri=09:00-15:00`. |
| **`InpStaleSeconds`** | `15` | **Heartbeat Timeout (Seconds)**.<br>If no heartbeat is received from Master for >15s, connection is flagged stale and new entries are halted until restored. |

### 8. System & Diagnostics
| Parameter | Default | Description & Recommended Usage |
| :--- | :---: | :--- |
| **`InpPollMs`** | `5` | Internal polling loop cadence (5 ms recommended). |
| **`InpMaxActionsPerTick`** | `4` | Max order actions executed per timer tick to prevent blocking the terminal thread. |
| **`InpLogLevel`** | `2` | Log verbosity (`0`=Errors, `1`=Warn, `2`=Info, `3`=Debug). |
| **`InpShowPanel`** | `true` | Show on-chart status HUD overlay. |
| **`InpShowOrphanedList`** | `false` | Displays list of orphaned trades on chart HUD. |
| **`InpConvergeSweepMs`** | `1000` | Full state reconciliation sweep interval (1000 ms = 1 second). |

---

## 6. Lot Sizing Models & Risk Management Matrix

### Scenario 1: Identical 1:1 Volume (Master & Slave Have Equal Capital)
- `SenderLotMode` = `LOT_MULTIPLIER` (0)
- `SenderLotParam` = `1.0`
- *Outcome*: Master opens 0.50 lots -> Slave opens 0.50 lots.

### Scenario 2: Proportional Lot Scaling (Master has $10,000, Slave has $2,000)
- `SenderLotMode` = `LOT_MULTIPLIER` (0)
- `SenderLotParam` = `0.2`
- *Outcome*: Master opens 1.00 lot -> Slave opens 0.20 lots (1/5 ratio).

### Scenario 3: Fixed Lot Defensive Sizing (Slave Maintains Uniform Micro Lots)
- `SenderLotMode` = `LOT_FIXED` (1)
- `SenderLotParam` = `0.05`
- *Outcome*: Master opens 0.01 or 10.00 lots -> Slave consistently executes exactly 0.05 lots per trade.

### Scenario 4: Dynamic Auto-Scaling by Account Equity Ratio
- `SenderLotMode` = `LOT_EQUITY_RATIO` (3)
- `SenderLotParam` = `1.0`
- *Outcome*: System continuously reads live equity from both accounts every second:
  $$\text{Slave Lots} = \text{Master Lots} \times \left( \frac{\text{Slave Equity}}{\text{Master Equity}} \right) \times \text{SenderLotParam}$$
  Volume automatically adjusts without manual reconfiguration as profits accumulate or withdrawals occur.

---

## 7. Cross-Broker Symbol & Suffix Mapping Guide

Broker naming conventions for identical trading instruments often differ across venues:

### Pattern A: Standard Broker Suffix (e.g. `.pro`, `.m`, `raw`)
- Master Broker: `EURUSD`, `GBPUSD`, `XAUUSD`
- Slave Broker: `EURUSD.pro`, `GBPUSD.pro`, `XAUUSD.pro`
- **Configuration**: In `CopierReceiver`, set:
  ```ini
  SenderSuffix = pro
  ```
  *(The system auto-formats leading periods; either `pro` or `.pro` is accepted).*

### Pattern B: Non-Standard Instrument Tickers (Gold, Indices, Oil)
- Gold: Master uses `GOLD`, Slave uses `XAUUSD`
- Crude Oil: Master uses `USOIL`, Slave uses `WTI`
- Nasdaq: Master uses `NAS100`, Slave uses `USTEC`
- **Configuration**: In `CopierReceiver`, set `SenderSymbolMap`:
  ```ini
  SenderSymbolMap = GOLD=XAUUSD,USOIL=WTI,NAS100=USTEC
  ```

---

## 8. Reverse Copying (Inverted Trades) Specification

Reverse copying is commonly used to hedge counter-trend strategies, exploit toxic toxic-flow accounts, or build market-neutral portfolios.

### Activation:
In `CopierReceiver` inputs:
- `InpInvertTrades` = `true`

### System Safeguards during Inversion:
1. **Trade Direction Reversal**:
   - Master Buy ➔ Slave executes **Sell**.
   - Master Sell ➔ Slave executes **Buy**.
2. **Intelligent SL / TP Role Inversion**:
   - Master's Take-Profit becomes Slave's **Stop-Loss**.
   - Master's Stop-Loss becomes Slave's **Take-Profit**.
   - Relative distance re-anchoring guarantees that price direction and stop levels are computed correctly relative to the local execution price, **completely preventing broker `10016` (Invalid Stops) rejections**.

---

## 9. 24/7 VPS Production Operations & Maintenance

Engineered for unattended 24/7/365 production use with minimal operational overhead:

1. **Zero Memory Leaks**:
   - ZeroMQ internal message queues and MQL static ring buffers are pre-allocated and bounded. Memory footprint remains constant indefinitely.
2. **Automated Terminal Log Hygiene**:
   - Included in the release package is [`clean_terminal_logs.bat`](tools/clean_terminal_logs.bat). Schedule this script in Windows Task Scheduler (e.g. weekly on Sundays) to purge gigabytes of historical platform debug logs.
3. **Hub Journal Compaction**:
   - The Rust Hub service performs automatic log compaction every 10 minutes, maintaining at most 10 rotated revisions to safeguard disk space on low-capacity VPS instances.

---

## 10. Troubleshooting & Frequently Asked Questions (FAQ)

### Q1: Sad face 🙁 or gray hat appears next to EA name on the chart?
- **Cause**: Automated trading or DLL imports are blocked by MetaTrader security settings.
- **Solution**:
  1. Press `F7` on the chart -> **Common** tab -> check **Allow automated trading** and **Allow DLL imports**.
  2. Verify that the **AutoTrading / Algo Trading** button in MetaTrader's top toolbar is activated (green).

### Q2: Alert: `ZeroMQ error: cannot load library libzmq.dll` or Error 4111?
- **Cause**: Missing or misplaced `libzmq.dll`, or architecture mismatch.
- **Solution**:
  - For **MT4 (32-bit)**: Place 32-bit `libzmq.dll` in `MQL4\Libraries\`.
  - For **MT5 (64-bit)**: Place 64-bit `libzmq.dll` in `MQL5\Libraries\`.
  - The 32-bit and 64-bit DLLs are distinct binaries; ensure you do not mix them up.

### Q3: In Direct Mode, Receiver HUD displays `Connecting...` indefinitely?
- **Troubleshooting Steps**:
  1. Check the Sender chart to ensure `Listening on port: 5000` is active.
  2. Verify that Receiver's `SenderPort` matches the Sender's port exactly.
  3. If connecting across machines, ensure Windows Firewall allows incoming connections on the target port.

### Q4: Entry copied successfully, but closing the Master trade did not close the Slave?
- **Troubleshooting Steps**:
  1. Verify `InpIgnoreAllExitSignals` is set to `false`.
  2. Check if the position was manually closed or partially closed on the Slave by an operator; the system enforces an **Intent Protection Ring** to avoid overriding human actions.
  3. Inspect the terminal Experts tab for broker rejection codes (e.g. market closed, off-quotes, or spread spike protection).

### Q5: Why is the fill price slightly different, but the Stop-Loss distance in pips is identical?
- **Explanation**: MT-Copier implements **Relative Distance Re-anchoring** rather than copying absolute price levels. If Broker A and Broker B have a 1.2-pip price feed divergence, copying raw price quotes would cause premature stop-outs. Re-anchoring preserves the exact intended risk distance in points from the actual fill price.
