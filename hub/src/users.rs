//! users.rs - M9: users, roles and sessions for the HTTP API.
//!
//! The plan's §17.2 (D10/D12) asks for auth + three roles on the dashboard
//! side - admin / operator / viewer, single-tenant, user-id + password - and
//! §19.1 (D5) says the ZMQ port stays firewall-only with NO token. This is
//! that: the HTTP API authenticates; the wire does not change.
//!
//! WHAT THE ROLES MAY DO (the plan's §17.2 matrix):
//!
//! | capability                          | viewer | operator | admin |
//! |-------------------------------------|:------:|:--------:|:-----:|
//! | GET topology/positions/nodes/config |   v    |    v     |   v   |
//! | GET audit log                       |        |          |   v   |
//! | write config (PUT/rollback)         |        |    v     |   v   |
//! | issue commands (per-node/global)    |        |    v     |   v   |
//! | manage users                        |        |          |   v   |
//!
//! `--writes off` still gates writes on top of the role: role says WHO may,
//! the flag says the hub MAY AT ALL. Both defaults are the operator's, and
//! until now the flag was the only one.
//!
//! CRYPTO, HONESTLY
//! ================
//! There is no `sha2`/`bcrypt` crate available to this build (the toolchain
//! is deliberately isolated and offline), so SHA-256 is implemented here,
//! straight from FIPS 180-4, with the standard vectors pinned in tests, and
//! stretched 4096 rounds over a per-user random salt. That is a real KDF
//! shape, not a toy - it is what PBKDF2-SHA256 does minus the HMAC wrapper
//! (irrelevant against a hash-length-extension-only adversary for a
//! single-block input). What is NOT here, and is deliberately documented
//! rather than faked: the session token is drawn from `RandomState` hashes,
//! not `/dev/urandom`. Session tokens are scoped to the firewall-bound
//! control plane and rotate on login; passwords carry the real entropy.

use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher, RandomState};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const USERS_PATH: &str = "users.json";

/// Sessions live this long, measured from the last request that touched
/// them. A hub restart forgets every session: log in again.
pub const SESSION_IDLE_SECS: u64 = 12 * 3600;

/// PBKDF2 rounds for the password hash. Cheap enough at login (4096 SHA-256
/// blocks is sub-millisecond) and 4096x the work for an offline guesser.
pub const HASH_ROUNDS: u32 = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Viewer,
    Operator,
    Admin,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Viewer => "viewer",
            Role::Operator => "operator",
            Role::Admin => "admin",
        }
    }
    pub fn parse(s: &str) -> Option<Role> {
        match s {
            "viewer" => Some(Role::Viewer),
            "operator" => Some(Role::Operator),
            "admin" => Some(Role::Admin),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    /// `salt$rounds$hex` - never the password itself.
    pub pass: String,
    pub role: Role,
    /// A disabled user keeps its row and its history; it simply cannot
    /// authenticate.
    #[serde(default)]
    pub disabled: bool,
}

#[derive(Clone, Debug)]
pub struct Session {
    pub user_id: String,
    pub role: Role,
    pub seen: u64,
}

/// The store: users (persisted) + sessions (in-memory, by design).
pub struct UserStore {
    users: Vec<User>,
    sessions: HashMap<String, Session>,
    /// In-memory nonces for login challenges: nonce -> (user_id, expire_at)
    auth_nonces: HashMap<String, (String, u64)>,
    /// Failed-login bookkeeping. In memory like the sessions, and for the
    /// same reason: a restart should not be able to LOCK an operator out,
    /// and a persisted counter is a weapon an attacker can aim at a name.
    guard: LoginGuard,
    /// Per-IP rate limiting on auth_nonce requests: ip -> (count, window_start)
    nonce_ip_rates: HashMap<String, (u32, u64)>,
    /// Where the users live. The hub passes --users; the tests pass their own
    /// so a test hub never writes (or misses) the real one.
    path: std::path::PathBuf,
}

/// How many unexpired challenges the hub will hold at once.
///
/// `/api/v1/auth/nonce` is UNAUTHENTICATED by necessity - the caller has no
/// session yet - and each call inserted a map entry that only a 10-second
/// expiry ever removed. A loop could therefore add entries faster than they
/// aged out: a few hundred thousand requests is tens of megabytes of hub
/// memory, from a request that costs the caller nothing. The cap turns that
/// into a refusal.
const MAX_PENDING_NONCES: usize = 512;

/// Failed-login throttling.
///
/// WHY A DELAY PER NAME AND A HARD LIMIT ONLY GLOBALLY
/// ==================================================
/// A per-name hard lockout is the obvious design and the wrong one here: any
/// caller who knows the admin's user id could lock the operator out of their
/// own hub for as long as they kept trying. So a name that keeps failing gets
/// a growing DELAY (which costs an attacker real time and costs the operator
/// one wait), while only the GLOBAL rate is hard-refused - and that refusal
/// exists to protect the CPU from a hash-flood, not to punish a person.
const FAIL_WINDOW_SECS: u64 = 60;
const FAILS_PER_NAME_BEFORE_DELAY: u32 = 3;
const FAIL_DELAY_STEP_MS: u64 = 250;
const FAIL_DELAY_MAX_MS: u64 = 4000;
const FAILS_GLOBAL_MAX: u32 = 40;
const GLOBAL_BLOCK_SECS: u64 = 10;

#[derive(Default)]
struct LoginGuard {
    /// user id -> (failures in the current window, window start)
    per_name: HashMap<String, (u32, u64)>,
    /// (failures in the current window, window start)
    global: (u32, u64),
    /// Set while the global window is over budget.
    blocked_until: u64,
}

impl LoginGuard {
    /// May this attempt proceed? `Some(retry_after)` means no.
    fn blocked_for(&mut self, now: u64) -> Option<u64> {
        if self.blocked_until > now {
            return Some(self.blocked_until - now);
        }
        None
    }

    /// Record a failure and return how long the caller should wait before
    /// answering. The wait is applied OUTSIDE any lock (it is an async sleep).
    /// N49-03: `is_hash_heavy` protects against CPU hash flooding without allowing
    /// cheap proof failures to trigger global lockout.
    fn note_failure(&mut self, id: &str, now: u64, is_hash_heavy: bool) -> u64 {
        if is_hash_heavy {
            if now.saturating_sub(self.global.1) > FAIL_WINDOW_SECS {
                self.global = (0, now);
            }
            self.global.0 = self.global.0.saturating_add(1);
            if self.global.0 >= FAILS_GLOBAL_MAX {
                self.blocked_until = now + GLOBAL_BLOCK_SECS;
                self.global = (0, now);
            }
        }

        let e = self
            .per_name
            .entry(id.to_string())
            .or_insert((0, now));
        if now.saturating_sub(e.1) > FAIL_WINDOW_SECS {
            *e = (0, now);
        }
        e.0 = e.0.saturating_add(1);
        if e.0 <= FAILS_PER_NAME_BEFORE_DELAY {
            return 0;
        }
        let extra = (e.0 - FAILS_PER_NAME_BEFORE_DELAY) as u64;
        (extra * FAIL_DELAY_STEP_MS).min(FAIL_DELAY_MAX_MS)
    }

    fn note_success(&mut self, id: &str) {
        self.per_name.remove(id);
    }

    /// Drop bookkeeping that can no longer affect a decision, so a hub that
    /// runs for months does not keep a row per name ever tried.
    fn prune(&mut self, now: u64) {
        self.per_name
            .retain(|_, (_, start)| now.saturating_sub(*start) <= FAIL_WINDOW_SECS);
        if self.blocked_until <= now {
            self.blocked_until = 0;
        }
    }
}

impl Default for UserStore {
    fn default() -> Self {
        UserStore::new()
    }
}

impl UserStore {
    pub fn new() -> Self {
        UserStore {
            users: Vec::new(),
            sessions: HashMap::new(),
            auth_nonces: HashMap::new(),
            guard: LoginGuard::default(),
            nonce_ip_rates: HashMap::new(),
            path: std::path::PathBuf::from(USERS_PATH),
        }
    }

    /// Load users.json. A missing file is an empty store (the caller
    /// bootstraps); malformed content is an ERROR, not a silent reset -
    /// losing the admin list to a typo is losing the only door.

    pub fn load_at(path: &std::path::Path) -> Result<Self, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                if text.trim().is_empty() {
                    return Ok(UserStore {
                        users: Vec::new(),
                        sessions: HashMap::new(),
                        auth_nonces: HashMap::new(),
                        guard: LoginGuard::default(),
                        nonce_ip_rates: HashMap::new(),
                        path: path.to_path_buf(),
                    });
                }
                let users: Vec<User> =
                    serde_json::from_str(&text).map_err(|e| format!("{}: {}", path.display(), e))?;
                Ok(UserStore {
                    users,
                    sessions: HashMap::new(),
                    auth_nonces: HashMap::new(),
                    guard: LoginGuard::default(),
                    nonce_ip_rates: HashMap::new(),
                    path: path.to_path_buf(),
                })
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(UserStore {
                users: Vec::new(),
                sessions: HashMap::new(),
                auth_nonces: HashMap::new(),
                guard: LoginGuard::default(),
                nonce_ip_rates: HashMap::new(),
                path: path.to_path_buf(),
            }),
            Err(e) => Err(format!("{}: {}", path.display(), e)),
        }
    }

    /// Write via a temp file + rename, the same shape the receiver's ini
    /// writer uses: a crash mid-write must not leave half a user list.
    pub fn save(&self) -> Result<(), String> {
        let tmp = self.path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(&self.users)
            .map_err(|e| format!("serialise users: {}", e))?;
        //--- fsync the temp before the rename. `write_all` returns once the
        //--- bytes are in the page cache; the rename - like every other
        //--- metadata operation - survives even if the data never reaches
        //--- the platter. After a power cut the new name then points at a
        //--- file whose contents are gone or torn, and the hub refuses to
        //--- start on an unreadable user table. The cost is one flush per
        //--- administrative change, which is not a hot path.
        {
            use std::io::Write;
            let mut f = std::fs::File::create(&tmp)
                .map_err(|e| format!("{}: {}", tmp.display(), e))?;
            f.write_all(text.as_bytes())
                .map_err(|e| format!("{}: {}", tmp.display(), e))?;
            f.sync_all()
                .map_err(|e| format!("{} (fsync): {}", tmp.display(), e))?;
        }
        std::fs::rename(&tmp, &self.path).map_err(|e| format!("{}: {}", self.path.display(), e))
    }

    pub fn users(&self) -> &[User] {
        &self.users
    }

    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    /// Reload users from disk (used by HA cluster replication).
    pub fn reload(&mut self) -> Result<(), String> {
        let loaded = Self::load_at(&self.path)?;
        self.users = loaded.users;
        Ok(())
    }

    pub fn get(&self, id: &str) -> Option<&User> {
        self.users.iter().find(|u| u.id == id)
    }

    /// HUB-07: Uniform path for .admin_bootstrap_password next to users.json
    pub fn bootstrap_password_path(&self) -> std::path::PathBuf {
        self.path.parent().unwrap_or(std::path::Path::new(".")).join(".admin_bootstrap_password")
    }

    /// HUB-07: Delete plaintext bootstrap password file safely upon admin login or password change
    pub fn cleanup_bootstrap_password(&self) {
        let p = self.bootstrap_password_path();
        let _ = std::fs::remove_file(&p);
        let _ = std::fs::remove_file(".admin_bootstrap_password");
    }

    /// Replace one user's password, keeping the role and disabled flag. This
    /// is the SELF-SERVICE path: any authenticated user may change their own
    /// password, and that is deliberately not an admin privilege - an
    /// operator locked out of their own credential is an operator who shares
    /// somebody else's.
    #[allow(dead_code)]
    pub fn set_password(&mut self, id: &str, new_password: &str) -> Result<(), String> {
        let salt = random_token()[..16].to_string();
        let hashed = hash_password(new_password, &salt);
        self.set_password_hashed(id, hashed)
    }

    /// Apply an ALREADY-HASHED password. Split out so a caller can do the
    /// expensive half (4096 SHA-256 rounds to verify the old one and to hash
    /// the new) with NO lock held and keep only this - a one-field memory
    /// write - inside it. See `stored_hash`.
    pub fn set_password_hashed(&mut self, id: &str, hashed: String) -> Result<(), String> {
        let u = self
            .users
            .iter_mut()
            .find(|u| u.id == id)
            .ok_or_else(|| format!("no such user: {}", id))?;
        u.pass = hashed;
        Ok(())
    }

    /// The stored hash for `id`, or None when the user does not exist or is
    /// disabled. Read-only on purpose: the caller runs the expensive
    /// verification (4096 SHA-256 rounds) with NO shared-state lock held,
    /// then calls `mint_session` - which re-reads the user under the lock,
    /// so a disable that lands during the hash still wins.
    pub fn stored_hash(&self, id: &str) -> Option<String> {
        self.users
            .iter()
            .find(|u| u.id == id && !u.disabled)
            .map(|u| u.pass.clone())
    }

    fn sweep_and_enforce_session_cap(&mut self, now: u64) {
        self.sessions
            .retain(|_, sess| now.saturating_sub(sess.seen) < SESSION_IDLE_SECS);
        if self.sessions.len() >= 1024 {
            // R47-13: Evict oldest session (LRU) instead of clearing all sessions
            if let Some(oldest_tok) = self
                .sessions
                .iter()
                .min_by_key(|(_, sess)| sess.seen)
                .map(|(tok, _)| tok.clone())
            {
                self.sessions.remove(&oldest_tok);
            }
        }
    }

    /// Mint a session for an id whose password was ALREADY verified outside
    /// the lock. Re-reads the user here (the world may have changed during
    /// the hashing) and refuses when the user is gone or now disabled - a
    /// session is never minted for someone who may no longer have one.
    pub fn mint_session(&mut self, id: &str, now: u64) -> Result<(String, Session), String> {
        let (user_id, role) = {
            let u = self
                .users
                .iter()
                .find(|u| u.id == id && !u.disabled)
                .ok_or_else(|| "invalid credentials".to_string())?;
            (u.id.clone(), u.role)
        };
        // R47-13: Enforce session sweep and LRU capacity cap on both legacy and challenge-response logins
        self.sweep_and_enforce_session_cap(now);
        let token = random_token();
        let s = Session {
            user_id,
            role,
            seen: now,
        };
        self.sessions.insert(token.clone(), s.clone());
        Ok((token, s))
    }

    /// Drop every session for `id` except `keep`. Called when a password
    /// changes: the credential a session was minted from is gone, so the
    /// session should not outlive it - except the one doing the changing,
    /// which would otherwise be logged out by its own act.
    pub fn drop_other_sessions(&mut self, id: &str, keep: Option<&str>) -> usize {
        let before = self.sessions.len();
        self.sessions
            .retain(|tok, s| s.user_id != id || Some(tok.as_str()) == keep);
        before - self.sessions.len()
    }

    /// Create or replace a user. The last admin cannot be demoted or
    /// disabled - a hub with no administrators is a hub nobody can fix.
    pub fn upsert(&mut self, u: User) -> Result<(), String> {
        if let Some(old) = self.users.iter().find(|x| x.id == u.id) {
            if u.role != old.role && self.admins() == 1 && old.role == Role::Admin {
                return Err("that is the last admin".to_string());
            }
        }
        if u.disabled && self.would_leave_no_admin(Some(&u)) {
            return Err("that is the last admin".to_string());
        }
        if let Some(slot) = self.users.iter_mut().find(|x| x.id == u.id) {
            //--- A ROLE CHANGE or a DISABLE must take effect NOW, and a
            //--- session carries the role it was minted with - so leaving an
            //--- existing session alive would keep honouring a privilege that
            //--- was just revoked for up to SESSION_IDLE_SECS (12h): a user
            //--- demoted to viewer could still read the audit log and change
            //--- configuration all afternoon. This is the revocation half of
            //--- the role model; without it the roles are advisory.
            //---
            //--- A no-op upsert (same role, still enabled) deliberately keeps
            //--- sessions: an admin saving the user table for any other
            //--- reason must not sign everybody out.
            let id = slot.id.clone();
            let role_changed = slot.role != u.role;
            let was_enabled = !slot.disabled;
            *slot = u;
            if role_changed || (slot.disabled && was_enabled) {
                self.sessions.retain(|_, s| s.user_id != id);
            }
        } else {
            self.users.push(u);
        }
        Ok(())
    }

    pub fn remove(&mut self, id: &str) -> Result<(), String> {        let idx = self
            .users
            .iter()
            .position(|u| u.id == id)
            .ok_or_else(|| format!("no such user: {}", id))?;
        if self.users[idx].role == Role::Admin && self.admins() == 1 {
            return Err("that is the last admin".to_string());
        }
        self.users.remove(idx);
        self.sessions.retain(|_, s| s.user_id != id);
        Ok(())
    }

    fn admins(&self) -> usize {
        self.users
            .iter()
            .filter(|u| u.role == Role::Admin && !u.disabled)
            .count()
    }

    /// Would this change take the hub from "has at least one admin" to "has
    /// none"? An empty-or-bootstrap store is never in that shape, so adding
    /// the first user - a viewer, even - is not "removing the last admin".
    fn would_leave_no_admin(&self, changed: Option<&User>) -> bool {
        let before = self.admins();
        let mut after = before;
        if let Some(c) = changed {
            if let Some(old) = self.users.iter().find(|u| u.id == c.id) {
                if old.role == Role::Admin && !old.disabled {
                    after -= 1;
                }
                if c.role == Role::Admin && !c.disabled {
                    after += 1;
                }
            } else if c.role == Role::Admin && !c.disabled {
                after += 1;
            }
        }
        before > 0 && after == 0
    }

    /// Verify a password and mint a session. A failed login says so
    /// WITHOUT saying whether the id exists - that distinction is the
    /// whole difference between a login and an account enumeration.
    /// Returns the token (the caller sets it as the HttpOnly cookie) and
    /// the session itself.
    #[allow(dead_code)]
    pub fn login(&mut self, id: &str, password: &str, now: u64) -> Result<(String, Session), String> {
        let u = self
            .users
            .iter()
            .find(|u| u.id == id && !u.disabled)
            .ok_or_else(|| "invalid credentials".to_string())?;
        if !verify_password(password, &u.pass) {
            return Err("invalid credentials".to_string());
        }
        let token = random_token();
        let s = Session {
            user_id: u.id.clone(),
            role: u.role,
            seen: now,
        };
        self.sessions.insert(token.clone(), s.clone());
        Ok((token, s))
    }

    /// Generate a short-lived nonce for challenge-response login.
    /// Returns (nonce, salt, rounds), or None when the hub is holding as many
    /// live challenges as it will (`MAX_PENDING_NONCES`).
    ///
    /// The cap is the whole point of the Option: this endpoint is
    /// unauthenticated, so without it a loop of requests grows the map faster
    /// than the 10-second expiry drains it.
    #[allow(dead_code)]
    pub fn create_nonce(
        &mut self,
        user_id: &str,
        now: u64,
        ttl_secs: u64,
    ) -> Option<(String, String, u32)> {
        self.create_nonce_with_ip(user_id, now, ttl_secs, "default")
    }

    pub fn create_nonce_with_ip(
        &mut self,
        user_id: &str,
        now: u64,
        ttl_secs: u64,
        ip: &str,
    ) -> Option<(String, String, u32)> {
        // N49-03: Rate limit nonce requests per client IP (max 25/sec)
        if ip != "default" {
            self.nonce_ip_rates.retain(|_, (_, start)| now.saturating_sub(*start) <= 2);
            let rate = self.nonce_ip_rates.entry(ip.to_string()).or_insert((0, now));
            if now.saturating_sub(rate.1) >= 1 {
                *rate = (0, now);
            }
            rate.0 = rate.0.saturating_add(1);
            if rate.0 > 25 {
                return None;
            }
        }

        // Prune expired nonces
        self.auth_nonces.retain(|_, (_, exp)| *exp > now);
        if self.auth_nonces.len() >= MAX_PENDING_NONCES {
            return None;
        }
        self.guard.prune(now);

        // R47-12 & R48-03: Per-user nonce capacity and race-invalidation protection.
        // Cap at 16 per user. When saturated, only evict nonces that have survived past
        // the 2-second in-flight protection window, guaranteeing legitimate user logins
        // are never invalidated mid-hash by concurrent attacker floods.
        let user_nonces = self.auth_nonces.values().filter(|(uid, _)| uid == user_id).count();
        if user_nonces >= 16 {
            let evictable = self
                .auth_nonces
                .iter()
                .filter(|(_, (uid, exp))| uid == user_id && *exp <= now + ttl_secs.saturating_sub(2))
                .min_by_key(|(_, (_, exp))| *exp)
                .map(|(k, _)| k.clone());
            if let Some(oldest) = evictable {
                self.auth_nonces.remove(&oldest);
            } else {
                return None;
            }
        }

        let (salt, rounds) = if let Some(u) = self.users.iter().find(|u| u.id == user_id && !u.disabled) {
            let parts: Vec<&str> = u.pass.split('$').collect();
            if parts.len() == 3 {
                let r = parts[1].parse::<u32>().unwrap_or(HASH_ROUNDS);
                (parts[0].to_string(), r)
            } else {
                (random_token()[..16].to_string(), HASH_ROUNDS)
            }
        } else {
            // Fake salt derived deterministically from user_id to prevent account enumeration timing attacks
            let dummy = sha256(format!("fake_salt:{}", user_id).as_bytes());
            (hex(&dummy)[..16].to_string(), HASH_ROUNDS)
        };

        let nonce = random_token();
        self.auth_nonces.insert(nonce.clone(), (user_id.to_string(), now + ttl_secs));
        Some((nonce, salt, rounds))
    }

    /// Is login currently refused outright? `Some(seconds)` means yes, and
    /// how long until it is worth trying again.
    pub fn login_blocked(&mut self, now: u64) -> Option<u64> {
        self.guard.blocked_for(now)
    }

    /// Record a failed login. Returns how long the caller should wait before
    /// answering - a delay, not a lockout, for the reasons on `LoginGuard`.
    pub fn note_login_failure(&mut self, id: &str, now: u64, is_hash_heavy: bool) -> u64 {
        self.guard.prune(now);
        self.guard.note_failure(id, now, is_hash_heavy)
    }

    /// Record a successful login: the name's counter goes back to zero.
    pub fn note_login_success(&mut self, id: &str) {
        self.guard.note_success(id);
    }

    /// Authenticate via challenge-response proof:
    /// proof = SHA256(stored_digest + ":" + nonce)
    /// The nonce is IMMEDIATELY destroyed upon first use (single-use token, replay proof).
    pub fn login_with_proof(
        &mut self,
        id: &str,
        nonce: &str,
        proof: &str,
        now: u64,
    ) -> Result<(String, Session), String> {
        // 1. Consume nonce immediately (must exist, match user, and not expired)
        let (nonce_user, expire_at) = self
            .auth_nonces
            .remove(nonce)
            .ok_or_else(|| "invalid credentials".to_string())?;

        if now > expire_at || nonce_user != id {
            return Err("invalid credentials".to_string());
        }

        // 2. Lookup user
        let u = self
            .users
            .iter()
            .find(|u| u.id == id && !u.disabled)
            .ok_or_else(|| "invalid credentials".to_string())?;

        let parts: Vec<&str> = u.pass.split('$').collect();
        if parts.len() != 3 {
            return Err("invalid credentials".to_string());
        }
        let stored_digest = parts[2];

        // 3. Expected proof = hex(sha256(stored_digest + ":" + nonce))
        let expected_proof = hex(&sha256(format!("{}:{}", stored_digest, nonce).as_bytes()));

        // Constant-time compare
        let a = expected_proof.as_bytes();
        let b = proof.as_bytes();
        if a.len() != b.len() {
            return Err("invalid credentials".to_string());
        }
        let mut diff = 0u8;
        for i in 0..a.len() {
            diff |= a[i] ^ b[i];
        }
        if diff != 0 {
            return Err("invalid credentials".to_string());
        }

        let user_id = u.id.clone();
        // 4. Issue session (centralized in mint_session with sweep and LRU eviction)
        self.mint_session(&user_id, now)
    }

    pub fn logout(&mut self, token: &str) {
        self.sessions.remove(token);
    }

    /// Resolve a token to a live session, sliding its idle window. Expired
    /// tokens are dropped rather than merely ignored, so the table does not
    /// grow with abandoned logins.
    pub fn session(&mut self, token: &str, now: u64) -> Option<Session> {
        let expired = self
            .sessions
            .get(token)
            .map(|s| now.saturating_sub(s.seen) >= SESSION_IDLE_SECS)
            .unwrap_or(true);
        if expired {
            self.sessions.remove(token);
            return None;
        }
        let s = self.sessions.get_mut(token)?;
        s.seen = now;
        Some(s.clone())
    }

    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }
}

//--- ------------------------------------------------------------------ crypto

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// SHA-256, straight from FIPS 180-4.
pub fn sha256(msg: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let bitlen = (msg.len() as u64).wrapping_mul(8);
    let mut data = msg.to_vec();
    data.push(0x80);
    while data.len() % 64 != 56 {
        data.push(0);
    }
    data.extend_from_slice(&bitlen.to_be_bytes());

    let mut w = [0u32; 64];
    for block in data.chunks_exact(64) {
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// `salt$rounds$hexdigest`. The salt is 16 random hex chars.
pub fn hash_password(password: &str, salt: &str) -> String {
    hash_password_rounds(password, salt, HASH_ROUNDS)
}

/// The workhorse: `rounds` total iterations of SHA-256 over
/// `salt:password`, then each digest. Exposed separately so `verify` can
/// honour the round count stored WITH the hash instead of the binary's
/// current constant - see verify_password.
pub fn hash_password_rounds(password: &str, salt: &str, rounds: u32) -> String {
    let rounds = rounds.max(1);
    let mut acc = sha256(format!("{}:{}", salt, password).as_bytes());
    for _ in 1..rounds {
        acc = sha256(&acc);
    }
    format!("{}${}${}", salt, rounds, hex(&acc))
}

pub fn verify_password(password: &str, stored: &str) -> bool {
    let parts: Vec<&str> = stored.split('$').collect();
    if parts.len() != 3 {
        return false;
    }
    //--- The rounds are part of the STORED hash's contract, not a property
    //--- of this binary. A hash written by a future build with a different
    //--- HASH_ROUNDS must verify with ITS rounds; hashing with today's
    //--- constant instead means every existing user gets "invalid
    //--- credentials" the day the constant is raised - a lockout that
    //--- nothing anywhere explains. An unparseable count falls back to the
    //--- current constant (a hand-edited hash is the only way to get here,
    //--- and it was already broken).
    //---
    //--- The rounds also ride the nonce challenge (/api/v1/auth/nonce
    //--- returns them), so the CLIENT computes the same digest with the
    //--- same count - this parse and that endpoint are the two ends of the
    //--- same string.
    let rounds: u32 = parts[1].parse().unwrap_or(HASH_ROUNDS);
    let candidate = hash_password_rounds(password, parts[0], rounds);
    // Constant-time compare, byte by byte, both digests always the same
    // length - a mismatch is a mismatch without saying WHERE.
    let a = candidate.as_bytes();
    let b = stored.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

#[cfg(windows)]
fn os_random_bytes(dest: &mut [u8]) -> bool {
    #[link(name = "bcrypt")]
    extern "system" {
        fn BCryptGenRandom(
            h_algorithm: *mut std::ffi::c_void,
            pb_buffer: *mut u8,
            cb_buffer: u32,
            dw_flags: u32,
        ) -> i32;
    }
    const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x00000002;
    unsafe {
        BCryptGenRandom(
            std::ptr::null_mut(),
            dest.as_mut_ptr(),
            dest.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        ) == 0
    }
}

#[cfg(not(windows))]
fn os_random_bytes(dest: &mut [u8]) -> bool {
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        f.read_exact(dest).is_ok()
    } else {
        false
    }
}

/// A random session token generated using OS CSPRNG (BCryptGenRandom on Windows, /dev/urandom on Unix).
pub fn random_token() -> String {
    let mut out = [0u8; 32];
    if os_random_bytes(&mut out) {
        return hex(&out);
    }
    let rs = [RandomState::new(), RandomState::new(), RandomState::new()];
    let nanos = || {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0)
    };
    for i in 0..4u64 {
        let seed = nanos() ^ i.wrapping_mul(0x9e3779b97f4a7c15);
        let mut h1 = rs[0].build_hasher();
        h1.write_u64(seed);
        let mut h2 = rs[1].build_hasher();
        h2.write_u64(seed.rotate_left(11));
        let mut h3 = rs[2].build_hasher();
        h3.write_u64(seed.rotate_left(23));
        let folded = h1.finish() ^ h2.finish().rotate_left(17) ^ h3.finish().rotate_left(43);
        out[(i * 8) as usize..(i * 8 + 8) as usize].copy_from_slice(&folded.to_be_bytes());
    }
    hex(&out)
}

/// A one-time bootstrap password: 12 chars from a URL-safe alphabet via CSPRNG.
pub fn random_password() -> String {
    const ALPHA: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
    let mut rand_bytes = [0u8; 12];
    if os_random_bytes(&mut rand_bytes) {
        let mut out = String::new();
        for &b in &rand_bytes {
            out.push(ALPHA[(b as usize) % ALPHA.len()] as char);
        }
        return out;
    }
    let mut h = RandomState::new().build_hasher();
    h.write_u64(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0),
    );
    let mut n = h.finish();
    let mut out = String::new();
    for _ in 0..12 {
        let mut hh = RandomState::new().build_hasher();
        hh.write_u64(n);
        n = hh.finish();
        out.push(ALPHA[(n % ALPHA.len() as u64) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_the_fips_vectors() {
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex(&sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn sha256_of_a_long_input_spanning_blocks() {
        let data = vec![b'a'; 1_000_000];
        assert_eq!(
            hex(&sha256(&data)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn a_hash_verifies_its_own_password_and_rejects_others() {
        let h = hash_password("correct horse battery staple", "0123456789abcdef");
        assert!(verify_password("correct horse battery staple", &h));
        assert!(!verify_password("Correct horse battery staple", &h));
        assert!(!verify_password("", &h));
    }

    #[test]
    fn the_same_password_two_salts_are_two_hashes() {
        assert_ne!(hash_password("hunter2", "aaaaaaaaaaaaaaaa"),
                   hash_password("hunter2", "bbbbbbbbbbbbbbbb"));
    }

    #[test]
    fn a_garbage_stored_hash_never_verifies() {
        assert!(!verify_password("x", "notahash"));
        assert!(!verify_password("x", "salt$rounds$nothex"));
    }

    #[test]
    fn a_hash_written_with_different_rounds_still_verifies() {
        //--- Raising HASH_ROUNDS used to lock out every existing user: verify
        //--- hashed with the binary's constant while the stored hash carried
        //--- its own. The rounds are data, and data wins over code.
        let h = hash_password_rounds("correct horse battery staple", "0123456789abcdef", 8);
        assert!(h.starts_with("0123456789abcdef$8$"));
        assert!(verify_password("correct horse battery staple", &h));
        assert!(!verify_password("wrong", &h));
    }

    #[test]
    fn a_role_change_drops_the_users_sessions_immediately() {
        //--- The revocation half of the role model: a demoted user's live
        //--- session carried the old role and kept it for up to 12h.
        let mut s = UserStore::new();
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Operator, disabled: false }).unwrap();
        let (tok, _) = s.login("op", "p", 100).unwrap();
        //--- demote to viewer
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Viewer, disabled: false }).unwrap();
        assert!(s.session(&tok, 100).is_none(), "the old-role session must die");
        //--- and the user can still log back in, with the NEW role
        let (tok2, sess2) = s.login("op", "p", 101).unwrap();
        assert_eq!(sess2.role, Role::Viewer);
        assert!(s.session(&tok2, 100).is_some());
    }

    #[test]
    fn a_disable_drops_sessions_and_a_noop_upsert_keeps_them() {
        let mut s = UserStore::new();
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Operator, disabled: false }).unwrap();
        let (tok, _) = s.login("op", "p", 100).unwrap();
        //--- disabling takes effect at once
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Operator, disabled: true }).unwrap();
        assert!(s.session(&tok, 100).is_none());
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Operator, disabled: false }).unwrap();
        let (tok2, _) = s.login("op", "p", 100).unwrap();
        //--- an unrelated save (same role, still enabled) must NOT log anybody out
        s.upsert(User { id: "op".into(), pass: hash_password("p", "s"), role: Role::Operator, disabled: false }).unwrap();
        assert!(s.session(&tok2, 100).is_some());
    }

    #[test]
    fn roles_order_viewer_below_operator_below_admin() {
        assert!(Role::Viewer < Role::Operator);
        assert!(Role::Operator < Role::Admin);
        assert_eq!(Role::parse("operator"), Some(Role::Operator));
        assert_eq!(Role::parse("root"), None);
    }

    #[test]
    fn the_last_admin_cannot_be_removed_or_demoted() {
        let mut s = UserStore::new();
        s.upsert(User { id: "a".into(), pass: hash_password("p", "s"), role: Role::Admin, disabled: false })
            .unwrap();
        s.upsert(User { id: "b".into(), pass: hash_password("p", "t"), role: Role::Operator, disabled: false })
            .unwrap();
        assert!(s.remove("a").is_err());
        assert!(s
            .upsert(User { id: "a".into(), pass: hash_password("p", "s2"), role: Role::Viewer, disabled: false })
            .is_err());
        assert!(s
            .upsert(User { id: "a".into(), pass: hash_password("p", "s2"), role: Role::Admin, disabled: true })
            .is_err());
        // A SECOND admin makes the first one removable.
        s.upsert(User { id: "c".into(), pass: hash_password("p", "u"), role: Role::Admin, disabled: false })
            .unwrap();
        s.remove("a").unwrap();
        assert!(s.get("a").is_none() && s.get("c").is_some());
    }

    #[test]
    fn sessions_expire_on_idle_and_resolve_while_alive() {
        let mut s = UserStore::new();
        // The slide: the window is measured from the last request, so the
        // alive call BELOW is what the expiry after it must be relative to.
        s.upsert(User {
            id: "op".into(),
            pass: hash_password("pw", "saltsalt"),
            role: Role::Operator,
            disabled: false,
        })
        .unwrap();
        let (token, sess) = s.login("op", "pw", 1000).unwrap();
        assert_eq!(sess.role, Role::Operator);
        // Alive within the window - and it slides `seen` to this moment.
        assert!(s.session(&token, 1000 + SESSION_IDLE_SECS - 1).is_some());
        // Expired beyond the window FROM THAT touched moment.
        assert!(s.session(&token, 1000 + SESSION_IDLE_SECS - 1 + SESSION_IDLE_SECS).is_none());
        // ...and gone from the table, not merely ignored.
        assert_eq!(s.session_count(), 0);
    }

    #[test]
    fn a_password_change_replaces_the_hash_and_ends_other_sessions() {
        let mut s = UserStore::new();
        s.upsert(User {
            id: "op".into(),
            pass: hash_password("oldpw", "saltsalt"),
            role: Role::Operator,
            disabled: false,
        })
        .unwrap();
        let (t1, _) = s.login("op", "oldpw", 1000).unwrap();
        let (t2, _) = s.login("op", "oldpw", 1001).unwrap();
        assert_eq!(s.session_count(), 2);

        s.set_password("op", "newpw").unwrap();

        // The session doing the change survives, the other one does not.
        // Checked BEFORE any further login, so the count is unambiguous.
        let dropped = s.drop_other_sessions("op", Some(&t1));
        assert_eq!(dropped, 1);
        assert!(s.session(&t1, 1004).is_some());
        assert!(s.session(&t2, 1004).is_none());

        // The old password no longer works; the new one does.
        assert!(s.login("op", "oldpw", 1005).is_err());
        assert!(s.login("op", "newpw", 1006).is_ok());
    }

    #[test]
    fn a_viewer_can_join_an_empty_store() {        // Regression: the last-admin guard once read an empty store as
        // "about to have no admin" and refused the FIRST user outright.
        let mut s = UserStore::new();
        s.upsert(User {
            id: "v".into(),
            pass: hash_password("pw", "saltsalt"),
            role: Role::Viewer,
            disabled: false,
        })
        .unwrap();
        assert_eq!(s.get("v").map(|u| u.role), Some(Role::Viewer));
    }

    #[test]
    fn tokens_are_long_hex_and_distinct() {
        let a = random_token();
        let b = random_token();
        assert_eq!(a.len(), 64);
        assert_eq!(b.len(), 64);
        assert_ne!(a, b);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn a_disabled_user_cannot_log_in() {
        let mut s = UserStore::new();
        s.upsert(User {
            id: "ghost".into(),
            pass: hash_password("pw", "saltsalt"),
            role: Role::Viewer,
            disabled: true,
        })
        .unwrap();
        assert!(s.login("ghost", "pw", 1).is_err());
    }

    #[test]
    fn challenge_response_authentication_flow() {
        let mut s = UserStore::new();
        s.upsert(User {
            id: "alice".into(),
            pass: hash_password("secret123", "0123456789abcdef"),
            role: Role::Operator,
            disabled: false,
        })
        .unwrap();

        let now = 1000;
        // 1. Request nonce
        let (nonce, salt, rounds) = s.create_nonce("alice", now, 10).expect("nonce");
        assert_eq!(salt, "0123456789abcdef");
        assert_eq!(rounds, HASH_ROUNDS);
        assert!(!nonce.is_empty());

        // 2. Client computes stored digest and proof
        let stored_digest = {
            let u = s.get("alice").unwrap();
            u.pass.split('$').nth(2).unwrap().to_string()
        };
        let proof = hex(&sha256(format!("{}:{}", stored_digest, nonce).as_bytes()));

        // 3. Login succeeds
        let res = s.login_with_proof("alice", &nonce, &proof, now + 1);
        assert!(res.is_ok());
        let (tok, sess) = res.unwrap();
        assert_eq!(sess.user_id, "alice");
        assert_eq!(sess.role, Role::Operator);
        assert!(s.session(&tok, now + 2).is_some());

        // 4. Replay attack fails: nonce was consumed immediately
        assert!(s.login_with_proof("alice", &nonce, &proof, now + 2).is_err());

        // 5. Expired nonce fails
        let (nonce2, _, _) = s.create_nonce("alice", now, 5).expect("nonce");
        let proof2 = hex(&sha256(format!("{}:{}", stored_digest, nonce2).as_bytes()));
        assert!(s.login_with_proof("alice", &nonce2, &proof2, now + 6).is_err());

        // 6. Bad proof fails
        let (nonce3, _, _) = s.create_nonce("alice", now, 10).expect("nonce");
        assert!(s.login_with_proof("alice", &nonce3, "wrong_proof", now + 1).is_err());

        // 7. Non-existent user returns a dummy salt and cannot authenticate
        let (dummy_nonce, dummy_salt, _) = s.create_nonce("nonexistent", now, 10).expect("nonce");
        assert_eq!(dummy_salt.len(), 16);
        assert!(s.login_with_proof("nonexistent", &dummy_nonce, "any", now + 1).is_err());
    }

    /// `/api/v1/auth/nonce` is unauthenticated, so without a cap a loop grows
    /// the map faster than the 10-second expiry drains it.
    #[test]
    fn pending_nonces_are_capped() {
        let mut s = UserStore::new();
        let now = 1_000_000u64;
        for i in 0..MAX_PENDING_NONCES {
            assert!(
                s.create_nonce(&format!("u{}", i), now, 10).is_some(),
                "the cap refused a request below it at {}",
                i
            );
        }
        assert!(
            s.create_nonce("one-too-many", now, 10).is_none(),
            "the cap did not refuse once full"
        );
        // Once the window has passed, the expired entries drain and the
        // endpoint works again - the cap is a rate limit, not a permanent wall.
        assert!(s.create_nonce("later", now + 11, 10).is_some());
    }

    /// Failures escalate a DELAY, and the delay resets on success. There is
    /// deliberately no per-name lockout: that would let anyone who knows the
    /// admin's id keep the operator out.
    #[test]
    fn failed_logins_escalate_a_delay_and_success_clears_it() {
        let mut s = UserStore::new();
        let now = 5_000_000u64;
        // The first few failures cost nothing.
        for i in 0..FAILS_PER_NAME_BEFORE_DELAY {
            assert_eq!(s.note_login_failure("alice", now, true), 0, "failure {}", i);
        }
        let d1 = s.note_login_failure("alice", now, true);
        let d2 = s.note_login_failure("alice", now, true);
        assert!(d1 > 0 && d2 > d1, "the delay did not escalate: {} then {}", d1, d2);
        // A different name is unaffected - the delay is per name.
        assert_eq!(s.note_login_failure("bob", now, true), 0);

        s.note_login_success("alice");
        assert_eq!(s.note_login_failure("alice", now, true), 0, "success did not reset the count");
    }

    /// A global flood is refused outright, and the refusal expires.
    #[test]
    fn a_global_failure_flood_is_refused_then_lifts() {
        let mut s = UserStore::new();
        let now = 7_000_000u64;
        assert_eq!(s.login_blocked(now), None);
        for i in 0..FAILS_GLOBAL_MAX {
            s.note_login_failure(&format!("name{}", i), now, true);
        }
        let wait = s.login_blocked(now).expect("the flood was not refused");
        assert!(wait <= GLOBAL_BLOCK_SECS);
        assert_eq!(s.login_blocked(now + GLOBAL_BLOCK_SECS + 1), None, "the block never lifted");
    }
}
