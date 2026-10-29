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
use crate::lockx::LockExt;
use crate::commands::CommandStore;
use crate::alerts::AlertEngine;
use crate::notifications::{NotificationChannel, NotificationStore};
use crate::users::{
    hash_password, verify_password, Role as UserRole, Session, User, UserStore, SESSION_IDLE_SECS,
};
use crate::config::ConfigStore;
use crate::positions::{Positions, SenderView};
use crate::registry::{Liveness, Node, Registry, Role};

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
    pub notif_tx: Option<tokio::sync::mpsc::UnboundedSender<crate::alerts::Alert>>,
    pub cluster: crate::cluster::ClusterManager,
    pub writes_allowed: bool,
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
                "lots": (n.wait_lots * 100.0).round() / 100.0,
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
        "positions_detail": if n.role == Role::Receiver {
            Value::Array(n.held_items.iter().map(|p| json!({
                "ticket": p.ticket,
                "symbol": p.symbol,
                "side": p.side,
                "lots": trim_lots(p.lots),
                "open_px": p.open_px,
                "sl": p.sl,
                "tp": p.tp,
                "magic": p.magic,
                "managed": p.managed,
                "comment": p.comment,
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

/// 0.5 not 0.5000000000001. JSON numbers are fine but a page showing
/// `0.5000000000000001` next to a page showing `0.50` for the same position
/// looks like a bug in the copier.
fn trim_lots(l: f64) -> String {
    let s = format!("{:.2}", l);
    s.trim_end_matches('0').trim_end_matches('.').to_string()
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
                        "lots": (n.held_lots * 100.0).round() / 100.0,
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
    let (nodes, counts, uptime) = {
        let s = st.lock_or_recover();
        let now = Instant::now();
        // One order, shared with the WebSocket. See nodes_json_list: this
        // used to sort by `key` here while the WS push sorted by `last_seen`,
        // and the page showed the second one.
        let v: Vec<Value> = nodes_json_list(&s.reg, &s.pos, now);
        let counts = json!({
            "online": s.reg.count(Liveness::Online, now),
            "stale": s.reg.count(Liveness::Stale, now),
            "offline": s.reg.count(Liveness::Offline, now),
            "total": s.reg.len(),
            "evicted": s.reg.evicted,
        });
        (Value::Array(v), counts, now - s.started)
    };
    Json(json!({
        "nodes": nodes,
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
                        .filter(|(_, recvs)| recvs.contains_key(&n.acc))
                        .map(|(sender, _)| sender.clone())
                        .collect();
                    targets.sort();
                    let targets: Vec<Value> = targets.into_iter().map(Value::String).collect();
                    obj.insert("mirrors".to_string(), Value::Array(targets));
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
    let out = {
        let s = st.lock_or_recover();
        let now = Instant::now();

        //--- Partition the ONE node list rather than building a second one.
        //--- This used to be a fourth serialization path with its own positions
        //--- join, which is how the three lists drifted apart in the first
        //--- place. `nodes_json_list` already orders by account and joins
        //--- positions, so partition is all that is left to do.
        let all = nodes_json_list(&s.reg, &s.pos, now);
        let mut senders: Vec<Value> = Vec::new();
        let mut receivers: Vec<Value> = Vec::new();
        for j in all {
            match j["role"].as_str() {
                Some("sender") => senders.push(j),
                Some("receiver") => receivers.push(j),
                _ => {}
            }
        }

        let mut edges: Vec<Value> = Vec::new();
        for (sender, recvs) in s.mirrors.iter() {
            let mut rs: Vec<&String> = recvs.keys().collect();
            rs.sort();
            for r in rs {
                edges.push(json!({ "from": sender, "to": r }));
            }
        }

        json!({
            "senders": Value::Array(senders),
            "receivers": Value::Array(receivers),
            "edges": Value::Array(edges),
            "alerts": Value::Array(s.alerts.recent_json(20)),
            //--- M9/§19.1. The PUBLIC key is not a secret - it is the thing
            //--- every node's HubPublicKey input needs - so showing it on the
            //--- dashboard is exactly as safe as printing it in the log, and
            //--- saves the operator a trip to the console.
            "curve": curve_json(&s),
            "cluster": cluster_json(&s),
            "counts": {
                "senders": s.reg.count_by_role(Role::Sender),
                "receivers": s.reg.count_by_role(Role::Receiver),
                "hub_uptime_secs": now.saturating_duration_since(s.started).as_secs(),
            }
        })
    };
    Json(out)
}

/// `GET /api/v1/positions` - the M3 view, as data rather than as a log line.
///
/// Same numbers `print_positions` puts on stdout, including the mismatch
/// warning. If the text and this ever disagree, the text is derived from the
/// same structs and this is not, so one of them has been changed - and the
/// honest fix is to make both read the same place.
async fn positions(State(st): State<SharedState>) -> Json<Value> {
    let out = {
        let s = st.lock_or_recover();
        let rows: Vec<Value> = positions_json_list(&s.pos);
        json!({
            "senders": Value::Array(rows),
            "parsed": s.pos.parsed,
            "mismatched": s.pos.mismatched,
            "total_positions": s.pos.total_positions(),
            "total_lots": trim_lots(s.pos.total_lots()),
        })
    };
    Json(out)
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
    State(st): State<SharedState>,
    axum::extract::Extension(tx): axum::extract::Extension<tokio::sync::broadcast::Sender<std::sync::Arc<String>>>,
) -> impl axum::response::IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, st, tx))
}

async fn handle_socket(
    mut socket: WebSocket,
    st: SharedState,
    tx: tokio::sync::broadcast::Sender<std::sync::Arc<String>>,
) {
    // Everything the page needs on arrival, so it can render before it has
    // made a single HTTP call of its own.
    if socket.send(Message::Text(snapshot_text(&st))).await.is_err() {
        return;
    }

    let mut rx = tx.subscribe();
    let mut beat = tokio::time::interval(std::time::Duration::from_secs(WS_HEARTBEAT_SECS));
    beat.tick().await; // the first tick fires immediately; consume it

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
            // text: the ZMQ thread serialises once per change and shares it
            // through the Arc, so N dashboards cost one serialisation instead
            // of N (that used to be N full passes over every node and every
            // position, each taking the shared lock).
            changed = rx.recv() => {
                match changed {
                    Ok(s) => {
                        if socket.send(Message::Text((*s).clone())).await.is_err() {
                            break;
                        }
                    }
                    // A slow client missed some. It is about to be sent the
                    // current state anyway, so a lag is not an error here -
                    // it is the reason this design is fine.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
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

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn cookie_token(cookies: &str) -> Option<String> {
    for part in cookies.split(';') {
        if let Some(v) = part.trim().strip_prefix("mtc_session=") {
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn constant_time_eq_str(a: &str, b: &str) -> bool {
    let a_bytes = a.as_bytes();
    let b_bytes = b.as_bytes();
    if a_bytes.len() != b_bytes.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a_bytes.iter().zip(b_bytes.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

async fn require_session(
    axum::extract::State(st): axum::extract::State<SharedState>,
    mut req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let path = req.uri().path().to_string();
    if path == "/"
        || path == "/api/v1/auth/nonce"
        || path == "/api/v1/login"
        || path == "/api/v1/logout"
        || path == "/api/v1/whoami"
        || path == "/favicon.ico"
        //--- The health probes MUST be open: a load balancer or a monitoring
        //--- cron cannot log in, and a health check that needs a session is
        //--- not a health check. They answer liveness and nothing else -
        //--- no positions, no keys, no state - so there is nothing here for
        //--- an unauthenticated caller to learn.
        || path == "/healthz"
        || path == "/readyz"
    {
        return next.run(req).await;
    }
    //--- Cluster internal communication authentication (ADR-09):
    //--- Authenticate via cluster_token in Authorization: Bearer <token> or X-Cluster-Token header.
    let is_cluster_path = path.starts_with("/api/v1/cluster/");
    if is_cluster_path {
        let cluster_token = st.lock_or_recover().cluster.cluster_token.clone();
        let auth_hdr = req.headers().get(axum::http::header::AUTHORIZATION).and_then(|v| v.to_str().ok());
        let x_hdr = req.headers().get("X-Cluster-Token").and_then(|v| v.to_str().ok());
        let token_matches = auth_hdr.map(|h| h.strip_prefix("Bearer ").unwrap_or(h)).map(|h| constant_time_eq_str(h, &cluster_token)).unwrap_or(false)
            || x_hdr.map(|h| constant_time_eq_str(h, &cluster_token)).unwrap_or(false);
        if token_matches {
            // R60-07: Inject Session extension for cluster endpoints expecting admin session
            req.extensions_mut().insert(Session {
                user_id: "cluster".to_string(),
                role: UserRole::Admin,
                seen: unix_secs(),
            });
            req.extensions_mut().insert(Token(cluster_token));
            return next.run(req).await;
        }
        // P0-2: If cluster token did not match and users auth is disabled, forbid anonymous access
        if !st.lock_or_recover().auth_enabled {
            return (
                axum::http::StatusCode::FORBIDDEN,
                Json(json!({ "error": "forbidden: cluster endpoints require valid cluster token" })),
            )
                .into_response();
        }
    }
    //--- --users none: no login exists, so demanding one would make the HTTP
    //--- face unusable. Answer as an anonymous viewer instead - the role gate
    //--- in every write handler still runs, so this remains read-only by
    //--- construction, and a denied write is still audited (actor "anonymous").
    if !st.lock_or_recover().auth_enabled {
        req.extensions_mut().insert(Session {
            user_id: "anonymous".to_string(),
            role: UserRole::Viewer,
            seen: unix_secs(),
        });
        req.extensions_mut().insert(Token(String::new()));
        return next.run(req).await;
    }
    let token = req
        .headers()
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(cookie_token)
        .or_else(|| {
            req.headers()
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .map(|v| v.strip_prefix("Bearer ").unwrap_or(v).to_string())
        });
    if let Some(t) = token {
        let sess = st.lock_or_recover().users.session(&t, unix_secs());
        if let Some(sess) = sess {
            // P0-2: Cluster endpoints accessed without cluster token require Admin role
            if is_cluster_path && sess.role < UserRole::Admin {
                return (
                    axum::http::StatusCode::FORBIDDEN,
                    Json(json!({ "error": "forbidden: cluster endpoints require Admin role or valid cluster token" })),
                )
                    .into_response();
            }
            req.extensions_mut().insert(sess);
            //--- The raw token too, for the one handler that must tell the
            //--- caller's session apart from the caller's other sessions
            //--- (a password change drops those, keeps this).
            req.extensions_mut().insert(Token(t));
            return next.run(req).await;
        }
    }
    (
        axum::http::StatusCode::UNAUTHORIZED,
        Json(json!({ "error": "not authenticated", "login_at": "/api/v1/login" })),
    )
        .into_response()
}

/// The role gate for the handler-level checks. A 403 is audited, because a
/// denied action is exactly what an operator later asks the log about.
///
/// The audit handle is cloned OUT of the state lock before `record` runs.
/// `record` fsyncs, and this function is on the path of every refused write -
/// a viewer clicking a button repeatedly would otherwise stall the ZMQ router
/// thread for a disk flush each time. (Same bug class as the login hash that
/// used to run under this lock.)
fn deny(st: &SharedState, sess: &Session, need: &str) -> axum::response::Response {
    use axum::response::IntoResponse;
    let audit = {
        let s = st.lock_or_recover();
        Arc::clone(&s.audit)
    };
    audit.record(
        &sess.user_id,
        "",
        "auth.denied",
        "",
        None,
        Some(json!({ "need": need, "have": sess.role.as_str() })),
        "rejected",
    );
    (
        axum::http::StatusCode::FORBIDDEN,
        Json(json!({ "error": format!("{} only", need), "your_role": sess.role.as_str() })),
    )
        .into_response()
}

#[derive(serde::Deserialize)]
struct NonceBody {
    id: String,
}

/// `POST /api/v1/auth/nonce` - request a short-lived nonce for challenge-response login.
async fn auth_nonce(
    headers: axum::http::HeaderMap,
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<NonceBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let now = unix_secs();
    //--- N56-15: only trust X-Forwarded-For when an operator has declared that a
    //--- proxy sits in front of this hub. Otherwise any caller can invent a fresh
    //--- "client IP" on every request, get a brand-new 25/s budget each time, and
    //--- still fill the 512-slot nonce table - which locks every real operator
    //--- out of the login page. Set MTC_TRUST_PROXY=1 only behind a real proxy
    //--- that overwrites (not appends to) this header.
    let trust_proxy = std::env::var("MTC_TRUST_PROXY")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let client_ip = if trust_proxy {
        headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(',').next())
            .map(|s| s.trim().to_string())
            .or_else(|| {
                headers
                    .get("x-real-ip")
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.trim().to_string())
            })
            .unwrap_or_else(|| "direct".to_string())
    } else {
        "direct".to_string()
    };
    let created = {
        let mut s = st.lock_or_recover();
        // 10-second single-use challenge window with IP rate limiting
        s.users.create_nonce_with_ip(&b.id, now, 10, &client_ip)
    };
    let Some((nonce, salt, rounds)) = created else {
        //--- The hub is already holding as many live challenges as it will.
        //--- Answering 429 rather than minting another is what stops an
        //--- unauthenticated loop from growing the map without bound.
        return (
            axum::http::StatusCode::TOO_MANY_REQUESTS,
            [(axum::http::header::RETRY_AFTER, "1".to_string())],
            Json(json!({ "error": "too many pending login challenges, retry shortly" })),
        )
            .into_response();
    };
    (
        axum::http::StatusCode::OK,
        Json(json!({
            "nonce": nonce,
            "salt": salt,
            "rounds": rounds,
        })),
    )
        .into_response()
}

#[derive(serde::Deserialize)]
struct LoginBody {
    id: String,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    proof: Option<String>,
}

async fn login(
    axum::extract::State(st): axum::extract::State<SharedState>,
    headers: axum::http::HeaderMap,
    Json(b): Json<LoginBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let now = unix_secs();
    //--- THE GLOBAL REFUSAL COMES FIRST, and it is the cheapest answer this
    //--- endpoint can give: no hashing, no nonce lookup, no audit write. It
    //--- exists so a password-spray cannot make the hub burn 4096 SHA-256
    //--- rounds per request. It is GLOBAL on purpose - see LoginGuard in
    //--- users.rs for why a per-name lockout would be a weapon.
    if let Some(wait) = { st.lock_or_recover().users.login_blocked(now) } {
        return (
            axum::http::StatusCode::TOO_MANY_REQUESTS,
            [(axum::http::header::RETRY_AFTER, wait.to_string())],
            Json(json!({
                "error": "too many failed logins, retry shortly",
                "retry_after_secs": wait,
            })),
        )
            .into_response();
    }
    let r = {
        if let (Some(nonce), Some(proof)) = (&b.nonce, &b.proof) {
            // Scheme B: the expensive half (the 4096-round hash) is computed
            // by the CLIENT; the server consumes the nonce and does one
            // constant-time hex compare. Cheap enough to keep in the lock.
            let mut s = st.lock_or_recover();
            s.users.login_with_proof(&b.id, nonce, proof, now)
        } else if let Some(pwd) = &b.password {
            //--- Legacy / fallback direct-password auth (tests, automation).
            //--- verify_password is 4096 SHA-256 rounds of REAL CPU, and it
            //--- used to run while the shared-state mutex was held - which
            //--- stalled the ZMQ router thread (every position update from
            //--- every sender waits behind that lock) for the duration of
            //--- every login. Read the stored hash under a short lock, hash
            //--- with NO lock, mint under a short one.
            let stored = {
                let s = st.lock_or_recover();
                s.users.stored_hash(&b.id)
            };
            // R47-14: Equalize timing with dummy hash when user is absent/disabled to prevent enumeration
            let dummy_hash = format!("dummy_salt_timing${}${}", crate::users::HASH_ROUNDS, "0".repeat(64));
            let target_hash = stored.as_deref().unwrap_or(&dummy_hash);
            let verified = crate::users::verify_password(pwd, target_hash) && stored.is_some();
            if verified {
                //--- Re-check under the lock: the user may have been
                //--- disabled while we were hashing, and mint_session
                //--- refuses that rather than handing out a stale pass.
                let mut s = st.lock_or_recover();
                s.users.mint_session(&b.id, now)
            } else {
                Err("invalid credentials".to_string())
            }
        } else {
            Err("invalid credentials".to_string())
        }
    };
    match r {
        Ok((token, sess)) => {
            let audit = {
                let mut s = st.lock_or_recover();
                // A good password clears this name's failure count, so an
                // operator who mistyped twice and then got it right starts
                // from zero next time.
                s.users.note_login_success(&b.id);
                Arc::clone(&s.audit)
            };
            //--- Outside the lock: `record` fsyncs.
            audit.record(
                &sess.user_id,
                "",
                "auth.login",
                &b.id,
                None,
                Some(json!({ "role": sess.role.as_str() })),
                "ok",
            );
            // HUB-07: Clean up plaintext initial admin bootstrap password on successful login
            if b.id == "admin" {
                let s = st.lock_or_recover();
                s.users.cleanup_bootstrap_password();
            }
            //--- N56-16: TLS state comes from CONFIGURATION, not from a request
            //--- header. A header is caller-controlled, so trusting it means the
            //--- cookie's Secure flag is decided by whoever is talking. The
            //--- dangerous direction is the silent one: a real TLS deployment
            //--- behind a proxy that does not set X-Forwarded-Proto gets a
            //--- NON-Secure session cookie, which then travels in cleartext.
            //--- Declare it with MTC_HTTPS=1, or MTC_TRUST_PROXY=1 behind a proxy
            //--- that overwrites (not appends to) X-Forwarded-Proto.
            let trust_proxy = std::env::var("MTC_TRUST_PROXY")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            let is_https = std::env::var("MTC_HTTPS")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false)
                || (trust_proxy
                    && (headers
                        .get("x-forwarded-proto")
                        .map(|v| v == "https")
                        .unwrap_or(false)
                        || headers
                            .get("x-forwarded-ssl")
                            .map(|v| v == "on")
                            .unwrap_or(false)));
            let secure_attr = if is_https { "; Secure" } else { "" };
            (
                axum::http::StatusCode::OK,
                [(
                    axum::http::header::SET_COOKIE,
                    format!(
                        "mtc_session={}; HttpOnly; Path=/; SameSite=Strict; Max-Age={}{}",
                        token, SESSION_IDLE_SECS, secure_attr
                    ),
                )],
                Json(json!({ "user": sess.user_id, "role": sess.role.as_str() })),
            )
                .into_response()
        }
        // Deliberately does NOT say whether the id exists.
        Err(_) => {
            let is_heavy = b.password.is_some();
            let (delay_ms, audit) = {
                let mut s = st.lock_or_recover();
                let d = s.users.note_login_failure(&b.id, now, is_heavy);
                (d, Arc::clone(&s.audit))
            };
            audit.record(
                &b.id, "", "auth.login", &b.id, None,
                Some(json!({ "why": "invalid credentials" })), "rejected",
            );
            //--- The delay is applied OUTSIDE the lock and OUTSIDE the
            //--- router thread: `tokio::time::sleep` yields to the runtime,
            //--- so it costs the attacker wall-clock time and costs the hub
            //--- nothing. It escalates per name, which is what makes a
            //--- dictionary attack against one account impractical without
            //--- giving anyone the power to lock that account out.
            if delay_ms > 0 {
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            }
            (
                axum::http::StatusCode::UNAUTHORIZED,
                Json(json!({ "error": "invalid credentials" })),
            )
                .into_response()
        }
    }
}

fn header_token(headers: &axum::http::HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(cookie_token)
        .or_else(|| {
            headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .map(|v| v.strip_prefix("Bearer ").unwrap_or(v).to_string())
        })
}

async fn logout(
    axum::extract::State(st): axum::extract::State<SharedState>,
    headers: axum::http::HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let tok = header_token(&headers);
    let mut who = String::new();
    if let Some(t) = &tok {
        let mut s = st.lock_or_recover();
        if let Some(sess) = s.users.session(t, unix_secs()) {
            who = sess.user_id.clone();
        }
        s.users.logout(t);
    }
    let audit = st.lock_or_recover().audit.clone();
    audit.record(&who, "", "auth.logout", &who, None, None, "ok");
    (
        axum::http::StatusCode::OK,
        [(
            axum::http::header::SET_COOKIE,
            "mtc_session=; HttpOnly; Path=/; SameSite=Strict; Max-Age=0".to_string(),
        )],
        Json(json!({ "ok": true })),
    )
        .into_response()
}

/// Exempt from the middleware, so it reads the cookie itself and answers 401
/// without one - which is the dashboard's "who am I, or login?" call.
async fn whoami(
    axum::extract::State(st): axum::extract::State<SharedState>,
    headers: axum::http::HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    //--- --users none: tell the dashboard it is already "in", or its overlay
    //--- would demand a login the hub has no door for.
    let disabled = st.lock_or_recover().auth_enabled == false;
    if disabled {
        return Json(json!({ "user": "anonymous", "role": "viewer",
                            "note": "login disabled (--users none)" }))
        .into_response();
    }
    let tok = header_token(&headers);
    if let Some(t) = tok {
        if let Some(s) = st.lock_or_recover().users.session(&t, unix_secs()) {
            return Json(json!({ "user": s.user_id, "role": s.role.as_str() })).into_response();
        }
    }
    (
        axum::http::StatusCode::UNAUTHORIZED,
        Json(json!({ "error": "not authenticated" })),
    )
        .into_response()
}

/// The raw session token, stashed by the middleware for handlers that need
/// to distinguish "this session" from "this user's other sessions".
#[derive(Clone)]
pub struct Token(pub String);

#[derive(serde::Deserialize)]
struct UserBody {
    id: String,
    /// Optional on PURPOSE: an empty password means "keep the existing hash",
    /// so a role change or a disable/enable does not silently reset the
    /// user's credential. Required for a user that does not exist yet.
    #[serde(default)]
    password: String,
    role: String,
    #[serde(default)]
    disabled: bool,
}

async fn users_list(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::State(st): axum::extract::State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let s = st.lock_or_recover();
    let list: Vec<Value> = s
        .users
        .users()
        .iter()
        .map(|u| json!({ "id": u.id, "role": u.role.as_str(), "disabled": u.disabled }))
        .collect();
    Json(json!({ "users": list, "sessions": s.users.session_count() })).into_response()
}

async fn users_upsert(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<UserBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    if !st.lock_or_recover().cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }
    let role = match UserRole::parse(&b.role) {
        Some(r) => r,
        None => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "role is one of viewer, operator, admin" })),
            )
                .into_response()
        }
    };
    //--- An EMPTY password means "keep what is there", which is what a role
    //--- change or a disable/enable wants - the dashboard's user table sends
    //--- exactly that, and requiring a password here would silently RESET
    //--- the user's credential every time an admin toggled a switch. A user
    //--- that does not exist yet has nothing to keep, so it is refused.
    //---
    //--- The READ of the old hash is one short lock; the 4096-round hash of a
    //--- NEW password runs with NO lock held, for the same reason the login
    //--- path was fixed: it is real CPU, and the router thread waits on this
    //--- mutex for every position update.
    let existing_pass = {
        let s = st.lock_or_recover();
        s.users.get(&b.id).map(|u| u.pass.clone())
    };
    let pass = if b.password.is_empty() {
        match existing_pass {
            Some(p) => p,
            None => {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "a new user needs a password" })),
                )
                    .into_response()
            }
        }
    } else {
        // F-14: Enforce consistent minimum password policy (at least 8 characters)
        if b.password.chars().count() < 8 {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "password must be at least 8 characters" })),
            )
                .into_response();
        }
        let salt = crate::users::random_token()[..16].to_string();
        hash_password(&b.password, &salt)
    };
    let u = User {
        id: b.id.clone(),
        pass,
        role,
        disabled: b.disabled,
    };
    let audit = {
        let mut s = st.lock_or_recover();
        if let Err(e) = s.users.upsert(u) {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": e })),
            )
                .into_response();
        }
        //--- Still inside the lock, deliberately: `users` is a plain field of
        //--- the shared state rather than its own Arc, and an admin write is
        //--- rare enough that one flush here is not the hot path. The audit
        //--- write below IS moved out, because it is the second flush.
        if !b.password.is_empty() || b.disabled {
            s.users.drop_other_sessions(&b.id, None);
        }
        if let Err(e) = s.users.save() {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("failed to save users: {}", e) })),
            )
                .into_response();
        }
        Arc::clone(&s.audit)
    };
    audit.record(
        &sess.user_id,
        "",
        "user.upsert",
        &b.id,
        None,
        Some(json!({ "role": b.role, "disabled": b.disabled })),
        "ok",
    );
    Json(json!({ "ok": true, "id": b.id })).into_response()
}

async fn users_delete(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::Path(id): axum::extract::Path<String>,
    axum::extract::State(st): axum::extract::State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    if !st.lock_or_recover().cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }
    let removed = {
        let mut s = st.lock_or_recover();
        match s.users.remove(&id) {
            Ok(()) => {
                if let Err(e) = s.users.save() {
                    Err(format!("failed to save users: {}", e))
                } else {
                    Ok(Arc::clone(&s.audit))
                }
            }
            Err(e) => Err(e),
        }
    };
    match removed {
        Ok(audit) => {
            //--- Out of the lock: `record` fsyncs.
            audit.record(&sess.user_id, "", "user.delete", &id, None, None, "ok");
            Json(json!({ "ok": true, "id": id })).into_response()
        }
        Err(e) => (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": e })),
        )
            .into_response(),
    }
}

#[derive(serde::Deserialize)]
struct PasswordBody {
    old: String,
    new: String,
}

/// `POST /api/v1/password` - change YOUR OWN password. Open to any role,
/// because needing an admin to rotate your own credential is how credentials
/// get shared. The old password is required even though the caller is already
/// authenticated: a borrowed session (a shoulder-surfed laptop) must not be
/// enough to lock the real owner out.
async fn change_password(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::Extension(tok): axum::extract::Extension<Token>,
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<PasswordBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if !st.lock_or_recover().cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }
    if b.new.chars().count() < 8 {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "the new password must be at least 8 characters" })),
        )
            .into_response();
    }
    //--- Read what the check needs under ONE short lock, then verify with no
    //--- lock held: `verify_password` is 4096 SHA-256 rounds of real CPU, and
    //--- holding the shared mutex across it stalls the ZMQ router thread for
    //--- every position update in flight. The login path was fixed for this
    //--- reason; this one had been left behind.
    let (auth_enabled, stored) = {
        let s = st.lock_or_recover();
        (s.auth_enabled, s.users.get(&sess.user_id).map(|u| u.pass.clone()))
    };
    if !auth_enabled {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({ "error": "login is disabled on this hub (--users none)" })),
        )
            .into_response();
    }
    let old_ok = stored.map(|h| verify_password(&b.old, &h)).unwrap_or(false);
    let audit = {
        let s = st.lock_or_recover();
        Arc::clone(&s.audit)
    };
    if !old_ok {
        audit.record(
            &sess.user_id,
            "",
            "user.password_changed",
            &sess.user_id,
            None,
            Some(json!({ "reason": "wrong current password" })),
            "rejected",
        );
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({ "error": "the current password is not correct" })),
        )
            .into_response();
    }
    let new_salt = crate::users::random_token()[..16].to_string();
    let new_hash = crate::users::hash_password(&b.new, &new_salt);
    let changed = {
        let mut s = st.lock_or_recover();
        match s.users.set_password_hashed(&sess.user_id, new_hash) {
            Err(e) => Err(e),
            Ok(()) => {
                if let Err(e) = s.users.save() {
                    Err(format!("failed to save users: {}", e))
                } else {
                    //--- The old credential is gone, so every session it minted
                    //--- should be too - except this one, which the caller is
                    //--- still using.
                    Ok(s.users.drop_other_sessions(&sess.user_id, Some(&tok.0)))
                }
            }
        }
    };
    let dropped = match changed {
        Ok(d) => d,
        Err(e) => {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": e })),
            )
                .into_response()
        }
    };
    audit.record(
        &sess.user_id,
        "",
        "user.password_changed",
        &sess.user_id,
        None,
        Some(json!({ "other_sessions_ended": dropped })),
        "ok",
    );
    // HUB-07: Clean up plaintext initial admin bootstrap password on password change
    if sess.user_id == "admin" {
        let s = st.lock_or_recover();
        s.users.cleanup_bootstrap_password();
    }
    Json(json!({ "ok": true, "other_sessions_ended": dropped })).into_response()
}

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
                let (alert_tx, mut alert_rx) = tokio::sync::mpsc::unbounded_channel::<crate::alerts::Alert>();
                let http_client = reqwest::Client::builder()
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
                            s.matching_channels_for_alert(&alert)
                        };
                        for ch in channels {
                            let c = http_worker.clone();
                            let a = alert.clone();
                            tokio::spawn(async move {
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

                let listener = match tokio::net::TcpListener::bind(&addr).await {
                    Ok(l) => l,
                    Err(e) => {
                        eprintln!("[hub] cannot bind the dashboard on {}: {}", addr, e);
                        return;
                    }
                };
                println!("[hub] dashboard + REST on http://{}", addr);
                if let Err(e) = axum::serve(listener, router(st, tx)).await {
                    eprintln!("[hub] API server stopped: {}", e);
                }
            });
        })
        .map_err(|e| format!("cannot spawn the API thread: {}", e))?;
    Ok(tx_out)
}

// ---------------------------------------------------------------------------
// M4a: the config endpoints.
//
// EVERY ONE OF THESE IS READ-ONLY EXCEPT TWO, and those two are gated on
// `--writes`. See `config.rs` for why the gate exists rather than an assumption
// that only trusted people can reach the port.
// ---------------------------------------------------------------------------

/// `GET /api/v1/nodes/{id}/config/revision/{rev}`
///
/// One revision's INI body. This exists because the history LIST no longer
/// carries bodies: fifty revisions of a 100-sender config is ~13 MB, for a
/// dialog that shows fifty rows and usually loads exactly one of them.
///
/// Read-only: no write gate, because reading a config cannot change anything.
async fn node_config_revision(
    State(st): State<SharedState>,
    Path((id, rev)): Path<(String, u64)>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let id = normalise_node(&id);
    let cfg = {
        let s = st.lock_or_recover();
        Arc::clone(&s.cfg)
    };
    match cfg.revision(&id, rev) {
        Some(r) => Json(json!({
            "node": id,
            "rev": r.rev,
            "ini": r.ini,
        }))
        .into_response(),
        None => (
            axum::http::StatusCode::NOT_FOUND,
            Json(json!({ "error": "no such revision", "node": id, "rev": rev })),
        )
            .into_response(),
    }
}

/// `GET /api/v1/nodes/{id}/config`
///
/// The current revision, its history (bodies elided - a list does not need
/// them), and the node's own reported rev so the two can be compared at a
/// glance. `drift` is the §7.4 condition: the node is running something the hub
/// did not issue.
async fn node_config(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    let id = normalise_node(&id);
    //--- `history` READS THE WHOLE REVISION FILE from disk (each line carries
    //--- a full ini body), and `for_node` clones every command. Doing that
    //--- under the shared mutex stalled the ZMQ router thread for the length
    //--- of a file read - on an endpoint the dashboard hits every time the
    //--- config modal opens. Grab the handles under the lock, read outside.
    let (cfg, cmd_store, node_rev, current_setting, current_setting_ts) = {
        let s = st.lock_or_recover();
        let (current_setting, current_setting_ts) = match s.node_current_ini.get(&id) {
            Some(c) => (Some(c.ini.clone()), Some(c.ts)),
            None => (None, None),
        };
        (
            Arc::clone(&s.cfg),
            Arc::clone(&s.cmds),
            s.node_rev.get(&id).copied().unwrap_or(0),
            current_setting,
            current_setting_ts,
        )
    };
    let cur = cfg.current(&id);
    let hist = cfg.history(&id, 50);
    let cmds: Vec<Value> = cmd_store
        .for_node(&id)
        .into_iter()
        .map(command_json)
        .collect();
    let hub_rev = cur.as_ref().map(|r| r.rev).unwrap_or(0);
    Json(json!({
        "node": id,
        "managed": cur.is_some(),
        "hub_rev": hub_rev,
        "node_rev": node_rev,
        "current_setting": current_setting,
        "current_setting_ts": current_setting_ts,
        //--- Only meaningful once the hub manages this node. Before that the
        //--- node's number is its own and comparing them would invent a drift
        //--- that is really just "the hub has not taken over yet".
        "in_sync": hub_rev > 0 && node_rev == hub_rev,
        "drift": hub_rev > 0 && node_rev > hub_rev,
        "rev": cur.as_ref().map(|r| json!({
            "rev": r.rev,
            "ts": r.ts,
            "actor": r.actor,
            "ip": r.ip,
            "kind": r.kind,
            "from_rev": r.from_rev,
            "ini": r.ini,
        })),
        "history": Value::Array(hist),
        "commands": Value::Array(cmds),
        "writes_enabled": st.lock_or_recover().writes,
    }))
}

/// `PUT /api/v1/nodes/{id}/config` — body is the whole ini, verbatim.
///
/// `202 Accepted`, not 200: the change has been RECORDED, not applied. It
/// reaches the node asynchronously and its result arrives as an `ACK`, which is
/// why the plan's §16 says every write answers with a `command_id`.
async fn put_node_config(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path(id): Path<String>,
    body: String,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // M9: operator or admin (the plan's §17.2 matrix).
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let id = normalise_node(&id);
    //--- The ACTOR is the session's user id, never the literal "operator".
    //--- An audit trail that records a role instead of a person cannot answer
    //--- "who pushed this config", which is the first question anyone asks
    //--- after an incident - and M9 exists precisely so there IS a person.
    let actor = sess.user_id.clone();
    let (writes, is_primary, node_rev) = {
        let s = st.lock_or_recover();
        (
            s.writes,
            s.cluster.is_primary(),
            s.node_rev.get(&id).copied().unwrap_or(0),
        )
    };

    if !is_primary {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }

    //--- The gate. Off by default, and the refusal says why rather than just
    //--- 403-ing: an operator who set this up and forgot the flag should be
    //--- able to read the fix off the response.
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "error": "writes are disabled",
                "detail": "this hub was started with --writes off. \
                           Restart without --writes off (or with --writes on) to allow config changes.",
                "why": "the hub-side write gate. The role check (operator or \
                        admin, M9) is the front door; this is the back one",
            })),
        )
            .into_response();
    }
    if !id.starts_with("receiver:") {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "only a receiver has a config",
                "node": id,
            })),
        )
            .into_response();
    }
    if let Err(e) = crate::config::validate_ini(&body) {
        //--- Rejected HERE rather than stored and pushed. A node that refuses a
        //--- config answers OK=0, and the hub would then re-push it on every REG
        //--- comparison - so the bad config would be a permanent condition
        //--- rather than a mistake somebody corrects.
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "not a usable ini", "detail": e, "node": id })),
        )
            .into_response();
    }

    //--- The three stores each have their OWN mutex and each call fsyncs.
    //--- Holding the global state lock across them stalled the ZMQ router
    //--- thread for three disk flushes per push - the same bug class as the
    //--- login hash. Cloning the Arcs out costs one short lock and nothing
    //--- else: the stores are internally synchronised and the revision
    //--- counter is monotonic under their own lock, so two concurrent pushes
    //--- still cannot mint the same revision.
    let (cfg, cmds, audit) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cfg), Arc::clone(&s.cmds), Arc::clone(&s.audit))
    };
    //--- Disabled is a configuration choice (503); a failed write is a disk
    //--- problem (500) and MUST NOT be reported as an accepted revision.
    let rev = match cfg.put(&id, &body, &actor, "", "push", node_rev) {
        Ok(r) => r,
        Err(crate::config::StoreError::Disabled) => {
            return (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "error": "the config store is disabled (--config none)" })),
            )
                .into_response()
        }
        Err(e) => {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.detail(), "node": id })),
            )
                .into_response()
        }
    };

    let cmd = cmds.issue_cfg(&id, rev.rev, &actor, "");
    audit.record(
        &actor,
        "",
        "config.changed",
        &id,
        None,
        Some(json!({
            "rev": rev.rev, "id": cmd.id, "ini_bytes": body.len(),
            "node_rev_before": node_rev,
        })),
        "ok",
    );

    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "node": id,
            "rev": rev.rev,
            "command_id": cmd.id,
            "state": cmd.state,
            "poll": format!("/api/v1/commands/{}", cmd.id),
        })),
    )
        .into_response()
}

/// `POST /api/v1/nodes/{id}/config/rollback/{rev}`
///
/// Appends a NEW revision carrying the old body - see `config.rs`. The response
/// says both numbers, because "rolled back to 3" and "now at 9" are different
/// facts and an operator needs both.
async fn rollback_node_config(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path((id, to_rev)): Path<(String, u64)>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // M9: operator or admin (the plan's §17.2 matrix).
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let id = normalise_node(&id);
    if !id.starts_with("receiver:") {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "only receivers accept configs", "node": id })),
        )
            .into_response();
    }
    let (writes, is_primary) = {
        let s = st.lock_or_recover();
        (s.writes, s.cluster.is_primary())
    };
    if !is_primary {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({ "error": "writes are disabled", "detail": "restart with --writes on" })),
        )
            .into_response();
    }
    let node_rev = {
        let s = st.lock_or_recover();
        s.node_rev.get(&id).copied().unwrap_or(0)
    };
    let actor = sess.user_id.clone();
    //--- Stores cloned out of the state lock: each fsyncs under its own
    //--- mutex, and none of them needs the global one. See put_node_config.
    let (cfg, cmds, audit) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cfg), Arc::clone(&s.cmds), Arc::clone(&s.audit))
    };
    let r = match cfg.rollback(&id, to_rev, &actor, "") {
        Ok(r) => r,
        Err(crate::config::StoreError::NotFound) => {
            return (
                axum::http::StatusCode::NOT_FOUND,
                Json(json!({
                    "error": "no such revision",
                    "node": id, "rev": to_rev,
                    "detail": "a rollback to a revision that never existed is not a rollback",
                })),
            )
                .into_response()
        }
        Err(crate::config::StoreError::Disabled) => {
            return (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "error": "config store is disabled (--config none)", "node": id })),
            )
                .into_response()
        }
        Err(e) => {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.detail(), "node": id })),
            )
                .into_response()
        }
    };
    let cmd = cmds.issue_cfg(&id, r.rev, &actor, "");
    audit.record(
        &actor,
        "",
        "config.rolled_back",
        &id,
        Some(json!({ "to_rev": to_rev })),
        Some(json!({ "rev": r.rev, "id": cmd.id, "node_rev_before": node_rev })),
        "ok",
    );
    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "node": id,
            "rolled_back_to": to_rev,
            "rev": r.rev,
            "command_id": cmd.id,
            "poll": format!("/api/v1/commands/{}", cmd.id),
            "state": cmd.state,
        })),
    )
        .into_response()
}

/// `GET /api/v1/config` — every node the hub holds a config for.
///
/// The operator's starting point: "what is this hub managing, and is each one
/// in step". Without it the only way to find out is to guess node ids and fetch
/// them one at a time.
async fn config_list(State(st): State<SharedState>) -> Json<Value> {
    let (nodes, path, enabled, writes) = {
        let s = st.lock_or_recover();
        let rows: Vec<Value> = s
            .cfg
            .nodes()
            .into_iter()
            .map(|(node, rev)| {
                let node_rev = s.node_rev.get(&node).copied().unwrap_or(0);
                json!({
                    "node": node,
                    "hub_rev": rev,
                    "node_rev": node_rev,
                    "in_sync": node_rev == rev,
                    //--- The node reporting HIGHER than the hub issued is the
                    //--- §7.4 drift condition, surfaced where it will be seen.
                    "drift": node_rev > rev,
                })
            })
            .collect();
        (
            rows,
            s.cfg.path().display().to_string(),
            s.cfg.enabled(),
            s.writes,
        )
    };
    Json(json!({
        "store_enabled": enabled,
        "store_path": path,
        "writes_enabled": writes,
        "nodes": Value::Array(nodes),
    }))
}

/// `GET /api/v1/commands` and `/api/v1/commands/{id}`.
///
/// `POST /api/v1/nodes/{id}/commands` - body `{"op":"pause"}` (or the bare word).
///
/// `202 Accepted`, not 200: the command has been RECORDED, not applied. It
/// reaches the node asynchronously and its result arrives as an `ACK`, which is
/// why the plan's §16 says every write answers with a `command_id`.
///
/// WHY ONLY RECEIVERS: the four operations are all things a receiver does - stop
/// acting, resume acting, close its mirrors, re-read its own ini. A sender has
/// no such surface, so a command addressed to one is a typo, not an intent, and
/// is refused at the door rather than sent into the void (where it would sit on
/// the ladder for 82 seconds before being reported `unknown` - which reads like
/// "the node did not answer" instead of "you mistyped the role").
async fn post_command(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path(id): Path<String>,
    body: String,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    //--- Parse the operation. Accept either `{"op":"pause"}` or the bare word
    //--- `pause`, because a CLI or a curl one-liner should not have to wrap it.
    let op = {
        let body = body.trim();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
            v.get("op")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| body.to_string())
        } else {
            body.to_string()
        }
    };

    let is_read_only = crate::commands::is_read_only_op(&op);

    // M9: operator or admin (the plan's §17.2 matrix), unless read-only telemetry request.
    if !is_read_only && sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let id = normalise_node(&id);
    let (writes, is_primary, known) = {
        let s = st.lock_or_recover();
        let known = s.reg.nodes().iter().any(|n| n.key == id);
        (s.writes, s.cluster.is_primary(), known)
    };

    if !is_read_only && !is_primary {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }

    //--- The gate. Off by default, and the refusal says why rather than just
    //--- 403-ing: an operator who set this up and forgot the flag should be
    //--- able to read the fix off the response.
    if !is_read_only && !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "error": "writes are disabled",
                "detail": "this hub was started with --writes off. \
                           Restart without --writes off (or with --writes on) to allow commands.",
                "why": "the hub-side write gate. The role check (operator or \
                        admin, M9) is the front door; this is the back one",
            })),
        )
            .into_response();
    }
    if !id.starts_with("receiver:") {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "commands apply to a receiver only",
                "node": id,
            })),
        )
            .into_response();
    }
    if !crate::commands::is_known_op(&op) {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "unknown operation",
                "op": op,
                "known": crate::commands::OPS.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            })),
        )
            .into_response();
    }

    let actor = sess.user_id.clone();
    //--- Out of the state lock: the command journal fsyncs, the audit fsyncs,
    //--- and neither needs the lock the router thread is waiting on.
    let (cmds, audit) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cmds), Arc::clone(&s.audit))
    };
    let cmd = cmds.issue_op(&id, &op, "", &actor, "");
    audit.record(
        &actor,
        "",
        "command.issued",
        &id,
        None,
        Some(json!({ "id": cmd.id, "op": op, "known_node": known })),
        "ok",
    );

    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "node": id,
            "op": cmd.op,
            "command_id": cmd.id,
            "state": cmd.state,
            "poll": format!("/api/v1/commands/{}", cmd.id),
        })),
    )
        .into_response()
}

/// G10: issue an operational command to EVERY known receiver at once.
///
/// One REST call, many commands - and deliberately NO ZMQ broadcast under the
/// hood. Each receiver gets its own `issue_op` call, so every command carries
/// its own per-node id (§5.4 rule 1: two distinct receivers are two distinct
/// commands with distinct ids), walks its own ladder, and lands in the audit
/// individually. A single broadcast frame would be one id shared by N nodes,
/// which is exactly the idempotency model the M4/M5 write path is built on.
///
/// Same gates as the per-node endpoint: 403 behind `--writes off`, 400 for an
/// unknown op. An empty receiver table answers 202 with an empty list - there
/// was nothing to refuse, and the operator should see that plainly rather
/// than have a missing node look like an error.
async fn commands_global(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    body: String,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // M9: operator or admin (the plan's §17.2 matrix).
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    //--- THE GATE, identical to the per-node endpoint's.
    let (writes, is_primary) = {
        let s = st.lock_or_recover();
        (s.writes, s.cluster.is_primary())
    };
    if !is_primary {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "error": "writes are disabled",
                "detail": "this hub was started with --writes off. \
                           Restart it with --writes on to allow commands.",
                "why": "the hub-side write gate; the role check (M9) is the front door",
            })),
        )
            .into_response();
    }

    //--- Parse the operation exactly as the per-node endpoint does.
    let op = {
        let body = body.trim();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
            v.get("op")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| body.to_string())
        } else {
            body.to_string()
        }
    };
    if !crate::commands::is_known_op(&op) {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "unknown operation",
                "op": op,
                "known": crate::commands::OPS.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            })),
        )
            .into_response();
    }

    //--- Every known receiver, in a deterministic order, one command each.
    let nodes: Vec<String> = {
        let s = st.lock_or_recover();
        let mut v: Vec<String> = s
            .reg
            .nodes()
            .iter()
            .filter(|n| n.key.starts_with("receiver:"))
            .map(|n| n.key.clone())
            .collect();
        v.sort();
        v
    };

    let actor = sess.user_id.clone();
    //--- One lock to grab the handles, then N fsync pairs with NO global lock
    //--- held. A fleet-wide `closeall` is exactly when the router thread must
    //--- not be blocked.
    let (cmds, audit) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cmds), Arc::clone(&s.audit))
    };
    let mut issued: Vec<Value> = Vec::new();
    for node in &nodes {
        let cmd = cmds.issue_op(node, &op, "", &actor, "");
        audit.record(
            &actor,
            "",
            "command.issued",
            node,
            None,
            Some(json!({ "id": cmd.id, "op": op, "global": true })),
            "ok",
        );
        issued.push(json!({
            "node": node,
            "command_id": cmd.id,
            "poll": format!("/api/v1/commands/{}", cmd.id),
        }));
    }

    let note = if issued.is_empty() {
        "no receiver is known to this hub yet"
    } else {
        "one command per receiver; each walks its own ladder"
    };

    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "op": op,
            "count": issued.len(),
            "note": note,
            "issued": issued,
        })),
    )
        .into_response()
}

/// The polling fallback the plan's §16 asks for: a write answers `202` and the
/// result arrives over ZMQ, so a caller that is not watching the WebSocket
/// needs somewhere to ask.
async fn commands_list(State(st): State<SharedState>) -> Json<Value> {
    //--- `commands()` clones every tracked command; grab the handle under the
    //--- lock and do the cloning outside it, so a large journal does not hold
    //--- up the router thread.
    let (cmd_store, writes) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cmds), s.writes)
    };
    let list: Vec<Value> = cmd_store.commands().into_iter().map(command_json).collect();
    Json(json!({ "commands": Value::Array(list), "writes_enabled": writes }))
}

async fn command_one(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    let c = { st.lock_or_recover().cmds.command(&id) };
    match c {
        Some(c) => Json(command_json(c)),
        None => Json(json!({ "error": "no such command", "id": id })),
    }
}

fn command_json(c: crate::commands::Command) -> Value {
    json!({
        "id": c.id,
        "node": c.node,
        "kind": c.kind,
        "op": c.op,
        "rev": c.rev,
        "state": c.state,
        "ts": c.ts,
        "attempts": c.attempts,
        "ack_at": c.ack_at,
        "err": c.err,
    })
}

/// `GET /api/v1/alerts` - the M6 ring, newest first.
///
/// Cheap by construction (a bounded in-memory deque, not the append-only
/// audit file), so a dashboard may poll it as often as it likes. The audit
/// file remains the durable record; `?limit=` bounds the answer, not the
/// store.
async fn alerts_list(State(st): State<SharedState>) -> Json<Value> {
    let s = st.lock_or_recover();
    Json(json!({ "alerts": Value::Array(s.alerts.recent_json(200)) }))
}

/// A path segment arrives percent-decoded, but a `ROLE:ACC` key is often typed
/// with the colon left as-is. Accept both rather than 404-ing on the difference.
fn normalise_node(id: &str) -> String {
    id.replace("%3A", ":").replace("%3a", ":")
}

// ---------------------------------------------------------------------------
// Notifications API: external alert channels (Telegram, WeCom, DingTalk, Webhook)
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct NotificationUpsertBody {
    #[serde(default)]
    id: String,
    name: String,
    channel_type: String,
    #[serde(default = "default_notif_enabled")]
    enabled: bool,
    #[serde(default = "default_notif_severity")]
    min_severity: String,
    config: Value,
}

fn default_notif_enabled() -> bool {
    true
}

fn default_notif_severity() -> String {
    "warning".to_string()
}

/// `GET /api/v1/notifications` - the channel list, masked.
///
/// READABLE BY ANY AUTHENTICATED ROLE, deliberately: the dashboard shows the
/// channel table to a viewer (it hides only the "add" button), and gating this
/// to operator would leave a viewer staring at an error panel for a list they
/// are allowed to see.
///
/// What makes that safe is the MASKING, not the role: `safe_json` reduces a
/// webhook URL to scheme + host (`https://hooks.slack.com/***`) because the
/// path of a Slack/Discord webhook IS the credential, and masks every header
/// value and secret-named key. Before that fix this endpoint handed a working
/// capability URL to any viewer, which is a write credential to somebody
/// else's chat channel.
async fn notifications_list(
    State(st): State<SharedState>,
) -> Json<Value> {
    let s = st.lock_or_recover();
    let channels = s.notif_store.lock_or_recover().list_safe();
    Json(json!({ "channels": Value::Array(channels) }))
}

async fn notifications_upsert(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<NotificationUpsertBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }
    if !st.lock_or_recover().cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }

    let id = if b.id.trim().is_empty() {
        format!("chan_{}_{}", unix_secs(), &crate::users::random_token()[..6])
    } else {
        b.id.trim().to_string()
    };

    let notif_store = {
        let s = st.lock_or_recover();
        s.notif_store.clone()
    };

    // N71-02: Validate final unmasked URL asynchronously BEFORE acquiring any lock
    let mut config_for_val = b.config.clone();
    {
        let store = notif_store.lock_or_recover();
        if let Some(existing) = store.get(&id) {
            crate::notifications::merge_unmasked_config(&mut config_for_val, &existing.config, &existing.channel_type);
        }
    }

    if let Some(url) = config_for_val.get("url").or_else(|| config_for_val.get("webhook_url")).and_then(|u| u.as_str()) {
        if let Err(e) = crate::notifications::validate_outgoing_url(url).await {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": e })),
            )
                .into_response();
        }
    }

    let ch = NotificationChannel {
        id: id.clone(),
        name: b.name,
        channel_type: b.channel_type,
        enabled: b.enabled,
        min_severity: b.min_severity,
        config: b.config,
        created_at: 0,
    };

    let (saved, err) = {
        let mut store = notif_store.lock_or_recover();
        match store.upsert(ch) {
            Ok(c) => (Some(c), None),
            Err(e) => (None, Some(e.to_string())),
        }
    };

    if let Some(err) = err {
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": err })),
        )
            .into_response();
    }

    let saved_channel = saved.unwrap();
    //--- Out of the lock: `record` fsyncs.
    let audit = {
        let s = st.lock_or_recover();
        Arc::clone(&s.audit)
    };
    audit.record(
        &sess.user_id,
        "",
        "notification.upsert",
        &id,
        None,
        Some(json!({
            "name": saved_channel.name,
            "type": saved_channel.channel_type,
            "enabled": saved_channel.enabled,
            "min_severity": saved_channel.min_severity
        })),
        "ok",
    );

    Json(json!({ "ok": true, "channel": saved_channel.safe_json() })).into_response()
}

async fn notifications_delete(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path(id): Path<String>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }
    if !st.lock_or_recover().cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": "Standby node is read-only. Modification is only allowed on Primary Hub." })),
        )
            .into_response();
    }

    let removed = {
        let s = st.lock_or_recover();
        let mut store = s.notif_store.lock_or_recover();
        store.remove(&id).unwrap_or(false)
    };

    if removed {
        let audit = {
            let s = st.lock_or_recover();
            Arc::clone(&s.audit)
        };
        //--- Out of the lock: `record` fsyncs.
        audit.record(
            &sess.user_id,
            "",
            "notification.delete",
            &id,
            None,
            None,
            "ok",
        );
        Json(json!({ "ok": true, "id": id })).into_response()
    } else {
        (
            axum::http::StatusCode::NOT_FOUND,
            Json(json!({ "error": "channel not found", "id": id })),
        )
            .into_response()
    }
}

#[derive(serde::Deserialize)]
struct NotificationTestReq {
    id: Option<String>,
    channel: Option<NotificationChannel>,
}

async fn notifications_test(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(req): Json<NotificationTestReq>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let target_channel = if let Some(mut ch) = req.channel {
        if !ch.id.is_empty() {
            let s = st.lock_or_recover();
            let store = s.notif_store.lock_or_recover();
            if let Some(existing) = store.get(&ch.id) {
                // HUB-04: If url was masked (e.g. contains '***') or identical, merge secret credentials from existing channel.
                let orig_url = existing.config.get("url").or_else(|| existing.config.get("webhook_url"));
                let new_url = ch.config.get("url").or_else(|| ch.config.get("webhook_url"));
                let is_unmodified = match (&orig_url, &new_url) {
                    (Some(orig), Some(new)) => orig == new || new.as_str().map(|s| s.contains("***")).unwrap_or(false),
                    (None, None) | (_, None) => true,
                    _ => false,
                };
                if is_unmodified {
                    crate::notifications::merge_unmasked_config(
                        &mut ch.config,
                        &existing.config,
                        &existing.channel_type,
                    );
                }
            }
        }
        ch
    } else if let Some(id) = req.id {
        let s = st.lock_or_recover();
        let store = s.notif_store.lock_or_recover();
        match store.get(&id) {
            Some(c) => c.clone(),
            None => {
                return (
                    axum::http::StatusCode::NOT_FOUND,
                    Json(json!({ "error": "channel not found", "id": id })),
                )
                    .into_response();
            }
        }
    } else {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "either id or channel object is required" })),
        )
            .into_response();
    };

    if target_channel.channel_type == "webhook" {
        if let Some(url) = target_channel.config.get("url").and_then(|u| u.as_str()) {
            if let Err(e) = crate::notifications::validate_outgoing_url(url).await {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "ok": false, "error": e })),
                )
                    .into_response();
            }
        }
    }

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .unwrap_or_default();

    let test_alert = crate::alerts::Alert {
        ts: unix_secs(),
        kind: "test",
        severity: crate::alerts::Severity::Warning,
        node: "hub:selftest".to_string(),
        detail: json!({
            "message": "Manual connection test from Copier Hub Dashboard",
            "operator": sess.user_id,
        }),
    };

    match crate::notifications::send_to_channel(&client, &target_channel, &test_alert).await {
        Ok(res) => Json(json!({ "ok": true, "result": res })).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": err })),
        )
            .into_response(),
    }
}

// ============================================================================
// HA Cluster Endpoints (Phase 2)
// ============================================================================

async fn cluster_status(
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let s = st.lock_or_recover();
    // P1-3 & P2-3: Fast memory accessors & cached file hashes under lock (zero disk I/O)
    let cfg_lines = s.cfg.total_lines();
    let (cmd_lines, max_cmd_seq) = s.cmds.sync_stats();
    let users_hash = crate::cluster::file_sha256(&s.users.path());
    let notif_hash = crate::cluster::file_sha256(&s.notif_store.lock_or_recover().path());
    let curve_clients_hash = crate::cluster::file_sha256(&s.cluster.curve_clients_path);

    let resp = crate::cluster::ClusterStatusResponse {
        ok: true,
        cluster_id: s.cluster.state.cluster_id.clone(),
        hub_id: s.cluster.state.hub_id.clone(),
        role: s.cluster.state.role.clone(),
        epoch: s.cluster.state.epoch,
        writes: s.writes,
        cfg_lines,
        cmd_lines,
        max_cmd_seq,
        users_hash,
        notif_hash,
        curve_clients_hash,
        is_configured_primary: s.cluster.state.is_configured_primary,
        failback_locked: s.cluster.state.failback_locked,
        ts: unix_secs(),
    };
    Json(resp).into_response()
}

async fn cluster_sync(
    State(st): State<SharedState>,
    Json(req): Json<crate::cluster::ClusterSyncRequest>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // DEF-61-06: Capture paths, epoch & total stats inside lock, then perform disk I/O & SHA256 outside lock.
    let (epoch, cfg_path, cmd_path, cfg_enabled, cmd_enabled, users_path, notif_path, curve_clients_path, total_cfg_lines, total_cmd_lines, max_cmd_seq) = {
        let s = st.lock_or_recover();
        if !s.cluster.is_primary() {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": "Only Primary node can serve sync requests." })),
            )
                .into_response();
        }
        let epoch = s.cluster.state.epoch;
        let cfg_path = s.cfg.path().to_path_buf();
        let cmd_path = s.cmds.path().to_path_buf();
        let cfg_enabled = s.cfg.enabled();
        let cmd_enabled = s.cmds.enabled();
        let users_p = s.users.path().to_path_buf();
        let notif_p = s.notif_store.lock_or_recover().path().to_path_buf();
        let curve_p = s.cluster.curve_clients_path.clone();
        let cfg_tot = s.cfg.total_lines();
        let (cmd_tot, max_seq) = s.cmds.sync_stats();
        (epoch, cfg_path, cmd_path, cfg_enabled, cmd_enabled, users_p, notif_p, curve_p, cfg_tot, cmd_tot, max_seq)
    };

    // Calculate file hashes completely outside the shared state lock
    let local_users_hash = crate::cluster::file_sha256(&users_path);
    let local_notif_hash = crate::cluster::file_sha256(&notif_path);
    let local_curve_hash = crate::cluster::file_sha256(&curve_clients_path);

    // DEF-61-07 & BUG-05 & N70-04: Bound max delta lines returned per sync batch.
    // Truncate only incremental deltas (from_line > 0). Full baseline resets (from_line == 0)
    // must return complete snapshot history so replace_all does not truncate active in-flight commands.
    const MAX_SYNC_BATCH: usize = 10000;
    let cfg_delta_lines = if !cfg_enabled || req.from_cfg_line >= total_cfg_lines {
        Vec::new()
    } else {
        crate::config::ConfigStore::read_lines_from_path(&cfg_path, req.from_cfg_line)
            .map(|(mut lines, _)| {
                if req.from_cfg_line > 0 && lines.len() > MAX_SYNC_BATCH {
                    lines.truncate(MAX_SYNC_BATCH);
                }
                lines
            })
            .unwrap_or_default()
    };

    let cmd_delta_lines = if !cmd_enabled || req.from_cmd_line >= total_cmd_lines {
        Vec::new()
    } else {
        crate::commands::CommandStore::read_lines_from_path(&cmd_path, req.from_cmd_line)
            .map(|(mut lines, _, _)| {
                if req.from_cmd_line > 0 && lines.len() > MAX_SYNC_BATCH {
                    lines.truncate(MAX_SYNC_BATCH);
                }
                lines
            })
            .unwrap_or_default()
    };

    //--- The user table carries password digests, and this hub's login proof is
    //--- computed FROM those digests (users.rs login_with_proof). Shipping the
    //--- file over a plaintext cluster channel therefore upgrades "can read one
    //--- file" into "can become admin". Sync is OFF by default and must be
    //--- opted into with MTC_SYNC_USERS=1 on both hubs. (N56-02)
    let users_sync_enabled = std::env::var("MTC_SYNC_USERS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let users_content = if users_sync_enabled && req.users_hash != local_users_hash {
        std::fs::read_to_string(&users_path).ok()
    } else {
        None
    };

    let notif_content = if req.notif_hash != local_notif_hash {
        std::fs::read_to_string(&notif_path).ok()
    } else {
        None
    };

    let curve_clients_content = if req.curve_clients_hash != local_curve_hash {
        std::fs::read_to_string(&curve_clients_path).ok()
    } else {
        None
    };

    let resp = crate::cluster::ClusterSyncResponse {
        ok: true,
        epoch,
        cfg_delta_lines,
        cmd_delta_lines,
        users_content,
        notif_content,
        curve_clients_content,
        total_cfg_lines,
        total_cmd_lines,
        max_cmd_seq,
    };
    Json(resp).into_response()
}

async fn cluster_handover_request(
    State(st): State<SharedState>,
    Json(req): Json<crate::cluster::HandoverRequest>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let mut s = st.lock_or_recover();

    if !s.cluster.is_primary() {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": "Local node is not Primary. Handover rejected."
            })),
        )
            .into_response();
    }

    if s.cluster.state.failback_locked {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": "Failback is locked by operator."
            })),
        )
            .into_response();
    }

    //--- N56-04: a handover request is only meaningful coming FROM a node that
    //--- is itself configured as primary. Without this check any holder of the
    //--- cluster token can force the real primary to close its write gate and
    //--- demote - that is a demotion order, not a handover. The field has
    //--- existed on HandoverRequest since cluster.rs:102 and was never read.
    if !req.is_configured_primary {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": "Handover rejected: requester is not a configured primary"
            })),
        )
            .into_response();
    }

    // H-04 & P2-2 fix: validate from_epoch >= current local epoch and verify from_hub_id
    if req.from_epoch < s.cluster.epoch() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": format!("Handover rejected: from_epoch {} is behind local epoch {}", req.from_epoch, s.cluster.epoch())
            })),
        )
            .into_response();
    }
    if req.from_hub_id.is_empty() || req.from_hub_id == s.cluster.hub_id() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": "Handover rejected: invalid or self from_hub_id"
            })),
        )
            .into_response();
    }
    // P2-2: Verify against known peer if peer status is recorded
    if let Some(peer) = s.cluster.peer_status.as_ref() {
        if !peer.hub_id.is_empty() && peer.hub_id != req.from_hub_id {
            return (
                axum::http::StatusCode::FORBIDDEN,
                Json(json!({
                    "ok": false,
                    "agreed": false,
                    "new_epoch": s.cluster.epoch(),
                    "error": format!("Handover rejected: from_hub_id {} does not match registered peer {}", req.from_hub_id, peer.hub_id)
                })),
            )
                .into_response();
        }
    }

    // Step down atomically on current Primary before agreeing:
    // 1. Close write gate immediately
    s.writes = false;
    //--- R58-06: step down WITHOUT advancing the epoch.
    //---
    //--- This used to be epoch()+1 and then tell the peer about it. The peer
    //--- promotes to max(new_epoch, its own)+1 - also N+1 - so after a handover
    //--- BOTH hubs sat at the same epoch. ADR-04 resolves a split brain with a
    //--- strict `remote.epoch > local.epoch`, which can no longer discriminate,
    //--- and the tie falls through to hub_id lexicographic order: which hub keeps
    //--- writing becomes arbitrary, with no relation to whose data is newer.
    //---
    //--- Staying at N lets the new primary take N+1, strictly above us, so epoch
    //--- stays a usable tie-breaker for every conflict that follows.
    let new_epoch = s.cluster.epoch();
    s.cluster.demote(new_epoch);
    let audit_rec = Arc::clone(&s.audit);

    audit_rec.record(
        "cluster",
        "",
        "cluster.handover_stepped_down",
        &format!("stepped down for {} (new_epoch={})", req.from_hub_id, new_epoch),
        None,
        None,
        "ok",
    );
    println!(
        "[hub] ADR-10 HANDOVER: Stepped down from Primary to Standby for host {} (new_epoch={}). Write gate closed.",
        req.from_hub_id, new_epoch
    );

    Json(crate::cluster::HandoverResponse {
        ok: true,
        agreed: true,
        new_epoch,
        error: None,
    })
    .into_response()
}

async fn cluster_promote(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let mut s = st.lock_or_recover();
    if s.cluster.is_primary() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "This node is already Primary." })),
        )
            .into_response();
    }
    //--- N57-04: jump above whatever the peer currently claims.
    //---
    //--- This used to be promote(None), i.e. local_epoch + 1. A standby that had
    //--- been isolated (local epoch 2) promoting while the real primary runs
    //--- epoch 5 got 3 - and ADR-04 demoted it back within one probe cycle
    //--- (remote.role=="primary" && remote.epoch > local.epoch), silently undoing
    //--- an explicit operator action. Pressing Promote means "this node takes
    //--- over NOW"; the epoch has to say so, not merely increment.
    //---
    //--- When the peer is unreachable its last known epoch is 0, so this
    //--- degrades to the old local+1, which is correct for a lone survivor.
    let peer_ep = s.cluster.peer_status.as_ref().map(|p| p.epoch).unwrap_or(0);
    let target_ep = peer_ep.max(s.cluster.state.epoch) + 1;
    let new_epoch = s.cluster.promote(Some(target_ep));
    s.writes = s.writes_allowed; // P1-2: Respect CLI --writes setting
    let current_writes = s.writes;
    let audit_rec = Arc::clone(&s.audit);
    drop(s);

    audit_rec.record(
        "operator",
        "",
        "cluster.promote",
        &format!("promoted to Primary with epoch {} (writes={})", new_epoch, current_writes),
        None,
        None,
        "ok",
    );
    println!(
        "[hub] OPERATOR PROMOTE: Hub promoted to Primary with epoch {}. Writes={}.",
        new_epoch, current_writes
    );

    Json(json!({
        "ok": true,
        "role": "primary",
        "epoch": new_epoch,
        "writes": current_writes
    }))
    .into_response()
}

#[derive(serde::Deserialize)]
struct FailbackLockBody {
    locked: bool,
}

async fn cluster_failback_lock(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<FailbackLockBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let mut s = st.lock_or_recover();
    s.cluster.set_failback_lock(b.locked);
    let audit_rec = Arc::clone(&s.audit);
    drop(s);

    audit_rec.record(
        "operator",
        "",
        "cluster.failback_lock",
        &format!("set failback_locked={}", b.locked),
        None,
        None,
        "ok",
    );

    Json(json!({ "ok": true, "failback_locked": b.locked })).into_response()
}

async fn cluster_failback_now(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (peer_url, token, epoch, hub_id, is_configured_primary) = {
        let s = st.lock_or_recover();
        if s.cluster.is_primary() {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "This node is already Primary." })),
            )
                .into_response();
        }
        if s.cluster.peer_url.is_empty() {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "No peer URL configured." })),
            )
                .into_response();
        }
        if !s.cluster.state.is_configured_primary {
            return (
                axum::http::StatusCode::FORBIDDEN,
                Json(json!({ "error": "Failback is only available to the configured Primary node." })),
            )
                .into_response();
        }
        (
            s.cluster.peer_url.clone(),
            s.cluster.cluster_token.clone(),
            s.cluster.epoch(),
            s.cluster.hub_id().to_string(),
            s.cluster.state.is_configured_primary,
        )
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap_or_default();

    let handover_url = format!("{}/api/v1/cluster/handover-request", peer_url);
    let h_req = crate::cluster::HandoverRequest {
        from_hub_id: hub_id,
        from_epoch: epoch,
        is_configured_primary,
        reason: "manual_failback_now".to_string(),
    };

    let resp = client
        .post(&handover_url)
        .header("Authorization", format!("Bearer {}", token))
        .json(&h_req)
        .send()
        .await;

    match resp {
        Ok(r) if r.status().is_success() => {
            if let Ok(h_data) = r.json::<crate::cluster::HandoverResponse>().await {
                if h_data.agreed {
                    let mut s = st.lock_or_recover();
                    // P0-02: Target epoch must strictly exceed both peer and local epochs to prevent tie/split-brain
                    let target_ep = Some(h_data.new_epoch.max(s.cluster.epoch()) + 1);
                    let new_epoch = s.cluster.promote(target_ep);
                    s.writes = s.writes_allowed; // P1-3: Respect CLI --writes setting
                    let current_writes = s.writes;
                    let audit_rec = Arc::clone(&s.audit);
                    drop(s);
                    audit_rec.record(
                        "operator",
                        "",
                        "cluster.manual_failback_success",
                        &format!("recovered Master identity with epoch {} (writes={})", new_epoch, current_writes),
                        None,
                        None,
                        "ok",
                    );
                    println!(
                        "[hub] MANUAL FAILBACK SUCCESS: Master identity recovered with epoch {}! Writes={}.",
                        new_epoch, current_writes
                    );
                    return Json(json!({
                        "ok": true,
                        "role": "primary",
                        "epoch": new_epoch,
                        "writes": current_writes
                    }))
                    .into_response();
                } else {
                    return (
                        axum::http::StatusCode::CONFLICT,
                        Json(json!({
                            "error": h_data.error.unwrap_or_else(|| "Peer rejected handover".to_string())
                        })),
                    )
                        .into_response();
                }
            }
            (
                axum::http::StatusCode::BAD_GATEWAY,
                Json(json!({ "error": "Invalid response from peer" })),
            )
                .into_response()
        }
        Ok(r) => (
            axum::http::StatusCode::BAD_GATEWAY,
            Json(json!({ "error": format!("Peer returned status {}", r.status()) })),
        )
            .into_response(),
        Err(e) => (
            axum::http::StatusCode::BAD_GATEWAY,
            Json(json!({ "error": format!("Cannot connect to peer: {}", e) })),
        )
            .into_response(),
    }
}
