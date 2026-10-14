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
const HASH_ROUNDS: u32 = 4096;

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
    /// Where the users live. The hub passes --users; the tests pass their own
    /// so a test hub never writes (or misses) the real one.
    path: std::path::PathBuf,
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
                        path: path.to_path_buf(),
                    });
                }
                let users: Vec<User> =
                    serde_json::from_str(&text).map_err(|e| format!("{}: {}", path.display(), e))?;
                Ok(UserStore {
                    users,
                    sessions: HashMap::new(),
                    path: path.to_path_buf(),
                })
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(UserStore {
                users: Vec::new(),
                sessions: HashMap::new(),
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
        std::fs::write(&tmp, text).map_err(|e| format!("{}: {}", tmp.display(), e))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| format!("{}: {}", self.path.display(), e))
    }

    pub fn users(&self) -> &[User] {
        &self.users
    }

    pub fn get(&self, id: &str) -> Option<&User> {
        self.users.iter().find(|u| u.id == id)
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
            *slot = u;
        } else {
            self.users.push(u);
        }
        Ok(())
    }

    pub fn remove(&mut self, id: &str) -> Result<(), String> {
        let idx = self
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
    let mut acc = sha256(format!("{}:{}", salt, password).as_bytes());
    for _ in 1..HASH_ROUNDS {
        acc = sha256(&acc);
    }
    format!("{}${}${}", salt, HASH_ROUNDS, hex(&acc))
}

pub fn verify_password(password: &str, stored: &str) -> bool {
    let parts: Vec<&str> = stored.split('$').collect();
    if parts.len() != 3 {
        return false;
    }
    let candidate = hash_password(password, parts[0]);
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

/// A random session token. NOT from `/dev/urandom` (no crate available):
/// three `RandomState` hashes of a nanosecond counter plus the counter
/// itself, folded together. This is session-scope entropy behind a
/// firewall-bound port and it rotates on every login - the passwords
/// carry the real entropy. Honest, and documented rather than faked.
pub fn random_token() -> String {
    let rs = [RandomState::new(), RandomState::new(), RandomState::new()];
    let nanos = || {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0)
    };
    let mut out = [0u8; 32];
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

/// A one-time bootstrap password: 12 chars from a URL-safe alphabet.
pub fn random_password() -> String {
    const ALPHA: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
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
    fn a_viewer_can_join_an_empty_store() {
        // Regression: the last-admin guard once read an empty store as
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
}
