//! M8/M10: the read-only half - HTTP + WebSocket, and the dashboard it serves.
//!
//! WHY IT IS SHAPED LIKE THIS
//! ==========================
//! The plan's §14 sketches the obvious async design: one tokio runtime, the
//! ZMQ socket inside it, and an inproc PAIR socket as a wake channel between
//! the two. That is the textbook answer and it was not used here, for three
//! reasons that are all about what this hub already is rather than about
//! elegance:
//!
//! 1. **The ZMQ loop works and is tested.** It is a single blocking thread with
//!    a poll timeout, 42 unit tests behind it, and a forwarding path that has
//!    been proven byte-for-byte against real EAs. Rewriting it as tokio tasks
//!    would put all of that back in play to gain nothing observable.
//!
//! 2. **ZMQ sockets are not Sync.** The textbook bridge exists precisely to
//!    keep the socket on one thread and pass *messages* out. But this API does
//!    not need messages - it needs *state*, and the state is already plain
//!    data (`Registry`, `Positions`). So the bridge can be a mutex.
//!
//! 3. **Nothing here is on the trading path.** A slow dashboard can cost a
//!    lock held for a few hundred nanoseconds. It cannot reorder a frame, and
//!    it cannot fail a forward: the forward has already happened by the time
//!    anything in this module runs. See `main.rs` for that ordering.
//!
//! So: the existing thread keeps its socket and now also publishes state under
//! `Arc<Mutex<Shared>>`; a second thread runs a tokio runtime that only ever
//! READS. `broadcast` wakes the WebSocket clients when state changes. The
//! consequence worth knowing is that a WebSocket client sees a *full snapshot*
//! per change rather than a diff - see `ws_handler` for when that stops being
//! fine.
//!
//! WHAT THIS MUST NOT BECOME
//! ========================
//! Every handler here reads. There is no POST, PUT or DELETE, and adding one
//! needs the plan's M4/M5 (config push, commands) with their `202` +
//! `command_id` semantics and their audit trail. Until then a write endpoint
//! could only act *locally*, which would be worse than having none: the hub
//! would appear able to change a node while being unable to.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::response::{Html, IntoResponse};
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};

use crate::audit::Audit;
use crate::lockx::{LockExt, RwLockExt};
use crate::commands::CommandStore;
use crate::alerts::AlertEngine;
use crate::notifications::{NotificationChannel, NotificationStore};
use crate::users::{
    hash_password, verify_password, Role as UserRole, Session, User, UserStore, SESSION_IDLE_SECS,
};
use crate::config::ConfigStore;
use crate::positions::{Positions, SenderView};
use crate::registry::{Liveness, Node, Registry, Role};

mod auth;
mod cluster;
mod commands;
mod tls;
use auth::*;
use cluster::*;
use commands::*;
use tls::*;

/// The dashboard, compiled in. `include_str!` rather than a served file for the
/// reason the plan's §18 wants: one binary is one deployment, there is no
/// asset directory to get wrong, and the page is same-origin with the API so
/// there is no CORS rule to maintain.
const DASHBOARD: &str = include_str!("assets/dashboard.html");

/// How often a WebSocket client is pushed a fresh snapshot even if nothing
/// changed. Not for the data - for the connection. A client that has heard
/// nothing for a minute cannot distinguish a quiet market from a dead socket,
/// and it will reconnect, and the reconnects are what make a log noisy.
const WS_HEARTBEAT_SECS: u64 = 15;

/// Everything the API is allowed to see.
///
/// Deliberately does NOT contain `Stats`: those counters belong to the stats
/// line the ZMQ thread prints, they are windowed rather than current, and
/// exposing them would invite treating a 30-second figure as instantaneous.
/// The numbers an operator wants here are `reg` and `pos`.
/// One node's last known live configuration.
#[derive(Clone, Debug, Default)]
pub struct CurrentSetting {
    /// The unescaped ini the node itself reported.
    pub ini: String,
    /// When it was recorded, unix seconds.
    pub ts: u64,
    /// `CopierCfgHash` of exactly that text - the reference for the node's `IH=`.
    pub hash: String,
}

pub struct Shared {
    pub reg: Registry,
    pub pos: Positions,
    /// sender NID -> receiver NID -> when that edge was last confirmed.
    ///
    /// The hub learns this as a by-product of relaying a receipt: a receiver's
    /// `STAT` carries the `SID` of the sender it is mirroring, and the hub has
    /// to read that field to know where to send the receipt. So the edge is
    /// information the hub already had and threw away. Recording it is what
    /// makes `/topology` a topology rather than two lists.
    pub mirrors: std::collections::HashMap<String, std::collections::HashMap<String, Instant>>,
    pub started: Instant,
    /// ZMQ port, for `/healthz` so a probe can say which hub it reached.
    pub zmq_port: u16,
    /// M7. Held here as well as by the ZMQ thread: the writer owns the file
    /// handle behind its own mutex, and the API only READS - an append-only
    /// file gives a reader a consistent prefix without any coordination, which
    /// is why this does not need to share the writer's lock.
    pub audit: Arc<Audit>,
    /// M4a. The same arrangement, and here the API WRITES as well - a PUT
    /// appends a revision. The store's own mutex serialises that against the
    /// ZMQ thread's retry loop, so the two cannot interleave a revision.
    pub cfg: Arc<ConfigStore>,
    /// M5. The command engine - the issue/retry/ack book shared by config pushes
    /// (M4) and operational commands (M5). The API reads it (to list commands
    /// and their state) and writes it (to issue a command on POST). The store's
    /// own mutex serialises that against the ZMQ thread's retry loop.
    pub cmds: Arc<CommandStore>,
    /// Whether the hub may change a node's config at all. `--writes on` by
    /// default since 2026-10-14. `--writes off` refuses PUT/POST with 403 and
    /// never emits a CFG or CMD message.
    pub writes: bool,
    /// The last `REV` each node reported in its REG. Runtime state, not
    /// persisted: it is only used to decide whether to push, and a hub restart
    /// gets a fresh answer from the next REG.
    pub node_rev: std::collections::HashMap<String, u64>,
    /// The current effective configuration ini reported directly by the receiver node.
    /// What each node last reported as its live config, plus WHEN, plus a
    /// content hash of that same text.
    ///
    /// The hash is the reference the node's 32-byte `IH=` is compared against:
    /// equal means "still what we last saw" and nothing is transferred. It is
    /// computed over the SAME text the node hashed, so a mismatch can only come
    /// from the node's settings actually differing - never from formatting,
    /// which is what hashing the *pushed* config instead would have made it.
    pub node_current_ini: std::collections::HashMap<String, CurrentSetting>,
    /// M6. The alert engine: the recent ring the API and the dashboard read,
    /// and the dedup/re-arm state the rules consult. The audit log holds the
    /// durable record; this holds the cheap one.
    pub alerts: AlertEngine,
    /// M9/§19.1. The hub's CURVE public key (empty string when `--curve off`)
    /// and whether learn mode is on. The dashboard shows both: the key is the
    /// one value every node's `HubPublicKey` input needs, and it is PUBLIC by
    /// definition - showing it here is no different from printing it in the
    /// log at every start.
    pub curve_public: String,
    pub curve_learn: bool,
    /// M9. Users, roles and sessions. The users persist to users.json; the
    /// sessions are in-memory by design (a hub restart logs everyone out,
    /// which is the honest trade for keeping tokens out of disk).
    pub users: UserStore,
    /// M9. False only under `--users none`: the middleware then answers as
    /// an anonymous viewer instead of demanding a session. Write endpoints
    /// still run the role gate, so this is read-only by construction.
    pub auth_enabled: bool,
    /// External notification channels (Telegram, WeCom, DingTalk, Webhook).
    pub notif_store: Arc<Mutex<NotificationStore>>,
    pub notif_tx: Option<tokio::sync::mpsc::Sender<crate::alerts::Alert>>,
    pub cluster: crate::cluster::ClusterManager,
    pub writes_allowed: bool,
    pub tls: Arc<crate::tls::TlsManager>,
    pub http_port: u16,
    /// B4: the interface the dashboard was actually bound to. The dedicated
    /// HTTPS listener reuses it instead of hard-coding 0.0.0.0, so enabling TLS
    /// from the UI cannot silently widen a 127.0.0.1-only deployment to the whole
    /// network.
    pub http_host: String,
    pub tx: Option<tokio::sync::broadcast::Sender<Arc<String>>>,
}

pub type SharedState = Arc<Mutex<Shared>>;

impl Shared {
    pub fn new(
        zmq_port: u16,
        audit: Arc<Audit>,
        cfg: Arc<ConfigStore>,
        cmds: Arc<CommandStore>,
        writes: bool,
        notif_path: Option<&std::path::Path>,
        cluster: crate::cluster::ClusterManager,
    ) -> Self {
        let is_primary = cluster.is_primary();
        let effective_writes = if !is_primary { false } else { writes };
        Shared {
            reg: Registry::new(),
            pos: Positions::new(),
            mirrors: std::collections::HashMap::new(),
            started: Instant::now(),
            zmq_port,
            audit,
            cfg,
            cmds,
            writes: effective_writes,
            node_rev: std::collections::HashMap::new(),
            node_current_ini: std::collections::HashMap::new(),
            alerts: AlertEngine::new(),
            curve_public: String::new(),
            curve_learn: false,
            users: UserStore::new(),
            auth_enabled: true,
            notif_store: Arc::new(Mutex::new(NotificationStore::new(notif_path))),
            notif_tx: None,
            cluster,
            writes_allowed: writes,
            tls: Arc::new(crate::tls::TlsManager::new(
                std::path::Path::new("."),
                std::path::Path::new(crate::tls::DEFAULT_TLS_CONFIG_PATH),
            )),
            http_port: 0,
            http_host: "127.0.0.1".to_string(),
            tx: None,
        }
    }

    /// A snapshot of the position table, taken without holding the lock
    /// afterwards.
    ///
    /// This exists because of one specific mistake it prevents: printing the
    /// stats line *while holding the mutex*. stdout to a pipe can block - a
    /// reader that stops reading, a full pipe buffer - and a blocked stdout is
    /// a held lock, which is a stalled API, which looks like a hung hub. The
    /// copy is a few kilobytes; the failure it avoids is not.
    ///
    /// `Clone` on `Positions` is derived for this and nothing else.
    pub fn clone_view(&self) -> Positions {
        self.pos.clone()
    }
}

/// One node as JSON. `liveness` and `quiet_secs` are derived, not stored: the
/// registry keeps timestamps and the definition of stale/offline stays in one
/// place (`Node::liveness`), so a page cannot show a node as online under a
/// rule the hub is not using.
fn node_json(n: &Node, now: Instant) -> Value {
    let live = n.liveness(now);
    let quiet = now.saturating_duration_since(n.last_seen).as_secs_f64();
    let waiting = if n.role == Role::Receiver {
        n.wait_total.map(|w| {
            json!({
                "total": w,
                "lots": (n.wait_lots * 1e8).round() / 1e8,
                "queued": n.wait_queued.unwrap_or(0),
                "delayed": n.wait_delayed.unwrap_or(0),
                "mkt_closed": n.wait_mkt.unwrap_or(0),
            })
        })
    } else {
        None
    };
    json!({
        "key": n.key,
        "role": n.role.as_str(),
        "acc": n.acc,
        "name": n.name,
        "ver": n.ver,
        "up_secs": n.up_secs,
        "liveness": match live {
            Liveness::Online => "online",
            Liveness::Stale => "stale",
            Liveness::Offline => "offline",
        },
        "quiet_secs": (quiet * 10.0).round() / 10.0,
        "regs": n.regs,
        "hbts": n.hbts,
        //--- M5b follow-through: whether the node reports itself hub-paused
        //--- (rides HBT2/REG as PAUSED=). False for a sender, which has no
        //--- hub pause - the flag exists so the dashboard can badge the row
        //--- without the operator reading the hub log.
        "paused": n.paused,
        "ping_ms": n.ping_ms,
        "equity": n.equity,
        "balance": n.balance,
        "waiting": waiting,
        "risk": if n.risk.is_empty() { Value::Null } else { Value::String(n.risk.clone()) },
        "blocked": n.blocked,
        "positions_detail": if n.role == Role::Receiver || n.role == Role::Sender {
            Value::Array(n.held_items.iter().map(|p| json!({
                "ticket": p.ticket,
                "ticket_str": p.ticket.to_string(),
                "symbol": p.symbol,
                "side": p.side,
                "lots": trim_lots(p.lots),
                "open_px": p.open_px,
                "sl": p.sl,
                "tp": p.tp,
                "magic": p.magic,
                "managed": p.managed,
                "comment": p.comment,
                "uid": if n.role == Role::Sender {
                    p.comment.clone()
                } else if n.role == Role::Receiver && p.comment.starts_with("tc|") {
                    let sub = &p.comment[3..];
                    if let Some(idx) = sub.find('|') {
                        sub[..idx].to_string()
                    } else if sub.len() >= 8 {
                        sub[..8].to_string()
                    } else {
                        sub.to_string()
                    }
                } else {
                    String::new()
                },
                "profit": p.profit,
                "swap": p.swap,
                "open_time": p.open_time,
            })).collect())
        } else {
            Value::Null
        },
        "waiting_detail": if n.role == Role::Receiver {
            Value::Array(n.wait_items.iter().map(|w| json!({
                "uid": w.uid,
                "symbol": w.symbol,
                "side": w.side,
                "lots": trim_lots(w.lots),
                "open_px": w.open_px,
                "stage": w.stage,
                "reason": w.reason,
            })).collect())
        } else {
            Value::Null
        },
    })
}

/// A RECEIVER's Pos column: the mirror count IT reports in its STAT
/// (`HELD=`/`LOTS=`). The hub never sees a receiver's account (§10 - it is a
/// transparent proxy), but the receiver counts its own mirrors and says so,
/// which is the honest version of the same number a sender's row shows from
/// its SNAP. `None` until the first STAT with figures - "not yet", not zero.
/// (The value itself is built inline in nodes_json_list; this comment is the
/// explanation of why a receiver has a Pos column at all.)

fn symbols_json(v: &SenderView) -> Value {
    Value::Array(
        v.symbols
            .iter()
            .map(|(s, c, l)| {
                json!({
                    "symbol": s,
                    "count": c,
                    "lots": trim_lots(*l),
                })
            })
            .collect(),
    )
}

/// BUG-10: Support up to 8 decimal places for crypto / micro-lots (CP_DIGITS_LOTS=8)
fn trim_lots(l: f64) -> String {
    let s = format!("{:.8}", (l * 1e8).round() / 1e8);
    let trimmed = s.trim_end_matches('0').trim_end_matches('.');
    if trimmed.is_empty() {
        "0".to_string()
    } else {
        trimmed.to_string()
    }
}

/// EVERY node as JSON, ordered by account.
///
/// ONE function, deliberately. The bug this replaces: `nodes()` sorted by
/// `key`, the WebSocket push used `Registry::nodes()` which sorts by
/// `last_seen`, and the dashboard prefers the WebSocket - so the table looked
/// correct for the first fetch and then reshuffled on every push, because a
/// heartbeat moves `last_seen`. Two orders for one table is not a cosmetic
/// problem, it is a readability one: a row that jumps when nothing about it
/// changed is a row nobody can track.
///
/// Both callers now come through here, so they cannot drift apart again.
fn nodes_json_list_from_nodes(nodes: &[Node], pos: &Positions, now: Instant) -> Vec<Value> {
    nodes
        .iter()
        .map(|n| {
            let mut j = node_json(n, now);
            //--- The NODES table's POS column, for BOTH roles:
            //--- DEF-63-04: Omit full items list inside nodes to eliminate redundant
            //--- double-serialization; items are already published in top-level positions array.
            let pv = if n.role == Role::Sender {
                pos.view_for(&n.acc)
                    .map(|v| {
                        json!({
                            "count": v.count,
                            "lots": trim_lots(v.lots),
                            "receipt": v.receipt,
                            "orphaned": Value::Null,
                        })
                    })
            } else {
                n.held.map(|count| {
                    json!({
                        "count": count,
                        "lots": (n.held_lots * 1e8).round() / 1e8,
                        "receipt": Value::Null,
                        "orphaned": n.orphaned,
                    })
                })
            };
            j.as_object_mut()
                .unwrap()
                .insert("positions".to_string(), pv.unwrap_or(Value::Null));
            j
        })
        .collect()
}

#[allow(dead_code)]
fn nodes_json_list(reg: &Registry, pos: &Positions, now: Instant) -> Vec<Value> {
    let nodes: Vec<Node> = reg.sorted().into_iter().cloned().collect();
    nodes_json_list_from_nodes(&nodes, pos, now)
}

/// EVERY sender's position view as JSON, ordered by account.
///
/// Same argument as `nodes_json_list`, and the same failure: the log line
/// orders by size (biggest first, capped at eight, which is right for a stats
/// window), and the API used to reuse that - so two senders swapped rows when
/// either opened a position.
fn positions_json_list(pos: &Positions) -> Vec<Value> {
    pos.sorted()
        .iter()
        .map(|(sid, v)| {
            json!({
                "sid": sid,
                "count": v.count,
                "lots": trim_lots(v.lots),
                "receipt": v.receipt,
                "snaps": v.snaps,
                "symbols": symbols_json(v),
                "items": v.items.iter().map(|p| json!({
                    "ticket": p.ticket,
                    "uid": p.uid,
                    "symbol": p.symbol,
                    "side": p.side,
                    "lots": trim_lots(p.lots),
                    "open_px": p.open_px,
                    "sl": p.sl,
                    "tp": p.tp,
                    "magic": p.magic,
                    "open_time": p.open_time,
                    "kind": p.kind,
                    "ptype": p.ptype,
                    "pprice": p.pprice,
                    "pstop": p.pstop,
                    "pexpire": p.pexpire,
                })).collect::<Vec<_>>(),
            })
        })
        .collect()
}

/// `GET /api/v1/nodes`
async fn nodes(State(st): State<SharedState>) -> Json<Value> {
    let now = Instant::now();
    // N73-02: Extract state and clone nodes (O(1) with Arc items) under lock;
    // construct all JSON ASTs completely outside the shared lock.
    let (reg_nodes, pos_clone, counts, uptime) = {
        let s = st.lock_or_recover();
        let counts = json!({
            "online": s.reg.count(Liveness::Online, now),
            "stale": s.reg.count(Liveness::Stale, now),
            "offline": s.reg.count(Liveness::Offline, now),
            "total": s.reg.len(),
            "evicted": s.reg.evicted,
        });
        let reg_nodes = s.reg.sorted().into_iter().cloned().collect::<Vec<_>>();
        let pos_clone = s.clone_view();
        let uptime = now.saturating_duration_since(s.started);
        (reg_nodes, pos_clone, counts, uptime)
    };
    let v: Vec<Value> = nodes_json_list_from_nodes(&reg_nodes, &pos_clone, now);
    Json(json!({
        "nodes": Value::Array(v),
        "counts": counts,
        "hub_uptime_secs": uptime.as_secs(),
    }))
}

/// `GET /api/v1/nodes/{id}`
///
/// The id is the registry key `ROLE:ACC`, URL-encoded. A sender also gets its
/// M3 position view; a receiver gets the senders it mirrors, which is the edge
/// the hub learned while relaying receipts.
async fn node_detail(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    let out = {
        let s = st.lock_or_recover();
        let now = Instant::now();
        let found = s.reg.nodes().into_iter().find(|n| n.key == id);
        match found {
            None => json!({ "error": "no such node", "key": id }),
            Some(n) => {
                let mut body = node_json(n, now);
                let obj = body.as_object_mut().unwrap();

                if n.role == Role::Sender {
                    // Positions, if the hub has ever seen a SNAP from it. A
                    // sender that has registered but never sent a snapshot is
                    // not an error - it is a node with nothing to report yet,
                    // and `null` says exactly that.
                    if let Some(v) = s.pos.view_for(&n.acc) {
                        obj.insert(
                            "positions".to_string(),
                            json!({
                                "count": v.count,
                                "lots": trim_lots(v.lots),
                                "receipt": v.receipt,
                                "symbols": symbols_json(v),
                                "snaps": v.snaps,
                                "items": v.items.iter().map(|p| json!({
                                    "ticket": p.ticket,
                                    "uid": p.uid,
                                    "symbol": p.symbol,
                                    "side": p.side,
                                    "lots": trim_lots(p.lots),
                                    "open_px": p.open_px,
                                    "sl": p.sl,
                                    "tp": p.tp,
                                    "magic": p.magic,
                                    "open_time": p.open_time,
                                    "kind": p.kind,
                                    "ptype": p.ptype,
                                    "pprice": p.pprice,
                                    "pstop": p.pstop,
                                    "pexpire": p.pexpire,
                                })).collect::<Vec<_>>(),
                            }),
                        );
                    } else {
                        obj.insert("positions".to_string(), Value::Null);
                    }
                }

                if n.role == Role::Receiver {
                    let mut targets: Vec<String> = s
                        .mirrors
                        .iter()
                        .filter(|(_, recvs)| {
                            recvs.contains_key(&n.acc)
                                || (n.acc.len() > 9 && recvs.contains_key(&crate::copier_nid(&n.acc)))
                        })
                        .map(|(sender, _)| sender.clone())
                        .collect();
                    targets.sort();
                    let targets: Vec<Value> = targets.into_iter().map(Value::String).collect();
                    obj.insert("mirrors".to_string(), Value::Array(targets));
                }

                if n.role == Role::Sender {
                    let recvs_opt = s.mirrors.get(&n.acc).or_else(|| {
                        if n.acc.len() > 9 {
                            s.mirrors.get(&crate::copier_nid(&n.acc))
                        } else {
                            None
                        }
                    });
                    if let Some(recvs) = recvs_opt {
                        let mut targets: Vec<String> = recvs.keys().cloned().collect();
                        targets.sort();
                        let targets: Vec<Value> = targets.into_iter().map(Value::String).collect();
                        obj.insert("mirrors".to_string(), Value::Array(targets));
                    }
                }

                body
            }
        }
    };
    Json(out)
}

/// `GET /api/v1/topology`
///
/// Two lists and the edges between them. The edges exist only because the
/// receipt relay has to read the target sender out of a receiver's STAT, so a
/// hub running an old build - one that relays nothing - reports senders and
/// receivers and no edges. That is honest: it really does not know.
async fn topology(State(st): State<SharedState>) -> Json<Value> {
    let now = Instant::now();
    // N76-06: Extract state and clone nodes (O(1) with Arc items) under lock;
    // construct all JSON ASTs completely outside the shared lock.
    let (reg_nodes, pos_clone, edges, alerts_json, curve_val, cluster_val, counts) = {
        let s = st.lock_or_recover();

        let mut edges: Vec<Value> = Vec::new();
        let nid_to_acc: std::collections::HashMap<String, String> = s
            .reg
            .nodes()
            .iter()
            .filter(|n| n.acc.len() > 9)
            .map(|n| (crate::copier_nid(&n.acc), n.acc.clone()))
            .collect();
        for (sender, recvs) in s.mirrors.iter() {
            let from_acc = nid_to_acc.get(sender).unwrap_or(sender);
            let mut rs: Vec<&String> = recvs.keys().collect();
            rs.sort();
            for r in rs {
                let to_acc = nid_to_acc.get(r).unwrap_or(r);
                edges.push(json!({ "from": from_acc, "to": to_acc }));
            }
        }

        let alerts_json = s.alerts.recent_json(20);
        let curve_val = curve_json(&s);
        let cluster_val = cluster_json(&s);
        let counts = json!({
            "senders": s.reg.count_by_role(Role::Sender),
            "receivers": s.reg.count_by_role(Role::Receiver),
            "hub_uptime_secs": now.saturating_duration_since(s.started).as_secs(),
        });
        let reg_nodes = s.reg.sorted().into_iter().cloned().collect::<Vec<_>>();
        let pos_clone = s.clone_view();
        (reg_nodes, pos_clone, edges, alerts_json, curve_val, cluster_val, counts)
    };

    let all = nodes_json_list_from_nodes(&reg_nodes, &pos_clone, now);
    let mut senders: Vec<Value> = Vec::new();
    let mut receivers: Vec<Value> = Vec::new();
    for j in all {
        match j["role"].as_str() {
            Some("sender") => senders.push(j),
            Some("receiver") => receivers.push(j),
            _ => {}
        }
    }

    Json(json!({
        "senders": Value::Array(senders),
        "receivers": Value::Array(receivers),
        "edges": Value::Array(edges),
        "alerts": Value::Array(alerts_json),
        "curve": curve_val,
        "cluster": cluster_val,
        "counts": counts,
    }))
}

/// `GET /api/v1/positions` - the M3 view, as data rather than as a log line.
///
/// Same numbers `print_positions` puts on stdout, including the mismatch
/// warning. If the text and this ever disagree, the text is derived from the
/// same structs and this is not, so one of them has been changed - and the
/// honest fix is to make both read the same place.
async fn positions(State(st): State<SharedState>) -> Json<Value> {
    // N74-06: Extract positions snapshot under lock; construct JSON AST completely outside the shared mutex.
    let (pos, parsed, mismatched, total_positions, total_lots) = {
        let s = st.lock_or_recover();
        (
            s.clone_view(),
            s.pos.parsed,
            s.pos.mismatched,
            s.pos.total_positions(),
            trim_lots(s.pos.total_lots()),
        )
    };
    let rows: Vec<Value> = positions_json_list(&pos);
    Json(json!({
        "senders": Value::Array(rows),
        "parsed": parsed,
        "mismatched": mismatched,
        "total_positions": total_positions,
        "total_lots": total_lots,
    }))
}

/// `GET /api/v1/audit?limit=N&since=SEQ`
///
/// BOUNDED, and that is the only interesting thing about it. The log is
/// permanent by design (§15), so "return everything" is a request that gets
/// slower forever and eventually does not return. `limit` defaults to 200 and
/// is capped; `since` lets a caller follow the tail without re-reading.
///
/// Newest LAST, which is the order the file is in - a caller that wants the
/// latest N gets them, and a caller reading forward from a `seq` it remembers
/// gets the continuation.
async fn audit_log(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    axum::extract::Query(q): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // M9: admin only (the plan's §17.2 matrix). A denial is audited too -
    // and it is a 403 in the response, not an error body on a 200: a handler
    // that narrows its return type to Json would answer 200-with-error, which
    // is the exact status a client cannot act on.
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let limit = q
        .get("limit")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(200)
        .min(2000);
    let since = q.get("since").and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);

    //--- Hold the global lock for an Arc clone and NOTHING ELSE.
    //---
    //--- The audit used to be read while the shared-state mutex was held:
    //--- read() opens the file, reads it to EOF, parses every line, and may
    //--- gunzip archives - so the whole hub froze for the duration, and a
    //--- ?limit=2000 against a 10 MB log plus archives held it for seconds.
    //--- On the other side of that lock is the ZMQ router thread, which
    //--- forwards every position update from every sender. A dashboard tab
    //--- left open on the audit page was a periodic stall of the live link.
    //---
    //--- The read itself needs no global lock at all: `Audit::read` takes
    //--- `&self`, does not touch the writer's inner mutex, and reads an
    //--- append-only file where a lock-free reader sees a consistent prefix
    //--- by construction (the writer appends, the reader parses; a torn last
    //--- line is counted, not fatal). So: clone the Arc under the global
    //--- lock, drop it, do the I/O. The accessors below take the AUDIT's
    //--- own mutex briefly - a different, uncontended one.
    let (audit, since) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.audit), since)
    };
    let (records, stats) = audit.read(limit, since);
    let (enabled, path, rotations, max_bytes, max_backups) = {
        (
            audit.enabled(),
            audit.path().display().to_string(),
            audit.rotations(),
            audit.max_bytes(),
            audit.max_backups(),
        )
    };
    let last_seq = records
        .last()
        .and_then(|r| r["seq"].as_u64())
        .unwrap_or(since);

    Json(json!({
        "enabled": enabled,
        "path": path,
        "records": Value::Array(records),
        "last_seq": last_seq,
        "rotations": rotations,
        "max_bytes": max_bytes,
        "max_backups": max_backups,
        //--- Reported rather than hidden. A torn line is a crash mid-append,
        //--- and a bad line in the MIDDLE should be impossible in an
        //--- append-only file - so it is a different number, and a nonzero one
        //--- is a fact about the log rather than a parse detail.
        "lines": stats.lines,
        "torn": stats.torn,
        "skipped": stats.skipped,
        "limit": limit,
        "since": since,
    }))
    .into_response()
}

/// `GET /healthz` - is this process alive. Answers while the ZMQ feed is
/// silent, which is the whole point of having it: a liveness check that goes
/// quiet when the market is quiet is worse than none.
async fn healthz(State(st): State<SharedState>) -> Json<Value> {
    let (uptime, zmq) = {
        let s = st.lock_or_recover();
        (Instant::now() - s.started, s.zmq_port)
    };
    Json(json!({
        "status": "ok",
        "hub_uptime_secs": uptime.as_secs(),
        "zmq_port": zmq,
    }))
}

/// `GET /readyz` - can it serve real answers yet. Distinct from healthz, and
/// the distinction is not pedantry: a hub that is alive but has no nodes has
/// nothing to tell an operator, and a probe that reports "ready" there sends
/// people to a dashboard that is correctly empty for a reason nobody sees.
///
/// Ready means at least one node is known. Before that the honest answer is
/// "yes, and there is nobody here" - which is what `total` says.
async fn readyz(State(st): State<SharedState>) -> Json<Value> {
    let (total, online) = {
        let s = st.lock_or_recover();
        let now = Instant::now();
        (s.reg.len(), s.reg.count(Liveness::Online, now))
    };
    let ready = total > 0;
    Json(json!({
        "status": if ready { "ready" } else { "starting" },
        "nodes_total": total,
        "nodes_online": online,
    }))
}

/// The dashboard. One route, one const, no file serving, no MIME guessing.
/// Never let a browser keep an older embedded page: the admin reset outcome
/// and role-gated controls must correspond to the hub binary currently served.
async fn dashboard() -> axum::response::Response {
    let mut response = Html(DASHBOARD).into_response();
    let headers = response.headers_mut();
    headers.insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store, no-cache, must-revalidate"),
    );
    headers.insert(
        axum::http::header::X_FRAME_OPTIONS,
        axum::http::HeaderValue::from_static("DENY"),
    );
    headers.insert(
        axum::http::header::X_CONTENT_TYPE_OPTIONS,
        axum::http::HeaderValue::from_static("nosniff"),
    );
    response
}

/// `WS /api/v1/stream`
///
/// On connect: one full snapshot. Then a full snapshot every time anything
/// changes, plus one every `WS_HEARTBEAT_SECS` so a client can tell a quiet
/// market from a dead socket.
///
/// THE DEVIATION FROM THE PLAN, stated plainly: §18 says "连接时全量快照 +
/// 之后增量". This sends the whole snapshot each time, not a diff. At the scale
/// this runs at - a handful of senders, changes a few times a second, a
/// snapshot of tens of kilobytes - a diff would be more code and a second
/// serialization path to keep consistent with the REST one, for bandwidth that
/// does not matter on loopback or a LAN. The number that would change that
/// decision: a hundred senders changing several times a second to a hundred
/// dashboards. Then the right move is to send the *changed field* only, which
/// is also when the "one serialization" argument stops being true.
///
/// The socket is handled without splitting into read and write halves. That
/// would need `futures-util` for one `select!`, and `select!` is already here.
async fn ws_handler(
    ws: WebSocketUpgrade,
    headers: axum::http::HeaderMap,
    State(st): State<SharedState>,
    axum::extract::Extension(tx): axum::extract::Extension<tokio::sync::broadcast::Sender<std::sync::Arc<String>>>,
    axum::extract::Extension(tok): axum::extract::Extension<Token>,
) -> impl axum::response::IntoResponse {
    use axum::response::IntoResponse;
    static WS_SEMAPHORE: std::sync::OnceLock<std::sync::Arc<tokio::sync::Semaphore>> = std::sync::OnceLock::new();
    const MAX_WS_CONNS: usize = 128;

    // D9-H03: Validate Origin header against Host to prevent CSWSH
    if let Some(origin) = headers.get(axum::http::header::ORIGIN).and_then(|v| v.to_str().ok()) {
        if let Some(host) = headers.get(axum::http::header::HOST).and_then(|v| v.to_str().ok()) {
            let expected_http = format!("http://{}", host);
            let expected_https = format!("https://{}", host);
            if origin != expected_http && origin != expected_https {
                return (axum::http::StatusCode::FORBIDDEN, "Invalid WebSocket Origin").into_response();
            }
        }
    }
    let sem = WS_SEMAPHORE.get_or_init(|| std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_WS_CONNS)));
    let Ok(permit) = std::sync::Arc::clone(sem).try_acquire_owned() else {
        return (axum::http::StatusCode::TOO_MANY_REQUESTS, "Max WebSocket connections reached").into_response();
    };
    ws.on_upgrade(move |socket| async move {
        let _permit = permit;
        handle_socket(socket, st, tx, tok.0).await
    }).into_response()
}

async fn handle_socket(
    mut socket: WebSocket,
    st: SharedState,
    tx: tokio::sync::broadcast::Sender<std::sync::Arc<String>>,
    token: String,
) {
    // Everything the page needs on arrival, so it can render before it has
    // made a single HTTP call of its own.
    let snap = snapshot_text(&st);
    if socket.send(Message::Text(snap)).await.is_err() {
        return;
    }

    let mut rx = tx.subscribe();
    let mut beat = tokio::time::interval(std::time::Duration::from_secs(WS_HEARTBEAT_SECS));
    beat.tick().await; // the first tick fires immediately; consume it
    // M2: Check session validity every 5 seconds to promptly revoke compromised/modified sessions
    let mut auth_tick = tokio::time::interval(std::time::Duration::from_secs(5));
    auth_tick.tick().await;

    loop {
        tokio::select! {
            // Client said something. Nothing here is a command - this is the
            // read-only half - so a text frame is logged once and dropped
            // rather than parsed into an action that cannot exist yet.
            incoming = socket.recv() => {
                match incoming {
                    None | Some(Err(_)) => break,
                    Some(Ok(Message::Close(_))) => break,
                    Some(Ok(_)) => {}
                }
            }
            // State changed somewhere else. The payload is ALREADY the JSON
            // text: the background worker serialises once per change window and
            // shares it through Arc, so N dashboards cost one serialization
            // without blocking the main ZMQ routing loop.
            changed = rx.recv() => {
                match changed {
                    Ok(s) => {
                        if socket.send(Message::Text((*s).clone())).await.is_err() {
                            break;
                        }
                    }
                    // BUG-08: A slow client missed some broadcast frames. Because beat.tick
                    // now sends lightweight Ping frames rather than full snapshots, actively
                    // resend a fresh snapshot to the lagged client so UI doesn't show stale state.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        let snap = snapshot_text(&st);
                        if socket.send(Message::Text(snap)).await.is_err() {
                            break;
                        }
                        continue;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
            _ = auth_tick.tick() => {
                // M2 & OPT-03: Re-verify session validity read-only every 5s without sliding idle timeout
                if !token.is_empty() {
                    let valid = st.lock_or_recover().users.is_session_valid(&token, unix_secs());
                    if !valid {
                        let _ = socket.send(Message::Close(Some(axum::extract::ws::CloseFrame {
                            code: axum::extract::ws::close_code::NORMAL,
                            reason: "Session revoked or expired".into(),
                        }))).await;
                        break;
                    }
                }
            }
            _ = beat.tick() => {
                // N49-09: Send lightweight WebSocket Ping keepalive instead of heavy full snapshot re-serialization
                if socket.send(Message::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
        }
    }
}

/// The wire format for a push. A shape the page can switch on, so a later
/// incremental message is a new `t` rather than a change to this one.
pub(crate) fn snapshot_text(st: &SharedState) -> String {
    // M-05 & R48-10 & N49-04: Extract state and clone data under lock;
    // construct all JSON ASTs completely outside the shared lock.
    let now = Instant::now();
    let (uptime_secs, reg_nodes, pos_clone, mismatched, alerts_list, curve_val, cluster_val) = {
        let s = st.lock_or_recover();
        (
            now.saturating_duration_since(s.started).as_secs(),
            s.reg.sorted().into_iter().cloned().collect::<Vec<_>>(),
            s.clone_view(),
            s.pos.mismatched,
            s.alerts.recent_json(20),
            curve_json(&s),
            cluster_json(&s),
        )
    };
    let nodes_list = nodes_json_list_from_nodes(&reg_nodes, &pos_clone, now);
    let pos_list = positions_json_list(&pos_clone);
    let body = json!({
        "hub_uptime_secs": uptime_secs,
        "nodes": Value::Array(nodes_list),
        "positions": Value::Array(pos_list),
        "mismatched": mismatched,
        "alerts": Value::Array(alerts_list),
        "curve": curve_val,
        "cluster": cluster_val,
    });
    json!({ "t": "snapshot", "data": body }).to_string()
}

fn cluster_json(s: &Shared) -> Value {
    let now = Instant::now();
    json!({
        "cluster_id": s.cluster.state.cluster_id,
        "hub_id": s.cluster.state.hub_id,
        "role": s.cluster.state.role,
        "epoch": s.cluster.state.epoch,
        "writes": s.writes,
        "peer_url": s.cluster.peer_url,
        "peer_online": s.cluster.peer_online,
        "sync_status": s.cluster.sync_status,
        "is_configured_primary": s.cluster.state.is_configured_primary,
        "failback_locked": s.cluster.state.failback_locked,
        "failback_stabilization_hours": s.cluster.state.failback_stabilization_hours,
        "auto_promote": s.cluster.auto_promote,
        "continuous_online_secs": s.cluster.continuous_online_start.map(|t| now.saturating_duration_since(t).as_secs_f64()).unwrap_or(0.0),
    })
}

/// The CURVE state the dashboard shows: is the link encrypted, what is the
/// hub's public key (public, not secret), and is learn mode on.
fn curve_json(s: &Shared) -> Value {
    json!({
        "on": !s.curve_public.is_empty(),
        "public_key": s.curve_public,
        "learn": s.curve_learn,
    })
}

/// `GET /api/v1/curve/hub_key` - download the Hub's Curve public key file (`copier_hub.key`).
///
/// Returns 200 with `Content-Disposition: attachment; filename="copier_hub.key"` and
/// plain text contents formatted as:
/// copier-hub-key v1
/// # Hub CurveZMQ Public Key file
/// # Downloaded from Copier Hub Web Dashboard
/// # Place this file in MQL4\Files, MQL5\Files, or Terminal\Common\Files
/// PUBLIC=<40 chars>
///
/// Or 404 if CURVE is disabled on this hub.
async fn curve_hub_key_download(State(st): State<SharedState>) -> axum::response::Response {
    let s = st.lock_or_recover();
    if s.curve_public.is_empty() {
        return (
            axum::http::StatusCode::NOT_FOUND,
            Json(json!({
                "error": "CURVE is disabled on this hub (--curve off). No public key file available."
            })),
        )
            .into_response();
    }

    let file_content = format!(
        "copier-hub-key v1\r\n\
         # Hub CurveZMQ Public Key file\r\n\
         # Downloaded from Copier Hub Web Dashboard\r\n\
         # Place this file in MQL4\\Files, MQL5\\Files, or Terminal\\Common\\Files\r\n\
         PUBLIC={}\r\n",
        s.curve_public
    );

    let mut resp = axum::response::Response::new(file_content.into());
    resp.headers_mut().insert(
        axum::http::header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    resp.headers_mut().insert(
        axum::http::header::CONTENT_DISPOSITION,
        axum::http::HeaderValue::from_static("attachment; filename=\"copier_hub.key\""),
    );
    resp.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store, no-cache, must-revalidate"),
    );
    resp
}

//--- ------------------------------------------------------------------ auth (M9)
//
// Everything under /api/v1 requires a session except the three auth
// endpoints and the page itself. A 401 from anywhere is the dashboard's cue
// to raise the login overlay - the page is one file and the login is part of
// it, so there is no second origin and no redirect dance.


/// The router. Versioned under `/api/v1`, because the plan's §16 says a
/// breaking change goes to v2 rather than editing v1 under a deployed
/// dashboard.
pub fn router(st: SharedState, tx: tokio::sync::broadcast::Sender<std::sync::Arc<String>>) -> Router {
    Router::new()
        .route("/", get(dashboard))
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/api/v1/nodes", get(nodes))
        .route("/api/v1/nodes/:id", get(node_detail))
        .route("/api/v1/topology", get(topology))
        .route("/api/v1/positions", get(positions))
        .route("/api/v1/audit", get(audit_log))
        .route(
            "/api/v1/nodes/:id/config",
            get(node_config).put(put_node_config),
        )
        .route(
            "/api/v1/nodes/:id/config/rollback/:rev",
            axum::routing::post(rollback_node_config),
        )
        //--- One revision's BODY. The history list deliberately omits it (a
        //--- list is not a document), so the dashboard fetches the body it
        //--- actually wants to load instead of receiving every body at once.
        .route(
            "/api/v1/nodes/:id/config/revision/:rev",
            get(node_config_revision),
        )
        .route("/api/v1/config", get(config_list))
        .route("/api/v1/commands", get(commands_list).post(commands_global))
        .route("/api/v1/alerts", get(alerts_list))
        .route("/api/v1/commands/:id", get(command_one))
        .route(
            "/api/v1/nodes/:id/commands",
            axum::routing::post(post_command),
        )
        .route("/api/v1/curve/hub_key", get(curve_hub_key_download))
        .route("/api/v1/curve/public_key.file", get(curve_hub_key_download))
        .route("/api/v1/stream", get(ws_handler))
        .route("/api/v1/auth/nonce", axum::routing::post(auth_nonce))
        .route("/api/v1/login", axum::routing::post(login))
        .route("/api/v1/logout", axum::routing::post(logout))
        .route("/api/v1/whoami", get(whoami))
        .route("/api/v1/users", get(users_list).post(users_upsert))
        .route("/api/v1/password", axum::routing::post(change_password))
        .route("/api/v1/users/:id", axum::routing::delete(users_delete))
        .route(
            "/api/v1/notifications",
            get(notifications_list).post(notifications_upsert),
        )
        .route(
            "/api/v1/notifications/test",
            axum::routing::post(notifications_test),
        )
        .route(
            "/api/v1/notifications/:id",
            axum::routing::delete(notifications_delete),
        )
        .route("/.well-known/acme-challenge/:token", get(acme_challenge_handler))
        .route("/api/v1/cluster/status", get(cluster_status))
        .route("/api/v1/cluster/sync", axum::routing::post(cluster_sync))
        .route(
            "/api/v1/cluster/handover-request",
            axum::routing::post(cluster_handover_request),
        )
        .route("/api/v1/cluster/promote", axum::routing::post(cluster_promote))
        .route(
            "/api/v1/cluster/failback-lock",
            axum::routing::post(cluster_failback_lock),
        )
        .route(
            "/api/v1/cluster/failback-now",
            axum::routing::post(cluster_failback_now),
        )
        .route(
            "/api/v1/cluster/peer",
            axum::routing::get(cluster_get_peer).post(cluster_set_peer),
        )
        .route("/api/v1/tls/status", get(tls_status))
        .route("/api/v1/tls/configure", axum::routing::post(tls_configure))
        .route("/api/v1/tls/import", axum::routing::post(tls_import))
        .route("/api/v1/tls/self-signed", axum::routing::post(tls_self_signed))
        .route("/api/v1/tls/disable", axum::routing::post(tls_disable))
        .route("/api/v1/tls/renew", axum::routing::post(tls_renew))
        .route("/api/v1/locales", get(locales_list))
        .route("/api/v1/locales/:code", get(locale_get))
        .layer(axum::extract::DefaultBodyLimit::max(256 * 1024))
        .layer(axum::extract::Extension(tx))
        .layer(axum::middleware::from_fn_with_state(st.clone(), require_session))
        .with_state(st)
}

/// Start the API on its own thread with its own runtime.
///
/// `spawn` rather than `await` because `main` has a ZMQ loop to run and the
/// API must not delay it by a single syscall. Two threads, two runtimes of
/// one kind, one process - and Ctrl-C still lands on the ZMQ thread's flag,
/// which exits the process and takes this one with it.
///
static DASHBOARD_POKE_NOTIFY: tokio::sync::Notify = tokio::sync::Notify::const_new();
static DASHBOARD_POKE_FLAG: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub const POKE_MIN_MS: u64 = 200;

/// H-02: Non-blocking dashboard poke notification.
/// Does not lock shared state or serialize JSON on caller thread.
pub fn poke() {
    DASHBOARD_POKE_FLAG.store(true, std::sync::atomic::Ordering::Relaxed);
    DASHBOARD_POKE_NOTIFY.notify_one();
}

/// The channel is created HERE and returned to the caller, because the ZMQ
/// thread is the thing that knows when state changed. Handing the sender out
/// is what makes "changed" mean "changed" rather than "somebody polled".
pub fn spawn(
    addr: String,
    st: SharedState,
) -> std::result::Result<tokio::sync::broadcast::Sender<std::sync::Arc<String>>, String> {
    // (the audit reaches this thread through `st`, which already holds it)
    let (tx, _rx) = tokio::sync::broadcast::channel::<std::sync::Arc<String>>(64);
    let tx_out = tx.clone();
    let tx_poke = tx.clone();
    let st_poke = st.clone();
    std::thread::Builder::new()
        .name("api".to_string())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
            {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[hub] cannot start the API runtime: {}", e);
                    return;
                }
            };
            rt.block_on(async move {
                // H-02: Asynchronous throttle worker for WebSocket dashboard pushes.
                // Serializes snapshot JSON outside the ZMQ routing thread, and shares
                // via Arc<String> across connected WebSocket clients.
                tokio::spawn(async move {
                    let mut throttle = tokio::time::interval(std::time::Duration::from_millis(POKE_MIN_MS));
                    throttle.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                    loop {
                        DASHBOARD_POKE_NOTIFY.notified().await;
                        throttle.tick().await;
                        let flagged = DASHBOARD_POKE_FLAG.swap(false, std::sync::atomic::Ordering::Relaxed);
                        if flagged && tx_poke.receiver_count() > 0 {
                            let snap = snapshot_text(&st_poke);
                            let _ = tx_poke.send(std::sync::Arc::new(snap));
                        }
                    }
                });

                let (alert_tx, mut alert_rx) = tokio::sync::mpsc::channel::<crate::alerts::Alert>(1024);
                let http_client = reqwest::Client::builder()
                    .no_proxy()
                    .redirect(reqwest::redirect::Policy::none())
                    .timeout(std::time::Duration::from_secs(crate::notifications::HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap_or_default();
                let notif_store_worker = {
                    let mut s = st.lock_or_recover();
                    s.notif_tx = Some(alert_tx);
                    s.notif_store.clone()
                };
                let http_worker = http_client.clone();
                let st_worker = st.clone();
                let notif_sem = std::sync::Arc::new(tokio::sync::Semaphore::new(16));
                tokio::spawn(async move {
                    while let Some(alert) = alert_rx.recv().await {
                        //--- Only the primary notifies.
                        //---
                        //--- A standby keeps its own alert_channels.json, and that
                        //--- file only tracks the primary's while the cluster link
                        //--- is up. On 2026-10-26 that gap pushed a CRITICAL
                        //--- "Node Offline" alert for a channel the operator had
                        //--- disabled SIX DAYS earlier: the link had been down the
                        //--- whole time (the token mismatch), so the standby still
                        //--- held enabled=true and sent it.
                        //---
                        //--- Two hubs must not both notify anyway - every alert
                        //--- would arrive twice. The standby stays silent and
                        //--- starts notifying only after it is promoted.
                        let is_primary = {
                            let s = st_worker.lock_or_recover();
                            s.cluster.is_primary()
                        };
                        if !is_primary {
                            continue;
                        }
                        let channels = {
                            let s = notif_store_worker.lock_or_recover();
                            if !s.enabled() {
                                continue;
                            }
                            s.matching_channels_for_alert(&alert)
                        };
                        for ch in channels {
                            let c = http_worker.clone();
                            let a = alert.clone();
                            let sem = std::sync::Arc::clone(&notif_sem);
                            tokio::spawn(async move {
                                let Ok(_permit) = sem.acquire_owned().await else {
                                    return;
                                };
                                let name = ch.name.clone();
                                let kind = ch.channel_type.clone();
                                match crate::notifications::send_to_channel(&c, &ch, &a).await {
                                    Ok(msg) => println!("[hub] NOTIFY {} ({}) -> OK: {}", name, kind, msg),
                                    Err(err) => eprintln!("[hub] NOTIFY {} ({}) -> ERR: {}", name, kind, err),
                                }
                            });
                        }
                    }
                });

                // Spawn the HA Cluster replication & heartbeat worker
                crate::cluster::spawn_cluster_worker(st.clone(), std::time::Duration::from_millis(1000));

                let tls_mgr = Arc::clone(&st.lock_or_recover().tls);
                if let Err(e) = tls_mgr.reload_from_disk() {
                    let c = tls_mgr.config.lock_or_recover();
                    if c.enabled {
                        eprintln!("[hub] TLS WARN: TLS is enabled in configuration, but loading certificate from disk failed: {}", e);
                    }
                }
                let current_port: u16 = addr.rsplit(':').next().and_then(|p| p.parse().ok()).unwrap_or(0);
                let current_host: String = addr.rsplit_once(':').map(|(h, _)| h.to_string()).unwrap_or_default();
                tls_mgr.set_active_http_port(current_port);
                {
                    let mut s = st.lock_or_recover();
                    s.http_port = current_port;
                    if !current_host.is_empty() {
                        s.http_host = current_host;
                    }
                    s.tx = Some(tx.clone());
                }

                // HUB-02: Ensure dedicated HTTPS listener is spawned if enabled on custom port
                ensure_dedicated_https_listener(&st);

                crate::tls::spawn_auto_renewal_worker(Arc::clone(&tls_mgr));

                let listener = match tokio::net::TcpListener::bind(&addr).await {
                    Ok(l) => l,
                    Err(e) => {
                        eprintln!("[hub] cannot bind the dashboard on {}: {}", addr, e);
                        return;
                    }
                };
                let (is_tls, tls_misconfigured) = {
                    let c = tls_mgr.config.lock_or_recover();
                    let port_matches = c.enabled && c.https_port == current_port;
                    let has_acceptor = tls_mgr.acceptor.read_or_recover().is_some();
                    (port_matches && has_acceptor, port_matches && !has_acceptor)
                };
                if tls_misconfigured {
                    eprintln!("[hub] TLS WARN: HTTPS configured on port {} but certificate is missing/unusable; connections will be refused (fail-closed) until valid certificate is configured.", current_port);
                }
                println!(
                    "[hub] dashboard + REST on {}://{}",
                    if is_tls { "https" } else { "http" },
                    addr
                );

                // RUST-OPT-01: Build Router once outside accept loop and clone per connection (O(1) Arc clone)
                let app_base_main = router(st.clone(), tx.clone());
                loop {
                    let (tcp_stream, _) = match listener.accept().await {
                        Ok(conn) => conn,
                        Err(_) => continue,
                    };
                    let is_https_on_main = {
                        let c = tls_mgr.config.lock_or_recover();
                        c.enabled && c.https_port == current_port
                    };
                    let acceptor_opt = if is_https_on_main {
                        tls_mgr.acceptor.read_or_recover().clone()
                    } else {
                        None
                    };
                    let app = app_base_main.clone();
                    let tls_mgr_spawn = Arc::clone(&tls_mgr);
                    tokio::spawn(async move {
                        if let Some(acceptor) = acceptor_opt {
                            match acceptor.accept(tcp_stream).await {
                                Ok(tls_stream) => {
                                    crate::tls::serve_stream_with_router(tls_stream, app).await;
                                }
                                Err(_) => {}
                            }
                        } else if is_https_on_main {
                            // H2: Fail-closed: If HTTPS is configured and active on this port but acceptor is missing,
                            // do NOT fall back to plaintext HTTP (prevent credential exposure). Drop the connection.
                            eprintln!("[hub] TLS ERR: Rejecting connection on https port {} because certificate acceptor is not ready", current_port);
                        } else {
                            // BUG-10: If TLS is enabled on a dedicated port and enable_http_redirect is active,
                            // redirect browser/dashboard requests arriving on the configured http_port (e.g. port 80)
                            // to HTTPS while preserving health/cluster/ACME paths.
                            let redirect_opt = {
                                let c = tls_mgr_spawn.config.lock_or_recover();
                                let has_acceptor = tls_mgr_spawn.acceptor.read_or_recover().is_some();
                                if c.enabled && c.enable_http_redirect && has_acceptor && c.https_port != 0 && c.https_port != current_port {
                                    Some((c.domain.clone(), c.https_port))
                                } else {
                                    None
                                }
                            };
                            if let Some((domain, https_port)) = redirect_opt {
                                let redirect_app = app.clone().layer(axum::middleware::from_fn(
                                    move |req: axum::extract::Request, next: axum::middleware::Next| {
                                        let domain = domain.clone();
                                        async move {
                                            use axum::response::IntoResponse;
                                            let path = req.uri().path();
                                            let is_html_nav = path == "/" || path == "/index.html"
                                                || req.headers().get(axum::http::header::ACCEPT)
                                                    .and_then(|a| a.to_str().ok())
                                                    .map(|s| s.contains("text/html"))
                                                    .unwrap_or(false);
                                            if !is_html_nav || path == "/healthz" || path == "/readyz" || path.starts_with("/api/v1/cluster") || path.starts_with("/.well-known") {
                                                return next.run(req).await;
                                            }
                                            let raw_host = req.headers().get(axum::http::header::HOST)
                                                .and_then(|h| h.to_str().ok())
                                                .unwrap_or("");
                                            let host_only = if raw_host.starts_with('[') {
                                                raw_host.split(']').next().map(|s| format!("{}]", s)).unwrap_or_default()
                                            } else {
                                                raw_host.split(':').next().unwrap_or("").to_string()
                                            };
                                            let host_valid = !host_only.is_empty()
                                                && host_only.len() <= 253
                                                && host_only.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'[' | b']'));
                                            let host = if !domain.is_empty() {
                                                domain.as_str()
                                            } else if host_valid {
                                                host_only.as_str()
                                            } else {
                                                "localhost"
                                            };
                                            let pq = req.uri().path_and_query().map(|x| x.as_str()).unwrap_or("/");
                                            let target = if https_port == 443 {
                                                format!("https://{}{}", host, pq)
                                            } else {
                                                format!("https://{}:{}{}", host, https_port, pq)
                                            };
                                            axum::response::Redirect::temporary(&target).into_response()
                                        }
                                    },
                                ));
                                crate::tls::serve_stream_with_router(tcp_stream, redirect_app).await;
                            } else {
                                crate::tls::serve_stream_with_router(tcp_stream, app).await;
                            }
                        }
                    });
                }
            });
        })
        .map_err(|e| format!("cannot spawn the API thread: {}", e))?;
    Ok(tx_out)
}





fn resolve_locales_dir() -> std::path::PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join("locales");
            if candidate.is_dir() {
                return candidate;
            }
        }
    }
    std::path::PathBuf::from("locales")
}

async fn locales_list() -> Json<Value> {
    let list = tokio::task::spawn_blocking(|| {
        let mut list = Vec::new();
        let locales_dir = resolve_locales_dir();
        if locales_dir.is_dir() {
            if let Ok(entries) = std::fs::read_dir(locales_dir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    if p.is_file() && p.extension().and_then(|s| s.to_str()) == Some("json") {
                        let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                        if stem == "template" {
                            continue;
                        }
                        if let Ok(content) = std::fs::read_to_string(&p) {
                            if let Ok(v) = serde_json::from_str::<Value>(&content) {
                                let name = v
                                    .get("meta")
                                    .and_then(|m| m.get("name"))
                                    .and_then(|n| n.as_str())
                                    .unwrap_or(stem);
                                let code = v
                                    .get("meta")
                                    .and_then(|m| m.get("code"))
                                    .and_then(|c| c.as_str())
                                    .unwrap_or(stem);
                                list.push(json!({
                                    "code": code,
                                    "name": name
                                }));
                            }
                        }
                    }
                }
            }
        }
        list.sort_by(|a, b| {
            let code_a = a.get("code").and_then(|c| c.as_str()).unwrap_or("");
            let code_b = b.get("code").and_then(|c| c.as_str()).unwrap_or("");
            code_a.cmp(code_b)
        });
        list
    })
    .await
    .unwrap_or_default();
    Json(json!({ "locales": list }))
}

async fn locale_get(Path(code): Path<String>) -> axum::response::Response {
    use axum::response::IntoResponse;
    if code.is_empty()
        || code.len() > 32
        || !code
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid locale code" })),
        )
            .into_response();
    }
    let res = tokio::task::spawn_blocking(move || {
        let file_path = resolve_locales_dir().join(format!("{}.json", code));
        if !file_path.exists() {
            return None;
        }
        Some(std::fs::read_to_string(&file_path))
    })
    .await;

    match res {
        Ok(Some(Ok(content))) => (
            [(
                axum::http::header::CONTENT_TYPE,
                "application/json; charset=utf-8",
            )],
            content,
        )
            .into_response(),
        Ok(Some(Err(e))) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("cannot read locale: {}", e) })),
        )
            .into_response(),
        _ => (
            axum::http::StatusCode::NOT_FOUND,
            Json(json!({ "error": "locale not found" })),
        )
            .into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::constant_time_eq_str;

    #[test]
    fn constant_time_eq_str_checks_equality_and_lengths() {
        assert!(constant_time_eq_str("", ""));
        assert!(constant_time_eq_str("secret_token_v1", "secret_token_v1"));
        assert!(!constant_time_eq_str("secret_token_v1", "secret_token_v2"));
        assert!(!constant_time_eq_str("secret_token_v1", "secret_token_v1_extra"));
        assert!(!constant_time_eq_str("", "nonempty"));
    }
}
