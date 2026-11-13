# Changelog

## v1.1.0 — 2026-11-13

32 commits since v1.0.0. Mostly audit fixes (rounds r1–r22) plus one behaviour change in HA.

### Behaviour change

- **HA: a Standby no longer promotes itself by default (ADR-03).** Before this release a Standby that lost contact with its Primary for 30 s promoted itself. With two hubs and no witness, a link cut between them looks the same as a dead Primary, so that could leave two writable Primaries. Now the Standby stays read-only, logs a warning and records `cluster.peer_lost_manual_promote_required` in the audit log about once a minute, and waits for an operator to click **Promote** (or `POST /api/v1/cluster/promote`). Start the Standby with `--auto-promote` to get the old behaviour. Trade data still flows through the Standby without any action, because terminals connect to both hubs.
- **HA handover:** a handover request is accepted only when the requesting hub was also *probed* as the configured primary. The request body's claim alone is no longer enough.

### Fixes in the final v1.1.0 audit

- Receiver: an operator `CMD close` on a manual/orphan position is no longer dropped when the market is closed, AutoTrading is off, or MT4 reports "trade context busy" (err 146). It is retried until the market reopens.
- Receiver: an open refused for insufficient margin is now parked under its own key, so it no longer re-queues and logs a warning on every pass.
- Receiver (MT4): the daily-loss baseline uses one formula everywhere. Before, open-trade commissions caused a small phantom withdrawal once a day that scaled the baseline and peak down.
- Hub: the "peer lost, manual Promote required" warning now fires once a minute starting at 30 s. Before, it fired several times per minute and only from 60 s.
- Packages: the README text uses the real EA input names (`HubEndpoint`, `SenderIP`/`SenderPort`, `SenderLotMode`/`SenderLotParam`) and describes HA promotion correctly.

### Fixes (summary)

- Receiver execution and accounting: partial fills, MT5 netting, pending-order expiry and activation, freeze/stop-level handling, requote and transient-error backoff, trim coalescing, manual-close detection, duplicate-open guards.
- Sizing and risk: cross-currency rate bridges, equity-ratio sizing, margin accounting, withdrawal-aware drawdown peak, cold-start risk baseline, micro-lot precision.
- Transport: ZeroMQ frame draining and torn multipart recovery, handle and refcount leaks, subscription bounds, batched STAT receipts.
- Hub: journal compaction and replication integrity, dual-standby election, epoch fencing, SSRF and TLS hardening, login throttling, audit rotation, WebSocket limits, dashboard fixes.

### Internal (no behaviour change)

- `CopierReceiver.mq4` split into `src/Include/Copier/Recv*.mqh`; hub `run_hub` control frames moved into `handlers.rs`; `api.rs` split into `api/{auth,commands,cluster,tls}.rs`.
- New `doc/ARCHITECTURE.md`. Old audit reports moved to `doc/archive/audits/`.
- Packages no longer pick up unrelated scripts from the build terminal's `Scripts` folder.

### Tests

Rust 201/201, MQL self-test 990 assertions, MQL compile 0 errors on all 5 terminals, 19 Python integration suites green.

## v1.0.0 — 2026-11-09

First public release: Direct P2P edition and Hub suite (Rust hub, web dashboard, HA pair, CURVE, TLS, Windows service, alerts).
