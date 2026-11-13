//! cluster.rs - HA Cluster Manager, State Machine, and Replication Engine.
//!
//! Enforces:
//! - ADR-03: Single-Writer policy (Primary writable, Standby read-only).
//! - ADR-04: Epoch-fenced state recovery (stale Primary automatically demoted).
//! - ADR-08: Incremental high-watermark replication of 5 key persistent files:
//!   `users.json`, `alert_channels.json`, `curve_clients.txt`, `config_revisions.jsonl`, `commands.jsonl`.
//! - ADR-09: Cluster token authentication over internal HTTP sync endpoints.
//! - ADR-10: Two-Phase Handover for graceful auto-failback to Primary after continuous online stabilization.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::api::SharedState;
use crate::lockx::LockExt;

pub const DEFAULT_CLUSTER_ID: &str = "mt-copier-cluster";
pub const DEFAULT_CLUSTER_TOKEN: &str = "mtc-cluster-auth-secret-token";
pub const DEFAULT_STATE_FILE: &str = "cluster_state.json";
pub const DEFAULT_FAILBACK_HOURS: f64 = 24.0;

/// Validates that a cluster token is configured, sufficiently long, and not a public/default token (N56-01 / ISSUE-11).
pub fn token_is_usable(t: &str) -> bool {
    !t.is_empty()
        && t.len() >= 16
        && t != DEFAULT_CLUSTER_TOKEN
        && t != "mtc_shared_cluster_token_2026"
}

pub fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Persisted state on disk (`cluster_state.json`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClusterStateFile {
    pub cluster_id: String,
    pub hub_id: String,
    pub role: String, // "primary" or "standby"
    pub epoch: u64,
    pub last_promoted_at: u64,
    pub is_configured_primary: bool,
    pub failback_stabilization_hours: f64,
    pub failback_locked: bool,
    #[serde(default)]
    pub cluster_token: String,
    #[serde(default)]
    pub peer_url: String,
    #[serde(default)]
    pub peer_zmq: String,
}

/// Status payload returned by `GET /api/v1/cluster/status`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClusterStatusResponse {
    pub ok: bool,
    pub cluster_id: String,
    pub hub_id: String,
    pub role: String,
    pub epoch: u64,
    pub writes: bool,
    pub cfg_lines: usize,
    pub cmd_lines: usize,
    pub max_cmd_seq: u64,
    #[serde(default)]
    pub max_cfg_rev: u64,
    #[serde(default)]
    pub cfg_enabled: bool,
    #[serde(default)]
    pub cmd_enabled: bool,
    #[serde(default)]
    pub cfg_hash: String,
    #[serde(default)]
    pub cmd_hash: String,
    pub users_hash: String,
    pub notif_hash: String,
    pub curve_clients_hash: String,
    /// F-10: whether THIS side actually has the feature switched on (a non-empty
    /// path). `notif_hash` alone cannot answer it: `file_sha256` returns "" both
    /// for "path is empty / feature off" and for "file does not exist yet", and
    /// treating those as the same meant a brand-new Standby with a valid path but
    /// no file yet never asked for the channels at all.
    /// `#[serde(default)]` so a peer running an older build (which sends neither
    /// field) deserialises instead of failing - see `needs_sync` for the fallback.
    #[serde(default)]
    pub notif_enabled: bool,
    #[serde(default)]
    pub curve_clients_enabled: bool,
    /// F-12: whether THIS hub replicates the user table. It is off by default
    /// because the file carries password digests and the cluster channel may be
    /// plaintext (N56-02) - but that default contradicts what the README promises
    /// for HA, so it is announced here rather than left to a WARN line every five
    /// minutes. An operator reading `/cluster/status` can now see, without
    /// grepping logs, that the standby's accounts are not being kept in step.
    #[serde(default)]
    pub users_sync_enabled: bool,
    pub is_configured_primary: bool,
    pub failback_locked: bool,
    pub ts: u64,
}

/// Request body for `POST /api/v1/cluster/sync`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClusterSyncRequest {
    pub from_cfg_line: usize,
    pub from_cmd_line: usize,
    pub users_hash: String,
    pub notif_hash: String,
    pub curve_clients_hash: String,
}

/// Response body from `POST /api/v1/cluster/sync`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClusterSyncResponse {
    pub ok: bool,
    pub epoch: u64,
    pub cfg_delta_lines: Vec<String>,
    pub cmd_delta_lines: Vec<String>,
    pub users_content: Option<String>,
    pub notif_content: Option<String>,
    pub curve_clients_content: Option<String>,
    pub total_cfg_lines: usize,
    pub total_cmd_lines: usize,
    pub max_cmd_seq: u64,
}

/// Handover request payload for Two-Phase Handover Protocol.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HandoverRequest {
    pub from_hub_id: String,
    pub from_epoch: u64,
    pub is_configured_primary: bool,
    pub reason: String,
}

/// Handover response payload for Two-Phase Handover Protocol.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HandoverResponse {
    pub ok: bool,
    pub agreed: bool,
    pub new_epoch: u64,
    pub error: Option<String>,
}

pub type JournalCache = Option<(std::time::SystemTime, u64, (usize, u64), std::time::Instant, String)>;

/// Runtime cluster manager held inside `Shared`.
pub struct ClusterManager {
    pub state_path: PathBuf,
    pub curve_clients_path: PathBuf,
    pub state: ClusterStateFile,
    pub peer_url: String,
    pub peer_zmq: String,
    pub cluster_token: String,
    pub peer_online: bool,
    pub last_peer_contact: Option<Instant>,
    pub continuous_online_start: Option<Instant>,
    pub peer_status: Option<ClusterStatusResponse>,
    pub last_sync_at: Option<Instant>,
    pub sync_status: String, // "synced", "syncing", "lagging", "disconnected", "conflict", "standalone"
    pub last_sync_err: String,
    pub api_cfg_cache: std::sync::Arc<std::sync::Mutex<JournalCache>>,
    pub api_cmd_cache: std::sync::Arc<std::sync::Mutex<JournalCache>>,
    pub handover_lease_until: Option<Instant>,
    /// ADR-03: a Standby that loses its peer does NOT promote itself unless the
    /// operator opted in with `--auto-promote`. With two hubs and no witness, a
    /// link cut between them looks identical to a dead Primary, and promoting on
    /// that evidence gives two writable Primaries. Off by default; manual
    /// promotion via `POST /api/v1/cluster/promote` is the supported path.
    pub auto_promote: bool,
}

/// Compute SHA-256 hex string of a file with mtime/len fast-path caching. Returns empty string if file does not exist.
/// SHA-256 of a file's bytes, or "" when it cannot be read.
///
/// F-15: this used to cache the result keyed by `(mtime, length)`. That is not a
/// valid identity: a file rewritten inside the filesystem's timestamp granularity
/// with the SAME length (`false` -> `true`, one URL swapped for another of equal
/// length) kept its old hash, so the two hubs agreed they were already in sync and
/// the change was never replicated. The files involved are `users.json`,
/// `alert_channels.json` and `curve_clients.txt` - tens of kilobytes at worst, so
/// hashing them once a second costs microseconds and the cache was buying nothing
/// but a correctness hole.
pub fn file_sha256(path: &Path) -> String {
    match fs::read(path) {
        Ok(bytes) => crate::users::hex(&crate::users::sha256(&bytes)),
        Err(_) => String::new(),
    }
}

/// MTC_SYNC / H7-01: Cached file SHA-256 for large journals (`commands.jsonl` and `config_revisions.jsonl`).
/// Uses `fs::metadata` `(mtime, len)` and `ver: (usize, u64)` fast path. If unchanged and checked within last 30s, returns cached hash.
pub fn cached_journal_sha256(
    path: &Path,
    ver: (usize, u64),
    cache: &mut JournalCache,
) -> String {
    let meta = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return String::new(),
    };
    let mtime = meta.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
    let len = meta.len();
    let now = std::time::Instant::now();

    if let Some((c_mtime, c_len, c_ver, c_inst, ref c_hash)) = cache {
        if *c_ver == ver && *c_mtime == mtime && *c_len == len && now.duration_since(*c_inst) < std::time::Duration::from_secs(30) {
            return c_hash.clone();
        }
    }

    let hash = file_sha256(path);
    // Do not poison the cache if the file changed on disk while we were hashing it.
    if let Ok(meta_after) = fs::metadata(path) {
        let mtime_after = meta_after.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        let len_after = meta_after.len();
        if mtime_after == mtime && len_after == len && (len == 0 || !hash.is_empty()) {
            *cache = Some((mtime, len, ver, now, hash.clone()));
        } else {
            *cache = None;
        }
    }
    hash
}

impl ClusterManager {
    pub fn load_or_create(
        state_path: &Path,
        curve_clients_path: &Path,
        cli_role: Option<&str>,
        peer_url: &str,
        peer_zmq: &str,
        cluster_token: &str,
        failback_hours: f64,
        failback_lock: bool,
    ) -> Result<Self, String> {
        // DEF-05: Recover from .bak if state_path is 0-byte from an interrupted write
        let bak = PathBuf::from(format!("{}.bak", state_path.display()));
        let is_empty = std::fs::metadata(state_path).map(|m| m.len() == 0).unwrap_or(false);
        if is_empty && bak.exists() {
            if let Ok(m) = std::fs::metadata(&bak) {
                if m.len() > 0 {
                    eprintln!("[hub] RECOVERY: Restoring {} from backup {}", state_path.display(), bak.display());
                    let _ = std::fs::copy(&bak, state_path);
                }
            }
        }
        let mut state: ClusterStateFile = if state_path.exists() {
            let data = fs::read_to_string(state_path)
                .map_err(|e| format!("cannot read {}: {}", state_path.display(), e))?;
            let s: ClusterStateFile = serde_json::from_str(data.trim_start_matches('\u{feff}'))
                .map_err(|e| format!("cannot parse {}: {}", state_path.display(), e))?;
            // F-02: Reject corrupted or exhausted epoch values
            if s.epoch == u64::MAX {
                return Err(format!("invalid epoch {} in cluster state (exhausted)", s.epoch));
            }
            s
        } else {
            let default_role = cli_role.unwrap_or("primary").to_string();
            let is_configured_primary = default_role == "primary";
            let hub_id = format!("hub-{}", &crate::users::random_token()[..8]);
            ClusterStateFile {
                cluster_id: DEFAULT_CLUSTER_ID.to_string(),
                hub_id,
                role: default_role,
                epoch: 1,
                last_promoted_at: unix_secs(),
                is_configured_primary,
                failback_stabilization_hours: if failback_hours > 0.0 { failback_hours } else { DEFAULT_FAILBACK_HOURS },
                failback_locked: failback_lock,
                cluster_token: String::new(),
                peer_url: String::new(),
                peer_zmq: String::new(),
            }
        };

        if failback_lock {
            state.failback_locked = true;
        }
        if failback_hours > 0.0 {
            state.failback_stabilization_hours = failback_hours;
        }

        let effective_peer_url = if !peer_url.is_empty() {
            peer_url.trim_end_matches('/').to_string()
        } else {
            state.peer_url.clone()
        };
        let effective_peer_zmq = if !peer_zmq.is_empty() {
            peer_zmq.to_string()
        } else {
            state.peer_zmq.clone()
        };
        state.peer_url = effective_peer_url.clone();
        state.peer_zmq = effective_peer_zmq.clone();

        //--- A token that has shipped inside this repository is public
        //--- knowledge, not a secret. Accepting one is equivalent to accepting
        //--- no authentication at all, so the known-public values are treated
        //--- exactly like an empty token. The length floor exists for the same
        //--- reason: "abc" is not a credential. (N56-01)
        let resolved_token = if token_is_usable(&cluster_token) {
            cluster_token.to_string()
        } else if token_is_usable(&state.cluster_token) {
            state.cluster_token.clone()
        } else {
            if !cluster_token.is_empty() {
                eprintln!("[hub] WARN LOGIC-04: provided cluster token is shorter than 16 chars or is a known default token; rejected and replaced with random token");
            }
            let gen = format!("ctok_{}_{}", unix_secs(), crate::users::random_token());
            //--- NEVER print the token itself. Logs get pasted into tickets,
            //--- chat windows and bug reports; printing a secret is precisely
            //--- how it stops being one. The path is enough for an operator.
            println!(
                "[hub] H-03: no usable cluster token - generated a new random one (persisted to {})",
                state_path.display()
            );
            gen
        };
        state.cluster_token = resolved_token.clone();

        let cm = ClusterManager {
            state_path: state_path.to_path_buf(),
            curve_clients_path: curve_clients_path.to_path_buf(),
            state,
            peer_url: effective_peer_url.clone(),
            peer_zmq: effective_peer_zmq,
            cluster_token: resolved_token,
            peer_online: false,
            last_peer_contact: None,
            continuous_online_start: None,
            peer_status: None,
            last_sync_at: None,
            sync_status: if effective_peer_url.is_empty() { "standalone".to_string() } else { "disconnected".to_string() },
            last_sync_err: String::new(),
            api_cfg_cache: std::sync::Arc::new(std::sync::Mutex::new(None)),
            api_cmd_cache: std::sync::Arc::new(std::sync::Mutex::new(None)),
            handover_lease_until: None,
            auto_promote: false,
        };

        cm.save().map_err(|e| format!("cannot save {}: {}", state_path.display(), e))?;
        Ok(cm)
    }

    pub fn save(&self) -> io::Result<()> {
        save_state_to_file(&self.state_path, &self.state)
    }

    // DEF-02: Returns save_info so caller can persist to disk OUTSIDE SharedState lock
    pub fn set_peer(&mut self, peer_url: String, peer_zmq: String) -> (PathBuf, ClusterStateFile) {
        let peer_url = peer_url.trim().trim_end_matches('/').to_string();
        let peer_zmq = peer_zmq.trim().trim_end_matches('/').to_string();
        let is_empty = peer_url.is_empty();
        self.peer_url = peer_url.clone();
        self.peer_zmq = peer_zmq.clone();
        self.state.peer_url = peer_url;
        self.state.peer_zmq = peer_zmq;
        self.peer_online = false;
        self.last_peer_contact = None;
        self.continuous_online_start = None;
        self.peer_status = None;
        self.last_sync_at = None;
        self.last_sync_err = String::new();
        if is_empty {
            self.sync_status = "standalone".to_string();
        } else {
            self.sync_status = "connecting".to_string();
        }
        self.save_info()
    }

    pub fn is_primary(&self) -> bool {
        self.state.role == "primary"
    }

    #[allow(dead_code)]
    pub fn is_standby(&self) -> bool {
        self.state.role == "standby"
    }

    pub fn role(&self) -> &str {
        &self.state.role
    }

    pub fn epoch(&self) -> u64 {
        self.state.epoch
    }

    pub fn hub_id(&self) -> &str {
        &self.state.hub_id
    }

    pub fn is_peer_alive(&self, timeout: Duration) -> bool {
        if self.peer_url.is_empty() {
            return false;
        }
        self.peer_online && self.last_peer_contact.map(|t| t.elapsed() < timeout).unwrap_or(false)
    }

    pub fn save_info(&self) -> (PathBuf, ClusterStateFile) {
        (self.state_path.clone(), self.state.clone())
    }

    pub fn promote(&mut self, target_epoch: Option<u64>) -> u64 {
        // F-02: Use next_epoch to prevent integer overflow wrapping to 0
        let candidate = target_epoch.unwrap_or_else(|| next_epoch(self.state.epoch));
        let new_epoch = candidate.max(next_epoch(self.state.epoch));
        self.state.epoch = new_epoch;
        self.state.role = "primary".to_string();
        self.handover_lease_until = None;
        self.state.last_promoted_at = unix_secs();
        new_epoch
    }

    pub fn demote(&mut self, new_epoch: u64) {
        // P0-2: demote does not advance epoch past what was requested
        self.state.epoch = new_epoch.max(self.state.epoch);
        self.state.role = "standby".to_string();
        self.continuous_online_start = None;
    }

    pub fn set_failback_lock(&mut self, locked: bool) {
        self.state.failback_locked = locked;
    }

    #[allow(dead_code)]
    pub fn disabled() -> Self {
        ClusterManager {
            state_path: PathBuf::new(),
            curve_clients_path: PathBuf::new(),
            state: ClusterStateFile {
                cluster_id: DEFAULT_CLUSTER_ID.to_string(),
                hub_id: "test-hub".to_string(),
                role: "primary".to_string(),
                epoch: 1,
                last_promoted_at: 0,
                is_configured_primary: true,
                failback_stabilization_hours: DEFAULT_FAILBACK_HOURS,
                failback_locked: false,
                cluster_token: DEFAULT_CLUSTER_TOKEN.to_string(),
                peer_url: String::new(),
                peer_zmq: String::new(),
            },
            peer_url: String::new(),
            peer_zmq: String::new(),
            cluster_token: DEFAULT_CLUSTER_TOKEN.to_string(),
            peer_online: false,
            last_peer_contact: None,
            continuous_online_start: None,
            peer_status: None,
            last_sync_at: None,
            sync_status: "standalone".to_string(),
            last_sync_err: String::new(),
            api_cfg_cache: std::sync::Arc::new(std::sync::Mutex::new(None)),
            api_cmd_cache: std::sync::Arc::new(std::sync::Mutex::new(None)),
            handover_lease_until: None,
            auto_promote: false,
        }
    }
}

/// F-02: Safely calculate the next epoch without overflow wrap in release or panic in debug.
pub fn next_epoch(base: u64) -> u64 {
    base.checked_add(1).unwrap_or(u64::MAX)
}

/// Replace target file atomically with retry loop and copy fallback to handle Windows file locks.
pub(crate) fn atomic_replace_file(tmp: &Path, target: &Path) -> Result<(), std::io::Error> {
    for attempt in 0..10 {
        match fs::rename(tmp, target) {
            Ok(()) => {
                let bak = PathBuf::from(format!("{}.bak", target.display()));
                let _ = fs::copy(target, &bak);
                return Ok(());
            }
            Err(_) if attempt < 9 => {
                let delay = if attempt < 4 { 15 * (1 << attempt) } else { 150 };
                std::thread::sleep(Duration::from_millis(delay));
            }
            Err(rename_err) => {
                // Fallback: preserve backup before overwriting target to prevent 0-byte truncation.
                // Scope File handles before removing/restoring files so Windows sharing locks release cleanly.
                if tmp.exists() {
                    if let Ok(bytes) = fs::read(tmp) {
                        let bak = PathBuf::from(format!("{}.bak", target.display()));
                        let _ = fs::copy(target, &bak);
                        let copy_ok = {
                            if let Ok(mut dst) = OpenOptions::new().write(true).create(true).open(target) {
                                dst.write_all(&bytes).is_ok()
                                    && dst.set_len(bytes.len() as u64).is_ok()
                                    && dst.sync_all().is_ok()
                            } else {
                                false
                            }
                        };
                        if copy_ok {
                            let _ = fs::remove_file(tmp);
                            let _ = fs::remove_file(&bak);
                            return Ok(());
                        } else if bak.exists() {
                            let _ = fs::copy(&bak, target);
                        }
                        // DEF-05: Preserve .bak on fallback error so restart can recover
                    }
                }
                return Err(rename_err);
            }
        }
    }
    Ok(())
}

pub(crate) fn unique_tmp_path(target: &Path, tag: &str) -> PathBuf {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    PathBuf::from(format!("{}.{}.{}.{}.tmp", target.display(), tag, std::process::id(), seq))
}

/// N72-03: Save cluster state to path atomically without holding SharedState mutex.
pub(crate) fn save_state_to_file(path: &Path, state: &ClusterStateFile) -> std::io::Result<()> {
    let tmp = unique_tmp_path(path, "state");
    let text = serde_json::to_string_pretty(state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    {
        let mut f = File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
    }
    let res = atomic_replace_file(&tmp, path);
    if res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    res
}

/// Autonomous recovery when Standby loses all contact with Primary after having previously connected.
///
/// ADR-03: gated on `auto_promote` (CLI `--auto-promote`, default OFF). Without
/// it a Standby that loses its peer stays read-only and says so once a minute;
/// the operator promotes it with `POST /api/v1/cluster/promote` after confirming
/// the old Primary is really down. Two hubs with no witness cannot tell "peer
/// dead" from "link between us cut", and guessing wrong gives two writers.
fn try_orphan_recovery(st: &SharedState) {
    let mut s = st.lock_or_recover();
    let role = s.cluster.state.role.clone();
    let handover_in_flight = s.cluster.handover_lease_until.map(|t| Instant::now() < t).unwrap_or(false);
    let outage_opt = s.cluster.last_peer_contact.map(|t| t.elapsed().as_secs());
    if role == "standby" && !handover_in_flight {
        if let Some(outage) = outage_opt {
            if outage >= 30 && !s.cluster.auto_promote {
                //--- report once per minute, not every probe
                if outage % 60 < 5 {
                    let audit_rec = Arc::clone(&s.audit);
                    drop(s);
                    eprintln!(
                        "[hub] STANDBY: peer unreachable for {}s. NOT promoting (ADR-03, --auto-promote is off). \
                         Confirm the Primary is down, then promote this hub from the dashboard or POST /api/v1/cluster/promote.",
                        outage
                    );
                    audit_rec.record(
                        "cluster",
                        "",
                        "cluster.peer_lost_manual_promote_required",
                        &format!("peer unreachable {}s; auto-promote disabled", outage),
                        None,
                        None,
                        "ok",
                    );
                }
                return;
            }
            if outage >= 30 {
                s.cluster.handover_lease_until = None;
                let target_ep = Some(next_epoch(
                    s.cluster.peer_status.as_ref().map(|p| p.epoch).unwrap_or(0).max(s.cluster.epoch()),
                ));
                let ep = s.cluster.promote(target_ep);
                s.writes = s.writes_allowed;
                let writes = s.writes;
                let audit_rec = Arc::clone(&s.audit);
                let (p, st_file) = s.cluster.save_info();
                drop(s);
                audit_rec.record(
                    "cluster",
                    "",
                    "cluster.orphan_primary_recovered",
                    &format!("recovered Primary role after {}s peer isolation (epoch {}, writes={})", outage, ep, writes),
                    None,
                    None,
                    "ok",
                );
                println!(
                    "[hub] ORPHAN RECOVERY: Promoting after {}s peer isolation. Epoch {}. Writes={}.",
                    outage, ep, writes
                );
                if let Err(err) = save_state_to_file(&p, &st_file) {
                    eprintln!("[hub] ORPHAN RECOVERY ERR: Failed to persist state: {}", err);
                }
            }
        }
    }
}

/// Spawns the background cluster replication and failback manager loop.
pub fn spawn_cluster_worker(st: SharedState, check_interval: Duration) {
    tokio::spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::limited(5))
            .build()
            .unwrap_or_default();
        let mut last_users_warn = Instant::now()
            .checked_sub(Duration::from_secs(300))
            .unwrap_or_else(Instant::now);
        let mut force_full_cfg_resync = false;
        let mut force_full_cmd_resync = false;
        let mut last_failback_attempt: Option<Instant> = None;
        let mut last_known_remote_cfg_lines = 0usize;
        let mut last_known_remote_cmd_lines = 0usize;
        let mut cfg_cache: JournalCache = None;
        let mut cmd_cache: JournalCache = None;
        let mut primary_cfg_cache: JournalCache = None;
        let mut primary_cmd_cache: JournalCache = None;

        loop {
            tokio::time::sleep(check_interval).await;

            let (peer_url, token) = {
                let s = st.lock_or_recover();
                (s.cluster.peer_url.clone(), s.cluster.cluster_token.clone())
            };

            if peer_url.is_empty() {
                continue;
            }

            // 1. Probe peer status
            let status_url = format!("{}/api/v1/cluster/status", peer_url);
            let resp = client
                .get(&status_url)
                .header("Authorization", format!("Bearer {}", token))
                .send()
                .await;

            let remote_st: ClusterStatusResponse = match resp {
                Ok(r) if r.status().is_success() => match r.json().await {
                    Ok(parsed) => parsed,
                    Err(e) => {
                        {
                            let mut s = st.lock_or_recover();
                            s.cluster.peer_online = false;
                            s.cluster.continuous_online_start = None;
                            s.cluster.sync_status = "disconnected".to_string();
                            s.cluster.last_sync_err = format!("Failed to parse status from {}: {}", peer_url, e);
                        }
                        try_orphan_recovery(&st);
                        continue;
                    }
                },
                Ok(r) => {
                    let status = r.status();
                    {
                        let mut s = st.lock_or_recover();
                        s.cluster.peer_online = false;
                        s.cluster.continuous_online_start = None;
                        s.cluster.sync_status = "disconnected".to_string();
                        s.cluster.last_sync_err = format!("Peer {} returned status code {}", peer_url, status);
                    }
                    if status != reqwest::StatusCode::UNAUTHORIZED && status != reqwest::StatusCode::FORBIDDEN {
                        try_orphan_recovery(&st);
                    }
                    continue;
                }
                Err(e) => {
                    {
                        let mut s = st.lock_or_recover();
                        s.cluster.peer_online = false;
                        s.cluster.continuous_online_start = None;
                        s.cluster.sync_status = "disconnected".to_string();
                        s.cluster.last_sync_err = format!("Cannot connect to peer {}: {}", peer_url, e);
                    }
                    try_orphan_recovery(&st);
                    continue;
                }
            };

            // Peer responded! Check peer identity and cluster id
            let (my_hub_id, my_cluster_id) = {
                let s = st.lock_or_recover();
                (s.cluster.hub_id().to_string(), s.cluster.state.cluster_id.clone())
            };
            if remote_st.hub_id == my_hub_id {
                let mut s = st.lock_or_recover();
                s.cluster.peer_online = false;
                s.cluster.last_sync_err = format!("peer_url {} points to self (hub_id {})", peer_url, my_hub_id);
                continue;
            }
            if remote_st.cluster_id != my_cluster_id {
                let mut s = st.lock_or_recover();
                s.cluster.peer_online = false;
                s.cluster.last_sync_err = format!("cluster_id mismatch: peer has {} vs local {}", remote_st.cluster_id, my_cluster_id);
                continue;
            }
            if remote_st.epoch == u64::MAX {
                let mut s = st.lock_or_recover();
                s.cluster.peer_online = false;
                s.cluster.last_sync_err = "peer reports exhausted/invalid epoch (u64::MAX)".to_string();
                continue;
            }

            let now = Instant::now();
            {
                let mut s = st.lock_or_recover();
                s.cluster.peer_online = true;
                s.cluster.last_peer_contact = Some(now);
                s.cluster.peer_status = Some(remote_st.clone());
            }

            // R14-C04: Re-read live cluster role/epoch/config after HTTP probe await
            let (role, epoch) = {
                let s = st.lock_or_recover();
                (s.cluster.state.role.clone(), s.cluster.state.epoch)
            };

            // 2. Check split-brain conflict and resolve (H-10 & P1-5 & P0-2)
            if role == "primary" && remote_st.role == "primary" && remote_st.epoch == epoch {
                let (should_demote, save_cmd, audit_rec_opt) = {
                    let mut s = st.lock_or_recover();
                    // R7-D7-02: Structured tie-break avoiding simultaneous demotion of both Primaries
                    let should = if s.cluster.state.is_configured_primary != remote_st.is_configured_primary {
                        !s.cluster.state.is_configured_primary
                    } else {
                        s.cluster.hub_id() > remote_st.hub_id.as_str()
                    };
                    if should {
                        // P0-2 fix: demote must NOT bump epoch to prevent triggering peer ADR-04 demotion flip-flop
                        s.cluster.demote(epoch);
                        s.writes = false;
                        s.cluster.sync_status = "conflict_demoted".to_string();
                        force_full_cfg_resync = true;
                        force_full_cmd_resync = true;
                        let audit_rec = Arc::clone(&s.audit);
                        (true, Some(s.cluster.save_info()), Some(audit_rec))
                    } else {
                        s.cluster.sync_status = "conflict_master".to_string();
                        (false, None, None)
                    }
                };
                if let Some(audit_rec) = audit_rec_opt {
                    audit_rec.record("cluster", "", "cluster.split_brain_demoted", &format!("demoted to Standby against peer {}", remote_st.hub_id), None, None, "ok");
                }
                if let Some((p, st_file)) = save_cmd {
                    // N80-04: Check save_state_to_file result and record error if write fails
                    if let Err(e) = save_state_to_file(&p, &st_file) {
                        eprintln!("[hub] CLUSTER ERR: failed to save state after split-brain demote: {}", e);
                        let mut s = st.lock_or_recover();
                        s.cluster.last_sync_err = format!("split-brain demote save failed: {}", e);
                    } else {
                        println!("[hub] CLUSTER CONFLICT RESOLVED: Demoted to Standby keeping epoch {}", epoch);
                    }
                } else if !should_demote {
                    eprintln!("[hub] CLUSTER CONFLICT RESOLVED: Maintaining Primary role against peer {}", remote_st.hub_id);
                }
                continue;
            }

            // 3. Stale Primary auto-demote (ADR-04) - only when peer is actively Primary!
            if role == "primary" && remote_st.role == "primary" && remote_st.epoch > epoch {
                println!(
                    "[hub] Peer {} has higher epoch ({} > {}). Demoting local Primary to Standby.",
                    peer_url, remote_st.epoch, epoch
                );
                force_full_cfg_resync = true;
                force_full_cmd_resync = true;
                let (audit_rec, save_info) = {
                    let mut s = st.lock_or_recover();
                    s.cluster.demote(remote_st.epoch);
                    s.writes = false;
                    (Arc::clone(&s.audit), s.cluster.save_info())
                };
                if let Err(e) = save_state_to_file(&save_info.0, &save_info.1) {
                    eprintln!("[hub] CLUSTER ERR: failed to save state after stale primary demote: {}", e);
                    let mut s = st.lock_or_recover();
                    s.cluster.last_sync_err = format!("stale primary demote save failed: {}", e);
                }
                audit_rec.record(
                    "hub",
                    "",
                    "cluster.demote_stale_epoch",
                    &format!("demoted to Standby because remote epoch is {}", remote_st.epoch),
                    None,
                    None,
                    "ok",
                );
            }

            // 4. Standby incremental sync
            let mut current_role = {
                let s = st.lock_or_recover();
                s.cluster.state.role.clone()
            };

            let handover_in_flight = {
                let s = st.lock_or_recover();
                s.cluster.handover_lease_until.map(|t| Instant::now() < t).unwrap_or(false)
            };

            // P1-2, D7-H02 & R4-D7-01: Dual Standby recovery - total lexicographical ordering to prevent election deadlock
            if current_role == "standby" && remote_st.role == "standby" && !handover_in_flight {
                let (live_epoch, my_seq, live_is_cfg_primary) = {
                    let s = st.lock_or_recover();
                    (
                        s.cluster.state.epoch,
                        s.cmds.sync_stats().1,
                        s.cluster.state.is_configured_primary,
                    )
                };
                use std::cmp::Ordering;
                let my_data = (live_epoch, my_seq);
                let remote_data = (remote_st.epoch, remote_st.max_cmd_seq);
                let should_recover = match my_data.cmp(&remote_data) {
                    Ordering::Greater => true,
                    Ordering::Less => false,
                    Ordering::Equal => {
                        if live_is_cfg_primary != remote_st.is_configured_primary {
                            live_is_cfg_primary
                        } else {
                            my_hub_id < remote_st.hub_id
                        }
                    }
                };
                if should_recover {
                    let (new_ep, current_writes, save_info, audit_rec) = {
                        let mut s = st.lock_or_recover();
                        let target = Some(next_epoch(remote_st.epoch.max(s.cluster.epoch())));
                        let ep = s.cluster.promote(target);
                        s.writes = s.writes_allowed; // P1-3: Respect CLI --writes configuration
                        let writes = s.writes;
                        let audit_rec = Arc::clone(&s.audit);
                        (ep, writes, s.cluster.save_info(), audit_rec)
                    };
                    audit_rec.record("cluster", "", "cluster.zero_primary_recovered", &format!("recovered Primary role with epoch {} (writes={})", new_ep, current_writes), None, None, "ok");
                    if let Err(e) = save_state_to_file(&save_info.0, &save_info.1) {
                        eprintln!("[hub] CLUSTER ERR: failed to save state after dual standby recovery: {}", e);
                        let mut s = st.lock_or_recover();
                        s.cluster.last_sync_err = format!("dual standby recovery save failed: {}", e);
                    }
                    println!("[hub] DUAL-STANDBY DETECTED: Master identity recovered with epoch {}. Writes={}.", new_ep, current_writes);
                    // N76-09: Refresh local current_role snapshot so this newly promoted Primary
                    // does not immediately proceed to execute Standby sync logic in the same tick.
                    current_role = "primary".to_string();
                }
            }

            if current_role == "standby" {
                // HUB-02: Do NOT prematurely adopt higher epoch before /cluster/sync succeeds!
                // Epoch is safely updated in post-sync handler only when file_sync_err is None,
                // preventing unsynced Standby from claiming equal epoch and causing split-brain/data-loss on handover.

                // DEF-64-03: Zero-disk-IO under lock. Extract paths & in-memory stats, then compute file_sha256 outside lock.
                let (cfg_lines_count, local_max_cfg_rev, cmd_lines_count, local_max_cmd_seq, local_epoch, cfg_dirty, cmd_dirty, users_path, notif_path, curve_path, cfg_path, cmd_path) = {
                    let s = st.lock_or_recover();
                    let (cfg_tot, max_cfg) = s.cfg.sync_stats();
                    let (cmd_tot, max_seq) = s.cmds.sync_stats();
                    let ep = s.cluster.epoch();
                    let c_dirty = s.cfg.dirty_seq();
                    let m_dirty = s.cmds.dirty_seq();
                    let u_p = s.users.path().to_path_buf();
                    let n_p = s.notif_store.lock_or_recover().path().to_path_buf();
                    let c_p = s.cluster.curve_clients_path.clone();
                    let cfg_p = s.cfg.path().to_path_buf();
                    let cmd_p = s.cmds.path().to_path_buf();
                    (cfg_tot, max_cfg, cmd_tot, max_seq, ep, c_dirty, m_dirty, u_p, n_p, c_p, cfg_p, cmd_p)
                };

                // H-03 / H-PERF-01: When journal lines differ, sync is already required;
                // skip reading and hashing large commands.jsonl / config_revisions.jsonl from disk.
                let lines_differ = remote_st.cfg_lines != cfg_lines_count
                    || remote_st.cmd_lines != cmd_lines_count
                    || remote_st.max_cmd_seq != local_max_cmd_seq;

                let users_h = file_sha256(&users_path);
                let notif_h = file_sha256(&notif_path);
                let curve_h = file_sha256(&curve_path);
                let (cfg_h, cmd_h) = if lines_differ {
                    (String::new(), String::new())
                } else {
                    (
                        cached_journal_sha256(&cfg_path, (cfg_lines_count, cfg_dirty), &mut cfg_cache),
                        cached_journal_sha256(&cmd_path, (cmd_lines_count, cmd_dirty), &mut cmd_cache),
                    )
                };

                //--- N57-12: `> 0` created a blind spot. When the primary's
                //--- journal is compacted to nothing (everything terminal and
                //--- older than the retention window, then a restart), it reports
                //--- cmd_lines == 0 - and the old condition refused to sync
                //--- because "0 < N" was gated on "0 > 0". The standby then kept
                //--- serving a history that no longer existed anywhere and
                //--- reported a cmd_lines figure the primary would deny.
                //--- R59-07: users_hash mismatch only triggers sync when MTC_SYNC_USERS
                //--- is active. If sync is off, the primary refuses to send users_content,
                //--- so gating needs_sync on users_hash trapped the standby in an infinite
                //--- sync request loop and permanently blocked auto-failback.
                let users_sync_enabled = std::env::var("MTC_SYNC_USERS")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false);

                if !users_sync_enabled && remote_st.users_hash != users_h {
                    if last_users_warn.elapsed() >= Duration::from_secs(300) {
                        last_users_warn = Instant::now();
                        eprintln!(
                            "[hub] CLUSTER WARN: Primary users.json hash differs from Standby, but MTC_SYNC_USERS is off. User accounts will not be replicated."
                        );
                    }
                }

                //--- B1: an EMPTY hash means "this side does not have that feature
                //--- enabled" (file_sha256 returns "" when the path is empty or the
                //--- file does not exist - `--notifications none` sets path to "").
                //--- Comparing "" against a real hash made the two sides permanently
                //--- unequal: the Standby asked for a sync every second forever, the
                //--- write to the empty path failed, sync_status stuck at sync_err,
                //--- and ADR-10 auto-failback could never satisfy its "synced" gate.
                //--- Only compare a hash both sides can actually produce.
                //--- F-10: "enabled" is a property of the PATH, not of the hash.
                //--- The local side knows its own path; the remote side announces it.
                //--- A peer too old to send the flag is judged by its hash being
                //--- non-empty, which is what the previous rule did.
                let local_notif_on = !notif_path.as_os_str().is_empty();
                let remote_notif_on = remote_st.notif_enabled || !remote_st.notif_hash.is_empty();
                let notif_diff =
                    local_notif_on && remote_notif_on && remote_st.notif_hash != notif_h;

                let local_curve_on = !curve_path.as_os_str().is_empty();
                let remote_curve_on =
                    remote_st.curve_clients_enabled || !remote_st.curve_clients_hash.is_empty();
                let curve_diff =
                    local_curve_on && remote_curve_on && remote_st.curve_clients_hash != curve_h;

                let local_cfg_on = !cfg_path.as_os_str().is_empty();
                let local_cmd_on = !cmd_path.as_os_str().is_empty();
                let remote_cfg_on = remote_st.cfg_enabled || !remote_st.cfg_hash.is_empty();
                let remote_cmd_on = remote_st.cmd_enabled || !remote_st.cmd_hash.is_empty();
                let cfg_diff = local_cfg_on && remote_cfg_on && !lines_differ && remote_st.cfg_hash != cfg_h;
                let cmd_diff = local_cmd_on && remote_cmd_on && !lines_differ && remote_st.cmd_hash != cmd_h;
                // BUG-03: Allow users sync when Standby starts with no local users file (users_h is empty)
                let users_diff = users_sync_enabled && remote_st.users_sync_enabled && !remote_st.users_hash.is_empty() && remote_st.users_hash != users_h;

                let cfg_needed = local_cfg_on && remote_cfg_on && (remote_st.cfg_lines != cfg_lines_count || (local_max_cfg_rev > 0 && remote_st.max_cfg_rev != local_max_cfg_rev) || force_full_cfg_resync || cfg_diff);
                let cmd_needed = local_cmd_on && remote_cmd_on && (remote_st.cmd_lines != cmd_lines_count || remote_st.max_cmd_seq != local_max_cmd_seq || force_full_cmd_resync || cmd_diff);
                let needs_sync = cfg_needed
                    || cmd_needed
                    || remote_st.epoch > local_epoch
                    || users_diff
                    || notif_diff
                    || curve_diff;

                if needs_sync {
                    let was_syncing = {
                        let mut s = st.lock_or_recover();
                        let was = s.cluster.sync_status == "syncing";
                        s.cluster.sync_status = "syncing".to_string();
                        was
                    };
                    if !was_syncing {
                        println!(
                            "[hub] CLUSTER SYNC: Initiating sync with Primary (cfg: {}/{}, cmd: {}/{}, seq: {}/{})...",
                            cfg_lines_count, remote_st.cfg_lines, cmd_lines_count, remote_st.cmd_lines, local_max_cmd_seq, remote_st.max_cmd_seq
                        );
                    }

                    // If Primary's line count shrank, Primary performed compaction: full resync required
                    let cfg_compacted = remote_st.cfg_lines < last_known_remote_cfg_lines;
                    let cmd_compacted = remote_st.cmd_lines < last_known_remote_cmd_lines;

                    let rev_discontinuity = (local_max_cfg_rev > 0 && remote_st.max_cfg_rev < local_max_cfg_rev)
                        || (local_max_cfg_rev > 0 && remote_st.max_cfg_rev > local_max_cfg_rev + (remote_st.cfg_lines.saturating_sub(cfg_lines_count) as u64));
                    let full_cfg_resync = local_cfg_on && (cfg_lines_count > remote_st.cfg_lines
                        || cfg_diff
                        || cfg_compacted
                        || rev_discontinuity
                        || (cfg_lines_count == remote_st.cfg_lines && remote_st.max_cfg_rev != local_max_cfg_rev)
                        || std::mem::replace(&mut force_full_cfg_resync, false));
                    let req_from_cfg_line = if full_cfg_resync { 0 } else { cfg_lines_count };

                    // BUG-03, BUG-05, BUG-06 & R7-D7-03: If command line count is greater or divergent (cmd_diff),
                    // or remote sequence differs from line count expectations (compaction while offline),
                    // request from line 0 and replace_all to prevent splicing onto uncompacted journal.
                    let seq_discontinuity = (local_max_cmd_seq > 0 && remote_st.max_cmd_seq < local_max_cmd_seq)
                        || (local_max_cmd_seq > 0 && remote_st.max_cmd_seq > local_max_cmd_seq + (remote_st.cmd_lines.saturating_sub(cmd_lines_count) as u64));
                    let full_cmd_resync = local_cmd_on && (cmd_lines_count > remote_st.cmd_lines
                        || cmd_diff
                        || cmd_compacted
                        || seq_discontinuity
                        || (cmd_lines_count == remote_st.cmd_lines && remote_st.max_cmd_seq != local_max_cmd_seq)
                        || std::mem::replace(&mut force_full_cmd_resync, false));
                    let req_from_cmd_line = if full_cmd_resync { 0 } else { cmd_lines_count };

                    let sync_req = ClusterSyncRequest {
                        from_cfg_line: req_from_cfg_line,
                        from_cmd_line: req_from_cmd_line,
                        users_hash: users_h,
                        notif_hash: notif_h,
                        curve_clients_hash: curve_h,
                    };

                    let sync_url = format!("{}/api/v1/cluster/sync", peer_url);
                    let sync_res = client
                        .post(&sync_url)
                        .header("Authorization", format!("Bearer {}", token))
                        .json(&sync_req)
                        .send()
                        .await;

                    match sync_res {
                        Ok(res) if res.status().is_success() => {
                            if let Ok(data) = res.json::<ClusterSyncResponse>().await {
                                // N71-05: Extract component handles and paths, then perform disk I/O outside SharedState lock
                                let (cfg, cmds, notif_store, users_path, curve_clients_path) = {
                                    let s = st.lock_or_recover();
                                    (
                                        s.cfg.clone(),
                                        s.cmds.clone(),
                                        s.notif_store.clone(),
                                        s.users.path().to_path_buf(),
                                        s.cluster.curve_clients_path.clone(),
                                    )
                                };

                                let mut file_sync_err: Option<String> = None;

                                // Apply delta configs (or replace if Primary was compacted or full resync triggered)
                                //--- F-05: symmetrical with cmds: allow replace_all(&[]) when Primary cfg is 0
                                if full_cfg_resync {
                                    // N71-04: Validate batch completeness against response's total_cfg_lines
                                    if data.cfg_delta_lines.len() >= data.total_cfg_lines {
                                        if let Err(e) = cfg.replace_all(&data.cfg_delta_lines) {
                                            let msg = format!("cfg replace_all failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                            force_full_cfg_resync = true;
                                        }
                                    } else {
                                        let msg = format!("full cfg resync received truncated batch ({} < {}), deferring replace_all", data.cfg_delta_lines.len(), data.total_cfg_lines);
                                        eprintln!("[hub] WARN {}", msg);
                                        file_sync_err = Some(msg);
                                        force_full_cfg_resync = true;
                                    }
                                } else if !data.cfg_delta_lines.is_empty() {
                                    match cfg.apply_delta_lines(&data.cfg_delta_lines) {
                                        Ok(_applied) => {
                                            let current_lines = cfg.sync_stats().0;
                                            if current_lines <= cfg_lines_count && current_lines < remote_st.cfg_lines {
                                                eprintln!("[hub] cluster sync: cfg delta received {} lines but local line count {} did not advance; scheduling full replace_all to align physical files", data.cfg_delta_lines.len(), current_lines);
                                                force_full_cfg_resync = true;
                                            }
                                        }
                                        Err(e) => {
                                            let msg = format!("cfg apply_delta_lines failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                        }
                                    }
                                }

                                // Apply delta commands (or replace if Primary was compacted or full resync triggered)
                                if full_cmd_resync {
                                    // N71-04: Validate batch completeness against response's total_cmd_lines
                                    if data.cmd_delta_lines.len() >= data.total_cmd_lines {
                                        if let Err(e) = cmds.replace_all(&data.cmd_delta_lines) {
                                            let msg = format!("cmds replace_all failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                            force_full_cmd_resync = true;
                                        }
                                    } else {
                                        let msg = format!("full cmd resync received truncated batch ({} < {}), deferring replace_all", data.cmd_delta_lines.len(), data.total_cmd_lines);
                                        eprintln!("[hub] WARN {}", msg);
                                        file_sync_err = Some(msg);
                                        force_full_cmd_resync = true;
                                    }
                                } else if !data.cmd_delta_lines.is_empty() {
                                    // F-01: Check and propagate apply_delta_lines failure to prevent false synced status
                                    match cmds.apply_delta_lines(&data.cmd_delta_lines) {
                                        Ok(_applied) => {
                                            let current_lines = cmds.sync_stats().0;
                                            if current_lines <= cmd_lines_count && current_lines < remote_st.cmd_lines {
                                                eprintln!("[hub] cluster sync: cmd delta received {} lines but local line count {} did not advance; scheduling full replace_all to align physical files", data.cmd_delta_lines.len(), current_lines);
                                                force_full_cmd_resync = true;
                                            }
                                        }
                                        Err(e) => {
                                            let msg = format!("cmds apply_delta_lines failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                        }
                                    }
                                }

                                // Apply full users content if updated (A86-08: propagate all errors)
                                let mut reload_users = false;
                                if let Some(u_content) = data.users_content {
                                    let tmp = unique_tmp_path(&users_path, "users");
                                    match File::create(&tmp).and_then(|mut f| {
                                        f.write_all(u_content.as_bytes())?;
                                        f.sync_all()
                                    }) {
                                        Ok(()) => {
                                            if let Err(e) = atomic_replace_file(&tmp, &users_path) {
                                                let msg = format!("users file replace failed: {}", e);
                                                eprintln!("[hub] cluster sync: {}", msg);
                                                file_sync_err = Some(msg);
                                            } else {
                                                reload_users = true;
                                            }
                                        }
                                        Err(e) => {
                                            let msg = format!("users file write failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                        }
                                    }
                                }

                                // Apply full notification channels if updated (A86-08: propagate all errors)
                                if let Some(n_content) = data.notif_content {
                                    let p = notif_store.lock_or_recover().path().to_path_buf();
                                    if p.as_os_str().is_empty() {
                                        //--- B1: this side runs with `--notifications none`.
                                        //--- Previously the write targeted the literal path
                                        //--- ".tmp.<pid>" in the working directory and the
                                        //--- replace of "" always failed, so a deliberate
                                        //--- configuration choice permanently pinned
                                        //--- sync_status to sync_err and littered the cwd.
                                        //--- Nothing to do: skipping is the correct outcome,
                                        //--- and it is NOT a sync error.
                                        eprintln!("[hub] cluster sync: local notifications are disabled (--notifications none); channel content not applied");
                                    } else {
                                    let tmp_path = unique_tmp_path(&p, "notif");
                                    match File::create(&tmp_path).and_then(|mut f| {
                                        f.write_all(n_content.as_bytes())?;
                                        f.sync_all()
                                    }) {
                                        Ok(()) => {
                                            if let Err(e) = atomic_replace_file(&tmp_path, &p) {
                                                let msg = format!("notifications file replace failed: {}", e);
                                                eprintln!("[hub] cluster sync: {}", msg);
                                                file_sync_err = Some(msg);
                                            } else if let Err(e) = notif_store.lock_or_recover().load() {
                                                let msg = format!("notifications reload failed: {}", e);
                                                eprintln!("[hub] cluster sync: {}", msg);
                                                file_sync_err = Some(msg);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = format!("notifications file write failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                        }
                                    }
                                    }
                                }

                                // P1-6 & A86-08: Apply curve clients content via atomic file overwrite with error propagation
                                if let Some(c_content) = data.curve_clients_content {
                                    if curve_clients_path.as_os_str().is_empty() {
                                        eprintln!("[hub] cluster sync: local curve allow-list path is empty; content not applied");
                                    } else {
                                    let tmp_path = unique_tmp_path(&curve_clients_path, "curve");
                                    match File::create(&tmp_path).and_then(|mut f| {
                                        f.write_all(c_content.as_bytes())?;
                                        f.sync_all()
                                    }) {
                                        Ok(()) => {
                                            if let Err(e) = atomic_replace_file(&tmp_path, &curve_clients_path) {
                                                let msg = format!("curve clients file replace failed: {}", e);
                                                eprintln!("[hub] cluster sync: {}", msg);
                                                file_sync_err = Some(msg);
                                            }
                                        }
                                        Err(e) => {
                                            let msg = format!("curve clients file write failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                        }
                                    }
                                    }
                                }

                                // N72-03 & A86-08: Pre-load users outside SharedState lock; report error if parse fails
                                let loaded_users = if reload_users {
                                    match crate::users::UserStore::load_at(&users_path) {
                                        Ok(u) => Some(u.into_users()),
                                        Err(e) => {
                                            let msg = format!("users file parse failed: {}", e);
                                            eprintln!("[hub] cluster sync: {}", msg);
                                            file_sync_err = Some(msg);
                                            None
                                        }
                                    }
                                } else {
                                    None
                                };

                                // Re-acquire SharedState lock briefly for in-memory status updates only (<5 microseconds)
                                let (need_save_cluster, state_to_save, state_path_to_save) = {
                                    let mut s = st.lock_or_recover();
                                    if let Some(u) = loaded_users {
                                        s.users.apply_loaded_users(u);
                                    }

                                    //--- F-11: adopt the Primary's epoch ONLY when every
                                    //--- part of the payload actually landed. This is the
                                    //--- guard the HUB-02 comment above promises; without
                                    //--- it a failed file write left the Standby holding
                                    //--- OLD users/commands/CURVE data while claiming the
                                    //--- Primary's epoch, so a later promote or takeover
                                    //--- would carry stale state into the highest epoch -
                                    //--- exactly the rollback HUB-02 exists to prevent.
                                    let cfg_shrunk = data.total_cfg_lines < req_from_cfg_line;
                                    let cmd_shrunk = data.total_cmd_lines < req_from_cmd_line;
                                    if cfg_shrunk {
                                        force_full_cfg_resync = true;
                                    }
                                    if cmd_shrunk {
                                        force_full_cmd_resync = true;
                                    }
                                    let batch_incomplete = cfg_shrunk
                                        || cmd_shrunk
                                        || (req_from_cmd_line + data.cmd_delta_lines.len() < data.total_cmd_lines)
                                        || (req_from_cfg_line + data.cfg_delta_lines.len() < data.total_cfg_lines);
                                    let sync_clean = file_sync_err.is_none() && !batch_incomplete;
                                    let save_info = if sync_clean && data.epoch > s.cluster.epoch() {
                                        s.cluster.state.epoch = data.epoch;
                                        (true, s.cluster.state.clone(), s.cluster.state_path.clone())
                                    } else {
                                        (false, s.cluster.state.clone(), s.cluster.state_path.clone())
                                    };

                                    if let Some(err) = file_sync_err {
                                        s.cluster.sync_status = "sync_err".to_string();
                                        s.cluster.last_sync_err = err;
                                    } else if batch_incomplete {
                                        s.cluster.sync_status = "syncing".to_string();
                                        s.cluster.last_sync_err = format!("catching up: batch received, {}/{} cmds, {}/{} cfgs", req_from_cmd_line + data.cmd_delta_lines.len(), data.total_cmd_lines, req_from_cfg_line + data.cfg_delta_lines.len(), data.total_cfg_lines);
                                    } else {
                                        s.cluster.sync_status = "synced".to_string();
                                        s.cluster.last_sync_at = Some(Instant::now());
                                        s.cluster.last_sync_err = String::new();
                                    }
                                    last_known_remote_cfg_lines = remote_st.cfg_lines;
                                    last_known_remote_cmd_lines = remote_st.cmd_lines;
                                    save_info
                                };

                                // N72-03 & N80-04: Save cluster state to disk outside the SharedState lock
                                if need_save_cluster {
                                    if let Err(e) = save_state_to_file(&state_path_to_save, &state_to_save) {
                                        eprintln!("[hub] CLUSTER ERR: failed to save state after sync: {}", e);
                                        let mut s = st.lock_or_recover();
                                        s.cluster.sync_status = "sync_err".to_string();
                                        s.cluster.last_sync_err = format!("state save failed: {}", e);
                                    }
                                }
                            } else {
                                let mut s = st.lock_or_recover();
                                s.cluster.sync_status = "sync_err".to_string();
                                s.cluster.last_sync_err = "failed to parse sync response json".to_string();
                            }
                        }
                        Ok(res) => {
                            let mut s = st.lock_or_recover();
                            s.cluster.sync_status = "sync_err".to_string();
                            s.cluster.last_sync_err = format!("sync request returned status {}", res.status());
                        }
                        Err(e) => {
                            let mut s = st.lock_or_recover();
                            s.cluster.sync_status = "sync_err".to_string();
                            s.cluster.last_sync_err = format!("sync network request failed: {}", e);
                        }
                    }
                } else {
                    let mut s = st.lock_or_recover();
                    s.cluster.sync_status = "synced".to_string();
                    s.cluster.last_sync_err = String::new();
                }

                // N68-02: Maintain continuous online duration strictly AFTER sync action completes.
                // Accumulated ONLY when Standby is genuinely in synced state with Primary.
                // Reset immediately to None if sync failed, peer disconnected, or peer is non-primary.
                {
                    let mut s = st.lock_or_recover();
                    if remote_st.role == "primary" && s.cluster.sync_status == "synced" {
                        if s.cluster.continuous_online_start.is_none() {
                            s.cluster.continuous_online_start = Some(now);
                        }
                    } else {
                        s.cluster.continuous_online_start = None;
                    }
                }

                // 5. ADR-10 Auto-Failback Check (re-read live config/lock under mutex after sync)
                let (can_failback, continuous_secs, live_hours) = {
                    let s = st.lock_or_recover();
                    let online_dur = s
                        .cluster
                        .continuous_online_start
                        .map(|t| t.elapsed().as_secs_f64())
                        .unwrap_or(0.0);
                    let h = s.cluster.state.failback_stabilization_hours;
                    let eligible = s.cluster.state.role == "standby"
                        && s.cluster.state.is_configured_primary
                        && !s.cluster.state.failback_locked
                        && s.cluster.sync_status == "synced"
                        && online_dur >= (h * 3600.0);
                    (eligible, online_dur, h)
                };

                let cooldown_ok = match last_failback_attempt {
                    Some(t) => t.elapsed() >= Duration::from_secs(60),
                    None => true,
                };

                if can_failback && cooldown_ok {
                    last_failback_attempt = Some(Instant::now());
                    println!(
                        "[hub] ADR-10: Host online continuous {:.1}s >= {:.1}h. Requesting graceful failback...",
                        continuous_secs, live_hours
                    );
                    let handover_url = format!("{}/api/v1/cluster/handover-request", peer_url);
                    let h_req = HandoverRequest {
                        from_hub_id: {
                            let s = st.lock_or_recover();
                            s.cluster.hub_id().to_string()
                        },
                        //--- N56-11: re-read the epoch under the lock. `epoch`
                        //--- was captured at the top of this tick, BEFORE the
                        //--- sync block above adopted the peer's epoch. Sending
                        //--- that stale value makes the peer reject the handover
                        //--- ("from_epoch is behind local epoch"), so graceful
                        //--- failback could never complete and the stabilization
                        //--- clock was reset every time.
                        from_epoch: {
                            let s = st.lock_or_recover();
                            s.cluster.epoch()
                        },
                        is_configured_primary: true,
                        reason: "auto_failback_stabilization_met".to_string(),
                    };

                    let h_res = client
                        .post(&handover_url)
                        .header("Authorization", format!("Bearer {}", token))
                        .json(&h_req)
                        .send()
                        .await;

                    if let Ok(res) = h_res {
                        if let Ok(h_data) = res.json::<HandoverResponse>().await {
                            if h_data.agreed {
                                let (audit_rec, new_ep, save_info) = {
                                    let mut s = st.lock_or_recover();
                                    // P0-02 & F-02: Target epoch must strictly exceed both peer and local epochs to prevent tie/split-brain
                                    let target_ep = Some(next_epoch(h_data.new_epoch.max(s.cluster.epoch())));
                                    let new_ep = s.cluster.promote(target_ep);
                                    s.writes = s.writes_allowed; // P1-3: Respect CLI --writes configuration
                                    let current_writes = s.writes;
                                    println!(
                                        "[hub] ADR-10 AUTO-FAILBACK SUCCESS: Master identity recovered with epoch {}! Writes={}.",
                                        new_ep, current_writes
                                    );
                                    (Arc::clone(&s.audit), new_ep, s.cluster.save_info())
                                };
                                if let Err(e) = save_state_to_file(&save_info.0, &save_info.1) {
                                    eprintln!("[hub] CLUSTER ERR: failed to save state after auto-failback: {}", e);
                                    let mut s = st.lock_or_recover();
                                    s.cluster.last_sync_err = format!("auto-failback save failed: {}", e);
                                }
                                audit_rec.record(
                                    "hub",
                                    "",
                                    "cluster.failback_success",
                                    &format!("recovered Master identity with epoch {}", new_ep),
                                    None,
                                    None,
                                    "ok",
                                );
                            } else {
                                let reason = h_data.error.clone().unwrap_or_else(|| "handover rejected by peer".to_string());
                                eprintln!("[hub] ADR-10 AUTO-FAILBACK REJECTED by Primary: {}", reason);
                                let mut s = st.lock_or_recover();
                                if !reason.contains("lagging") && !reason.contains("behind") {
                                    s.cluster.continuous_online_start = None;
                                }
                                s.cluster.last_sync_err = format!("failback rejected: {}", reason);
                            }
                        }
                    }
                }
            } else {
                // BUG-02 & BUG-03 / H7-05: Primary node verifies if Standby peer has caught up with our journals and hashes
                let (my_cfg, my_cmd, my_seq, my_cfg_dirty, my_cmd_dirty, cfg_p, cmd_p, u_p, c_p, n_p) = {
                    let s = st.lock_or_recover();
                    let n_path = s.notif_store.lock_or_recover().path().to_path_buf();
                    (
                        s.cfg.total_lines(),
                        s.cmds.sync_stats().0,
                        s.cmds.sync_stats().1,
                        s.cfg.dirty_seq(),
                        s.cmds.dirty_seq(),
                        s.cfg.path().to_path_buf(),
                        s.cmds.path().to_path_buf(),
                        s.users.path().to_path_buf(),
                        s.cluster.curve_clients_path.clone(),
                        n_path,
                    )
                };
                let users_sync_enabled = std::env::var("MTC_SYNC_USERS")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false);

                let my_u_h = file_sha256(&u_p);
                let my_n_h = file_sha256(&n_p);
                let my_c_h = file_sha256(&c_p);

                // DEF-01: cmd_in_sync strictly requires both max_seq AND total line count
                let cmd_in_sync = remote_st.cmd_lines == my_cmd && (my_seq == 0 || remote_st.max_cmd_seq == my_seq);
                let lines_match = remote_st.cmd_lines == my_cmd && remote_st.max_cmd_seq == my_seq && remote_st.cfg_lines == my_cfg;
                let (my_cfg_h, my_cmd_h) = if lines_match {
                    (
                        cached_journal_sha256(&cfg_p, (my_cfg, my_cfg_dirty), &mut primary_cfg_cache),
                        cached_journal_sha256(&cmd_p, (my_cmd, my_cmd_dirty), &mut primary_cmd_cache),
                    )
                } else {
                    (String::new(), String::new())
                };

                let local_notif_on = !n_p.as_os_str().is_empty();
                let local_curve_on = !c_p.as_os_str().is_empty();
                let remote_notif_on = remote_st.notif_enabled || !remote_st.notif_hash.is_empty();
                let remote_curve_on = remote_st.curve_clients_enabled || !remote_st.curve_clients_hash.is_empty();
                let hashes_ok = (remote_st.cfg_hash == my_cfg_h)
                    && (remote_st.cmd_hash == my_cmd_h)
                    && (!users_sync_enabled || !remote_st.users_sync_enabled || remote_st.users_hash == my_u_h)
                    && (!local_notif_on || !remote_notif_on || remote_st.notif_hash == my_n_h)
                    && (!local_curve_on || !remote_curve_on || remote_st.curve_clients_hash == my_c_h);

                let mut s = st.lock_or_recover();
                if !cmd_in_sync || remote_st.cmd_lines != my_cmd || remote_st.cfg_lines != my_cfg || !hashes_ok {
                    s.cluster.sync_status = "lagging".to_string();
                    s.cluster.last_sync_err = format!(
                        "standby lagging behind (cmd: {}/{} seq: {}/{} cfg: {}/{} hashes_ok: {})",
                        remote_st.cmd_lines, my_cmd, remote_st.max_cmd_seq, my_seq, remote_st.cfg_lines, my_cfg, hashes_ok
                    );
                } else {
                    s.cluster.sync_status = "synced".to_string();
                    s.cluster.last_sync_err = String::new();
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ADR-03: a Standby that has lost its peer for well over 30s must stay
    /// read-only unless `--auto-promote` was given, and must promote when it was.
    #[test]
    fn standby_does_not_self_promote_unless_auto_promote_is_on() {
        let make = |auto: bool| -> SharedState {
            let audit = Arc::new(crate::audit::Audit::disabled());
            let cfg = Arc::new(crate::config::ConfigStore::disabled());
            let cmds = Arc::new(crate::commands::CommandStore::disabled());
            let mut cm = ClusterManager::disabled();
            cm.state.role = "standby".to_string();
            cm.state.is_configured_primary = false;
            cm.last_peer_contact = Instant::now().checked_sub(Duration::from_secs(120));
            cm.auto_promote = auto;
            cm.state_path = std::env::temp_dir()
                .join(format!("mtc_adr03_state_{}_{}.json", std::process::id(), auto));
            let mut s = crate::api::Shared::new(
                0,
                audit,
                cfg,
                cmds,
                true,
                None,
                cm,
            );
            s.writes = false;
            Arc::new(std::sync::Mutex::new(s))
        };

        let off = make(false);
        try_orphan_recovery(&off);
        {
            let s = off.lock_or_recover();
            assert_eq!(s.cluster.state.role, "standby", "must not self-promote when auto_promote is off");
            assert!(!s.writes, "write gate must stay closed when auto_promote is off");
        }

        let on = make(true);
        try_orphan_recovery(&on);
        {
            let s = on.lock_or_recover();
            assert_eq!(s.cluster.state.role, "primary", "must self-promote when auto_promote is on");
        }
    }

    #[test]
    fn test_cluster_state_file_save_and_load() {
        let dir = std::env::temp_dir().join(format!("mtc_test_cluster_{}", crate::users::random_token()));
        let _ = fs::create_dir_all(&dir);
        let state_path = dir.join("cluster_state.json");
        let curve_path = dir.join("curve_clients.txt");

        let cm = ClusterManager::load_or_create(
            &state_path,
            &curve_path,
            Some("primary"),
            "http://127.0.0.1:6011",
            "tcp://127.0.0.1:6001",
            "test_token_0123456789abcdef",
            24.0,
            false,
        ).expect("create cluster manager");

        assert!(cm.is_primary());
        assert!(!cm.is_standby());
        assert_eq!(cm.epoch(), 1);
        assert_eq!(cm.role(), "primary");
        assert_eq!(cm.peer_url, "http://127.0.0.1:6011");
        assert_eq!(cm.peer_zmq, "tcp://127.0.0.1:6001");
        assert_eq!(cm.cluster_token, "test_token_0123456789abcdef");

        // Reload from file
        let reloaded = ClusterManager::load_or_create(
            &state_path,
            &curve_path,
            None,
            "http://127.0.0.1:6011",
            "tcp://127.0.0.1:6001",
            "test_token_0123456789abcdef",
            24.0,
            false,
        ).expect("reload cluster manager");

        assert_eq!(reloaded.hub_id(), cm.hub_id());
        assert_eq!(reloaded.epoch(), 1);
        assert!(reloaded.is_primary());
        assert_eq!(reloaded.peer_url, "http://127.0.0.1:6011");
        assert_eq!(reloaded.peer_zmq, "tcp://127.0.0.1:6001");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_cluster_promote_and_demote() {
        let dir = std::env::temp_dir().join(format!("mtc_test_cluster_pd_{}", crate::users::random_token()));
        let _ = fs::create_dir_all(&dir);
        let state_path = dir.join("cluster_state.json");
        let curve_path = dir.join("curve_clients.txt");

        let mut cm = ClusterManager::load_or_create(
            &state_path,
            &curve_path,
            Some("standby"),
            "",
            "",
            "",
            24.0,
            false,
        ).expect("create standby");

        assert!(cm.is_standby());
        assert_eq!(cm.epoch(), 1);

        let new_epoch = cm.promote(None);
        assert_eq!(new_epoch, 2);
        assert!(cm.is_primary());
        assert_eq!(cm.epoch(), 2);

        cm.demote(5);
        assert!(cm.is_standby());
        assert_eq!(cm.epoch(), 5);

        cm.set_failback_lock(true);
        assert!(cm.state.failback_locked);
        cm.set_failback_lock(false);
        assert!(!cm.state.failback_locked);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_file_sha256() {
        let dir = std::env::temp_dir().join(format!("mtc_test_sha_{}", crate::users::random_token()));
        let _ = fs::create_dir_all(&dir);
        let file_path = dir.join("test.txt");

        fs::write(&file_path, b"hello world\n").expect("write test file");
        let hash = file_sha256(&file_path);
        assert_eq!(hash.len(), 64);

        // Non-existent file gives empty string
        let no_hash = file_sha256(&dir.join("non_existent.txt"));
        assert_eq!(no_hash, "");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_epoch_overflow_protection_and_exhausted_load_rejection() {
        // F-02: Test that next_epoch does not overflow-wrap to 0
        assert_eq!(next_epoch(1), 2);
        assert_eq!(next_epoch(u64::MAX - 1), u64::MAX);
        assert_eq!(next_epoch(u64::MAX), u64::MAX);

        // Test that load_or_create rejects state file with epoch == u64::MAX
        let dir = std::env::temp_dir().join(format!("mtc_test_epoch_max_{}", crate::users::random_token()));
        let _ = fs::create_dir_all(&dir);
        let state_path = dir.join("cluster_state.json");
        let curve_path = dir.join("curve_clients.txt");

        let bad_state = serde_json::json!({
            "cluster_id": "test",
            "hub_id": "hub-bad",
            "role": "primary",
            "epoch": u64::MAX,
            "last_promoted_at": 100,
            "is_configured_primary": true,
            "failback_stabilization_hours": 24.0,
            "failback_locked": false,
            "cluster_token": "ctok_1234567890123456",
            "peer_url": "",
            "peer_zmq": ""
        });
        fs::write(&state_path, bad_state.to_string()).unwrap();

        let res = ClusterManager::load_or_create(
            &state_path,
            &curve_path,
            None,
            "",
            "",
            "",
            24.0,
            false,
        );
        match res {
            Err(e) => assert!(e.contains("exhausted")),
            Ok(_) => panic!("must reject exhausted epoch state"),
        }

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_cached_journal_sha256_invalidates_on_same_size_rewrite() {
        let dir = std::env::temp_dir().join(format!("mtc_test_cache_{}", crate::users::random_token()));
        let _ = fs::create_dir_all(&dir);
        let file_path = dir.join("commands.jsonl");
        let mut cache = None;

        // Initial content: state is pending (7 bytes)
        let content_v1 = b"{\"id\":1001,\"state\":\"pending\"}\n";
        fs::write(&file_path, content_v1).unwrap();
        let hash_v1 = cached_journal_sha256(&file_path, (1, 0), &mut cache);

        // Same-size rewrite: state becomes unknown (also 7 bytes, identical file length)
        let content_v2 = b"{\"id\":1001,\"state\":\"unknown\"}\n";
        assert_eq!(content_v1.len(), content_v2.len());
        fs::write(&file_path, content_v2).unwrap();

        // With updated mutation version (dirty_seq incremented from 0 to 1), hash must invalidate!
        let hash_v2 = cached_journal_sha256(&file_path, (1, 1), &mut cache);
        assert_ne!(hash_v1, hash_v2, "CRITICAL: Cached hash returned stale SHA-256 on same-size rewrite!");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_unique_tmp_path_is_monotonic() {
        let p = PathBuf::from("sample.json");
        let t1 = unique_tmp_path(&p, "save");
        let t2 = unique_tmp_path(&p, "save");
        assert_ne!(t1, t2, "consecutive unique_tmp_path calls must produce distinct paths");
    }
}
