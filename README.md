# MT4 / MT5 High-Performance Trade Copier & HA Risk Platform

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-MT4%20%7C%20MT5%20%7C%20Windows%20%7C%20Linux%20(Wine)-green.svg)]()
[![Rust Backend](https://img.shields.io/badge/Rust-1.80%2B%20(Tokio%20%26%20ZeroMQ)-orange.svg)]()
[![Tests](https://img.shields.io/badge/Tests-161%2F161%20Rust%20PASS%20%7C%2022%20Python%20Suites-brightgreen.svg)]()
[![MQL Build](https://img.shields.io/badge/MQL%20Matrix-16%2F16%20Binaries%20ALL%20GREEN-success.svg)]()

**[ English ](README.md) | [ 简体中文 ](README.zh-CN.md)**

*An institutional-grade, ultra-low-latency (<10ms) trade replication and centralized risk management platform for MetaTrader 4 and MetaTrader 5, powered by ZeroMQ and Rust.*

</div>

---

## 📌 Overview

**mt-copier** is a production-hardened, self-hosted replacement for traditional copiers (such as FX Blue and legacy socket-based solutions). 

Traditional copiers suffer from chronic un-bounded memory growth, lack of cross-platform (MT4 ↔ MT5) flexibility, vulnerability to network drops, and zero centralized observability. **mt-copier** redesigns the entire replication paradigm around **ZeroMQ pub/sub streams coupled with an authoritative snapshot convergence model**, delivering microsecond-level order forwarding, resilient fail-safe recovery, and a modern dual-active high-availability (HA) management cluster.

---

## ⚡ Core Design Principles

| Pillar | Architectural Choice | Operational Benefit |
| :--- | :--- | :--- |
| **Consistency** | Event stream (`OPEN`/`CLOSE`/`MODIFY`) + Periodic Authoritative **Snapshot** (`SNAP`) | Events deliver sub-10ms execution; snapshots enforce absolute eventual consistency. A lost packet costs milliseconds, never correctness. |
| **Platform Neutrality** | MQL4 (32-bit) ↔ MQL5 (64-bit) bi-directional matrix | Any terminal can act as Sender or Receiver with identical protocol framing and shared C++ MinGW-w64 ZeroMQ binaries. |
| **Identity Guarantee** | Deterministic 8-char alphanumeric `UID` in order comments | Receiver tracks origin without modifying sender trades; survive MT4 ticket replacements and partial fills. |
| **Fail-Safe Discipline** | Re-anchor stop distance, signed break-even trailing, disconnect protection | On network loss or feed stall: **keep existing positions protected**, halt new entries, and trigger immediate circuit breakers. |
| **High Availability** | Dual-active Primary (6000/6010) / Standby (6001/6011) with ADR-10 failback | Monotonic epoch fencing, two-phase journal replication, zero split-brain risk, automatic promotion and graceful handover. |

---

## 🚀 Key Features

### 1. Any-to-Any Ultra-Low Latency Execution
- **Sub-10ms End-to-End Latency**: ZeroMQ asynchronous memory buffers and optimized protocol serializers.
- **Bi-directional Matrix**: Seamless copy between MT4 and MT5 across any broker:
  - MT4 ➔ MT4
  - MT5 ➔ MT5
  - MT4 ➔ MT5 (32-bit to 64-bit bridge)
  - MT5 ➔ MT4 (64-bit to 32-bit bridge)
- **Many-to-Many Routing**: A single receiver can replicate from dozens of distinct senders concurrently with isolated sequence counters, independent lot multipliers, and magic numbers.

### 2. Enterprise High-Availability (HA) Dual-Active Cluster
- **Active-Standby Redundancy**: Primary Hub continuously synchronizes commands, configuration revisions, and client states to the Standby Hub.
- **Failover & Auto-Failback (ADR-04 / ADR-10)**: Strict epoch-based tie breaking, continuous heartbeat health probes, and stabilized two-phase handover without state loss or duplicate orders.
- **Atomic Journal Persistence**: Two-phase write barriers with `sync_data` fsync barriers, guaranteeing 100% crash durability for all operational commands.

### 3. Financial-Grade Security & Encryption
- **ZeroMQ CURVE Encryption**: 256-bit elliptic-curve cryptography (Curve25519) with per-terminal Z85 keypair authentication. Unauthorized nodes are dropped at ZAP handshake before entering the network.
- **Native TLS 1.3 / HTTPS / WSS**: Built-in Axum web server supporting custom SSL certificates or on-demand ACME (Let's Encrypt) challenge generation with invisible port 80 binding.
- **SSRF & DNS Rebinding Immunity**: All outgoing notification webhooks enforce pinned IP resolution, loopback/link-local blacklisting, and redirect prohibition.

### 4. Modern Centralized Web Cockpit
- **Interactive Multi-Node Dashboard**: Real-time position monitor, node topology graph, and command center.
- **Split Cockpit Layout**: Dedicated Senders overview card paired with linked real-time position details, featuring live **Profit** and **Swap** interest telemetry.
- **Multi-Language (i18n)**: Instant client-side switching between **English, 简体中文, 繁體中文, 日本語, Русский, and Español**.
- **Responsive Theme & Scaling**: Built-in dark Night Mode, mobile-optimized responsive layout, and global 80%~140% dynamic typography scaling.

### 5. Advanced Quantitative Risk Management
- **Circuit Breakers**: Multi-tier threshold gates for Maximum Open Positions, Maximum Total Lots, Daily Loss Limit (% / Currency), and Maximum Allowed Slippage/Spread.
- **Dynamic Stop Re-anchoring**:
  - Distance preservation relative to local entry.
  - Signed break-even and trailing profit lock mirroring.
  - Inverted trade mapping (Take-Profit becomes Stop-Loss, and vice-versa).
  - MT5 ECN 10016 auto-degradation (market execution with immediate stop clamping).
- **Manual-Closed Protection Ring**: Prevents the copier from re-opening trades closed manually by the operator while the sender still holds them (`g_manualClosed` intent ring with targeted GC).

### 6. Multi-Channel Instant Alerting
- **Real-Time Push Notifications**: Instant alerting on tripped risk rules, node disconnects, clock drifts, and automated recovery loops.
- **Supported Channels**:
  - **WeChat (微信 / Xtuis 虾推啥)**
  - **Telegram Bot**
  - **WeCom (企业微信机器人)**
  - **DingTalk (钉钉机器人)**
  - **Custom JSON Webhook**
- **Per-Channel Localization**: Each alert destination can be assigned its own language preference independently.

### 7. Production Windows Services
- **Background Daemon Installation**: Simple scripts (`install_services.bat`, `start_services.bat`) to install Primary and Standby Hubs as native Windows services, running invisibly with automatic restart on failure.

---

## 🏗️ Topologies

### Mode 1: Direct P2P (Lightweight, No Central Process)
Ideal for simple local copying across terminals on the same machine.
```text
[ MT4 / MT5 Sender EA ]  -- ZeroMQ XPUB (AutoPort 5000+acc%1000) -->  [ MT4 / MT5 Receiver EA ]
```

### Mode 2: Centralized Hub (Monitoring, Fleet Controls, REST API)
Single central Rust process coordinating dozens of senders and receivers with web management.
```text
[ Sender Terminals ]  -- TCP (XSUB) --> [ Central Hub :6000 ] -- TCP (XPUB) --> [ Receiver Terminals ]
                                                │
                                        ┌───────┴───────┐
                                  [ Web Cockpit ] [ Alert Push ]
                                      (:6010)     (WeChat/TG/etc.)
```

### Mode 3: High-Availability Dual-Active Cluster (Enterprise Zero-Downtime)
Two mutually synchronized hubs with automatic split-brain prevention and seamless failover.
```text
[ Sender / Receiver Nodes ] ── (Dual uplink to both Hubs)
           │
     ┌─────┴─────────────────────────┐
     ▼                               ▼
[ Primary Hub ]   ◄── Sync ──►   [ Standby Hub ]
  ZMQ :6000                       ZMQ :6001
  Web :6010 (RW)                  Web :6011 (RO)
```

---

## 📂 Repository Structure

```text
mt-copier/
├── src/
│   ├── Experts/                  # Production MetaTrader EAs
│   │   ├── CopierSender.mq4      # Dual MT4/MT5 Sender Expert Advisor
│   │   └── CopierReceiver.mq4    # Dual MT4/MT5 Receiver Expert Advisor
│   ├── Include/Copier/           # Core MQL library
│   │   ├── CopierDefs.mqh        # Normalised models & platform abstractions
│   │   ├── CopierCodec.mqh       # Wire format encoding/decoding & snapshot validator
│   │   ├── CopierModel.mqh       # Low-level MT4/MT5 trade execution models
│   │   ├── CopierRisk.mqh        # Multi-tiered circuit breakers & drawdown guards
│   │   ├── CopierTransport.mqh   # ZeroMQ transport layer & uplink dispatchers
│   │   └── ...                   # State persistence, Sizing, Symbol mapping, etc.
│   └── Scripts/                  # Self-tests & network probe utilities
├── hub/                          # Rust Central Hub
│   ├── src/                      # 17 core Rust modules (Tokio async engine)
│   │   ├── main.rs               # ZMQ proxy, heartbeat router & service hooks
│   │   ├── api.rs                # REST API, WebSocket streams & Web Cockpit handler
│   │   ├── cluster.rs            # Dual-active HA cluster manager & failback engine
│   │   ├── commands.rs           # Durable command journal & retry ladders
│   │   ├── notifications.rs      # Multi-channel alerting (WeChat, Telegram, WeCom, DingTalk)
│   │   ├── tls.rs                # SSL/TLS 1.3 engine with on-demand ACME worker
│   │   └── assets/dashboard.html # Modern responsive Web UI
│   └── target/release/           # Optimized production binary (copier-hub.exe)
├── locales/                      # Full external i18n dictionaries (zh-CN, zh-TW, ja, ru, es, en)
├── doc/                          # Technical specifications & design specs
│   ├── PROTOCOL.md               # Wire protocol specification & message envelopes
│   ├── HANDOFF.md                # Engineering handbook & evolution history
│   └── ...                       # Architecture & design documents
└── tools/                        # Deployment, testing & verification toolchain
    ├── deploy.sh / compile.sh    # Multi-terminal deployment & automated compilation
    ├── tests.sh / tests.bat      # 22 Python integration & contract test suites
    ├── start_primary.bat         # Launch Primary Hub (Port 6000 / Web 6010)
    ├── start_standby.bat         # Launch Standby Hub (Port 6001 / Web 6011)
    └── install_services.bat      # Install as background Windows Services
```

---

## ⚡ Quick Start Guide (5 Minutes)

### Step 1: Deploy & Compile MT4 / MT5 Terminals
Run the automated deployment script to link libraries and compile binaries for all local terminals:
```bash
# In Git Bash or Windows CMD:
cd mt-copier
bash tools/deploy.sh
bash tools/compile.sh
```
*Compiles all 16 target binaries across MT4 and MT5 installations with 0 errors and 0 warnings.*

### Step 2: Start the Central Hub

**Option A — Interactive Console Mode**:
Double-click `start_primary_hub.bat` in the root folder, or launch via command line:
```bash
./hub/target/release/copier-hub.exe --port 6000 --http 0.0.0.0:6010 --role primary
```

**Option B — Native Windows Service Mode**:
Right-click `install_services.bat` and select **Run as Administrator** to install the Hub as a background auto-start Windows Service.

### Step 3: Attach EAs to Your Terminals
1. Open your MetaTrader terminal, ensure **Allow DLL imports** and **AutoTrading** are checked in terminal settings.
2. **On the Sender terminal**: Attach `CopierSender` to any single chart (e.g., EURUSD H1).
   - Set `HubEndpoint` = `tcp://127.0.0.1:6000`
3. **On the Receiver terminal**: Attach `CopierReceiver` to any single chart.
   - Set `HubEndpoint` = `tcp://127.0.0.1:6000`
   - Specify the Sender ID under `[sender0]` in `copier.ini` or configure via Web UI.

### Step 4: Access the Central Web Cockpit
Open your web browser and navigate to:
```text
http://127.0.0.1:6010
```
- Default user: `admin`
- Enter the admin password stored in `.admin_bootstrap_password` printed on first run (or set via `MTC_ADMIN_PASSWORD`).
- Switch themes, inspect node heartbeats, customize lot multipliers, view live floating PnL & Swap, or trigger fleet-wide emergency operations.

---

## 🛡️ Quality Assurance & Test Verification

Every release is validated against an exhaustive multi-layered regression test suite:

| Test Suite | Scope | Passing Threshold |
| :--- | :--- | :--- |
| **MQL Matrix Build** | 4 Terminals (MT4 & MT5, 32-bit & 64-bit), 16 target binaries | **16 / 16 ALL GREEN (0 errors, 0 warnings)** |
| **Rust Hub Unit Tests** | Protocol codec, HA election, journal recovery, SSRF, TLS | **161 / 161 Passed (0 failed)** |
| **Python Contract Suites** | 22 comprehensive test suites (E2E protocol, chaos, failover) | **445+ Assertions ALL GREEN** |
| **Static Linter & i18n** | `dash_check.py` (252 DOM IDs, 138 JS functions), `i18n_check.py` | **100% ID Match & 435 Keys per Locale Validated** |

To execute the full verification suite locally:
```bash
bash tools/tests.sh
bash hub/build.sh --test
python tools/dash_check.py
python tools/i18n_check.py
```

---

## 📖 Documentation Index

- [doc/PROTOCOL.md](doc/PROTOCOL.md) — Comprehensive wire protocol, envelope format, and framing specifications.
- [doc/HANDOFF.md](doc/HANDOFF.md) — Complete engineering history, operational runbook, and architectural decisions (ADR).
- [locales/README.md](locales/README.md) — Guide for creating and customizing language translation packs.

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
