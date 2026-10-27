//! cluster.rs - HA Cluster Manager, State Machine, and Replication Engine.
//!
//! Enforces:
//! - ADR-03: Single-Writer policy (Primary writable, Standby read-only).
//! - ADR-04: Epoch-fenced state recovery (stale Primary automatically demoted).
//! - ADR-08: Incremental high-watermark replication of 5 key persistent files:
//!   `users.json`, `alert_channels.json`, `curve_clients.txt`, `config_revisions.jsonl`, `commands.jsonl`.
//! - ADR-09: Cluster token authentication over internal HTTP sync endpoints.
//! - ADR-10: Two-Phase Handover for graceful auto-failback to Primary after continuous online stabilization.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::api::SharedState;
use crate::lockx::LockExt;

pub const DEFAULT_CLUSTER_ID: &str = "mt-copier-cluster";
pub const DEFAULT_CLUSTER_TOKEN: &str = "mtc-cluster-auth-secret-token";
pub const DEFAULT_STATE_FILE: &str = "cluster_state.json";
pub const DEFAULT_FAILBACK_HOURS: f64 = 24.0;

static HASH_CACHE: Mutex<Option<HashMap<PathBuf, (Option<SystemTime>, u64, String)>>> = Mutex::new(None);

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
    pub users_hash: String,
    pub notif_hash: String,
    pub curve_clients_hash: String,
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

/// Runtime cluster manager held inside `Shared`.
pub struct ClusterManager {
    pub state_path: PathBuf,
    pub curve_clients_path: PathBuf,
    pub state: ClusterStateFile,
    pub peer_url: String,
    pub cluster_token: String,
    pub peer_online: bool,
    pub last_peer_contact: Option<Instant>,
    pub continuous_online_start: Option<Instant>,
    pub peer_status: Option<ClusterStatusResponse>,
    pub last_sync_at: Option<Instant>,
    pub sync_status: String, // "synced", "syncing", "lagging", "disconnected", "conflict", "standalone"
    pub last_sync_err: String,
}

/// Compute SHA-256 hex string of a file with mtime/len fast-path caching. Returns empty string if file does not exist.
pub fn file_sha256(path: &Path) -> String {
    let meta = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return String::new(),
    };
    let mtime = meta.modified().ok();
    let len = meta.len();

    let mut guard = HASH_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let map = guard.get_or_insert_with(HashMap::new);
    if let Some((c_mtime, c_len, hash)) = map.get(path) {
        if *c_mtime == mtime && *c_len == len {
            return hash.clone();
        }
    }

    if let Ok(bytes) = fs::read(path) {
        let hash = crate::users::hex(&crate::users::sha256(&bytes));
        map.insert(path.to_path_buf(), (mtime, len, hash.clone()));
        hash
    } else {
        String::new()
    }
}

impl ClusterManager {
    pub fn load_or_create(
        state_path: &Path,
        curve_clients_path: &Path,
        cli_role: Option<&str>,
        peer_url: &str,
        cluster_token: &str,
        failback_hours: f64,
        failback_lock: bool,
    ) -> Result<Self, String> {
        let mut state: ClusterStateFile = if state_path.exists() {
            let data = fs::read_to_string(state_path)
                .map_err(|e| format!("cannot read {}: {}", state_path.display(), e))?;
            serde_json::from_str(&data)
                .map_err(|e| format!("cannot parse {}: {}", state_path.display(), e))?
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
            }
        };

        // If explicit CLI role passed, apply it
        if let Some(r) = cli_role {
            state.role = r.to_string();
            if r == "primary" {
                state.is_configured_primary = true;
            } else if r == "standby" {
                state.is_configured_primary = false;
            }
        }
        if failback_lock {
            state.failback_locked = true;
        }
        if failback_hours > 0.0 {
            state.failback_stabilization_hours = failback_hours;
        }

        //--- A token that has shipped inside this repository is public
        //--- knowledge, not a secret. Accepting one is equivalent to accepting
        //--- no authentication at all, so the known-public values are treated
        //--- exactly like an empty token. The length floor exists for the same
        //--- reason: "abc" is not a credential. (N56-01)
        let token_is_usable = |t: &str| -> bool {
            !t.is_empty()
                && t.len() >= 16
                && t != DEFAULT_CLUSTER_TOKEN
                && t != "mtc_shared_cluster_token_2026"
        };

        let resolved_token = if token_is_usable(&cluster_token) {
            cluster_token.to_string()
        } else if token_is_usable(&state.cluster_token) {
            state.cluster_token.clone()
        } else {
            let gen = format!("ctok_{}_{}", unix_secs(), &crate::users::random_token()[..16]);
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
            peer_url: peer_url.trim_end_matches('/').to_string(),
            cluster_token: resolved_token,
            peer_online: false,
            last_peer_contact: None,
            continuous_online_start: None,
            peer_status: None,
            last_sync_at: None,
            sync_status: if peer_url.is_empty() { "standalone".to_string() } else { "disconnected".to_string() },
            last_sync_err: String::new(),
        };

        cm.save().map_err(|e| format!("cannot save {}: {}", state_path.display(), e))?;
        Ok(cm)
    }

    pub fn save(&self) -> io::Result<()> {
        let tmp = PathBuf::from(format!("{}.tmp.{}", self.state_path.display(), std::process::id()));
        let text = serde_json::to_string_pretty(&self.state)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        {
            let mut f = File::create(&tmp)?;
            f.write_all(text.as_bytes())?;
            f.sync_all()?;
        }
        //--- N56-03: NO remove_file() before the rename.
        //---
        //--- On Windows rename() is MoveFileEx(REPLACE_EXISTING), so it already
        //--- replaces atomically. Deleting the target first opens a window where
        //--- a crash leaves NO state file at all - and the next boot then invents
        //--- a fresh hub_id, epoch=1 and whatever role the CLI passed. That is
        //--- precisely how a standby comes back as a write-enabled primary, and
        //--- it also breaks HandoverRequest.from_hub_id forever.
        match fs::rename(&tmp, &self.state_path) {
            Ok(()) => Ok(()),
            Err(_) => {
                //--- Some Windows setups still refuse to replace a file another
                //--- handle holds open. Copy over the target instead of deleting
                //--- it: never destroy the only copy we have.
                let r = fs::copy(&tmp, &self.state_path).map(|_| ());
                let _ = fs::remove_file(&tmp);
                r
            }
        }
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

    pub fn promote(&mut self, target_epoch: Option<u64>) -> u64 {
        let new_epoch = target_epoch.unwrap_or(self.state.epoch + 1);
        self.state.epoch = new_epoch;
        self.state.role = "primary".to_string();
        self.state.last_promoted_at = unix_secs();
        let _ = self.save();
        new_epoch
    }

    pub fn demote(&mut self, new_epoch: u64) {
        // P0-2: demote does not advance epoch past what was requested
        self.state.epoch = new_epoch.max(self.state.epoch);
        self.state.role = "standby".to_string();
        self.continuous_online_start = None;
        let _ = self.save();
    }

    pub fn set_failback_lock(&mut self, locked: bool) {
        self.state.failback_locked = locked;
        let _ = self.save();
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
            },
            peer_url: String::new(),
            cluster_token: DEFAULT_CLUSTER_TOKEN.to_string(),
            peer_online: false,
            last_peer_contact: None,
            continuous_online_start: None,
            peer_status: None,
            last_sync_at: None,
            sync_status: "standalone".to_string(),
            last_sync_err: String::new(),
        }
    }
}

/// Spawns the background cluster replication and failback manager loop.
pub fn spawn_cluster_worker(st: SharedState, check_interval: Duration) {
    tokio::spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(3))
            .build()
            .unwrap_or_default();

        loop {
            tokio::time::sleep(check_interval).await;

            let (peer_url, token, role, epoch, is_cfg_primary, locked, hours) = {
                let s = st.lock_or_recover();
                (
                    s.cluster.peer_url.clone(),
                    s.cluster.cluster_token.clone(),
                    s.cluster.state.role.clone(),
                    s.cluster.state.epoch,
                    s.cluster.state.is_configured_primary,
                    s.cluster.state.failback_locked,
                    s.cluster.state.failback_stabilization_hours,
                )
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
                        let mut s = st.lock_or_recover();
                        s.cluster.peer_online = false;
                        s.cluster.continuous_online_start = None;
                        s.cluster.sync_status = "disconnected".to_string();
                        s.cluster.last_sync_err = format!("Failed to parse status from {}: {}", peer_url, e);
                        continue;
                    }
                },
                Ok(r) => {
                    let mut s = st.lock_or_recover();
                    s.cluster.peer_online = false;
                    s.cluster.continuous_online_start = None;
                    s.cluster.sync_status = "disconnected".to_string();
                    s.cluster.last_sync_err = format!("Peer {} returned status code {}", peer_url, r.status());
                    continue;
                }
                Err(e) => {
                    let mut s = st.lock_or_recover();
                    s.cluster.peer_online = false;
                    s.cluster.continuous_online_start = None;
                    s.cluster.sync_status = "disconnected".to_string();
                    s.cluster.last_sync_err = format!("Cannot connect to peer {}: {}", peer_url, e);
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

            let now = Instant::now();
            {
                let mut s = st.lock_or_recover();
                s.cluster.peer_online = true;
                s.cluster.last_peer_contact = Some(now);
                s.cluster.peer_status = Some(remote_st.clone());
            }

            // 2. Check split-brain conflict and resolve (H-10 & P1-5 & P0-2)
            if role == "primary" && remote_st.role == "primary" && remote_st.epoch == epoch {
                let mut s = st.lock_or_recover();
                let should_demote = !s.cluster.state.is_configured_primary
                    || (remote_st.is_configured_primary && s.cluster.hub_id() > remote_st.hub_id.as_str());
                if should_demote {
                    // P0-2 fix: demote must NOT bump epoch to prevent triggering peer ADR-04 demotion flip-flop
                    s.cluster.demote(epoch);
                    s.writes = false;
                    s.cluster.sync_status = "conflict_demoted".to_string();
                    let audit_rec = Arc::clone(&s.audit);
                    audit_rec.record("cluster", "", "cluster.split_brain_demoted", &format!("demoted to Standby against peer {}", remote_st.hub_id), None, None, "ok");
                    println!("[hub] CLUSTER CONFLICT RESOLVED: Demoted to Standby keeping epoch {}", epoch);
                } else {
                    s.cluster.sync_status = "conflict_master".to_string();
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
                let audit_rec = {
                    let mut s = st.lock_or_recover();
                    s.cluster.demote(remote_st.epoch);
                    s.writes = false;
                    Arc::clone(&s.audit)
                };
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
            let current_role = {
                let s = st.lock_or_recover();
                s.cluster.state.role.clone()
            };

            // P1-2: Dual Standby recovery - deterministic tie breaker (configured primary or lower hub_id)
            if current_role == "standby" && remote_st.role == "standby" {
                let should_recover = if is_cfg_primary != remote_st.is_configured_primary {
                    is_cfg_primary
                } else {
                    my_hub_id < remote_st.hub_id
                };
                if should_recover {
                    let mut s = st.lock_or_recover();
                    let new_ep = s.cluster.promote(None);
                    s.writes = s.writes_allowed; // P1-3: Respect CLI --writes configuration
                    let current_writes = s.writes;
                    let audit_rec = Arc::clone(&s.audit);
                    audit_rec.record("cluster", "", "cluster.zero_primary_recovered", &format!("recovered Primary role with epoch {} (writes={})", new_ep, current_writes), None, None, "ok");
                    println!("[hub] DUAL-STANDBY DETECTED: Master identity recovered with epoch {}. Writes={}.", new_ep, current_writes);
                }
            }

            if current_role == "standby" {
                // P1-7: Adopt higher epoch from Primary even if no file diffs
                if remote_st.role == "primary" && remote_st.epoch > epoch {
                    let mut s = st.lock_or_recover();
                    s.cluster.state.epoch = remote_st.epoch;
                    let _ = s.cluster.save();
                }

                // P1-3, P1-4 & P2-3: Use zero-disk-IO memory statistics, max_seq watermark and cached file hashes under lock
                let (cfg_lines_count, cmd_lines_count, local_max_cmd_seq, users_h, notif_h, curve_h) = {
                    let s = st.lock_or_recover();
                    let cfg_tot = s.cfg.total_lines();
                    let (cmd_tot, max_seq) = s.cmds.sync_stats();
                    let u_h = file_sha256(&s.users.path());
                    let n_h = file_sha256(&s.notif_store.lock_or_recover().path());
                    let c_h = file_sha256(&s.cluster.curve_clients_path);
                    (cfg_tot, cmd_tot, max_seq, u_h, n_h, c_h)
                };

                //--- N57-12: `> 0` created a blind spot. When the primary's
                //--- journal is compacted to nothing (everything terminal and
                //--- older than the retention window, then a restart), it reports
                //--- cmd_lines == 0 - and the old condition refused to sync
                //--- because "0 < N" was gated on "0 > 0". The standby then kept
                //--- serving a history that no longer existed anywhere and
                //--- reported a cmd_lines figure the primary would deny.
                let needs_sync = remote_st.cfg_lines > cfg_lines_count
                    || remote_st.cmd_lines > cmd_lines_count
                    || remote_st.max_cmd_seq > local_max_cmd_seq
                    || remote_st.cmd_lines < cmd_lines_count
                    || remote_st.cfg_lines < cfg_lines_count
                    || remote_st.users_hash != users_h
                    || remote_st.notif_hash != notif_h
                    || remote_st.curve_clients_hash != curve_h;

                // P1-1 & P2-5: Only track continuous online duration for failback when Standby is healthy & in sync with Primary
                if remote_st.role == "primary" && !needs_sync {
                    let mut s = st.lock_or_recover();
                    if s.cluster.continuous_online_start.is_none() {
                        s.cluster.continuous_online_start = Some(now);
                    }
                } else {
                    let mut s = st.lock_or_recover();
                    s.cluster.continuous_online_start = None;
                }

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

                    let req_from_cfg_line = if cfg_lines_count > remote_st.cfg_lines { 0 } else { cfg_lines_count };
                    let req_from_cmd_line = if cmd_lines_count > remote_st.cmd_lines { 0 } else { cmd_lines_count };

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
                                let mut s = st.lock_or_recover();
                                // Apply delta configs (or replace if Primary was compacted)
                                if req_from_cfg_line == 0 && !data.cfg_delta_lines.is_empty() && (remote_st.cfg_lines < cfg_lines_count && cfg_lines_count > 0) {
                                    let _ = s.cfg.replace_all(&data.cfg_delta_lines);
                                } else if !data.cfg_delta_lines.is_empty() {
                                    let _ = s.cfg.apply_delta_lines(&data.cfg_delta_lines);
                                }
                                // Apply delta commands (or replace if Primary was compacted)
                                //--- N57-12: the `!is_empty()` guard meant a primary
                                //--- compacted to zero rows produced no delta AND no
                                //--- replace, so the standby kept its stale history.
                                //--- replace_all(&[]) is exactly the reset needed.
                                if req_from_cmd_line == 0 && remote_st.cmd_lines < cmd_lines_count {
                                    let _ = s.cmds.replace_all(&data.cmd_delta_lines);
                                } else if !data.cmd_delta_lines.is_empty() {
                                    let _ = s.cmds.apply_delta_lines(&data.cmd_delta_lines);
                                }
                                // Apply full users content if updated
                                if let Some(u_content) = data.users_content {
                                    let p = s.users.path().to_path_buf();
                                    let tmp = p.with_extension("json.tmp");
                                    if let Ok(mut f) = File::create(&tmp) {
                                        let _ = f.write_all(u_content.as_bytes());
                                        let _ = f.sync_all();
                                        //--- N57-07: never swallow this. On Windows
                                        //--- a rename onto a file another thread has
                                        //--- open fails with OS Error 5, and the
                                        //--- standby then serves a users.json that
                                        //--- silently never updated.
                                        if let Err(e) = fs::rename(&tmp, &p) {
                                            eprintln!(
                                                "[hub] cluster sync: users rename {} -> {} failed: {} (kept old file)",
                                                tmp.display(),
                                                p.display(),
                                                e
                                            );
                                        }
                                        let _ = s.users.reload();
                                    }
                                }
                                // Apply full notification channels if updated
                                if let Some(n_content) = data.notif_content {
                                    let p = s.notif_store.lock_or_recover().path().to_path_buf();
                                    let tmp = format!("{}.tmp.{}", p.display(), std::process::id());
                                    if let Ok(mut f) = File::create(&tmp) {
                                        let _ = f.write_all(n_content.as_bytes());
                                        let _ = f.sync_all();
                                        //--- N57-07: see the users branch above.
                                        if let Err(e) = fs::rename(&tmp, &p) {
                                            eprintln!(
                                                "[hub] cluster sync: notifications rename {} -> {} failed: {} (kept old file)",
                                                tmp,
                                                p.display(),
                                                e
                                            );
                                        }
                                        let _ = s.notif_store.lock_or_recover().load();
                                    }
                                }
                                // P1-6: Apply curve clients content via atomic file overwrite
                                if let Some(c_content) = data.curve_clients_content {
                                    let p = s.cluster.curve_clients_path.clone();
                                    let tmp = format!("{}.tmp.{}", p.display(), std::process::id());
                                    if let Ok(mut f) = File::create(&tmp) {
                                        let _ = f.write_all(c_content.as_bytes());
                                        let _ = f.sync_all();
                                        //--- N57-07: see the users branch above.
                                        if let Err(e) = fs::rename(&tmp, &p) {
                                            eprintln!(
                                                "[hub] cluster sync: curve clients rename {} -> {} failed: {} (kept old file)",
                                                tmp,
                                                p.display(),
                                                e
                                            );
                                        }
                                    }
                                }

                                if data.epoch > s.cluster.epoch() {
                                    s.cluster.state.epoch = data.epoch;
                                    let _ = s.cluster.save();
                                }
                                s.cluster.sync_status = "synced".to_string();
                                s.cluster.last_sync_at = Some(Instant::now());
                                s.cluster.last_sync_err = String::new();
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

                // 5. ADR-10 Auto-Failback Check
                let (can_failback, continuous_secs) = {
                    let s = st.lock_or_recover();
                    let online_dur = s
                        .cluster
                        .continuous_online_start
                        .map(|t| t.elapsed().as_secs_f64())
                        .unwrap_or(0.0);
                    let eligible = is_cfg_primary
                        && !locked
                        && s.cluster.sync_status == "synced"
                        && online_dur >= (hours * 3600.0);
                    (eligible, online_dur)
                };

                if can_failback {
                    println!(
                        "[hub] ADR-10: Host online continuous {:.1}s >= {:.1}h. Requesting graceful failback...",
                        continuous_secs, hours
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
                                let audit_rec = {
                                    let mut s = st.lock_or_recover();
                                    // P2-1: Ensure target epoch is strictly greater than local epoch
                                    let target_ep = if h_data.new_epoch > s.cluster.epoch() {
                                        Some(h_data.new_epoch)
                                    } else {
                                        Some(s.cluster.epoch() + 1)
                                    };
                                    let new_ep = s.cluster.promote(target_ep);
                                    s.writes = s.writes_allowed; // P1-3: Respect CLI --writes configuration
                                    let current_writes = s.writes;
                                    println!(
                                        "[hub] ADR-10 AUTO-FAILBACK SUCCESS: Master identity recovered with epoch {}! Writes={}.",
                                        new_ep, current_writes
                                    );
                                    Arc::clone(&s.audit)
                                };
                                audit_rec.record(
                                    "hub",
                                    "",
                                    "cluster.failback_success",
                                    &format!("recovered Master identity with epoch {}", h_data.new_epoch),
                                    None,
                                    None,
                                    "ok",
                                );
                            }
                        }
                    }
                }
            } else {
                // Primary node: since peer is online and responding, update sync_status to "synced"
                let mut s = st.lock_or_recover();
                s.cluster.sync_status = "synced".to_string();
                s.cluster.last_sync_err = String::new();
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
            "test_token_0123456789abcdef",
            24.0,
            false,
        ).expect("create cluster manager");

        assert!(cm.is_primary());
        assert!(!cm.is_standby());
        assert_eq!(cm.epoch(), 1);
        assert_eq!(cm.role(), "primary");
        assert_eq!(cm.peer_url, "http://127.0.0.1:6011");
        assert_eq!(cm.cluster_token, "test_token_0123456789abcdef");

        // Reload from file
        let reloaded = ClusterManager::load_or_create(
            &state_path,
            &curve_path,
            None,
            "http://127.0.0.1:6011",
            "test_token_0123456789abcdef",
            24.0,
            false,
        ).expect("reload cluster manager");

        assert_eq!(reloaded.hub_id(), cm.hub_id());
        assert_eq!(reloaded.epoch(), 1);
        assert!(reloaded.is_primary());

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
}
