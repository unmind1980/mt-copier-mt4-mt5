//! Sessions, login/logout, nonce challenge and user management.
//!
//! Split out of api.rs without behaviour change; shares its imports.

use super::*;

pub(crate) fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub(crate) fn cookie_token(cookies: &str) -> Option<String> {
    for part in cookies.split(';') {
        if let Some(v) = part.trim().strip_prefix("mtc_session=") {
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

pub(crate) fn constant_time_eq_str(a: &str, b: &str) -> bool {
    use sha2::{Digest, Sha256};
    let ha = Sha256::digest(a.as_bytes());
    let hb = Sha256::digest(b.as_bytes());
    let mut diff: u8 = 0;
    for i in 0..32 {
        diff |= ha[i] ^ hb[i];
    }
    diff == 0
}

pub(crate) async fn require_session(
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
        || path == "/api/v1/locales"
        || path.starts_with("/api/v1/locales/")
        || path.starts_with("/.well-known/acme-challenge/")
    {
        return next.run(req).await;
    }
    //--- Cluster internal communication authentication (ADR-09):
    //--- Authenticate via cluster_token in Authorization: Bearer <token> or X-Cluster-Token header,
    //--- restricted to peer sync/status/handover endpoints (admin mutations require normal RBAC session).
    let is_cluster_token_path = path == "/api/v1/cluster/status"
        || path == "/api/v1/cluster/sync"
        || path == "/api/v1/cluster/handover-request";
    let is_cluster_path = path.starts_with("/api/v1/cluster/");
    if is_cluster_path {
        let cluster_token = st.lock_or_recover().cluster.cluster_token.clone();
        // ISSUE-11: Enforce token_is_usable - reject weak/default cluster tokens (DEFAULT_CLUSTER_TOKEN)
        if is_cluster_token_path && crate::cluster::token_is_usable(&cluster_token) {
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
                    created_at: unix_secs(),
                    pass_hash: String::new(),
                });
                req.extensions_mut().insert(Token(cluster_token));
                return next.run(req).await;
            }
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
            created_at: unix_secs(),
            pass_hash: String::new(),
        });
        req.extensions_mut().insert(Token(String::new()));
        return next.run(req).await;
    }
    let token = header_token(req.headers());
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
pub(crate) fn deny(st: &SharedState, sess: &Session, need: &str) -> axum::response::Response {
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
pub(crate) struct NonceBody {
    id: String,
}

/// `POST /api/v1/auth/nonce` - request a short-lived nonce for challenge-response login.
pub(crate) async fn auth_nonce(
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
            .get("cf-connecting-ip")
            .or_else(|| headers.get("x-real-ip"))
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim().to_string())
            .or_else(|| {
                headers
                    .get("x-forwarded-for")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.rsplit(',').next())
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
pub(crate) struct LoginBody {
    id: String,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    proof: Option<String>,
}

pub(crate) async fn login(
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
            let target_hash = stored.as_deref().unwrap_or(&dummy_hash).to_string();
            let pwd_clone = pwd.clone();
            let verified = tokio::task::spawn_blocking(move || {
                crate::users::verify_password(&pwd_clone, &target_hash)
            })
            .await
            .unwrap_or(false) && stored.is_some();
            if verified {
                //--- Re-check under the lock: the user may have been
                //--- disabled or password changed while hashing.
                let mut s = st.lock_or_recover();
                s.users.mint_session_with_expected_hash(&b.id, stored.as_deref().unwrap_or(""), now)
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
            // RUST-BUG-04 & BUG-04: Include native TLS manager enabled status safely with lock_or_recover()
            let tls_active = st.lock_or_recover().tls.config.lock_or_recover().enabled;
            let is_https = tls_active
                || std::env::var("MTC_HTTPS")
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
        Err(err_msg) => {
            let is_bogus_nonce = err_msg == "invalid challenge nonce";
            let is_heavy = b.password.is_some();
            let (delay_ms, audit) = {
                let mut s = st.lock_or_recover();
                let d = if is_bogus_nonce {
                    0
                } else {
                    s.users.note_login_failure(&b.id, now, is_heavy)
                };
                (d, Arc::clone(&s.audit))
            };
            // HUB-02: Prevent disk I/O DoS. Skip synchronous fsync audit write under heavy flood
            if delay_ms <= 1000 {
                audit.record(
                    &b.id, "", "auth.login", &b.id, None,
                    Some(json!({ "why": "invalid credentials" })), "rejected",
                );
            }
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

pub(crate) fn header_token(headers: &axum::http::HeaderMap) -> Option<String> {
    headers
        .get_all(axum::http::header::COOKIE)
        .iter()
        .find_map(|v| v.to_str().ok().and_then(cookie_token))
        .or_else(|| {
            headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| {
                    let v = v.trim();
                    if let Some(t) = v.strip_prefix("Bearer ").or_else(|| v.strip_prefix("bearer ")) {
                        let t = t.trim();
                        if !t.is_empty() { Some(t.to_string()) } else { None }
                    } else if !v.is_empty() && !v.contains(' ') {
                        Some(v.to_string())
                    } else {
                        None
                    }
                })
        })
}

pub(crate) async fn logout(
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
pub(crate) async fn whoami(
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
pub(crate) struct UserBody {
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

pub(crate) async fn users_list(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::State(st): axum::extract::State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    //--- H-06: Grab users slice clone and session count under lock; construct JSON outside.
    let (users, session_count) = {
        let s = st.lock_or_recover();
        (s.users.users().to_vec(), s.users.session_count())
    };
    let list: Vec<Value> = users
        .iter()
        .map(|u| json!({ "id": u.id, "role": u.role.as_str(), "disabled": u.disabled }))
        .collect();
    Json(json!({ "users": list, "sessions": session_count })).into_response()
}

// BUG-09: Standardize Standby 409 conflict responses to include `primary` URL and `detail` guide
pub(crate) fn standby_readonly_conflict(peer_url: &str, action: &str) -> (axum::http::StatusCode, Json<serde_json::Value>) {
    let hint = if peer_url.is_empty() {
        "Perform modifications against the Primary Hub.".to_string()
    } else {
        format!("Perform modifications against the Primary at {}.", peer_url)
    };
    (
        axum::http::StatusCode::CONFLICT,
        Json(json!({
            "error": format!("Standby node is read-only. {} is only allowed on Primary Hub.", action),
            "detail": hint,
            "primary": peer_url,
        })),
    )
}

pub(crate) async fn users_upsert(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<UserBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
    }
    let user_id = b.id.trim().to_string();
    if user_id.is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(json!({ "error": "user id cannot be empty" })),
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
    let is_password_update = !b.password.is_empty();
    let new_hashed_pass = if is_password_update {
        if b.password.chars().count() < 8 {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({ "error": "password must be at least 8 characters" })),
            )
                .into_response();
        }
        let salt = crate::users::random_token()[..16].to_string();
        let pw = b.password.clone();
        let hashed = tokio::task::spawn_blocking(move || hash_password(&pw, &salt))
            .await
            .unwrap_or_default();
        Some(hashed)
    } else {
        None
    };
    let audit = {
        let mut s = st.lock_or_recover();
        let final_pass = match new_hashed_pass {
            Some(p) => p,
            None => match s.users.get(&user_id).map(|u| u.pass.clone()) {
                Some(p) => p,
                None => {
                    return (
                        axum::http::StatusCode::BAD_REQUEST,
                        Json(json!({ "error": "a new user needs a password" })),
                    )
                        .into_response()
                }
            },
        };
        let prev_user = s.users.get(&user_id).cloned();
        let u = User {
            id: user_id.clone(),
            pass: final_pass,
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
        //--- Persist before evicting sessions, and rollback in-memory state if save fails.
        if let Err(e) = s.users.save() {
            if let Some(old_u) = prev_user {
                let _ = s.users.upsert(old_u);
            } else {
                let _ = s.users.remove(&user_id);
            }
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("failed to save users: {}", e) })),
            )
                .into_response();
        }
        if !b.password.is_empty() || b.disabled {
            s.users.drop_other_sessions(&user_id, None);
        }
        Arc::clone(&s.audit)
    };
    audit.record(
        &sess.user_id,
        "",
        "user.upsert",
        &user_id,
        None,
        Some(json!({ "role": b.role, "disabled": b.disabled })),
        "ok",
    );
    Json(json!({ "ok": true, "id": user_id })).into_response()
}

pub(crate) async fn users_delete(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::Path(id): axum::extract::Path<String>,
    axum::extract::State(st): axum::extract::State<SharedState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if sess.role < UserRole::Admin {
        return deny(&st, &sess, "admin");
    }
    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
    }
    let removed = {
        let mut s = st.lock_or_recover();
        let prev_user = s.users.get(&id).cloned();
        match s.users.remove(&id) {
            Ok(()) => {
                if let Err(e) = s.users.save() {
                    if let Some(old_u) = prev_user {
                        let _ = s.users.upsert(old_u);
                    }
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
pub(crate) struct PasswordBody {
    old: String,
    new: String,
}

/// `POST /api/v1/password` - change YOUR OWN password. Open to any role,
/// because needing an admin to rotate your own credential is how credentials
/// get shared. The old password is required even though the caller is already
/// authenticated: a borrowed session (a shoulder-surfed laptop) must not be
/// enough to lock the real owner out.
pub(crate) async fn change_password(
    axum::extract::Extension(sess): axum::extract::Extension<Session>,
    axum::extract::Extension(tok): axum::extract::Extension<Token>,
    axum::extract::State(st): axum::extract::State<SharedState>,
    Json(b): Json<PasswordBody>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let (is_primary, peer_url) = {
        let s = st.lock_or_recover();
        (s.cluster.is_primary(), s.cluster.peer_url.clone())
    };
    if !is_primary {
        return standby_readonly_conflict(&peer_url, "Modification").into_response();
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
    let old_pw = b.old.clone();
    let old_ok = match stored {
        Some(h) => tokio::task::spawn_blocking(move || verify_password(&old_pw, &h))
            .await
            .unwrap_or(false),
        None => false,
    };
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
    let new_pw = b.new.clone();
    let new_hash = tokio::task::spawn_blocking(move || crate::users::hash_password(&new_pw, &new_salt))
        .await
        .unwrap_or_default();
    let changed = {
        let mut s = st.lock_or_recover();
        let prev_hash = s.users.get(&sess.user_id).map(|u| u.pass.clone());
        match s.users.set_password_hashed(&sess.user_id, new_hash) {
            Err(e) => Err(e),
            Ok(()) => {
                if let Err(e) = s.users.save() {
                    if let Some(old_h) = prev_hash {
                        let _ = s.users.set_password_hashed(&sess.user_id, old_h);
                    }
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
