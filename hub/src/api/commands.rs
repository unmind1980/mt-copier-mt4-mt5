//! Per-node config revisions, commands, alerts and notification channels.
//!
//! Split out of api.rs without behaviour change; shares its imports.

use super::*;

/// `GET /api/v1/nodes/{id}/config/revision/{rev}`
///
/// One revision's INI body. This exists because the history LIST no longer
/// carries bodies: fifty revisions of a 100-sender config is ~13 MB, for a
/// dialog that shows fifty rows and usually loads exactly one of them.
///
/// Read-only: no write gate, because reading a config cannot change anything.
pub(crate) async fn node_config_revision(
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
pub(crate) async fn node_config(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
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
pub(crate) async fn put_node_config(
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
    let (writes, is_primary, peer_url, node_rev) = {
        let s = st.lock_or_recover();
        (
            s.writes,
            s.cluster.is_primary(),
            s.cluster.peer_url.clone(),
            s.node_rev.get(&id).copied().unwrap_or(0),
        )
    };

    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
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
    if cmd.state == crate::commands::STATE_UNKNOWN {
        audit.record(
            &actor,
            "",
            "config.changed",
            &id,
            None,
            Some(json!({
                "rev": rev.rev, "id": cmd.id, "error": cmd.err,
            })),
            "failed",
        );
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": cmd.err, "node": id })),
        )
            .into_response();
    }
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
pub(crate) async fn rollback_node_config(
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
    let (writes, is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.writes, s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
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
    if cmd.state == crate::commands::STATE_UNKNOWN {
        audit.record(
            &actor,
            "",
            "config.rolled_back",
            &id,
            Some(json!({ "to_rev": to_rev })),
            Some(json!({ "rev": r.rev, "id": cmd.id, "error": cmd.err })),
            "failed",
        );
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": cmd.err, "node": id })),
        )
            .into_response();
    }
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
pub(crate) async fn config_list(State(st): State<SharedState>) -> Json<Value> {
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
pub(crate) async fn post_command(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path(id): Path<String>,
    body: String,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    //--- Parse the operation. Accept either `{"op":"pause"}` or the bare word
    //--- `pause`, because a CLI or a curl one-liner should not have to wrap it.
    let (op, args, is_force) = {
        let body = body.trim();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
            let op_str = v.get("op")
                .and_then(|x| x.as_str())
                .unwrap_or(body)
                .to_string();
            let mut args_str = v.get("args")
                .map(|x| {
                    if let Some(s) = x.as_str() {
                        s.to_string()
                    } else if let Some(n) = x.as_i64() {
                        n.to_string()
                    } else {
                        x.to_string()
                    }
                })
                .unwrap_or_default();
            if args_str.is_empty() {
                if let Some(t) = v.get("ticket") {
                    args_str = if let Some(s) = t.as_str() {
                        s.to_string()
                    } else if let Some(n) = t.as_i64() {
                        n.to_string()
                    } else {
                        t.to_string()
                    };
                }
            }
            let force = v.get("force")
                .and_then(|x| x.as_bool())
                .unwrap_or(false);
            (op_str, args_str, force)
        } else {
            (body.to_string(), String::new(), false)
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

    if !is_primary {
        //--- N-02: same rule as the fleet-wide endpoint, and now the same words.
        let peer_url = st.lock_or_recover().cluster.peer_url.clone();
        let hint = if peer_url.is_empty() {
            "No peer is configured.".to_string()
        } else {
            format!("Issue it against the Primary at {}.", peer_url)
        };
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({
                "error": "Standby node does not dispatch commands (read-only queries included).",
                "detail": hint,
                "primary": peer_url,
            })),
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
    let is_pos_query = op == "reqpos" || op == "refreshpos" || op == "refresh";
    if !id.starts_with("receiver:") && !id.starts_with("sender:") {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "unknown node prefix (expected receiver: or sender:)",
                "node": id,
            })),
        )
            .into_response();
    }
    if id.starts_with("sender:") && !is_pos_query {
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

    if op == "close" && args.trim().is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "close command requires ticket in 'args' or 'ticket' field",
                "op": op,
            })),
        )
            .into_response();
    }

    static LAST_REQPOS: std::sync::Mutex<Option<std::collections::HashMap<String, Instant>>> = std::sync::Mutex::new(None);
    if op == "reqpos" && !is_force {
        let mut guard = LAST_REQPOS.lock().unwrap_or_else(|e| e.into_inner());
        let map = guard.get_or_insert_with(std::collections::HashMap::new);
        //--- H-05: Auto-prune stale entries (> 5 mins) when table grows
        if map.len() > 64 {
            map.retain(|_, t| t.elapsed() < Duration::from_secs(300));
        }
        if let Some(last_t) = map.get(&id) {
            if last_t.elapsed() < Duration::from_secs(30) {
                return (
                    axum::http::StatusCode::ACCEPTED,
                    Json(json!({
                        "accepted": true,
                        "coalesced": true,
                        "node": id,
                        "op": "reqpos",
                        "message": "coalesced: positions request within 30s window",
                    })),
                )
                    .into_response();
            }
        }
        map.insert(id.clone(), Instant::now());
    } else if op == "reqpos" {
        let mut guard = LAST_REQPOS.lock().unwrap_or_else(|e| e.into_inner());
        let map = guard.get_or_insert_with(std::collections::HashMap::new);
        if map.len() > 64 {
            map.retain(|_, t| t.elapsed() < Duration::from_secs(300));
        }
        map.insert(id.clone(), Instant::now());
    }

    let actor = sess.user_id.clone();
    //--- Out of the state lock: the command journal fsyncs, the audit fsyncs,
    //--- and neither needs the lock the router thread is waiting on.
    let (cmds, audit) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cmds), Arc::clone(&s.audit))
    };
    let cmd = cmds.issue_op(&id, &op, &args, &actor, "");
    // BUG-85-03: Validate that command was successfully persisted before returning 202 Accepted
    if cmd.state == crate::commands::STATE_UNKNOWN && !cmd.err.is_empty() {
        audit.record(
            &actor,
            "",
            "command.issued",
            &id,
            None,
            Some(json!({ "id": cmd.id, "op": op, "args": args, "known_node": known, "error": cmd.err })),
            "failed",
        );
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "error": cmd.err,
                "node": id,
                "op": op,
            })),
        )
            .into_response();
    }

    audit.record(
        &actor,
        "",
        "command.issued",
        &id,
        None,
        Some(json!({ "id": cmd.id, "op": op, "args": args, "known_node": known })),
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
pub(crate) async fn commands_global(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    body: String,
) -> axum::response::Response {
    use axum::response::IntoResponse;

    //--- Parse the operation and optional arguments FIRST (BUG-85-05) to check read-only ops.
    let (op, args, is_force) = {
        let body = body.trim();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
            let o = v.get("op")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| body.to_string());
            // HUB-07: Symmetrize with post_command to parse integer ticket/args
            let mut a = v.get("args")
                .map(|x| {
                    if let Some(s) = x.as_str() {
                        s.to_string()
                    } else if let Some(n) = x.as_i64() {
                        n.to_string()
                    } else {
                        x.to_string()
                    }
                })
                .unwrap_or_default();
            if a.is_empty() {
                if let Some(t) = v.get("ticket") {
                    a = if let Some(s) = t.as_str() {
                        s.to_string()
                    } else if let Some(n) = t.as_i64() {
                        n.to_string()
                    } else {
                        t.to_string()
                    };
                }
            }
            let force = v.get("force").and_then(|x| x.as_bool()).unwrap_or(false);
            (o, a, force)
        } else {
            (body.to_string(), String::new(), false)
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

    let is_read_only = crate::commands::is_read_only_op(&op);

    // M9: operator or admin for state-changing commands; viewers allowed for read-only ops (like reqpos).
    if !is_read_only && sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    //--- THE GATE, identical to the per-node endpoint's.
    let (writes, is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.writes, s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    //--- N-02: a Standby accepts NO command, not even a read-only one.
    //---
    //--- F-14 opened this for reqpos/reqcfg on the theory that "a pure query is
    //--- safe on a read-only node". It is not: the dispatcher (`due_gated`) only
    //--- runs on the Primary, so the command was journaled here, answered 202,
    //--- and never sent to anyone - it did not even reach `unknown`, because that
    //--- transition also comes from the dispatcher. The operator saw "accepted"
    //--- and a dashboard that never refreshed. An honest 409 that names the
    //--- Primary is strictly better than a 202 that does nothing; forwarding the
    //--- query to the Primary is a separate change (it needs a cluster-token
    //--- endpoint, because a session token from this hub is not valid there
    //--- unless MTC_SYNC_USERS is on).
    if !is_primary {
        let hint = if peer_url.is_empty() {
            "No peer is configured.".to_string()
        } else {
            format!("Issue it against the Primary at {}.", peer_url)
        };
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({
                "error": "Standby node does not dispatch commands (read-only queries included).",
                "detail": hint,
                "primary": peer_url,
            })),
        )
            .into_response();
    }
    // BUG-85-05: Allow read-only operations (reqpos/reqcfg) even when --writes off
    if !is_read_only && !writes {
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

    // N83-09: Prevent dispatching close command with empty ticket/args across fleet
    if op == "close" && args.trim().is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "close command requires ticket in 'args' or 'ticket' field",
                "op": op,
            })),
        )
            .into_response();
    }
    //--- B2: `close` is NOT a fleet-wide operation.
    //--- A broker ticket is unique only WITHIN one account. Fanning "close ticket
    //--- 12345" out to every receiver means any other account that happens to own
    //--- the same ticket number - routine for accounts opened together at the same
    //--- broker - gets an unrelated position closed. The operator cannot see that
    //--- account's ticket list from this dialog, so there is no way for them to
    //--- discover the mistake before it executes.
    //--- pause / resume / closeall / reload / reqpos / reqcfg ARE account-scoped
    //--- and stay fleet-wide.
    if op == "close" {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "close cannot be issued fleet-wide",
                "detail": "a ticket is unique only inside one account; use \
                           POST /api/v1/nodes/{node}/commands with op=close to \
                           target the account that owns it",
                "op": op,
            })),
        )
            .into_response();
    }

    // BUG-07: Coalesce fleet-wide reqpos commands within a 30-second window
    static LAST_FLEET_REQPOS: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);
    if op == "reqpos" && !is_force {
        let mut guard = LAST_FLEET_REQPOS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(last_t) = *guard {
            if last_t.elapsed() < Duration::from_secs(30) {
                return (
                    axum::http::StatusCode::ACCEPTED,
                    Json(json!({
                        "accepted": true,
                        "coalesced": true,
                        "op": "reqpos",
                        "message": "coalesced: fleet-wide positions request within 30s window",
                    })),
                )
                    .into_response();
            }
        }
        *guard = Some(Instant::now());
    } else if op == "reqpos" {
        let mut guard = LAST_FLEET_REQPOS.lock().unwrap_or_else(|e| e.into_inner());
        *guard = Some(Instant::now());
    }

    //--- Every known target node in deterministic order.
    //--- LOGIC-03: Pos queries (reqpos/refreshpos/refresh) query both senders & receivers
    let is_pos_query = op == "reqpos" || op == "refreshpos" || op == "refresh";
    let nodes: Vec<String> = {
        let s = st.lock_or_recover();
        let mut v: Vec<String> = s
            .reg
            .nodes()
            .iter()
            .filter(|n| n.key.starts_with("receiver:") || (is_pos_query && n.key.starts_with("sender:")))
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
    let mut any_failed = false;
    for node in &nodes {
        let cmd = cmds.issue_op(node, &op, &args, &actor, "");
        // BUG-85-03: Validate persistence per node command
        if cmd.state == crate::commands::STATE_UNKNOWN && !cmd.err.is_empty() {
            any_failed = true;
            audit.record(
                &actor,
                "",
                "command.issued",
                node,
                None,
                Some(json!({ "id": cmd.id, "op": op, "global": true, "error": cmd.err })),
                "failed",
            );
            issued.push(json!({
                "node": node,
                "command_id": cmd.id,
                "error": cmd.err,
                "failed": true,
            }));
        } else {
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
    }

    let note = if issued.is_empty() {
        "no receiver is known to this hub yet"
    } else if any_failed {
        "some commands failed to queue to journal"
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
pub(crate) async fn commands_list(
    State(st): State<SharedState>,
    axum::extract::Query(q): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Json<Value> {
    //--- H-03: `commands()` clones every tracked command; grab the handle under the
    //--- lock and do the cloning outside it.
    //--- When the caller only wants writes_enabled (e.g. dashboard boots with ?limit=0),
    //--- return immediately without cloning or sorting the 30-day journal.
    let (cmd_store, writes) = {
        let s = st.lock_or_recover();
        (Arc::clone(&s.cmds), s.writes)
    };
    let limit = q
        .get("limit")
        .and_then(|s| s.trim().parse::<usize>().ok())
        .unwrap_or(200);

    let list: Vec<Value> = if limit == 0 {
        Vec::new()
    } else {
        cmd_store
            .commands_recent(limit)
            .into_iter()
            .map(command_json)
            .collect()
    };
    Json(json!({ "commands": Value::Array(list), "writes_enabled": writes }))
}

pub(crate) async fn command_one(State(st): State<SharedState>, Path(id): Path<String>) -> Json<Value> {
    //--- H-02: Don't read CommandStore inside the Shared lock. CommandStore::command
    //--- takes inner mutex which can wait on fsync in append_many. Grab handle, query outside.
    let cmd_store = {
        let s = st.lock_or_recover();
        Arc::clone(&s.cmds)
    };
    let c = cmd_store.command(&id);
    match c {
        Some(c) => Json(command_json(c)),
        None => Json(json!({ "error": "no such command", "id": id })),
    }
}

pub(crate) fn command_json(c: crate::commands::Command) -> Value {
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
pub(crate) async fn alerts_list(State(st): State<SharedState>) -> Json<Value> {
    let s = st.lock_or_recover();
    Json(json!({ "alerts": Value::Array(s.alerts.recent_json(200)) }))
}

/// A path segment arrives percent-decoded, but a `ROLE:ACC` key is often typed
/// with the colon left as-is. Accept both rather than 404-ing on the difference.
pub(crate) fn normalise_node(id: &str) -> String {
    id.replace("%3A", ":").replace("%3a", ":")
}

// ---------------------------------------------------------------------------
// Notifications API: external alert channels (Telegram, WeCom, DingTalk, Webhook)
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
pub(crate) struct NotificationUpsertBody {
    #[serde(default)]
    id: String,
    name: String,
    channel_type: String,
    #[serde(default = "default_notif_enabled")]
    enabled: bool,
    #[serde(default = "default_notif_severity")]
    min_severity: String,
    #[serde(default)]
    lang: String,
    config: Value,
}

pub(crate) fn default_notif_enabled() -> bool {
    true
}

pub(crate) fn default_notif_severity() -> String {
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
pub(crate) async fn notifications_list(
    State(st): State<SharedState>,
) -> Json<Value> {
    let notif_store = {
        let s = st.lock_or_recover();
        s.notif_store.clone()
    };
    let channels = notif_store.lock_or_recover().list_safe();
    Json(json!({ "channels": Value::Array(channels) }))
}

pub(crate) async fn notifications_upsert(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<NotificationUpsertBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }
    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
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

    let primary_url = config_for_val.get("url").and_then(|v| v.as_str());
    let hook_url = config_for_val.get("webhook_url").and_then(|v| v.as_str());
    let is_wechat_type = b.channel_type == "wechat" || b.channel_type == "xtuis";
    for (idx, opt_u) in [primary_url, hook_url].iter().enumerate() {
        if let Some(u) = opt_u {
            if is_wechat_type && idx == 1 && !u.trim().is_empty() && !u.trim().starts_with("http://") && !u.trim().starts_with("https://") {
                continue;
            }
            if idx == 1 && primary_url.is_some() && u.trim().is_empty() {
                continue;
            }
            if let Err(e) = crate::notifications::validate_outgoing_url(u).await {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": e })),
                )
                    .into_response();
            }
        }
    }

    // N83-05 & N84-14: Validate WeChat token/key/webhook_url if URL or raw token
    if b.channel_type == "wechat" || b.channel_type == "xtuis" {
        let tok_val = config_for_val.get("token")
            .or_else(|| config_for_val.get("key"))
            .or_else(|| config_for_val.get("webhook_url"))
            .and_then(|t| t.as_str());
        if let Some(tok) = tok_val {
            let t = tok.trim();
            if t.starts_with("http://") || t.starts_with("https://") {
                if let Err(e) = crate::notifications::validate_outgoing_url(t).await {
                    return (
                        axum::http::StatusCode::BAD_REQUEST,
                        Json(json!({ "error": e })),
                    )
                        .into_response();
                }
            } else if !t.is_empty() {
                let clean = t.trim_end_matches(".send");
                if !clean.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                    return (
                        axum::http::StatusCode::BAD_REQUEST,
                        Json(json!({ "error": "WeChat (Xtuis) token contains invalid characters" })),
                    )
                        .into_response();
                }
            }
        }
    }

    if b.channel_type == "wecom" || b.channel_type == "wechat_work" {
        if let Some(key) = config_for_val.get("key").and_then(|v| v.as_str()) {
            if !key.is_empty() && !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "WeCom webhook key contains invalid characters" })),
                )
                    .into_response();
            }
        }
    }
    if b.channel_type == "dingtalk" {
        if let Some(tok) = config_for_val.get("access_token").and_then(|v| v.as_str()) {
            if !tok.is_empty() && !tok.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "DingTalk access_token contains invalid characters" })),
                )
                    .into_response();
            }
        }
    }
    if b.channel_type == "telegram" {
        if let Some(tok) = config_for_val.get("bot_token").and_then(|v| v.as_str()) {
            if !tok.is_empty() && !tok.chars().all(|c| c.is_ascii_alphanumeric() || c == ':' || c == '_' || c == '-') {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "Telegram bot_token contains invalid characters" })),
                )
                    .into_response();
            }
        }
    }

    let (existing_lang, existing_created_at) = {
        let store = notif_store.lock_or_recover();
        match store.get(&id) {
            Some(c) => (Some(c.lang.clone()), c.created_at),
            None => (None, 0),
        }
    };
    // WEB-01: Preserve channel's existing language if omitted in request (e.g. toggle active)
    let lang = if !b.lang.trim().is_empty() {
        b.lang.trim().to_string()
    } else if let Some(l) = b.config.get("lang").and_then(|v| v.as_str()).filter(|s| !s.trim().is_empty()) {
        l.trim().to_string()
    } else {
        existing_lang.unwrap_or_else(|| "zh-CN".to_string())
    };

    let ch = NotificationChannel {
        id: id.clone(),
        name: b.name,
        channel_type: b.channel_type,
        enabled: b.enabled,
        min_severity: b.min_severity,
        lang,
        config: b.config,
        created_at: existing_created_at,
    };

    let saved_res = {
        let mut store = notif_store.lock_or_recover();
        store.upsert(ch)
    };

    let saved = match saved_res {
        Ok(c) => c,
        Err(e) => {
            let status = if e.kind() == std::io::ErrorKind::InvalidInput {
                axum::http::StatusCode::BAD_REQUEST
            } else {
                axum::http::StatusCode::INTERNAL_SERVER_ERROR
            };
            return (status, Json(json!({ "error": e.to_string() }))).into_response();
        }
    };
    let saved_channel = saved;
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

pub(crate) async fn notifications_delete(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Path(id): Path<String>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }
    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
    }

    let notif_store = {
        let s = st.lock_or_recover();
        s.notif_store.clone()
    };

    // N73-05 & M3: Call store.remove outside SharedState mutex, and distinguish I/O errors from 404 Not Found
    let remove_res = {
        let mut store = notif_store.lock_or_recover();
        store.remove(&id)
    };

    match remove_res {
        Ok(true) => {
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
        }
        Ok(false) => {
            (
                axum::http::StatusCode::NOT_FOUND,
                Json(json!({ "error": "channel not found", "id": id })),
            )
                .into_response()
        }
        Err(e) => {
            eprintln!("[hub] failed to delete notification channel {}: {}", id, e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("failed to delete channel: {}", e), "id": id })),
            )
                .into_response()
        }
    }
}

#[derive(serde::Deserialize)]
pub(crate) struct NotificationTestReq {
    id: Option<String>,
    channel: Option<NotificationChannel>,
}

pub(crate) async fn notifications_test(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(req): Json<NotificationTestReq>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }

    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Notification Testing").into_response();
    }
    let notif_enabled = {
        let s = st.lock_or_recover();
        let en = s.notif_store.lock_or_recover().enabled();
        en
    };
    if !notif_enabled {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Notification subsystem is disabled on this hub (--notifications none)" })),
        )
            .into_response();
    }

    let target_channel = if let Some(mut ch) = req.channel {
        if !ch.id.is_empty() {
            let s = st.lock_or_recover();
            let store = s.notif_store.lock_or_recover();
            if let Some(existing) = store.get(&ch.id) {
                // BUG-11: Merge unmasked credentials field-by-field from existing channel
                crate::notifications::merge_unmasked_config(
                    &mut ch.config,
                    &existing.config,
                    &existing.channel_type,
                );
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

    static TEST_HTTP_CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    let client = TEST_HTTP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(8))
            .build()
            .unwrap_or_default()
    });

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
        Err(err) => {
            // OPT-12: Map SSRF/URL and token validation errors to 400 Bad Request uniformly across all channels
            let status = if err.contains("prohibited")
                || err.contains("must begin with")
                || err.contains("userinfo")
                || err.contains("no host")
                || err.contains("Invalid URL")
                || err.contains("missing")
                || err.contains("cannot be empty")
                || err.contains("invalid characters")
                || err.contains("cannot appear in a token")
                || err.contains("Unknown channel type")
            {
                axum::http::StatusCode::BAD_REQUEST
            } else {
                axum::http::StatusCode::BAD_GATEWAY
            };
            (
                status,
                Json(json!({ "ok": false, "error": err })),
            )
                .into_response()
        }
    }
}

// ============================================================================
// HA Cluster Endpoints (Phase 2)
// ============================================================================
