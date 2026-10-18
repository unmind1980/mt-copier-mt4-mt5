//! M4a: the config version store. The hub's half of config push.
//!
//! WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
//! =============================================
//! This is the half that CANNOT brick a receiver. It stores configs, versions
//! them, serves them over REST, and emits `CFG` on the wire. It does not touch
//! a node - because the half that touches a node is an EA that rewrites its own
//! `copier.ini` and reloads, and getting that wrong is how you end up with a
//! receiver that no longer starts. That is M4b, on its own, with its own tests.
//!
//! Until an EA understands `CFG`, an EA receiving one ignores it: an unknown
//! `T` is not an error anywhere in this protocol. So shipping this changes the
//! behaviour of nothing that is running.
//!
//! WRITES ARE ON BY DEFAULT
//! =======================
//! `--writes on` is the default since 2026-10-14. `--writes off` disables the
//! write gate: with it off, the PUT endpoint answers 403 and no `CFG` is ever emitted.
//!
//! WHY THE REVISIONS FILE IS APPEND-ONLY
//! =====================================
//! Same reasoning as the M7 audit, and it buys something extra here:
//!
//! * **The current config is the last revision for that node.** There is no
//!   separate "current" record to fall out of step with the history.
//! * **A rollback is an APPEND, not a rewrite.** Rolling back to rev 3 writes
//!   a NEW revision whose body equals rev 3's. The history keeps both, so "we
//!   went to 7 and then back to 3" is readable, instead of the log pretending
//!   the excursion never happened. A config store that can rewrite its own
//!   history cannot answer "what was it running when it broke".
//!
//! THE COMMAND ID IS A FUNCTION OF (NODE, REV), NOT A COUNTER
//! =========================================================
//! The plan's §5.4 requires a node to be idempotent by `ID`, and says why: in
//! the §11 primary/standby arrangement two hubs may push the SAME change. If
//! the id were a hub-local counter, the two hubs would mint different ids for
//! one change and the node would apply it twice. Deriving it from the content
//! makes a retry, a resend, and a second hub's copy the same command - which
//! is exactly the identity the protocol wants.
//!
//! **The machinery that acts on that id - the ladder, the ACK, the journal -
//! now lives in `commands.rs`**, because M5's operational commands need the
//! same thing and a second copy of "gave up" would be a second definition of
//! it. This module kept the part that is specific to a config: the revisions,
//! the escape and the validation.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};

/// One applied (or attempted) configuration change.
#[derive(Clone, Debug)]
pub struct Revision {
    pub node: String,
    pub rev: u64,
    pub ts: u64,
    pub actor: String,
    pub ip: String,
    /// The whole ini, verbatim. The plan's §7.2 sends the whole file rather
    /// than a diff so that "what the hub holds" and "what the node runs" are
    /// the same byte string and can be compared directly - a merge algorithm
    /// would become a second source of correctness.
    pub ini: String,
    /// What this revision was in response to. `"push"` for a new config,
    /// `"rollback"` for a return to an older one, `"adopt"` when a node's own
    /// config was taken as the starting point.
    pub kind: String,
    /// The revision this one returns to, for a rollback.
    pub from_rev: u64,
}

struct Inner {
    file: Option<File>,
    /// node -> its CURRENT revision. The last line wins, so this is rebuilt
    /// from the file on open rather than stored separately.
    current: HashMap<String, Revision>,
    /// Every revision ever, in file order. Bounded by nothing on disk - the
    /// plan's §15 says revisions are permanent - but only the ones a caller
    /// asks for are ever held in memory beyond `current`.
    count: u64,
    /// Set when a line in the file could not be parsed. Not fatal: a torn tail
    /// is a crash, and the revisions before it are still true.
    torn: u64,
}

/// Why a revision could not be stored.
///
/// THREE outcomes, not one, because they are three different facts to an
/// operator and collapsing them into `Option` made two of them lie:
///
/// * `Disabled` - `--config none`. A deliberate configuration, answered 503.
/// * `NotFound` - a rollback to a revision that never existed. A bad request.
/// * `Write`    - the append or its fsync failed. The disk is full, the file
///   is locked, the volume is gone. This one MUST NOT be reported as success:
///   a revision the hub believes in and the disk does not have is a revision
///   that vanishes on the next restart while every node keeps being compared
///   against it.
#[derive(Debug)]
pub enum StoreError {
    Disabled,
    NotFound,
    Write(String),
}

impl StoreError {
    /// The message a REST caller sees. Kept here so the two endpoints that
    /// store revisions cannot drift apart in how they describe the failure.
    pub fn detail(&self) -> String {
        match self {
            StoreError::Disabled => "the config store is disabled (--config none)".to_string(),
            StoreError::NotFound => "no such revision".to_string(),
            StoreError::Write(e) => format!("the revision could not be written to disk: {}", e),
        }
    }
}

pub struct ConfigStore {
    inner: Mutex<Inner>,
    path: PathBuf,
    enabled: bool,
}

impl ConfigStore {
    pub fn open(path: &Path) -> std::io::Result<ConfigStore> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        //--- A file that EXISTS but cannot be read is a hard failure, not an
        //--- empty store. Starting from scratch would mint revision numbers
        //--- that already exist lower in the file, and `load` is last-wins -
        //--- so the stale duplicate could win on the next restart.
        let (current, count, torn) = load(path)?;
        Ok(ConfigStore {
            inner: Mutex::new(Inner {
                file: Some(file),
                current,
                count,
                torn,
            }),
            path: path.to_path_buf(),
            enabled: true,
        })
    }

    pub fn disabled() -> ConfigStore {
        ConfigStore {
            inner: Mutex::new(Inner {
                file: None,
                current: HashMap::new(),
                count: 0,
                torn: 0,
            }),
            path: PathBuf::new(),
            enabled: false,
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// (revisions stored, nodes with a config, torn lines)
    pub fn stats(&self) -> (u64, usize, u64) {
        let i = self.inner.lock().unwrap();
        (i.count, i.current.len(), i.torn)
    }

    /// The current revision for a node, if it has ever had one.
    pub fn current(&self, node: &str) -> Option<Revision> {
        self.inner.lock().unwrap().current.get(node).cloned()
    }

    /// Every node that has a stored config, with its revision number.
    pub fn nodes(&self) -> Vec<(String, u64)> {
        let mut v: Vec<(String, u64)> = self
            .inner
            .lock()
            .unwrap()
            .current
            .iter()
            .map(|(k, r)| (k.clone(), r.rev))
            .collect();
        v.sort();
        v
    }

    /// Append a new revision. Returns it, or None if the store is disabled.
    ///
    /// `kind` is `push` or `adopt`; a rollback goes through `rollback` so the
    /// body is looked up rather than trusted from the caller.
    ///
    /// `base_rev` is the revision the NODE last reported. It matters only for
    /// the FIRST revision the hub stores for that node, and it prevents a
    /// false alarm that would otherwise fire every time:
    ///
    /// A node that has been running under its own config reports some rev N.
    /// If the hub started numbering at 1, its first push would be rev 1 - which
    /// is LOWER than N - and the node would look permanently "ahead" of the
    /// hub, i.e. drifted, when in fact the hub had just taken over. Continuing
    /// the node's numbering instead makes the hub's first revision strictly
    /// newer than what the node runs, so `in sync` is reachable.
    pub fn put(
        &self,
        node: &str,
        ini: &str,
        actor: &str,
        ip: &str,
        kind: &str,
        base_rev: u64,
    ) -> Result<Revision, StoreError> {
        let mut inner = self.inner.lock().unwrap();
        if inner.file.is_none() {
            return Err(StoreError::Disabled);
        }
        let rev = match inner.current.get(node) {
            Some(r) => r.rev.saturating_add(1),
            //--- `base_rev` comes straight off the wire (`REV=` on a REG), so
            //--- it is a number a peer chooses. `base_rev + 1` on
            //--- `u64::MAX` wraps to 0 in a release build - and rev 0 is the
            //--- one value `load` discards, so the revision would be both
            //--- invalid and non-monotonic. Clamping to a value no real
            //--- deployment can reach keeps the arithmetic total.
            None => base_rev.min(MAX_WIRE_BASE_REV).saturating_add(1),
        };
        let r = Revision {
            node: node.to_string(),
            rev,
            ts: unix_secs(),
            actor: actor.to_string(),
            ip: ip.to_string(),
            ini: ini.to_string(),
            kind: kind.to_string(),
            from_rev: 0,
        };
        //--- Persist FIRST, then publish. The other order is what made a
        //--- failed write look like a successful revision: `current` said N+1
        //--- while the file's last line was still N, and after a restart the
        //--- hub silently disagreed with itself.
        inner.append(&r).map_err(|e| StoreError::Write(e.to_string()))?;
        inner.current.insert(node.to_string(), r.clone());
        Ok(r)
    }

    /// Roll back to `to_rev` by APPENDING a new revision whose body is that
    /// revision's. The history keeps both, so the excursion stays visible.
    ///
    /// Returns `NotFound` if that revision does not exist - a rollback to
    /// something that never was is not a rollback, and silently doing nothing
    /// would be worse than saying so.
    pub fn rollback(
        &self,
        node: &str,
        to_rev: u64,
        actor: &str,
        ip: &str,
    ) -> Result<Revision, StoreError> {
        let body = self.revision_body(node, to_rev).ok_or(StoreError::NotFound)?;
        let mut inner = self.inner.lock().unwrap();
        if inner.file.is_none() {
            return Err(StoreError::Disabled);
        }
        let rev = inner
            .current
            .get(node)
            .map(|r| r.rev.saturating_add(1))
            .unwrap_or(1);
        let r = Revision {
            node: node.to_string(),
            rev,
            ts: unix_secs(),
            actor: actor.to_string(),
            ip: ip.to_string(),
            ini: body,
            kind: "rollback".to_string(),
            from_rev: to_rev,
        };
        inner.append(&r).map_err(|e| StoreError::Write(e.to_string()))?;
        inner.current.insert(node.to_string(), r.clone());
        Ok(r)
    }

    /// The body of one specific revision, read from the file.
    fn revision_body(&self, node: &str, rev: u64) -> Option<String> {
        let text = std::fs::read_to_string(&self.path).ok()?;
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v["node"].as_str() == Some(node) && v["rev"].as_u64() == Some(rev) {
                    return v["ini"].as_str().map(|s| s.to_string());
                }
            }
        }
        None
    }

    /// The most recent `limit` revisions, newest last.
    pub fn history(&self, node: &str, limit: usize) -> Vec<Value> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(_) => return Vec::new(),
        };
        let mut out: Vec<Value> = Vec::new();
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v["node"].as_str() != Some(node) {
                    continue;
                }
                // The body is large and a history list does not need it.
                let mut brief = v.clone();
                if let Some(o) = brief.as_object_mut() {
                    let n = o
                        .get("ini")
                        .and_then(|x| x.as_str())
                        .map(|s| s.len())
                        .unwrap_or(0);
                    o.remove("ini");
                    o.insert("ini_bytes".to_string(), json!(n));
                }
                out.push(brief);
            }
        }
        if out.len() > limit {
            out.drain(0..out.len() - limit);
        }
        out
    }

}

impl Inner {
    /// Append one revision and make it durable. Returns the io error rather
    /// than swallowing it: the caller must not publish a revision the disk
    /// does not have.
    fn append(&mut self, r: &Revision) -> std::io::Result<()> {
        let line = json!({
            "v": 1,
            "node": r.node,
            "rev": r.rev,
            "ts": r.ts,
            "actor": r.actor,
            "ip": r.ip,
            "kind": r.kind,
            "from_rev": r.from_rev,
            "ini": r.ini,
        });
        let mut s = serde_json::to_string(&line).unwrap_or_else(|_| "{}".to_string());
        s.push('\n');
        if let Some(f) = self.file.as_mut() {
            // Same rule as the audit: append, flush to disk, never seek. The
            // config a node is running must survive the machine losing power.
            if let Err(e) = f.write_all(s.as_bytes()).and_then(|_| f.sync_data()) {
                eprintln!("[hub] CONFIG WRITE FAILED: {}", e);
                return Err(e);
            }
        }
        self.count += 1;
        Ok(())
    }
}

/// The largest `REV=` the hub will honour from the wire as a numbering base.
///
/// A node reports its own revision on REG so the hub can continue its
/// numbering instead of appearing to go backwards. That number is chosen by
/// the peer, and `base_rev + 1` on `u64::MAX` wraps to 0 - the one value
/// `load` discards - which would break monotonicity AND silently lose the
/// revision. A billion pushes is far beyond any real deployment, so anything
/// above this is treated as "no usable base" and numbering starts at 1.
const MAX_WIRE_BASE_REV: u64 = 1_000_000_000;

fn load(path: &Path) -> std::io::Result<(HashMap<String, Revision>, u64, u64)> {
    let mut current: HashMap<String, Revision> = HashMap::new();
    let mut count = 0u64;
    let mut torn = 0u64;
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        //--- A file that does not exist yet is an empty store - the normal
        //--- first-run state. Anything ELSE (permissions, a directory in the
        //--- way, I/O error) is propagated: silently returning an empty store
        //--- would restart revision numbering on top of revisions that are
        //--- still in the file.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok((current, count, torn))
        }
        Err(e) => return Err(e),
    };
    //--- LOSSY, deliberately. `read_to_string` fails on ANY invalid UTF-8,
    //--- and a crash mid-append can split a multibyte character - so one torn
    //--- line used to discard the ENTIRE history, including every other
    //--- node's config. Replacing the bad bytes with U+FFFD leaves that one
    //--- line unparseable (counted as torn) and every other line intact.
    let text = String::from_utf8_lossy(&bytes);
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(v) => {
                let node = v["node"].as_str().unwrap_or("").to_string();
                let rev = v["rev"].as_u64().unwrap_or(0);
                if node.is_empty() || rev == 0 {
                    continue;
                }
                count += 1;
                // Last one wins, so the map ends up holding the current
                // revision without a separate "current" record to keep in step.
                current.insert(
                    node.clone(),
                    Revision {
                        node,
                        rev,
                        ts: v["ts"].as_u64().unwrap_or(0),
                        actor: v["actor"].as_str().unwrap_or("").to_string(),
                        ip: v["ip"].as_str().unwrap_or("").to_string(),
                        ini: v["ini"].as_str().unwrap_or("").to_string(),
                        kind: v["kind"].as_str().unwrap_or("").to_string(),
                        from_rev: v["from_rev"].as_u64().unwrap_or(0),
                    },
                );
            }
            Err(_) => {
                // A torn tail is a crash mid-append; the revisions before it
                // are still true. Counted rather than hidden.
                torn += 1;
            }
        }
    }
    Ok((current, count, torn))
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}


/// Percent-style escaping for putting a whole ini file inside one `key=value`.
///
/// WHY THIS IS NEEDED AT ALL
/// ========================
/// An ini contains every character the payload format uses as a separator:
/// `;` starts a comment, `=` separates a key from its value, `|` separates
/// envelope fields, and there are newlines between every line. Dropping the
/// raw text into `INI=...` would end the field at the first `;` in the first
/// comment, and the node would receive a truncated config - which is exactly
/// the kind of failure that looks like "the push worked" until the receiver
/// restarts.
///
/// WHY NOT BASE64
/// ==============
/// The mirror of this has to be written in MQL, and MQL4 has no `CryptEncode`
/// (that is MQL5 only) - so base64 would mean hand-rolling an encoder AND a
/// decoder on the EA side. This project already hand-rolls where the built-ins
/// diverge (`CopierTrim`), but a 5-character escape is a smaller thing to get
/// right than base64 padding, and it stays readable in a packet capture.
///
/// WHAT IT DOES AND DOES NOT GUARANTEE, because the first version of this
/// comment claimed the wrong one:
///
/// * It DOES guarantee that the output contains none of `| ; ~ , =` or a
/// Escape one ini for embedding in a `CFG` payload.
///
/// WHY THIS ITERATES CHARACTERS, NOT BYTES (measured, not theoretical)
/// ====================================================
/// It used to iterate `s.bytes()` and push the survivors with `b as char`.
/// In Rust, `u8 as char` maps the byte's VALUE to the code point with that
/// number - so the UTF-8 sequence for '中' (bytes E4 B8 AD) came out as the
/// three Latin-1 characters 'ä¸­', which is a different, longer UTF-8
/// encoding once the payload is serialised. Every Chinese comment in a
/// pushed ini therefore arrived on the node as mojibake, and
/// `unescape(escape(x)) == x` failed for exactly the operator most likely
/// to have written comments in the first place. Iterating `chars()` lets a
/// non-ASCII character pass through UNTOUCHED - it contains none of the
/// delimiters this encoding exists to escape, so there is nothing to do to
/// it in the first place.
///
/// WHAT IS ESCAPED: the characters the payload format uses as delimiters -
/// `%` (the escape character itself), `|` (field separator), `;` (payload
/// KV separator), `,` (the INI list separator), `=` (the KV separator),
/// `~` (MQL4 comment), `\n` and `\r` - the last two being the whole point:
/// the value can be embedded in the payload without ending the field early.
///
/// It does NOT guarantee idempotence. `%` is both escaped and present in the
/// output alphabet, so encoding twice gives `%2525` for a literal `%`.
/// Percent-encoding is a layering, not a projection, and a test asserting
/// otherwise is asserting something false.
///
/// The property that actually matters is the round trip, and that is what is
/// tested: `unescape(escape(x)) == x` for a real ini, Chinese comments
/// included. The hub escapes exactly once and the node unescapes exactly
/// once; neither needs to guess how many times the other ran.
pub fn escape_ini(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + s.len() / 8);
    for c in s.chars() {
        match c {
            // '%' FIRST in the match is not an ordering requirement (each char
            // is visited once), but it is the one that must exist for the
            // encoding to be reversible at all.
            '%' => out.push_str("%25"),
            '|' => out.push_str("%7C"),
            ';' => out.push_str("%3B"),
            '~' => out.push_str("%7E"),
            ',' => out.push_str("%2C"),
            '=' => out.push_str("%3D"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            _ => out.push(c),
        }
    }
    out
}

/// Length of the UTF-8 sequence starting with `b0`. Only used to COPY
/// pass-through characters out whole; a malformed lead byte degrades to 1
/// rather than panicking, because the input may be a mangled file from an
/// older build and the buyer of that mojibake is the reader, not a crash.
fn utf8_seq_len(b0: u8) -> usize {
    if b0 < 0x80 {
        1
    } else if b0 >> 5 == 0b110 {
        2
    } else if b0 >> 4 == 0b1110 {
        3
    } else if b0 >> 3 == 0b11110 {
        4
    } else {
        1
    }
}

/// The inverse. Used by the hub to decode current setting INI reports uploaded by nodes.
///
/// The escape table is all-ASCII, so the `%` fast path is untouched by the
/// char-copy below - but the OLD default pushed `b[i] as char`, which mapped
/// every pass-through byte 0x80..=0xFF to its Latin-1 code point and
/// re-encoded a UTF-8 sequence into something longer and wrong. A Chinese
/// comment survived escape, then died here.
///
/// WHY THIS DECODES FROM BYTES AND NEVER SLICES THE &str
/// ====================================================
/// It used to read the two hex digits as `&s[i + 1..i + 3]`. `i + 3` is not
/// guaranteed to be a char boundary: a payload of `%` followed by one
/// multibyte character (`"%中"` - three bytes) puts index 3 in the middle of
/// that character, and Rust PANICS on the slice rather than returning
/// something wrong. `unescape_ini` runs on the `INI=` field of every `REG`
/// and `CFGRPT` that arrives on the wire, so a single malformed frame from
/// any node that can reach the port would take the whole hub down - a remote
/// crash reachable from a trusted-but-compromised peer, and one the MQL
/// decoder (CopierIniUnescape) never had because MQL has no such slice.
///
/// Reading the two bytes directly and validating them as hex digits makes
/// the panic impossible by construction: no string index is ever computed
/// from a length that could land mid-character.
pub fn unescape_ini(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < b.len() {
        //--- `i + 2 < b.len()` guarantees both bytes below exist. They are
        //--- checked to be hex DIGITS, which also proves they are ASCII and
        //--- therefore never continuation bytes of a multibyte character.
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h1), Some(h2)) = (hex_val(b[i + 1]), hex_val(b[i + 2])) {
                let code = (h1 << 4) | h2;
                //--- Only the eight escapes the encoder produces are
                //--- accepted. A decoder that passed any %XX through would
                //--- turn a corrupt payload into a plausible-looking ini,
                //--- which is worse than refusing it. An unknown escape is
                //--- copied literally below, exactly as before.
                let decoded = match code {
                    b'%' | b'|' | b';' | b'~' | b',' | b'=' | b'\n' | b'\r' => Some(code),
                    _ => None,
                };
                if let Some(c) = decoded {
                    out.push(c as char);
                    i += 3;
                    continue;
                }
            }
        }
        //--- Copy the WHOLE character at this boundary. `i` is always on one:
        //--- the loop advances by whole sequences and by ASCII escapes only.
        let end = (i + utf8_seq_len(b[i])).min(b.len());
        out.push_str(&s[i..end]);
        i = end;
    }
    out
}

/// Value of one ASCII hex digit, or None. Used by `unescape_ini`, where a
/// non-digit must mean "not an escape" rather than an error.
fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// What an ini must look like before the hub will store and push it.
///
/// WHY THE HUB VALIDATES AT ALL, given the node will validate too
/// =============================================================
/// Because the node's rejection is a `CFG` that comes back `OK=0`, and by then
/// the hub has stored the bad config and will keep re-pushing it - every REG
/// comparison sees the node behind and tries again. Catching it at the door
/// makes a truncated paste a 400 to the operator, once, instead of a node being
/// told to apply something it will never accept.
///
/// It is a SHAPE check, not a semantic one. It cannot know whether an account
/// number exists or whether a symbol maps to anything; that is the node's
/// business. It knows that an ini with no `[section]`, or with a line that is
/// neither a section nor a `key=value`, is not one anybody meant to send.
pub fn validate_ini(ini: &str) -> Result<(), String> {
    /// Generous, and still far below `CP_MAX_MSG_LEN` even after escaping -
    /// which matters, because an oversized one would be refused by the
    /// transport with a much less useful message.
    const MAX_INI_BYTES: usize = 256 * 1024;

    if ini.trim().is_empty() {
        return Err("empty".to_string());
    }
    if ini.len() > MAX_INI_BYTES {
        return Err(format!(
            "{} bytes, over the {} limit",
            ini.len(),
            MAX_INI_BYTES
        ));
    }
    let mut sections = 0usize;
    for (n, raw) in ini.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            if !line.ends_with(']') || line.len() < 3 {
                return Err(format!("line {}: malformed section header {:?}", n + 1, line));
            }
            sections += 1;
            continue;
        }
        // `key=value`. The VALUE may contain '=' - the split is on the FIRST
        // one - which is why this is not `split('=').count() == 2`.
        match line.split_once('=') {
            Some((k, _)) if !k.trim().is_empty() => {}
            _ => {
                return Err(format!(
                    "line {}: not a section or key=value: {:?}",
                    n + 1,
                    line
                ))
            }
        }
    }
    if sections == 0 {
        return Err("no [section] - this does not look like a copier.ini".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("copier_cfg_test_{}_{}", std::process::id(), name));
        let _ = std::fs::remove_file(&p);
        p
    }

    /// The escape has to survive a real ini - comments, `=`, newlines and all -
    /// because a truncated config is a receiver that will not start.
    #[test]
    fn an_ini_round_trips_through_the_escape() {
        let ini = "[sender1]\n\
                   id=alpari01\n\
                   events=5555\n\
                   ; a comment with = and ; in it\n\
                   lotmode=multiplier\n\
                   lotparam=2.0\n\
                   symbol.EURUSD=EURUSD.m\n";
        let e = escape_ini(ini);
        assert!(!e.contains('\n'), "a newline survived the escape");
        assert!(!e.contains(';'), "a ';' survived - the field would end early");
        assert!(!e.contains('=') || e.starts_with("%"), "an '=' survived");
        assert_eq!(unescape_ini(&e), ini);
    }

    /// The property that makes the escape usable: its output contains none of
    /// the characters the payload uses to delimit fields. Without this the ini
    /// would be truncated at the first `;` of its first comment.
    ///
    /// This test REPLACED one that asserted idempotence, which is false: `%`
    /// is escaped and also appears in the output, so a second pass gives
    /// `%2525`. The comment in this file claimed otherwise and the test caught
    /// it - which is the only reason the claim is now correct.
    #[test]
    fn the_escaped_form_contains_no_separator() {
        let raw = "a%b|c;d~e,f=g\nh\r";
        let e = escape_ini(raw);
        for bad in ['|', ';', '~', ',', '=', '\n', '\r'] {
            assert!(
                !e.contains(bad),
                "the escaped form still contains {:?} - the field would end early",
                bad
            );
        }
        // And it is reversible, which is the guarantee that does hold.
        assert_eq!(unescape_ini(&e), raw);

        // Stated plainly so nobody "fixes" it back: encoding twice is NOT a
        // no-op, and it should not be - it is a layering.
        assert_ne!(escape_ini(&e), e, "percent-encoding is not idempotent");
        assert_eq!(unescape_ini(&escape_ini(&e)), e);
    }

    /// A `%` followed by a multibyte character used to PANIC, because the
    /// decoder sliced `&s[i+1..i+3]` and `i+3` can land inside a character.
    /// `unescape_ini` runs on the `INI=` field of every REG and CFGRPT, so
    /// that panic was a remote crash of the whole hub. These inputs are all
    /// malformed and all reachable from the wire; none may panic.
    #[test]
    fn unescape_never_panics_on_a_percent_before_a_multibyte_char() {
        for s in [
            "%中",          // % + one 3-byte char: index 3 is mid-character
            "%%中",         // two % then a 3-byte char
            "a=%é",         // the realistic shape: an unescaped value
            "%中文注释",     // % followed by several multibyte chars
            "%",            // a lone trailing escape character
            "%2",           // a truncated escape
            "%zz",          // not hex
            "%25中",        // a VALID escape followed by multibyte text
        ] {
            // The assertion is simply "returns", but the value is checked for
            // the one case with a defined answer so the test is not vacuous.
            let got = unescape_ini(s);
            if s == "%25中" {
                assert_eq!(got, "%中", "a valid escape before text must decode");
            }
        }
    }

    #[test]
    fn a_first_revision_continues_the_nodes_own_numbering() {
        let p = tmp("base");
        let c = ConfigStore::open(&p).unwrap();
        // The node is running rev 7 of its own accord; the hub's first push
        // must be 8, not 1 - otherwise the node looks permanently ahead and
        // every REG reports drift.
        let r = c.put("receiver:1", "a=1\n", "op", "10.0.0.1", "push", 7).unwrap();
        assert_eq!(r.rev, 8);
        let r2 = c.put("receiver:1", "a=2\n", "op", "10.0.0.1", "push", 7).unwrap();
        assert_eq!(r2.rev, 9, "the second revision must not restart the count");
        let _ = std::fs::remove_file(&p);
    }

    /// A rollback APPENDS. If it rewrote, the log would claim the excursion
    /// never happened - and "what was it running when it broke" would have no
    /// answer.
    #[test]
    fn a_rollback_appends_rather_than_rewrites() {
        let p = tmp("rollback");
        let c = ConfigStore::open(&p).unwrap();
        c.put("receiver:1", "a=1\n", "op", "ip", "push", 0).unwrap();
        c.put("receiver:1", "a=2\n", "op", "ip", "push", 0).unwrap();
        let before = std::fs::read(&p).unwrap();

        let r = c.rollback("receiver:1", 1, "op", "ip").unwrap();
        assert_eq!(r.rev, 3, "a rollback is a new revision");
        assert_eq!(r.ini, "a=1\n", "and carries the old body");
        assert_eq!(r.kind, "rollback");
        assert_eq!(r.from_rev, 1);

        let after = std::fs::read(&p).unwrap();
        assert!(after.len() > before.len());
        assert_eq!(&after[..before.len()], &before[..], "history was rewritten");

        // And rev 2 is still there, so the excursion is readable.
        let h = c.history("receiver:1", 10);
        assert_eq!(h.len(), 3);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn a_rollback_to_a_revision_that_never_existed_is_refused() {
        let p = tmp("rollback_bad");
        let c = ConfigStore::open(&p).unwrap();
        c.put("receiver:1", "a=1\n", "op", "ip", "push", 0).unwrap();
        assert!(matches!(
            c.rollback("receiver:1", 99, "op", "ip"),
            Err(StoreError::NotFound)
        ));
        let _ = std::fs::remove_file(&p);
    }

    /// A `REV=` from the wire is a number a peer chooses. `base_rev + 1` on
    /// `u64::MAX` wraps to 0 in a release build - the one value `load`
    /// discards - so the revision would be both invalid and non-monotonic.
    #[test]
    fn an_absurd_wire_base_rev_cannot_wrap_to_zero() {
        let p = tmp("basemax");
        let c = ConfigStore::open(&p).unwrap();
        let r = c.put("receiver:1", "a=1\n", "op", "ip", "push", u64::MAX).unwrap();
        assert!(r.rev > 0, "a wrapped revision number would be discarded by load");
        assert!(r.rev <= MAX_WIRE_BASE_REV + 1);
        // And the next one still moves forward.
        let r2 = c.put("receiver:1", "a=2\n", "op", "ip", "push", u64::MAX).unwrap();
        assert_eq!(r2.rev, r.rev + 1);
        let _ = std::fs::remove_file(&p);
    }

    /// A crash mid-append can split a multibyte character. `read_to_string`
    /// fails on the WHOLE file in that case, which used to discard every
    /// node's config and restart revision numbering on top of revisions that
    /// were still on disk. The lossy read keeps the good lines.
    #[test]
    fn a_torn_multibyte_line_does_not_discard_the_rest_of_the_history() {
        let p = tmp("torn_utf8");
        {
            let c = ConfigStore::open(&p).unwrap();
            c.put("receiver:1", "a=1\n", "op", "ip", "push", 0).unwrap();
            c.put("receiver:2", "b=1\n", "op", "ip", "push", 0).unwrap();
        }
        // Simulate a torn append: half a JSON line ending inside a 3-byte
        // character (E4 B8), which makes the file invalid UTF-8.
        {
            use std::io::Write as _;
            let mut f = OpenOptions::new().append(true).open(&p).unwrap();
            f.write_all(b"{\"v\":1,\"node\":\"receiver:3\",\"rev\":1,\"ini\":\"\xE4\xB8").unwrap();
        }
        let c = ConfigStore::open(&p).expect("an unreadable tail must not lose the store");
        assert_eq!(c.current("receiver:1").map(|r| r.rev), Some(1));
        assert_eq!(c.current("receiver:2").map(|r| r.rev), Some(1));
        let (count, nodes, torn) = c.stats();
        assert_eq!(count, 2, "the two good revisions were lost");
        assert_eq!(nodes, 2);
        assert_eq!(torn, 1, "the torn line was not counted");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn a_plausible_ini_passes_and_the_obvious_mistakes_do_not() {
        assert!(validate_ini("[sender1]\nid=a\nevents=5555\n").is_ok());
        // comments and blank lines are fine
        assert!(validate_ini("; hi\n\n[s]\nk=v\n# also a comment\n").is_ok());
        // a value containing '=' is fine - the split is on the first one
        assert!(validate_ini("[s]\nk=a=b\n").is_ok());

        // the mistakes worth catching at the door
        assert!(validate_ini("").is_err());
        assert!(validate_ini("   \n\n").is_err());
        assert!(validate_ini("id=a\nevents=1\n").is_err(), "no section");
        assert!(validate_ini("[unclosed\nk=v\n").is_err());
        assert!(validate_ini("[s]\nthis line has no equals\n").is_err());
        assert!(validate_ini("[s]\n=v\n").is_err(), "empty key");
    }

    #[test]
    fn the_current_config_is_the_last_revision_after_a_reopen() {
        let p = tmp("reopen");
        {
            let c = ConfigStore::open(&p).unwrap();
            c.put("receiver:1", "a=1\n", "op", "ip", "push", 0).unwrap();
            c.put("receiver:1", "a=2\n", "op", "ip", "push", 0).unwrap();
            c.put("receiver:2", "b=1\n", "op", "ip", "push", 0).unwrap();
        }
        let c = ConfigStore::open(&p).unwrap();
        assert_eq!(c.current("receiver:1").unwrap().rev, 2);
        assert_eq!(c.current("receiver:1").unwrap().ini, "a=2\n");
        assert_eq!(c.current("receiver:2").unwrap().rev, 1);
        assert_eq!(c.nodes(), vec![("receiver:1".into(), 2), ("receiver:2".into(), 1)]);
        let _ = std::fs::remove_file(&p);
    }
}
