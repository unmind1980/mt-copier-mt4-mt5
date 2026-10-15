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
use std::time::Instant;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::response::Html;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};

use crate::audit::Audit;
use crate::commands::CommandStore;
use crate::alerts::AlertEngine;
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
    /// Whether the hub may change a node's config at all. `--writes off` by
    /// default; the PUT endpoint is the only thing that consults it, and the
    /// CFG emitter is the only thing that acts on it.
    pub writes: bool,
    /// The last `REV` each node reported in its REG. Runtime state, not
    /// persisted: it is only used to decide whether to push, and a hub restart
    /// gets a fresh answer from the next REG.
    pub node_rev: std::collections::HashMap<String, u64>,
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
}

pub type SharedState = Arc<Mutex<Shared>>;

impl Shared {
    pub fn new(
        zmq_port: u16,
        audit: Arc<Audit>,
        cfg: Arc<ConfigStore>,
        cmds: Arc<CommandStore>,
        writes: bool,
    ) -> Self {
        Shared {
            reg: Registry::new(),
            pos: Positions::new(),
            mirrors: std::collections::HashMap::new(),
            started: Instant::now(),
            zmq_port,
            audit,
            cfg,
            cmds,
            writes,
            node_rev: std::collections::HashMap::new(),
            alerts: AlertEngine::new(),
            curve_public: String::new(),
            curve_learn: false,
            users: UserStore::new(),
            auth_enabled: true,
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
    })
}

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
fn nodes_json_list(reg: &Registry, pos: &Positions, now: Instant) -> Vec<Value> {
    reg.sorted()
        .iter()
        .map(|n| {
            let mut j = node_json(n, now);
            //--- A sender ALSO carries what the hub has seen it hold. This is
            //--- the join that makes the NODES table's POS column real: the
            //--- data has been in the hub since M3 and the column was reading
            //--- a field no node list ever included.
            //---
            //--- `null` for a receiver, and for a sender that has registered
            //--- but whose first SNAP has not arrived yet - which is not an
            //--- error, it is "nothing to report yet".
            let pv = if n.role == Role::Sender {
                pos.sorted()
                    .iter()
                    .find(|(sid, _)| *sid == n.acc)
                    .map(|(_, v)| {
                        json!({
                            "count": v.count,
                            "lots": trim_lots(v.lots),
                            "receipt": v.receipt,
                        })
                    })
            } else {
                None
            };
            j.as_object_mut()
                .unwrap()
                .insert("positions".to_string(), pv.unwrap_or(Value::Null));
            j
        })
        .collect()
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
            })
        })
        .collect()
}

/// `GET /api/v1/nodes`
async fn nodes(State(st): State<SharedState>) -> Json<Value> {
    let (nodes, counts, uptime) = {
        let s = st.lock().unwrap();
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
        let s = st.lock().unwrap();
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
                    if let Some((_sid, v)) =
                        s.pos.top(64).into_iter().find(|(sid, _)| *sid == n.acc)
                    {
                        obj.insert(
                            "positions".to_string(),
                            json!({
                                "count": v.count,
                                "lots": trim_lots(v.lots),
                                "receipt": v.receipt,
                                "symbols": symbols_json(v),
                                "snaps": v.snaps,
                            }),
                        );
                    } else {
                        obj.insert("positions".to_string(), Value::Null);
                    }
                }

                if n.role == Role::Receiver {
                    let targets: Vec<Value> = s
                        .mirrors
                        .iter()
                        .flat_map(|(sender, recvs)| {
                            recvs.keys().map(move |_| sender.clone())
                        })
                        .filter(|sender| {
                            s.mirrors
                                .get(sender)
                                .map(|r| r.contains_key(&n.acc))
                                .unwrap_or(false)
                        })
                        .map(Value::String)
                        .collect();
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
        let s = st.lock().unwrap();
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
        let s = st.lock().unwrap();
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

    let (records, stats, enabled, path) = {
        let s = st.lock().unwrap();
        let (recs, stats) = s.audit.read(limit, since);
        (recs, stats, s.audit.enabled(), s.audit.path().display().to_string())
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
        let s = st.lock().unwrap();
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
        let s = st.lock().unwrap();
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
async fn dashboard() -> Html<&'static str> {
    Html(DASHBOARD)
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
    axum::extract::Extension(tx): axum::extract::Extension<tokio::sync::broadcast::Sender<()>>,
) -> impl axum::response::IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, st, tx))
}

async fn handle_socket(
    mut socket: WebSocket,
    st: SharedState,
    tx: tokio::sync::broadcast::Sender<()>,
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
            // State changed somewhere else.
            changed = rx.recv() => {
                match changed {
                    Ok(()) => {
                        if socket.send(Message::Text(snapshot_text(&st))).await.is_err() {
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
                if socket.send(Message::Text(snapshot_text(&st))).await.is_err() {
                    break;
                }
            }
        }
    }
}

/// The wire format for a push. A shape the page can switch on, so a later
/// incremental message is a new `t` rather than a change to this one.
fn snapshot_text(st: &SharedState) -> String {
    let body = {
        let s = st.lock().unwrap();
        let now = Instant::now();
        json!({
            "hub_uptime_secs": now.saturating_duration_since(s.started).as_secs(),
            "nodes": Value::Array(nodes_json_list(&s.reg, &s.pos, now)),
            "positions": Value::Array(positions_json_list(&s.pos)),
            "mismatched": s.pos.mismatched,
            "alerts": Value::Array(s.alerts.recent_json(20)),
            "curve": curve_json(&s),
        })
    };
    json!({ "t": "snapshot", "data": body }).to_string()
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

async fn require_session(
    axum::extract::State(st): axum::extract::State<SharedState>,
    mut req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let path = req.uri().path().to_string();
    if path == "/"
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
    //--- --users none: no login exists, so demanding one would make the HTTP
    //--- face unusable. Answer as an anonymous viewer instead - the role gate
    //--- in every write handler still runs, so this remains read-only by
    //--- construction, and a denied write is still audited (actor "anonymous").
    if !st.lock().unwrap().auth_enabled {
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
        let sess = st.lock().unwrap().users.session(&t, unix_secs());
        if let Some(sess) = sess {
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
fn deny(st: &SharedState, sess: &Session, need: &str) -> axum::response::Response {
    use axum::response::IntoResponse;
    st.lock().unwrap().audit.record(
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
struct LoginBody {
    id: String,
    password: String,
}

async fn login(
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<LoginBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let now = unix_secs();
    let r = {
        let mut s = st.lock().unwrap();
        s.users.login(&b.id, &b.password, now)
    };
    match r {
        Ok((token, sess)) => {
            st.lock().unwrap().audit.record(
                &sess.user_id,
                "",
                "auth.login",
                &b.id,
                None,
                Some(json!({ "role": sess.role.as_str() })),
                "ok",
            );
            (
                axum::http::StatusCode::OK,
                [(
                    axum::http::header::SET_COOKIE,
                    format!(
                        "mtc_session={}; HttpOnly; Path=/; SameSite=Strict; Max-Age={}",
                        token, SESSION_IDLE_SECS
                    ),
                )],
                Json(json!({ "user": sess.user_id, "role": sess.role.as_str() })),
            )
                .into_response()
        }
        // Deliberately does NOT say whether the id exists.
        Err(_) => {
            st.lock().unwrap().audit.record(
                &b.id, "", "auth.login", &b.id, None,
                Some(json!({ "why": "invalid credentials" })), "rejected",
            );
            (
                axum::http::StatusCode::UNAUTHORIZED,
                Json(json!({ "error": "invalid credentials" })),
            )
                .into_response()
        }
    }
}

async fn logout(
    axum::extract::State(st): axum::extract::State<SharedState>,
    headers: axum::http::HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let tok = headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(cookie_token);
    let mut who = String::new();
    if let Some(t) = &tok {
        let mut s = st.lock().unwrap();
        if let Some(sess) = s.users.session(t, unix_secs()) {
            who = sess.user_id.clone();
        }
        s.users.logout(t);
    }
    st.lock()
        .unwrap()
        .audit
        .record(&who, "", "auth.logout", &who, None, None, "ok");
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
    let disabled = st.lock().unwrap().auth_enabled == false;
    if disabled {
        return Json(json!({ "user": "anonymous", "role": "viewer",
                            "note": "login disabled (--users none)" }))
        .into_response();
    }
    let tok = headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(cookie_token);
    if let Some(t) = tok {
        if let Some(s) = st.lock().unwrap().users.session(&t, unix_secs()) {
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
    let s = st.lock().unwrap();
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
    let mut s = st.lock().unwrap();
    //--- An EMPTY password means "keep what is there", which is what a role
    //--- change or a disable/enable wants - the dashboard's user table sends
    //--- exactly that, and requiring a password here would silently RESET
    //--- the user's credential every time an admin toggled a switch. A user
    //--- that does not exist yet has nothing to keep, so it is refused.
    let pass = if b.password.is_empty() {
        match s.users.get(&b.id) {
            Some(u) => u.pass.clone(),
            None => {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "a new user needs a password" })),
                )
                    .into_response()
            }
        }
    } else {
        let salt = crate::users::random_token()[..16].to_string();
        hash_password(&b.password, &salt)
    };
    let u = User {
        id: b.id.clone(),
        pass,
        role,
        disabled: b.disabled,
    };
    if let Err(e) = s.users.upsert(u) {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": e })),
        )
            .into_response();
    }
    let _ = s.users.save();
    s.audit.record(
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
    let mut s = st.lock().unwrap();
    match s.users.remove(&id) {
        Ok(()) => {
            let _ = s.users.save();
            s.audit.record(&sess.user_id, "", "user.delete", &id, None, None, "ok");
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
    if b.new.chars().count() < 8 {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "the new password must be at least 8 characters" })),
        )
            .into_response();
    }
    let mut s = st.lock().unwrap();
    if !s.auth_enabled {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({ "error": "login is disabled on this hub (--users none)" })),
        )
            .into_response();
    }
    let old_ok = s
        .users
        .get(&sess.user_id)
        .map(|u| verify_password(&b.old, &u.pass))
        .unwrap_or(false);
    if !old_ok {
        s.audit.record(
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
    if let Err(e) = s.users.set_password(&sess.user_id, &b.new) {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({ "error": e })),
        )
            .into_response();
    }
    let _ = s.users.save();
    //--- The old credential is gone, so every session it minted should be
    //--- too - except this one, which the caller is still using.
    let dropped = s.users.drop_other_sessions(&sess.user_id, Some(&tok.0));
    s.audit.record(
        &sess.user_id,
        "",
        "user.password_changed",
        &sess.user_id,
        None,
        Some(json!({ "other_sessions_ended": dropped })),
        "ok",
    );
    Json(json!({ "ok": true, "other_sessions_ended": dropped })).into_response()
}

/// The router. Versioned under `/api/v1`, because the plan's §16 says a
/// breaking change goes to v2 rather than editing v1 under a deployed
/// dashboard.
pub fn router(st: SharedState, tx: tokio::sync::broadcast::Sender<()>) -> Router {
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
        .route("/api/v1/config", get(config_list))
        .route("/api/v1/commands", get(commands_list).post(commands_global))
        .route("/api/v1/alerts", get(alerts_list))
        .route("/api/v1/commands/:id", get(command_one))
        .route(
            "/api/v1/nodes/:id/commands",
            axum::routing::post(post_command),
        )
        .route("/api/v1/stream", get(ws_handler))
        .route("/api/v1/login", axum::routing::post(login))
        .route("/api/v1/logout", axum::routing::post(logout))
        .route("/api/v1/whoami", get(whoami))
        .route("/api/v1/users", get(users_list).post(users_upsert))
        .route("/api/v1/password", axum::routing::post(change_password))
        .route("/api/v1/users/:id", axum::routing::delete(users_delete))
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
) -> std::result::Result<tokio::sync::broadcast::Sender<()>, String> {
    // (the audit reaches this thread through `st`, which already holds it)
    let (tx, _rx) = tokio::sync::broadcast::channel::<()>(64);
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

/// `GET /api/v1/nodes/{id}/config`
///
/// The current revision, its history (bodies elided - a list does not need
/// them), and the node's own reported rev so the two can be compared at a
/// glance. `drift` is the §7.4 condition: the node is running something the hub
/// did not issue.
async fn node_config(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    let id = normalise_node(&id);
    let (cur, hist, node_rev, cmds) = {
        let s = st.lock().unwrap();
        let cur = s.cfg.current(&id);
        let hist = s.cfg.history(&id, 50);
        let node_rev = s.node_rev.get(&id).copied().unwrap_or(0);
        let cmds: Vec<Value> = s
            .cmds
            .for_node(&id)
            .into_iter()
            .map(command_json)
            .collect();
        (cur, hist, node_rev, cmds)
    };
    let hub_rev = cur.as_ref().map(|r| r.rev).unwrap_or(0);
    Json(json!({
        "node": id,
        "managed": cur.is_some(),
        "hub_rev": hub_rev,
        "node_rev": node_rev,
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
        "writes_enabled": st.lock().unwrap().writes,
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
    let (writes, node_rev, actor) = {
        let s = st.lock().unwrap();
        (
            s.writes,
            s.node_rev.get(&id).copied().unwrap_or(0),
            "operator".to_string(),
        )
    };

    //--- The gate. Off by default, and the refusal says why rather than just
    //--- 403-ing: an operator who set this up and forgot the flag should be
    //--- able to read the fix off the response.
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "error": "writes are disabled",
                "detail": "this hub was started with --writes off (the default). \
                           Restart it with --writes on to allow config changes.",
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

    let rev = {
        let s = st.lock().unwrap();
        s.cfg.put(&id, &body, &actor, "", "push", node_rev)
    };
    let Some(rev) = rev else {
        return (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "the config store is disabled (--config none)" })),
        )
            .into_response();
    };

    let cmd = {
        let s = st.lock().unwrap();
        s.cmds.issue_cfg(&id, rev.rev, "operator", "")
    };
    {
        let s = st.lock().unwrap();
        s.audit.record(
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
    }

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
    let writes = st.lock().unwrap().writes;
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({ "error": "writes are disabled", "detail": "restart with --writes on" })),
        )
            .into_response();
    }
    let node_rev = {
        let s = st.lock().unwrap();
        s.node_rev.get(&id).copied().unwrap_or(0)
    };
    let rolled = {
        let s = st.lock().unwrap();
        s.cfg.rollback(&id, to_rev, "operator", "")
    };
    let Some(r) = rolled else {
        return (
            axum::http::StatusCode::NOT_FOUND,
            Json(json!({
                "error": "no such revision",
                "node": id, "rev": to_rev,
                "detail": "a rollback to a revision that never existed is not a rollback",
            })),
        )
            .into_response();
    };
    let cmd = {
        let s = st.lock().unwrap();
        s.cmds.issue_cfg(&id, r.rev, "operator", "")
    };
    {
        let s = st.lock().unwrap();
        s.audit.record(
            "operator",
            "",
            "config.rolled_back",
            &id,
            Some(json!({ "to_rev": to_rev })),
            Some(json!({ "rev": r.rev, "id": cmd.id, "node_rev_before": node_rev })),
            "ok",
        );
    }
    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "node": id,
            "rolled_back_to": to_rev,
            "rev": r.rev,
            "command_id": cmd.id,
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
        let s = st.lock().unwrap();
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
    // M9: operator or admin (the plan's §17.2 matrix).
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let id = normalise_node(&id);
    let (writes, known) = {
        let s = st.lock().unwrap();
        let known = s.reg.nodes().iter().any(|n| n.key == id);
        (s.writes, known)
    };

    //--- The gate. Off by default, and the refusal says why rather than just
    //--- 403-ing: an operator who set this up and forgot the flag should be
    //--- able to read the fix off the response.
    if !writes {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(json!({
                "error": "writes are disabled",
                "detail": "this hub was started with --writes off (the default). \
                           Restart it with --writes on to allow commands.",
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

    let cmd = {
        let s = st.lock().unwrap();
        s.cmds.issue_op(&id, &op, "", "operator", "")
    };
    {
        let s = st.lock().unwrap();
        s.audit.record(
            "operator",
            "",
            "command.issued",
            &id,
            None,
            Some(json!({ "id": cmd.id, "op": op, "known_node": known })),
            "ok",
        );
    }

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
    let writes = st.lock().unwrap().writes;
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
        let s = st.lock().unwrap();
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

    let mut issued: Vec<Value> = Vec::new();
    {
        let s = st.lock().unwrap();
        for node in &nodes {
            let cmd = s.cmds.issue_op(node, &op, "", "operator", "");
            s.audit.record(
                "operator",
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
    let (list, writes) = {
        let s = st.lock().unwrap();
        (
            s.cmds.commands().into_iter().map(command_json).collect::<Vec<_>>(),
            s.writes,
        )
    };
    Json(json!({ "commands": Value::Array(list), "writes_enabled": writes }))
}

async fn command_one(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    let c = { st.lock().unwrap().cmds.command(&id) };
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
    let s = st.lock().unwrap();
    Json(json!({ "alerts": Value::Array(s.alerts.recent_json(200)) }))
}

/// A path segment arrives percent-decoded, but a `ROLE:ACC` key is often typed
/// with the colon left as-is. Accept both rather than 404-ing on the difference.
fn normalise_node(id: &str) -> String {
    id.replace("%3A", ":").replace("%3a", ":")
}
