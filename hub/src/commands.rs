//! M5: the command engine. One implementation of issue → retry → acknowledge,
//! shared by config pushes (M4) and operational commands (M5).
//!
//! WHY THIS IS ONE MODULE AND NOT TWO
//! ==================================
//! M4 built the whole "mint an id, watch for an ACK, walk a backoff ladder,
//! give up as `unknown`" machinery for `CFG`. M5's commands are the same
//! problem with a different payload, so the honest thing is to move that
//! machinery here and have both callers use it - not to write a second copy
//! that drifts. A second ladder would be a second definition of "gave up",
//! and the two would disagree the first time somebody tuned one of them.
//!
//! `config.rs` still owns what is specific to a config: the revisions, the
//! escape, the validation. It no longer owns a command.
//!
//! THE ID, AND WHAT IT CAN AND CANNOT GUARANTEE
//! ============================================
//! §5.4 rule 2 requires a node to be idempotent by `ID`: a repeated id
//! re-sends the previous ACK and does **not** re-apply. Two properties follow,
//! and they pull in opposite directions:
//!
//! * A RETRY must carry the same id as the original. Otherwise a lost ACK
//!   makes the node apply the same intent twice.
//! * Two DISTINCT intents must carry different ids. Otherwise "pause, resume,
//!   pause" collapses: the third command would look like the first, and the
//!   node would answer "already did that" while it is actually running.
//!
//! A config revision satisfies both for free, because the revision number *is*
//! the identity of the thing being applied: `(node, rev)`. A command has no
//! such content - `pause` is `pause` - so it needs a sequence to tell two
//! pauses apart, and the sequence is per node and continues across a restart
//! (the same rule revisions follow, and for the same reason: restarting the
//! count would make a new command collide with an old one).
//!
//! **What this does NOT guarantee, stated plainly:** the sequence is
//! hub-local. Under §11 primary/standby, two hubs would mint different ids for
//! one operator intent, exactly as the plan warns about counters. The config
//! path only escapes that once the store is REPLICATED, and §11's replication
//! is not built. What makes it acceptable meanwhile is not the id at all - it
//! is §5.4 rule 2 at the node, plus the fact that all four operations are
//! idempotent (`pause` twice is `pause`, and the second `closeall` finds
//! nothing left to close). When replication lands, the id is the thing that
//! has to change, and this comment is where that is recorded.
//!
//! WHY THE JOURNAL IS APPEND-ONLY, AND WHY COMMANDS ARE IN IT
//! =========================================================
//! §15 says in-flight commands are stored, because after a restart the hub
//! must still know what it told a node to do. That is the whole reason this
//! file exists: a `closeall` that the hub forgets across a restart is
//! indistinguishable from one that was never sent, and those must never look
//! alike.
//!
//! The shape is the config store's, deliberately: one JSON object per line,
//! append and `sync_data`, never seek or truncate. A command's STATE changes
//! over its life, and a state change is written as a NEW LINE carrying the
//! same id - so the file holds the history of the command (issued, sent,
//! acked) and loading it is last-wins per id. Nothing is ever rewritten, so
//! "what did the hub believe, and when" stays answerable.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

/// Backoff for an unacknowledged command, from the plan's §5.4: 2s → 5s → 15s
/// → 60s, then give up. Deliberately finite: an unbounded retry against a node
/// that is never coming back is a way to fill a log and a queue forever.
pub const RETRY_LADDER_SECS: [u64; 4] = [2, 5, 15, 60];

/// After the ladder is exhausted the command is `unknown` - the plan's word,
/// and the right one. `failed` would claim we know it did not happen; we do
/// not know either way.
pub const STATE_PENDING: &str = "pending";
pub const STATE_ACKED: &str = "acked";
pub const STATE_REJECTED: &str = "rejected";
pub const STATE_UNKNOWN: &str = "unknown";

/// A config push. Sent as `CFG`; the ladder re-sends the stored revision.
pub const KIND_CONFIG: &str = "config";
/// An operational command. Sent as `CMD`; the ladder re-sends the same id.
pub const KIND_OP: &str = "op";

/// How long a FINISHED config command stays finished before `issue_cfg` will
/// revive it. See the note there: the comparison that calls it runs on every
/// heartbeat, so this is what separates "self-heal" from "flood".
pub const REVIVE_COOLDOWN_SECS: u64 = 60;

/// The operational commands, and the ONLY ones the hub will issue.
///
/// A closed set, checked at the door, because the hub cannot tell a typo from
/// a command: `POST {"op":"paus"}` that were accepted would sit on the ladder
/// for 82 seconds and then be reported as `unknown`, which reads like "the
/// node did not answer" rather than "you misspelled it".
pub const OPS: [&str; 4] = ["pause", "resume", "closeall", "reload"];

pub fn is_known_op(op: &str) -> bool {
    OPS.contains(&op)
}

/// One command, whatever kind.
#[derive(Clone, Debug)]
pub struct Command {
    pub id: String,
    /// The registry key, `ROLE:ACC`.
    pub node: String,
    /// `config` or `op`. Decides which message the ladder emits and which
    /// audit action the result is recorded under.
    pub kind: String,
    /// The config revision, for `config`; 0 for `op`.
    pub rev: u64,
    /// The operation, for `op`; empty for `config`.
    pub op: String,
    /// The per-node sequence this operation was issued under, for `op`; 0 for
    /// `config`. Stored rather than parsed back out of the id so the counter
    /// does not depend on the id format staying what it is today.
    pub seq: u64,
    /// Reserved for an operation that needs an argument. Nothing uses it yet,
    /// and it is on the wire so that adding one is not a protocol change.
    pub args: String,
    pub state: String,
    pub ts: u64,
    pub actor: String,
    pub ip: String,
    pub attempts: u32,
    pub ack_at: u64,
    pub err: String,
    /// When this command is next allowed to be sent. Runtime only - it is an
    /// `Instant`, which does not survive a restart, and it should not: a hub
    /// that comes back up should retry a pending command promptly rather than
    /// wait out the remainder of a ladder it inherited.
    pub next_at: Instant,
}

struct Inner {
    file: Option<File>,
    /// id -> the command, at its LATEST state. Rebuilt last-wins from the
    /// file, so there is no separate "current state" record to fall out of
    /// step with the history.
    commands: HashMap<String, Command>,
    /// node -> highest op sequence ever issued. Also rebuilt from the file, so
    /// a restart does not hand out a number that was already used.
    seq: HashMap<String, u64>,
    /// Lines that would not parse. Not fatal: a torn tail is a crash, and the
    /// commands before it are still true.
    torn: u64,
}

pub struct CommandStore {
    inner: Mutex<Inner>,
    path: PathBuf,
    enabled: bool,
    salt: String,
}

impl CommandStore {
    pub fn open(path: &Path) -> std::io::Result<CommandStore> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        let (commands, seq, torn) = load(path);
        Ok(CommandStore {
            inner: Mutex::new(Inner {
                file: Some(file),
                commands,
                seq,
                torn,
            }),
            path: path.to_path_buf(),
            enabled: true,
            salt: String::new(),
        })
    }

    /// No file: commands are still tracked and retried, they just do not
    /// survive a restart. Kept as a real mode rather than a refusal because
    /// `--config none` already means "run without the config feature", and a
    /// hub with no journal should still be able to answer `/commands` honestly
    /// rather than 503.
    pub fn disabled() -> CommandStore {
        let salt = format!("{:04x}", (unix_millis() ^ (std::process::id() as u64)) & 0xffff);
        CommandStore {
            inner: Mutex::new(Inner {
                file: None,
                commands: HashMap::new(),
                seq: HashMap::new(),
                torn: 0,
            }),
            path: PathBuf::new(),
            enabled: false,
            salt,
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// (total commands known, pending, torn lines)
    pub fn stats(&self) -> (usize, usize, u64) {
        let i = self.inner.lock().unwrap();
        let pending = i
            .commands
            .values()
            .filter(|c| c.state == STATE_PENDING)
            .count();
        (i.commands.len(), pending, i.torn)
    }

    /// Register (or return) the config-push command for a revision.
    ///
    /// Idempotent by construction: the id is a function of `(node, rev)`, so a
    /// REG comparison that decides to push again, and a `CFGR` from the node,
    /// and a retry - all land on the same command instead of minting another.
    /// That is §5.4 rule 2 seen from the hub's side.
    pub fn issue_cfg(&self, node: &str, rev: u64, actor: &str, ip: &str) -> Command {
        self.issue_cfg_at(node, rev, actor, ip, unix_secs())
    }

    /// `issue_cfg` with an explicit clock, so the revive cooldown can be
    /// exercised without sleeping for a minute.
    pub fn issue_cfg_at(
        &self,
        node: &str,
        rev: u64,
        actor: &str,
        ip: &str,
        now_secs: u64,
    ) -> Command {
        let id = command_id_cfg(node, rev);
        let mut inner = self.inner.lock().unwrap();
        if let Some(c) = inner.commands.get_mut(&id) {
            if c.state == STATE_PENDING {
                c.next_at = Instant::now();
                return c.clone();
            }
            //--- A command that has ENDED - `unknown` after the ladder, or
            //--- `rejected` by the node - is revived here, because the whole
            //--- point of this call is "this node needs this revision". A node
            //--- that restarts with a stale ini, or one that was simply
            //--- offline for the whole ladder, would otherwise be stuck on the
            //--- old config forever: the command existed, so nothing new was
            //--- ever minted, and nothing ever re-sent it.
            //---
            //--- BUT NOT ON EVERY HEARTBEAT. This is called from the REG/HBT2
            //--- comparison, which fires every 5 s - so an unconditional
            //--- revival turns a node that keeps REJECTING a bad config into a
            //--- push every 5 seconds, forever, with a log line each time.
            //--- The cooldown makes the self-heal a retry every minute instead:
            //--- fast enough to recover a node that came back, slow enough that
            //--- a refusal is not amplified into a flood.
            let last = c.ts.max(c.ack_at);
            if now_secs.saturating_sub(last) < REVIVE_COOLDOWN_SECS {
                return c.clone();
            }
            c.state = STATE_PENDING.to_string();
            c.attempts = 0;
            c.ack_at = 0;
            c.err = String::new();
            c.ts = now_secs;
            c.next_at = Instant::now();
            if !actor.is_empty() {
                c.actor = actor.to_string();
            }
            if !ip.is_empty() {
                c.ip = ip.to_string();
            }
            let updated = c.clone();
            inner.append(&updated);
            return updated;
        }
        let c = Command {
            id: id.clone(),
            node: node.to_string(),
            kind: KIND_CONFIG.to_string(),
            rev,
            op: String::new(),
            seq: 0,
            args: String::new(),
            state: STATE_PENDING.to_string(),
            ts: now_secs,
            actor: actor.to_string(),
            ip: ip.to_string(),
            attempts: 0,
            ack_at: 0,
            err: String::new(),
            next_at: Instant::now(),
        };
        inner.commands.insert(id, c.clone());
        inner.append(&c);
        c
    }

    /// Register an operational command. Always a NEW command: an operator
    /// asking for `pause` a second time means it a second time.
    pub fn issue_op(&self, node: &str, op: &str, args: &str, actor: &str, ip: &str) -> Command {
        let mut inner = self.inner.lock().unwrap();
        let seq = inner.seq.get(node).copied().unwrap_or(0) + 1;
        inner.seq.insert(node.to_string(), seq);
        let id = if self.salt.is_empty() {
            command_id_op(node, op, seq)
        } else {
            format!("{}-{}-{}-{}", node.replace(':', "-"), self.salt, op, seq)
        };
        let c = Command {
            id: id.clone(),
            node: node.to_string(),
            kind: KIND_OP.to_string(),
            rev: 0,
            op: op.to_string(),
            seq,
            args: args.to_string(),
            state: STATE_PENDING.to_string(),
            ts: unix_secs(),
            actor: actor.to_string(),
            ip: ip.to_string(),
            attempts: 0,
            ack_at: 0,
            err: String::new(),
            next_at: Instant::now(),
        };
        inner.commands.insert(c.id.clone(), c.clone());
        inner.append(&c);
        c
    }

    pub fn command(&self, id: &str) -> Option<Command> {
        self.inner.lock().unwrap().commands.get(id).cloned()
    }

    /// Newest first, with stable tie-breaking on id.
    pub fn commands(&self) -> Vec<Command> {
        let mut v: Vec<Command> = self
            .inner
            .lock()
            .unwrap()
            .commands
            .values()
            .cloned()
            .collect();
        v.sort_by(|a, b| b.ts.cmp(&a.ts).then_with(|| b.id.cmp(&a.id)));
        v
    }

    /// Every command for one node, newest first, with stable tie-breaking on id.
    pub fn for_node(&self, node: &str) -> Vec<Command> {
        let mut v: Vec<Command> = self
            .inner
            .lock()
            .unwrap()
            .commands
            .values()
            .filter(|c| c.node == node)
            .cloned()
            .collect();
        v.sort_by(|a, b| b.ts.cmp(&a.ts).then_with(|| b.id.cmp(&a.id)));
        v
    }

    /// Commands whose next retry is due, marking them as sent.
    ///
    /// Marking on the way out (rather than on the ACK) is what makes the
    /// ladder advance: a command that is never acknowledged walks 2 → 5 → 15 →
    /// 60 → unknown without needing anything else to happen.
    ///
    /// Every send is persisted to the journal (not only the `unknown`
    /// transition), because after a restart the hub must still know where on
    /// the ladder it was - otherwise a `closeall` that was about to be retried
    /// a third time would come back up as a first try and wait a full 2 s
    /// before resending. See `load`, which restores `attempts`.
    pub fn due(&self, now: Instant) -> Vec<Command> {
        let mut inner = self.inner.lock().unwrap();
        let ids: Vec<String> = inner.commands.keys().cloned().collect();
        let mut out = Vec::new();
        // Collected rather than appended inline: the loop below holds a
        // mutable borrow of `inner.commands`, and appending needs `inner`.
        let mut changed: Vec<Command> = Vec::new();
        for id in ids {
            let c = inner.commands.get_mut(&id).unwrap();
            if c.state != STATE_PENDING || now < c.next_at {
                continue;
            }
            let step = RETRY_LADDER_SECS.get(c.attempts as usize).copied();
            c.attempts += 1;
            match step {
                Some(secs) => {
                    c.next_at = now + Duration::from_secs(secs);
                    out.push(c.clone());
                    changed.push(c.clone());
                }
                None => {
                    // The ladder is exhausted. `unknown`, not `failed` - we do
                    // not know that it did not arrive, only that nobody said.
                    c.state = STATE_UNKNOWN.to_string();
                    c.err = format!(
                        "no ACK after {} attempts ({}s ladder exhausted)",
                        c.attempts,
                        RETRY_LADDER_SECS.len()
                    );
                    let snapshot = c.clone();
                    out.push(snapshot.clone());
                    changed.push(snapshot);
                }
            }
        }
        for c in &changed {
            inner.append(c);
        }
        out
    }

    /// Record an `ACK`. Returns false if there was no such command - which is
    /// worth reporting rather than ignoring: it means a node acknowledged
    /// something the hub has no record of sending.
    pub fn ack(&self, id: &str, ok: bool, rev: u64, err: &str) -> bool {
        let mut inner = self.inner.lock().unwrap();
        let updated = match inner.commands.get_mut(id) {
            None => return false,
            Some(c) => {
                c.state = if ok { STATE_ACKED } else { STATE_REJECTED }.to_string();
                c.ack_at = unix_secs();
                c.err = err.to_string();
                if ok && rev > 0 {
                    c.rev = rev;
                }
                c.clone()
            }
        };
        inner.append(&updated);
        true
    }
}

impl Inner {
    fn append(&mut self, c: &Command) {
        let line = json!({
            "v": 1,
            "id": c.id,
            "node": c.node,
            "kind": c.kind,
            "rev": c.rev,
            "op": c.op,
            "seq": c.seq,
            "args": c.args,
            "state": c.state,
            "ts": c.ts,
            "actor": c.actor,
            "ip": c.ip,
            "attempts": c.attempts,
            "ack_at": c.ack_at,
            "err": c.err,
        });
        let mut s = serde_json::to_string(&line).unwrap_or_else(|_| "{}".to_string());
        s.push('\n');
        if let Some(f) = self.file.as_mut() {
            // Same rule as the audit and the revisions: append, flush, never
            // seek. "What did we tell that node to do" must survive the
            // machine losing power.
            if let Err(e) = f.write_all(s.as_bytes()).and_then(|_| f.sync_data()) {
                eprintln!("[hub] COMMAND JOURNAL WRITE FAILED: {}", e);
                return;
            }
        }
    }
}

/// `CFG` identity: a function of `(node, rev)`. See the module docs.
pub fn command_id_cfg(node: &str, rev: u64) -> String {
    format!("{}R{}", node.replace(':', "-"), rev)
}

/// `CMD` identity: a function of `(node, op, seq)`. See the module docs for
/// what the sequence buys and what it does not.
pub fn command_id_op(node: &str, op: &str, seq: u64) -> String {
    format!("{}-{}-{}", node.replace(':', "-"), op, seq)
}

fn load(path: &Path) -> (HashMap<String, Command>, HashMap<String, u64>, u64) {
    let mut commands: HashMap<String, Command> = HashMap::new();
    let mut seq: HashMap<String, u64> = HashMap::new();
    let mut torn = 0u64;
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return (commands, seq, torn),
    };
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => {
                // A torn tail is a crash mid-append; the commands before it are
                // still true. Counted rather than hidden.
                torn += 1;
                continue;
            }
        };
        let id = v["id"].as_str().unwrap_or("");
        if id.is_empty() {
            continue;
        }
        let node = v["node"].as_str().unwrap_or("").to_string();
        let kind = v["kind"].as_str().unwrap_or(KIND_CONFIG).to_string();
        let seqn = v["seq"].as_u64().unwrap_or(0);
        if kind == KIND_OP {
            let e = seq.entry(node.clone()).or_insert(0);
            if seqn > *e {
                *e = seqn;
            }
        }
        // Last one wins, so the map ends up holding each command at its latest
        // state without a second record to keep in step.
        commands.insert(
            id.to_string(),
            Command {
                id: id.to_string(),
                node,
                kind,
                rev: v["rev"].as_u64().unwrap_or(0),
                op: v["op"].as_str().unwrap_or("").to_string(),
                seq: seqn,
                args: v["args"].as_str().unwrap_or("").to_string(),
                state: v["state"].as_str().unwrap_or(STATE_PENDING).to_string(),
                ts: v["ts"].as_u64().unwrap_or(0),
                actor: v["actor"].as_str().unwrap_or("").to_string(),
                ip: v["ip"].as_str().unwrap_or("").to_string(),
                attempts: v["attempts"].as_u64().unwrap_or(0) as u32,
                ack_at: v["ack_at"].as_u64().unwrap_or(0),
                err: v["err"].as_str().unwrap_or("").to_string(),
                // Runtime, and deliberately not restored: see the field docs.
                next_at: Instant::now(),
            },
        );
    }
    (commands, seq, torn)
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("copier_cmd_test_{}_{}", std::process::id(), name));
        let _ = std::fs::remove_file(&p);
        p
    }

    /// The property §5.4 rule 2 rests on: a retry, a re-send and a second
    /// caller registering the same revision are the SAME command.
    #[test]
    fn a_config_command_is_content_derived_so_a_resend_is_the_same_command() {
        assert_eq!(
            command_id_cfg("receiver:222222", 12),
            command_id_cfg("receiver:222222", 12)
        );
        assert_ne!(
            command_id_cfg("receiver:222222", 12),
            command_id_cfg("receiver:222222", 13)
        );
        assert_ne!(
            command_id_cfg("receiver:222222", 12),
            command_id_cfg("receiver:333333", 12)
        );

        let p = tmp("cfgid");
        let s = CommandStore::open(&p).unwrap();
        let a = s.issue_cfg("receiver:1", 5, "op", "");
        let b = s.issue_cfg("receiver:1", 5, "op", "");
        assert_eq!(a.id, b.id);
        assert_eq!(s.commands().len(), 1, "a resend minted a second command");
        let _ = std::fs::remove_file(&p);
    }

    /// The other half of the identity requirement, and the half a config gets
    /// for free: two DISTINCT operator intents must not collide. Pause,
    /// resume, pause is three commands, not one.
    #[test]
    fn two_distinct_operations_get_distinct_ids() {
        let p = tmp("opid");
        let s = CommandStore::open(&p).unwrap();
        let a = s.issue_op("receiver:1", "pause", "", "op", "");
        let b = s.issue_op("receiver:1", "resume", "", "op", "");
        let c = s.issue_op("receiver:1", "pause", "", "op", "");
        assert_ne!(a.id, b.id);
        assert_ne!(a.id, c.id, "the second pause collided with the first");
        assert_eq!(s.commands().len(), 3);
        // And the sequence continues across a reopen - reusing a number would
        // make a new command indistinguishable from an old one.
        drop(s);
        let s = CommandStore::open(&p).unwrap();
        let d = s.issue_op("receiver:1", "pause", "", "op", "");
        assert_ne!(d.id, c.id);
        assert_ne!(d.id, a.id);
        let _ = std::fs::remove_file(&p);
    }

    /// The ladder is finite on purpose: an unbounded retry against a node that
    /// is never coming back fills a queue and a log forever.
    #[test]
    fn the_retry_ladder_walks_and_then_gives_up_as_unknown() {
        let p = tmp("ladder");
        let s = CommandStore::open(&p).unwrap();
        s.issue_op("receiver:1", "pause", "", "op", "");

        let mut now = Instant::now();
        let mut sent = 0;
        let mut states = Vec::new();
        for _ in 0..12 {
            for cmd in s.due(now) {
                sent += 1;
                states.push(cmd.state.clone());
            }
            now += Duration::from_secs(120); // long enough for any rung
        }
        assert_eq!(
            sent,
            RETRY_LADDER_SECS.len() + 1,
            "expected one send per rung plus the giving-up"
        );
        assert_eq!(states.last().unwrap(), STATE_UNKNOWN);
        // And once unknown it is never sent again.
        let again = s.due(now + Duration::from_secs(600));
        assert!(again.is_empty(), "an unknown command kept being retried");
        let _ = std::fs::remove_file(&p);
    }

    /// The journal's whole reason for existing: a hub that restarts still
    /// knows what it told a node to do. Without this, a `closeall` issued just
    /// before a restart is indistinguishable from one never sent.
    #[test]
    fn a_pending_command_survives_a_restart_and_is_retried() {
        let p = tmp("restart");
        let id;
        {
            let s = CommandStore::open(&p).unwrap();
            let c = s.issue_op("receiver:1", "closeall", "", "op", "");
            id = c.id.clone();
            // It was sent twice and never answered before the hub went down.
            let now = Instant::now();
            s.due(now);
            s.due(now + Duration::from_secs(120));
        }
        let s = CommandStore::open(&p).unwrap();
        let c = s.command(&id).expect("the command was forgotten across a restart");
        assert_eq!(c.state, STATE_PENDING);
        assert_eq!(c.op, "closeall");
        assert_eq!(c.attempts, 2, "the ladder position was not restored");
        // And it is due immediately rather than waiting out an inherited rung.
        assert_eq!(s.due(Instant::now()).len(), 1, "a pending command did not resume");
        let _ = std::fs::remove_file(&p);
    }

    /// A state change is an APPEND, so the file holds the command's whole
    /// history and the load is last-wins. If an ACK rewrote the issue line,
    /// "issued, then acked" would be unreadable afterwards.
    #[test]
    fn a_state_change_appends_and_the_file_only_ever_grows() {
        let p = tmp("append");
        let s = CommandStore::open(&p).unwrap();
        let c = s.issue_op("receiver:1", "reload", "", "op", "");
        let issued = std::fs::read(&p).unwrap();
        assert!(s.ack(&c.id, true, 0, ""));
        let acked = std::fs::read(&p).unwrap();
        assert!(acked.starts_with(&issued), "history was rewritten");
        assert!(acked.len() > issued.len());

        // Both states are on disk, in order - the record is a log, not a slot.
        let text = String::from_utf8(acked).unwrap();
        let states: Vec<&str> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                if l.contains("\"acked\"") {
                    "acked"
                } else {
                    "pending"
                }
            })
            .collect();
        assert_eq!(states, vec!["pending", "acked"]);

        // And the reloaded view is the LATEST state, not the first.
        drop(s);
        let s = CommandStore::open(&p).unwrap();
        assert_eq!(s.command(&c.id).unwrap().state, STATE_ACKED);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn an_ack_moves_the_command_and_an_unknown_id_is_reported() {
        let p = tmp("ack");
        let s = CommandStore::open(&p).unwrap();
        let cmd = s.issue_cfg("receiver:1", 3, "op", "");
        assert!(s.ack(&cmd.id, true, 3, ""));
        assert_eq!(s.command(&cmd.id).unwrap().state, STATE_ACKED);
        assert!(
            !s.ack("no-such-command", true, 0, ""),
            "an unknown ACK must be reported, not silently accepted"
        );

        let cmd2 = s.issue_cfg("receiver:1", 4, "op", "");
        assert!(s.ack(&cmd2.id, false, 0, "magic overflow"));
        let got = s.command(&cmd2.id).unwrap();
        assert_eq!(got.state, STATE_REJECTED);
        assert_eq!(got.err, "magic overflow");
        let _ = std::fs::remove_file(&p);
    }

    /// The two kinds share one store and one ladder but stay distinguishable -
    /// the retry loop dispatches on `kind`, so a `CMD` must never be re-sent as
    /// a `CFG`.
    #[test]
    fn the_two_kinds_coexist_and_keep_their_own_payload() {
        let p = tmp("kinds");
        let s = CommandStore::open(&p).unwrap();
        let cfg = s.issue_cfg("receiver:1", 2, "op", "");
        let op = s.issue_op("receiver:1", "pause", "", "op", "");
        assert_eq!(cfg.kind, KIND_CONFIG);
        assert_eq!(op.kind, KIND_OP);
        assert_eq!(cfg.rev, 2);
        assert_eq!(cfg.op, "");
        assert_eq!(op.op, "pause");
        assert_eq!(op.rev, 0);

        let due = s.due(Instant::now());
        assert_eq!(due.len(), 2, "both kinds must be retried by one ladder");
        assert!(due.iter().any(|c| c.kind == KIND_CONFIG));
        assert!(due.iter().any(|c| c.kind == KIND_OP));

        assert_eq!(s.for_node("receiver:1").len(), 2);
        assert!(s.for_node("receiver:2").is_empty());
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn only_the_closed_set_of_operations_is_accepted() {
        for op in OPS {
            assert!(is_known_op(op), "{} should be known", op);
        }
        assert!(!is_known_op("paus"), "a typo must not be accepted");
        assert!(!is_known_op(""));
        assert!(!is_known_op("PAUSE"), "the set is case-sensitive, on purpose");
    }

    /// A torn tail is a crash mid-append. The commands before it are still
    /// true, so the store opens - and counts it rather than hiding it.
    #[test]
    fn a_torn_tail_does_not_lose_the_commands_before_it() {
        let p = tmp("torn");
        {
            let s = CommandStore::open(&p).unwrap();
            s.issue_op("receiver:1", "pause", "", "op", "");
        }
        {
            use std::io::Write as _;
            let mut f = OpenOptions::new().append(true).open(&p).unwrap();
            f.write_all(b"{\"v\":1,\"id\":\"half-a-li").unwrap();
        }
        let s = CommandStore::open(&p).unwrap();
        let (total, _, torn) = s.stats();
        assert_eq!(total, 1, "the good command was lost");
        assert_eq!(torn, 1, "the torn line was not counted");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn repushing_terminal_config_command_revives_it() {
        let p = tmp("repush");
        let s = CommandStore::open(&p).unwrap();
        let t0 = 1_700_000_000u64;
        let cmd = s.issue_cfg_at("receiver:1", 5, "op", "", t0);
        assert_eq!(cmd.state, STATE_PENDING);

        // Exhaust the retry ladder so it ends up unknown
        let mut now = Instant::now();
        for _ in 0..10 {
            let _ = s.due(now);
            now += Duration::from_secs(120);
        }
        assert_eq!(s.command(&cmd.id).unwrap().state, STATE_UNKNOWN);

        // Inside the cooldown the command stays finished: the comparison that
        // calls this runs every 5 s, and reviving on every heartbeat would turn
        // a node that keeps REJECTING a config into a permanent flood.
        let early = s.issue_cfg_at("receiver:1", 5, "op", "", t0 + 5);
        assert_eq!(early.state, STATE_UNKNOWN, "revived inside the cooldown");

        // After it, the re-push must revive the command to pending with 0
        // attempts and due immediately.
        let revived =
            s.issue_cfg_at("receiver:1", 5, "op", "", t0 + REVIVE_COOLDOWN_SECS + 1);
        assert_eq!(revived.state, STATE_PENDING);
        assert_eq!(revived.attempts, 0);

        let due = s.due(Instant::now());
        assert_eq!(due.len(), 1, "revived command must be due immediately");
        assert_eq!(due[0].id, cmd.id);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn disabled_commands_store_uses_salted_ids() {
        let s1 = CommandStore::disabled();
        let c1 = s1.issue_op("receiver:1", "pause", "", "op", "");
        assert!(c1.id.starts_with("receiver-1-"));
        assert!(c1.id.ends_with("-pause-1"));
        assert!(!s1.salt.is_empty());
    }

    #[test]
    fn commands_sorting_is_deterministic_on_same_timestamp() {
        let p = tmp("sort");
        let s = CommandStore::open(&p).unwrap();
        let _c1 = s.issue_op("receiver:1", "pause", "", "op", "");
        let _c2 = s.issue_op("receiver:1", "resume", "", "op", "");
        let list1 = s.commands();
        let list2 = s.commands();
        assert_eq!(list1.len(), 2);
        assert_eq!(list1[0].id, list2[0].id);
        assert_eq!(list1[1].id, list2[1].id);
        let _ = std::fs::remove_file(&p);
    }
}
