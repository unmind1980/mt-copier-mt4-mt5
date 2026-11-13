//! HTTPS listener, ACME challenge and TLS management endpoints.
//!
//! Split out of api.rs without behaviour change; shares its imports.

use super::*;

/// HUB-02: Ensure dedicated HTTPS listener is spawned when TLS is active on custom/standard port
pub(crate) fn ensure_dedicated_https_listener(st: &SharedState) {
    let (current_port, https_bind_host, tls_mgr, tx) = {
        let s = st.lock_or_recover();
        (s.http_port, s.http_host.clone(), Arc::clone(&s.tls), s.tx.clone())
    };
    let (https_port, tls_enabled) = {
        let c = tls_mgr.config.lock_or_recover();
        (c.https_port, c.enabled)
    };
    if !tls_enabled || https_port == 0 || https_port == current_port {
        if let Some((_, old_tx)) = tls_mgr.active_https_shutdown.lock_or_recover().take() {
            let _ = old_tx.send(());
        }
        return;
    }
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    {
        let mut active = tls_mgr.active_https_shutdown.lock_or_recover();
        if let Some((old_port, old_tx)) = active.take() {
            if old_port == https_port {
                // Already listening on this port, keep existing shutdown sender
                *active = Some((old_port, old_tx));
                return;
            }
            // Shut down existing listener on different port
            let _ = old_tx.send(());
        }
        *active = Some((https_port, shutdown_tx));
    }

    let st_https = st.clone();
    let tls_mgr_https = Arc::clone(&tls_mgr);
    let tx_https = match tx {
        Some(t) => t,
        None => return,
    };
    let app_base_https = router(st_https, tx_https);
    tokio::spawn(async move {
        //--- B4: bind the SAME interface the plain listener uses. Hard-coding
        //--- 0.0.0.0 here meant one click in the dashboard silently published a
        //--- panel that shows every position to the whole network, even though
        //--- --http 127.0.0.1 was chosen deliberately.
        let bind_addr = format!("{}:{}", https_bind_host, https_port);
        match tokio::net::TcpListener::bind(&bind_addr).await {
            Ok(l) => {
                println!("[hub] TLS: Dedicated HTTPS listener active on https://{}", bind_addr);
                loop {
                    tokio::select! {
                        conn_res = l.accept() => {
                            let (tcp_stream, _) = match conn_res {
                                Ok(conn) => conn,
                                Err(_) => continue,
                            };
                            let acceptor_opt = tls_mgr_https.acceptor.read_or_recover().clone();
                            let app = app_base_https.clone();
                            tokio::spawn(async move {
                                if let Some(acceptor) = acceptor_opt {
                                    if let Ok(tls_stream) = acceptor.accept(tcp_stream).await {
                                        crate::tls::serve_stream_with_router(tls_stream, app).await;
                                    }
                                }
                            });
                        }
                        _ = &mut shutdown_rx => {
                            println!("[hub] TLS: Dedicated HTTPS listener on port {} shutting down", https_port);
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("[hub] TLS: cannot bind dedicated HTTPS listener on {}: {}", bind_addr, e);
                let mut active = tls_mgr_https.active_https_shutdown.lock_or_recover();
                if let Some((p, _)) = active.as_ref() {
                    if *p == https_port {
                        *active = None;
                    }
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// M4a: the config endpoints.
//
// EVERY ONE OF THESE IS READ-ONLY EXCEPT TWO, and those two are gated on
// `--writes`. See `config.rs` for why the gate exists rather than an assumption
// that only trusted people can reach the port.
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
pub(crate) struct TlsConfigureBody {
    mode: crate::tls::TlsMode,
    domain: Option<String>,
    https_port: Option<u16>,
    http_port: Option<u16>,
    email: Option<String>,
    enable_http_redirect: Option<bool>,
    auto_renew: Option<bool>,
    staging_mode: Option<bool>,
}

#[derive(serde::Deserialize)]
pub(crate) struct TlsImportBody {
    cert_pem: String,
    key_pem: String,
    domain: String,
    https_port: Option<u16>,
    enable_http_redirect: Option<bool>,
}

#[derive(serde::Deserialize)]
pub(crate) struct TlsSelfSignedBody {
    domain: String,
    https_port: Option<u16>,
    enable_http_redirect: Option<bool>,
}

pub(crate) fn tls_ip_client() -> &'static reqwest::Client {
    static IP_CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    IP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_millis(1500))
            .build()
            .unwrap_or_default()
    })
}

pub(crate) async fn acme_challenge_handler(
    State(st): State<SharedState>,
    axum::extract::Path(token): axum::extract::Path<String>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let key_auth = {
        let s = st.lock_or_recover();
        s.tls.get_acme_token(&token)
    };
    match key_auth {
        Some(ka) => (
            axum::http::StatusCode::OK,
            [(axum::http::header::CONTENT_TYPE, "text/plain")],
            ka,
        )
            .into_response(),
        None => (axum::http::StatusCode::NOT_FOUND, "Token not found").into_response(),
    }
}

pub(crate) async fn tls_status(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    // HUB-03: Require operator role or higher to query TLS status and probe public IP
    if sess.role < UserRole::Operator {
        return deny(&st, &sess, "operator");
    }
    let cfg = {
        let s = st.lock_or_recover();
        let c = s.tls.config.lock_or_recover().clone();
        c
    };
    let client = tls_ip_client();
    let detected_ip = crate::tls::detect_public_ip(client).await;
    let sslip_domain = detected_ip.as_deref().map(crate::tls::format_sslip_domain);

    Json(json!({
        "ok": true,
        "config": cfg,
        "detected_public_ip": detected_ip,
        "suggested_sslip_domain": sslip_domain,
    }))
    .into_response()
}

pub(crate) async fn tls_configure(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<TlsConfigureBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url, tls_mgr, audit) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone(), Arc::clone(&s.tls), Arc::clone(&s.audit))
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Configuration").into_response();
    }

    // RUST-OPT-02 & BUG-12: Only detect public IP on-demand when Auto mode is selected, reusing client pool with 1500ms timeout
    let target_domain = match b.mode {
        crate::tls::TlsMode::Auto => {
            if let Some(d) = b.domain.as_deref().filter(|s| !s.trim().is_empty()) {
                d.trim().to_string()
            } else {
                let client = tls_ip_client();
                let detected_ip = crate::tls::detect_public_ip(client).await;
                if let Some(ip) = detected_ip.as_deref() {
                    crate::tls::format_sslip_domain(ip)
                } else {
                    return (
                        axum::http::StatusCode::BAD_REQUEST,
                        Json(json!({ "error": "Could not auto-detect public IP. Please specify domain explicitly." })),
                    )
                        .into_response();
                }
            }
        }
        _ => b.domain.unwrap_or_default().trim().to_string(),
    };

    if target_domain.is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Domain name cannot be empty." })),
        )
            .into_response();
    }

    let https_port = b.https_port.unwrap_or(crate::tls::DEFAULT_HTTPS_PORT);
    let http_port = b.http_port.unwrap_or(crate::tls::DEFAULT_HTTP_PORT);
    let enable_redirect = b.enable_http_redirect.unwrap_or(true);
    let auto_renew = b.auto_renew.unwrap_or(true);
    let staging = b.staging_mode.unwrap_or_else(|| tls_mgr.config.lock_or_recover().staging_mode);

    {
        let mut c = tls_mgr.config.lock_or_recover();
        // N84-05: Prevent concurrent ACME enrollment jobs from colliding
        if c.status.in_progress {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": "A TLS certificate enrollment is already in progress." })),
            )
                .into_response();
        }
        c.status.in_progress = true;
        c.status.progress_step = "initiating".to_string();
        c.status.last_error = None;
        let _ = crate::tls::save_config(&tls_mgr.config_path, &c);
    }

    audit.record(
        &sess.user_id,
        "",
        "tls.configure",
        &target_domain,
        None,
        Some(json!({ "mode": format!("{:?}", b.mode), "https_port": https_port, "domain": target_domain })),
        "ok",
    );

    // Spawn ACME enrollment job in background
    let mgr_bg = Arc::clone(&tls_mgr);
    let domain_bg = target_domain.clone();
    let email_bg = b.email.clone();
    let st_bg = st.clone();
    let pending_settings = crate::tls::PendingTlsSettings {
        mode: b.mode,
        domain: target_domain.clone(),
        https_port,
        http_port,
        email: b.email.clone(),
        enable_http_redirect: enable_redirect,
        auto_renew,
        staging_mode: staging,
    };
    tokio::spawn(async move {
        let dir_url = if let Ok(custom) = std::env::var("MTC_ACME_DIR_URL") {
            custom
        } else if staging {
            crate::tls::LETS_ENCRYPT_STAGING_DIR.to_string()
        } else {
            crate::tls::LETS_ENCRYPT_PRODUCTION_DIR.to_string()
        };
        let acme = crate::tls::AcmeClient::new(dir_url);
        match acme.enroll_certificate_with_settings(&mgr_bg, &domain_bg, email_bg.as_deref(), Some(pending_settings)).await {
            Ok(()) => {
                // HUB-02: Dynamically spawn HTTPS listener on dedicated port once cert is active
                ensure_dedicated_https_listener(&st_bg);
            }
            Err(e) => {
                eprintln!("[hub] TLS ERR: Enrollment failed for {}: {}", domain_bg, e);
            }
        }
    });

    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({
            "accepted": true,
            "message": format!("Certificate enrollment initiated for {}", target_domain),
            "domain": target_domain,
            "https_port": https_port,
        })),
    )
        .into_response()
}

pub(crate) async fn tls_import(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<TlsImportBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url, tls_mgr, audit) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone(), Arc::clone(&s.tls), Arc::clone(&s.audit))
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "TLS import").into_response();
    }

    let port = b.https_port.unwrap_or(crate::tls::DEFAULT_HTTPS_PORT);
    match tls_mgr.apply_imported_cert(&b.cert_pem, &b.key_pem, &b.domain, port) {
        Ok(()) => {
            if let Some(redir) = b.enable_http_redirect {
                let mut c = tls_mgr.config.lock_or_recover();
                c.enable_http_redirect = redir;
                let _ = crate::tls::save_config(&tls_mgr.config_path, &c);
            }
            audit.record(&sess.user_id, "", "tls.import", &b.domain, None, None, "ok");
            // HUB-02: Dynamically spawn dedicated listener if custom HTTPS port
            ensure_dedicated_https_listener(&st);
            Json(json!({ "ok": true, "message": "Certificate imported and activated." })).into_response()
        }
        Err(e) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

pub(crate) async fn tls_self_signed(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
    Json(b): Json<TlsSelfSignedBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url, tls_mgr, audit) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone(), Arc::clone(&s.tls), Arc::clone(&s.audit))
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "TLS import").into_response();
    }

    let port = b.https_port.unwrap_or(crate::tls::DEFAULT_HTTPS_PORT);
    match tls_mgr.apply_self_signed(&b.domain, port) {
        Ok(()) => {
            if let Some(redir) = b.enable_http_redirect {
                let mut c = tls_mgr.config.lock_or_recover();
                c.enable_http_redirect = redir;
                let _ = crate::tls::save_config(&tls_mgr.config_path, &c);
            }
            audit.record(&sess.user_id, "", "tls.self_signed", &b.domain, None, None, "ok");
            // HUB-02: Dynamically spawn dedicated listener if custom HTTPS port
            ensure_dedicated_https_listener(&st);
            Json(json!({ "ok": true, "message": "Self-signed certificate generated and activated." })).into_response()
        }
        Err(e) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

pub(crate) async fn tls_disable(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url, tls_mgr, audit) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone(), Arc::clone(&s.tls), Arc::clone(&s.audit))
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "TLS import").into_response();
    }

    {
        let mut acc = tls_mgr.acceptor.write_or_recover();
        *acc = None;
    }
    {
        let mut c = tls_mgr.config.lock_or_recover();
        c.enabled = false;
        c.status.cert_valid = false;
        c.status.progress_step = "disabled".to_string();
        let _ = crate::tls::save_config(&tls_mgr.config_path, &c);
    }
    {
        // BUG-08: Signal dedicated HTTPS listener task to shut down and unbind port
        let mut active = tls_mgr.active_https_shutdown.lock_or_recover();
        if let Some((_, shutdown_tx)) = active.take() {
            let _ = shutdown_tx.send(());
        }
    }
    audit.record(&sess.user_id, "", "tls.disable", "", None, None, "ok");

    Json(json!({ "ok": true, "message": "TLS disabled. Hub returned to HTTP mode." })).into_response()
}

pub(crate) async fn tls_renew(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    State(st): State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url, tls_mgr, audit) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone(), Arc::clone(&s.tls), Arc::clone(&s.audit))
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "TLS import").into_response();
    }

    let (domain, email, staging, is_self_signed, https_port) = {
        let mut c = tls_mgr.config.lock_or_recover();
        // N84-05: Prevent concurrent ACME renewal jobs from colliding
        if c.status.in_progress {
            return (
                axum::http::StatusCode::CONFLICT,
                Json(json!({ "error": "A TLS certificate enrollment is already in progress." })),
            )
                .into_response();
        }
        if c.domain.is_empty() {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "No domain configured to renew." })),
            )
                .into_response();
        }
        if c.mode == crate::tls::TlsMode::SelfSigned {
            (c.domain.clone(), c.email.clone(), c.staging_mode, true, c.https_port)
        } else {
            c.status.in_progress = true;
            c.status.progress_step = "initiating".to_string();
            c.status.last_error = None;
            let _ = crate::tls::save_config(&tls_mgr.config_path, &c);
            (c.domain.clone(), c.email.clone(), c.staging_mode, false, c.https_port)
        }
    };

    if is_self_signed {
        return match tls_mgr.apply_self_signed(&domain, https_port) {
            Ok(()) => {
                audit.record(&sess.user_id, "", "tls.renew", &domain, None, None, "ok");
                ensure_dedicated_https_listener(&st);
                (
                    axum::http::StatusCode::ACCEPTED,
                    Json(json!({ "accepted": true, "message": "Self-signed certificate renewed and activated." })),
                )
                    .into_response()
            }
            Err(e) => (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": e })),
            )
                .into_response(),
        };
    }

    let mgr_bg = Arc::clone(&tls_mgr);
    let domain_bg = domain.clone();
    let st_bg = st.clone();
    tokio::spawn(async move {
        // BUG-15: Support custom MTC_ACME_DIR_URL during renew and re-arm dedicated listener upon success
        let dir_url = if let Ok(custom) = std::env::var("MTC_ACME_DIR_URL") {
            custom
        } else if staging {
            crate::tls::LETS_ENCRYPT_STAGING_DIR.to_string()
        } else {
            crate::tls::LETS_ENCRYPT_PRODUCTION_DIR.to_string()
        };
        let acme = crate::tls::AcmeClient::new(dir_url);
        match acme.enroll_certificate(&mgr_bg, &domain_bg, email.as_deref()).await {
            Ok(()) => {
                ensure_dedicated_https_listener(&st_bg);
            }
            Err(e) => {
                eprintln!("[hub] TLS ERR: Renewal failed for {}: {}", domain_bg, e);
                let mut c = mgr_bg.config.lock_or_recover();
                c.status.in_progress = false;
                c.status.progress_step = "failed".to_string();
                c.status.last_error = Some(e);
                let _ = crate::tls::save_config(&mgr_bg.config_path, &c);
            }
        }
    });

    audit.record(&sess.user_id, "", "tls.renew", &domain, None, None, "ok");
    (
        axum::http::StatusCode::ACCEPTED,
        Json(json!({ "accepted": true, "message": "Certificate renewal initiated." })),
    )
        .into_response()
}

// ============================================================================
// I18N / Locales Endpoints
// ============================================================================
