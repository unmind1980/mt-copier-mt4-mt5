//! HA cluster endpoints: status, sync, handover, promote, failback, peer.
//!
//! Split out of api.rs without behaviour change; shares its imports.

use super::*;

pub(crate) async fn cluster_status(
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let (cluster_id, hub_id, role, epoch, writes, is_configured_primary, failback_locked, cfg_lines, max_cfg_rev, cfg_enabled, cmd_enabled, cmd_lines, max_cmd_seq, cfg_dirty, cmd_dirty, users_path, notif_path, curve_clients_path, cfg_path, cmd_path, api_cfg_cache, api_cmd_cache) = {
        let s = st.lock_or_recover();
        let (cfg_lines, max_cfg_rev) = s.cfg.sync_stats();
        let cfg_enabled = s.cfg.enabled();
        let cmd_enabled = s.cmds.enabled();
        let (cmd_lines, max_cmd_seq) = s.cmds.sync_stats();
        let cfg_dirty = s.cfg.dirty_seq();
        let cmd_dirty = s.cmds.dirty_seq();
        let users_p = s.users.path().to_path_buf();
        let notif_p = s.notif_store.lock_or_recover().path().to_path_buf();
        let curve_p = s.cluster.curve_clients_path.clone();
        let cfg_p = s.cfg.path().to_path_buf();
        let cmd_p = s.cmds.path().to_path_buf();
        let api_cfg_c = s.cluster.api_cfg_cache.clone();
        let api_cmd_c = s.cluster.api_cmd_cache.clone();
        (
            s.cluster.state.cluster_id.clone(),
            s.cluster.state.hub_id.clone(),
            s.cluster.state.role.clone(),
            s.cluster.state.epoch,
            s.writes,
            s.cluster.state.is_configured_primary,
            s.cluster.state.failback_locked,
            cfg_lines,
            max_cfg_rev,
            cfg_enabled,
            cmd_enabled,
            cmd_lines,
            max_cmd_seq,
            cfg_dirty,
            cmd_dirty,
            users_p,
            notif_p,
            curve_p,
            cfg_p,
            cmd_p,
            api_cfg_c,
            api_cmd_c,
        )
    };
    // N87-02 & BUG-03: Compute file hashes strictly OUTSIDE SharedState lock so 1Hz polling does not block forwarding thread
    let users_hash = crate::cluster::file_sha256(&users_path);
    let notif_hash = crate::cluster::file_sha256(&notif_path);
    let curve_clients_hash = crate::cluster::file_sha256(&curve_clients_path);
    let cfg_hash = {
        let mut c = api_cfg_cache.lock().unwrap_or_else(|p| p.into_inner());
        crate::cluster::cached_journal_sha256(&cfg_path, (cfg_lines, cfg_dirty), &mut *c)
    };
    let cmd_hash = {
        let mut c = api_cmd_cache.lock().unwrap_or_else(|p| p.into_inner());
        crate::cluster::cached_journal_sha256(&cmd_path, (cmd_lines, cmd_dirty), &mut *c)
    };
    {
        let s = st.lock_or_recover();
        if s.cfg.total_lines() != cfg_lines || s.cfg.dirty_seq() != cfg_dirty {
            let mut c = api_cfg_cache.lock().unwrap_or_else(|p| p.into_inner());
            *c = None;
        }
        if s.cmds.sync_stats().0 != cmd_lines || s.cmds.dirty_seq() != cmd_dirty {
            let mut c = api_cmd_cache.lock().unwrap_or_else(|p| p.into_inner());
            *c = None;
        }
    }

    let resp = crate::cluster::ClusterStatusResponse {
        ok: true,
        cluster_id,
        hub_id,
        role,
        epoch,
        writes,
        cfg_lines,
        cmd_lines,
        max_cmd_seq,
        max_cfg_rev,
        cfg_enabled,
        cmd_enabled,
        cfg_hash,
        cmd_hash,
        users_hash,
        notif_hash,
        curve_clients_hash,
        //--- F-10: announce whether the feature is ON, independently of whether the
        //--- file exists yet. "path empty" is the only reliable off-switch.
        notif_enabled: !notif_path.as_os_str().is_empty(),
        curve_clients_enabled: !curve_clients_path.as_os_str().is_empty(),
        users_sync_enabled: std::env::var("MTC_SYNC_USERS")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false),
        is_configured_primary,
        failback_locked,
        ts: unix_secs(),
    };
    Json(resp).into_response()
}

pub(crate) async fn cluster_sync(
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

    // DEF-61-07, BUG-05, N70-04 & N72-04: Bound max delta lines returned per sync batch.
    // Truncate only incremental deltas (from_line > 0). Full baseline resets (from_line == 0)
    // must return complete snapshot history so replace_all does not truncate active in-flight commands.
    // Propagate journal read errors as 500 so Standby detects transient failures and backs off.
    const MAX_SYNC_BATCH: usize = 10000;
    let mut reported_total_cfg_lines = total_cfg_lines;
    let cfg_delta_lines = if !cfg_enabled || req.from_cfg_line >= total_cfg_lines {
        Vec::new()
    } else {
        match crate::config::ConfigStore::read_lines_from_path(&cfg_path, req.from_cfg_line) {
            Ok((mut lines, actual_tot)) => {
                reported_total_cfg_lines = actual_tot;
                if req.from_cfg_line > 0 && actual_tot < req.from_cfg_line {
                    Vec::new()
                } else {
                    if req.from_cfg_line > 0 && lines.len() > MAX_SYNC_BATCH {
                        lines.truncate(MAX_SYNC_BATCH);
                    }
                    lines
                }
            }
            Err(e) => {
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": format!("failed to read config journal: {}", e) })),
                )
                    .into_response();
            }
        }
    };

    let mut reported_total_cmd_lines = total_cmd_lines;
    let cmd_delta_lines = if !cmd_enabled || req.from_cmd_line >= total_cmd_lines {
        Vec::new()
    } else {
        match crate::commands::CommandStore::read_lines_from_path(&cmd_path, req.from_cmd_line) {
            Ok((mut lines, actual_tot, _)) => {
                reported_total_cmd_lines = actual_tot;
                if req.from_cmd_line > 0 && actual_tot < req.from_cmd_line {
                    Vec::new()
                } else {
                    if req.from_cmd_line > 0 && lines.len() > MAX_SYNC_BATCH {
                        lines.truncate(MAX_SYNC_BATCH);
                    }
                    lines
                }
            }
            Err(e) => {
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": format!("failed to read command journal: {}", e) })),
                )
                    .into_response();
            }
        }
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
        total_cfg_lines: reported_total_cfg_lines,
        // N87-03: If commands are disabled (--commands none), report 0 to avoid truncated batch errors on Standby
        total_cmd_lines: if cmd_enabled { reported_total_cmd_lines } else { 0 },
        max_cmd_seq: if cmd_enabled { max_cmd_seq } else { 0 },
    };
    Json(resp).into_response()
}

pub(crate) async fn cluster_handover_request(
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
    //--- The body's claim is also cross-checked against what this hub last
    //--- PROBED from its peer, so a hand-built request cannot self-assert it.
    let probed_configured_primary = s
        .cluster
        .peer_status
        .as_ref()
        .map(|p| p.hub_id == req.from_hub_id && p.is_configured_primary)
        .unwrap_or(false);
    if !req.is_configured_primary || !probed_configured_primary {
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

    // R2-D7-H02 & R4-D7-02: Verify Standby has fully replicated local journals before stepping down
    let (my_cfg, my_cfg_rev) = s.cfg.sync_stats();
    let (my_cmd, my_seq) = s.cmds.sync_stats();
    let (my_cfg_enabled, my_cmd_enabled) = (s.cfg.enabled(), s.cmds.enabled());
    if let Some(peer) = s.cluster.peer_status.as_ref() {
        // DEF-01 & R17-C02: Check synchronization only for enabled components; prevent asymmetric cluster deadlocks
        let cmd_behind = my_cmd_enabled && peer.cmd_enabled && (peer.cmd_lines < my_cmd || (my_seq > 0 && peer.max_cmd_seq < my_seq));
        let cfg_behind = my_cfg_enabled && peer.cfg_enabled && (peer.cfg_lines < my_cfg || (my_cfg_rev > 0 && peer.max_cfg_rev < my_cfg_rev));
        if cmd_behind || cfg_behind {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({
                    "ok": false,
                    "agreed": false,
                    "new_epoch": s.cluster.epoch(),
                    "error": format!("Handover rejected: Standby is lagging behind (cmd seq: {}/{}, lines: {}/{}, cfg: {}/{})", peer.max_cmd_seq, my_seq, peer.cmd_lines, my_cmd, peer.cfg_lines, my_cfg)
                })),
            )
                .into_response();
        }
    } else if my_cfg > 0 || my_cmd > 0 || my_seq > 0 {
        return (
            axum::http::StatusCode::CONFLICT,
            Json(json!({
                "ok": false,
                "agreed": false,
                "new_epoch": s.cluster.epoch(),
                "error": "Handover rejected: peer sync status unknown"
            })),
        )
            .into_response();
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
    // Guard against immediate Dual-Standby recovery while handover agreement is in flight
    s.cluster.handover_lease_until = Some(std::time::Instant::now() + std::time::Duration::from_secs(15));
    let save_info = s.cluster.save_info();
    let audit_rec = Arc::clone(&s.audit);
    drop(s);
    if let Err(e) = crate::cluster::save_state_to_file(&save_info.0, &save_info.1) {
        eprintln!("[hub] CLUSTER ERR: handover step-down state save failed: {}", e);
        // DEF-06: Rollback in-memory demotion to avoid leaving cluster with zero Primaries
        let mut s = st.lock_or_recover();
        s.cluster.state.role = "primary".to_string();
        s.writes = s.writes_allowed;
        s.cluster.handover_lease_until = None;
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "agreed": false, "error": format!("failed to persist step-down state: {}", e) })),
        )
            .into_response();
    }

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

pub(crate) async fn cluster_promote(
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
    // F-02: Safely compute next target epoch with checked_add
    let target_ep = crate::cluster::next_epoch(peer_ep.max(s.cluster.state.epoch));
    let new_epoch = s.cluster.promote(Some(target_ep));
    s.writes = s.writes_allowed; // P1-2: Respect CLI --writes setting
    let current_writes = s.writes;
    let save_info = s.cluster.save_info();
    let audit_rec = Arc::clone(&s.audit);
    drop(s);
    if let Err(e) = crate::cluster::save_state_to_file(&save_info.0, &save_info.1) {
        eprintln!("[hub] CLUSTER ERR: operator promote state save failed: {}", e);
    }

    audit_rec.record(
        &sess.user_id,
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
pub(crate) struct FailbackLockBody {
    locked: bool,
}

pub(crate) async fn cluster_failback_lock(
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
    let save_info = s.cluster.save_info();
    let audit_rec = Arc::clone(&s.audit);
    drop(s);
    if let Err(e) = crate::cluster::save_state_to_file(&save_info.0, &save_info.1) {
        eprintln!("[hub] CLUSTER ERR: failback lock state save failed: {}", e);
    }

    audit_rec.record(
        &sess.user_id,
        "",
        "cluster.failback_lock",
        &format!("set failback_locked={}", b.locked),
        None,
        None,
        "ok",
    );

    Json(json!({ "ok": true, "failback_locked": b.locked })).into_response()
}

pub(crate) async fn cluster_failback_now(
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
        // HUB-02: Prevent handover when Standby has not fully synchronized with Primary
        if s.cluster.sync_status != "synced" {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": format!("Cannot failback: node is not synced with Primary (current status: {}).", s.cluster.sync_status) })),
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
        .redirect(reqwest::redirect::Policy::none())
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
                    // P0-02 & F-02: Target epoch must strictly exceed both peer and local epochs to prevent tie/split-brain
                    let target_ep = Some(crate::cluster::next_epoch(h_data.new_epoch.max(s.cluster.epoch())));
                    let new_epoch = s.cluster.promote(target_ep);
                    s.writes = s.writes_allowed; // P1-3: Respect CLI --writes setting
                    let current_writes = s.writes;
                    let save_info = s.cluster.save_info();
                    let audit_rec = Arc::clone(&s.audit);
                    drop(s);
                    if let Err(e) = crate::cluster::save_state_to_file(&save_info.0, &save_info.1) {
                        eprintln!("[hub] CLUSTER ERR: manual failback state save failed: {}", e);
                    }
                    audit_rec.record(
                        &sess.user_id,
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

#[derive(serde::Deserialize)]
pub(crate) struct SetClusterPeerBody {
    #[serde(default)]
    peer_ip: String,
    #[serde(default)]
    peer_api_port: Option<u16>,
    #[serde(default)]
    peer_zmq_port: Option<u16>,
    #[serde(default)]
    peer_url: Option<String>,
    #[serde(default)]
    peer_zmq: Option<String>,
}

pub(crate) async fn cluster_get_peer(
    axum::extract::Extension(_sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let s = st.lock_or_recover();
    let is_standalone = s.cluster.peer_url.is_empty();
    let resp = json!({
        "ok": true,
        "peer_url": s.cluster.peer_url,
        "peer_zmq": s.cluster.peer_zmq,
        "peer_online": s.cluster.peer_online,
        "sync_status": s.cluster.sync_status,
        "is_standalone": is_standalone,
        "role": s.cluster.state.role,
        "epoch": s.cluster.state.epoch,
    });
    Json(resp).into_response()
}

pub(crate) fn validate_peer_url(url: &str) -> Result<(), String> {
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("Invalid URL: {}", e))?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err("peer URL scheme must be http or https".to_string());
    }
    if parsed.host_str().is_none() {
        return Err("peer URL must include a valid host".to_string());
    }
    Ok(())
}

pub(crate) async fn cluster_set_peer(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<SetClusterPeerBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }

    let (new_url, new_zmq) = if let Some(url) = b.peer_url.filter(|u| !u.trim().is_empty()) {
        (url.trim().trim_end_matches('/').to_string(), b.peer_zmq.unwrap_or_default().trim().trim_end_matches('/').to_string())
    } else if !b.peer_ip.trim().is_empty() {
        let raw_ip = b.peer_ip.trim().trim_end_matches('/');
        let scheme = if raw_ip.starts_with("https://") { "https" } else { "http" };
        let mut ip = raw_ip;
        if let Some(stripped) = ip.strip_prefix("http://") {
            ip = stripped;
        } else if let Some(stripped) = ip.strip_prefix("https://") {
            ip = stripped;
        }
        ip = ip.trim_end_matches('/');
        if ip.contains('/') {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "peer_ip cannot contain paths or trailing slashes" })),
            )
                .into_response();
        }
        let (host, api_port_override) = if let Some(colon_pos) = ip.rfind(':') {
            if !ip.contains(']') && ip.chars().filter(|&c| c == ':').count() > 1 {
                (format!("[{}]", ip), None)
            } else if ip.starts_with('[') && ip.ends_with(']') {
                (ip.to_string(), None)
            } else if ip.contains(']') && colon_pos > ip.rfind(']').unwrap() {
                let (h, p) = ip.split_at(colon_pos);
                let p_val: u16 = p[1..].parse().unwrap_or(0);
                (h.to_string(), if p_val > 0 { Some(p_val) } else { None })
            } else if !ip.contains(']') && ip.chars().filter(|&c| c == ':').count() == 1 {
                let (h, p) = ip.split_at(colon_pos);
                let p_val: u16 = p[1..].parse().unwrap_or(0);
                (h.to_string(), if p_val > 0 { Some(p_val) } else { None })
            } else {
                (ip.to_string(), None)
            }
        } else if ip.contains(':') && !ip.starts_with('[') {
            (format!("[{}]", ip), None)
        } else {
            (ip.to_string(), None)
        };
        let api_port = api_port_override.or(b.peer_api_port).unwrap_or(6010);
        let zmq_port = b.peer_zmq_port.unwrap_or(6000);
        (format!("{}://{}:{}", scheme, host, api_port), format!("tcp://{}:{}", host, zmq_port))
    } else {
        // Clear peer -> switch cleanly to standalone mode
        (String::new(), String::new())
    };

    if !new_url.is_empty() {
        if !new_url.starts_with("http://") && !new_url.starts_with("https://") {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "peer_url must begin with http:// or https://" })),
            )
                .into_response();
        }
        if let Err(e) = validate_peer_url(&new_url) {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": format!("Invalid peer URL: {}", e) })),
            )
                .into_response();
        }
    }

    if !new_zmq.is_empty() {
        if new_zmq.contains(';') || new_zmq.contains('\n') || new_zmq.contains('\r') {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "peer_zmq contains forbidden delimiters" })),
            )
                .into_response();
        }
        if !new_zmq.starts_with("tcp://") && !new_zmq.starts_with("ipc://") {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "peer_zmq must start with tcp:// or ipc://" })),
            )
                .into_response();
        }
    }

    let mut s = st.lock_or_recover();
    let (state_path, state) = s.cluster.set_peer(new_url.clone(), new_zmq.clone());
    let audit_rec = Arc::clone(&s.audit);
    drop(s);

    if let Err(e) = crate::cluster::save_state_to_file(&state_path, &state) {
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Failed to save cluster state: {}", e) })),
        )
            .into_response();
    }

    audit_rec.record(
        &sess.user_id,
        "",
        "cluster.set_peer",
        &format!("configured peer_url='{}', peer_zmq='{}'", new_url, new_zmq),
        None,
        None,
        "ok",
    );

    Json(json!({
        "ok": true,
        "peer_url": new_url,
        "peer_zmq": new_zmq,
        "message": if new_url.is_empty() { "Switched to Standalone mode" } else { "Peer cluster settings updated and connecting" }
    }))
    .into_response()
}

// ============================================================================
// TLS / HTTPS Configuration Endpoints
// ============================================================================
