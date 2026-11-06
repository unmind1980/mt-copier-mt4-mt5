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

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use crate::lockx::LockExt;
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
pub const STATE_SUPERSEDED: &str = "superseded";

/// A config push. Sent as `CFG`; the ladder re-sends the stored revision.
pub const KIND_CONFIG: &str = "config";
/// An operational command. Sent as `CMD`; the ladder re-sends the same id.
pub const KIND_OP: &str = "op";

/// How long a FINISHED config command stays finished before `issue_cfg` will
/// revive it. See the note there: the comparison that calls it runs on every
/// heartbeat, so this is what separates "self-heal" from "flood".
pub const REVIVE_COOLDOWN_SECS: u64 = 60;

/// How long a TERMINAL command (acked / rejected / unknown) is kept.
///
/// The journal is append-only and the in-memory map was rebuilt from it in
/// full at every start, so without a retention window a hub that has been up
/// for a year holds every command it ever issued and re-parses all of them on
/// boot. 30 days is longer than anyone reads `/commands` back, and PENDING
/// commands are never dropped regardless of age.
pub const COMMAND_KEEP_SECS: u64 = 30 * 24 * 3600;

/// Compact the journal once it passes this size. Compaction rewrites the file
/// with ONE line per surviving command, so the append-only history of
/// transitions becomes a snapshot of current state - which is all `load()`
/// reconstructs anyway (last one wins).
pub const COMMAND_JOURNAL_COMPACT_BYTES: u64 = 8 * 1024 * 1024;

/// The operational commands, and the ONLY ones the hub will issue.
///
/// A closed set, checked at the door, because the hub cannot tell a typo from
/// a command: `POST {"op":"paus"}` that were accepted would sit on the ladder
/// for 82 seconds and then be reported as `unknown`, which reads like "the
/// node did not answer" rather than "you misspelled it".
pub const OPS: [&str; 7] = [
    "pause", "resume", "closeall", "close", "reload", "reqpos", "reqcfg",
];

fn state_rank(st: &str) -> u8 {
    match st {
        STATE_ACKED => 4,
        STATE_REJECTED => 3,
        STATE_UNKNOWN => 2,
        STATE_SUPERSEDED => 1,
        _ => 0, // STATE_PENDING
    }
}

impl Command {
    pub fn is_terminal(&self) -> bool {
        self.state == STATE_ACKED || self.state == STATE_REJECTED || self.state == STATE_UNKNOWN || self.state == STATE_SUPERSEDED
    }
}
pub fn is_known_op(op: &str) -> bool {
    OPS.contains(&op)
}

/// The commands that only ever ASK a node something, and are therefore safe to
/// dispatch when `--writes off`.
///
/// A set rather than the single `op == "reqpos"` comparison it replaced: the
/// second read-only op (`reqcfg`) is exactly what a hardcoded comparison
/// forgets, and forgetting it would silently stop the hub from ever pulling a
/// current config on a read-only hub - the node looks up to date forever and
/// the dashboard's Current Setting is stale with nothing to say so.
pub fn is_read_only_op(op: &str) -> bool {
    matches!(op, "reqpos" | "reqcfg")
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
    enabled: bool,
    /// id -> the command, at its LATEST state. Rebuilt last-wins from the
    /// file, so there is no separate "current state" record to fall out of
    /// step with the history.
    commands: HashMap<String, Command>,
    /// Fast set of commands currently pending retry ladder execution.
    in_flight: HashSet<String>,
    /// node -> highest op sequence ever issued. Also rebuilt from the file, so
    /// a restart does not hand out a number that was already used.
    seq: HashMap<String, u64>,
    /// Lines that would not parse. Not fatal: a torn tail is a crash, and the
    /// commands before it are still true.
    torn: u64,
    /// Total lines in commands journal (for fast sync status & zero-I/O diff checks)
    line_count: usize,
    /// Highest op sequence recorded globally
    max_seq: u64,
}

pub struct CommandStore {
    inner: Mutex<Inner>,
    path: PathBuf,
    enabled: bool,
    salt: String,
}

impl CommandStore {
    pub fn open(path: &Path) -> std::io::Result<CommandStore> {
        //--- Load BEFORE opening the append handle: the journal may be
        //--- compacted below, and rewriting a file that is open for append
        //--- would leave the handle writing into the old inode.
        let (mut commands, seq, torn, line_count, max_seq) = load(path)?;

        //--- Retention. A command is never deleted while it is pending - those
        //--- are the ones still owed an answer - but a terminal one (acked,
        //--- rejected, unknown) older than COMMAND_KEEP_SECS is history that
        //--- nothing reads. Without this the map only ever grows, and every
        //--- restart re-parses the whole journal.
        let now = unix_secs();
        let mut inner = Inner {
            file: None,
            enabled: true,
            commands: HashMap::new(),
            in_flight: HashSet::new(),
            seq,
            torn,
            line_count,
            max_seq,
        };
        inner.commands = std::mem::take(&mut commands);
        inner.prune_terminal(now, COMMAND_KEEP_SECS);

        //--- Compact the journal itself once it has grown past the threshold.
        //--- One line per SURVIVING command, so the file reflects the map the
        //--- process is about to run with rather than every transition it ever
        //--- recorded.
        if let Ok(md) = std::fs::metadata(path) {
            if md.len() > COMMAND_JOURNAL_COMPACT_BYTES {
                match compact_journal(path, &inner.commands) {
                    Ok(n) => {
                        println!(
                            "[hub] command journal compacted: {} -> {} command(s), {} bytes",
                            md.len(),
                            n,
                            std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
                        );
                        inner.line_count = n;
                    }
                    Err(e) => eprintln!("[hub] command journal compaction failed: {}", e),
                }
            }
        }

        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        inner.file = Some(file);
        let in_flight = inner
            .commands
            .iter()
            .filter(|(_, c)| c.state == STATE_PENDING)
            .map(|(k, _)| k.clone())
            .collect();
        inner.in_flight = in_flight;
        Ok(CommandStore {
            inner: Mutex::new(inner),
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
                enabled: false,
                commands: HashMap::new(),
                in_flight: HashSet::new(),
                seq: HashMap::new(),
                torn: 0,
                line_count: 0,
                max_seq: 0,
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

    /// Fast memory accessor for (total_lines, max_seq) in command journal for cluster sync (zero disk I/O).
    pub fn sync_stats(&self) -> (usize, u64) {
        // N87-03: If commands are disabled (--commands none), report (0, 0) for cluster sync
        if !self.enabled {
            return (0, 0);
        }
        let inner = self.inner.lock_or_recover();
        (inner.line_count, inner.max_seq)
    }

    /// Read lines from path starting from line index `from_line` without holding the inner lock.
    pub fn read_lines_from_path(path: &Path, from_line: usize) -> std::io::Result<(Vec<String>, usize, u64)> {
        use std::io::BufRead;
        if !path.exists() {
            return Ok((Vec::new(), 0, 0));
        }
        let file = std::fs::File::open(path)?;
        let reader = std::io::BufReader::new(file);
        let mut lines = Vec::new();
        let mut total = 0;
        let mut max_seq = 0u64;
        for line_res in reader.lines() {
            let line = line_res?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            // N87-01: Count only valid, parseable command lines, matching load()'s count & skipping torn/empty lines
            if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
                let id = v["id"].as_str().unwrap_or("");
                let node = v["node"].as_str().unwrap_or("");
                if !id.is_empty() && !node.is_empty() {
                    if let Some(s) = v["seq"].as_u64() {
                        max_seq = max_seq.max(s);
                    }
                    if total >= from_line {
                        lines.push(trimmed.to_string());
                    }
                    total += 1;
                }
            }
        }
        Ok((lines, total, max_seq))
    }

    /// Read lines starting from line index `from_line` for incremental replication.
    #[allow(dead_code)]
    pub fn read_lines_from(&self, from_line: usize) -> std::io::Result<(Vec<String>, usize, u64)> {
        if !self.enabled || !self.path.exists() {
            return Ok((Vec::new(), 0, 0));
        }
        let (total_lines, cur_max_seq) = self.sync_stats();
        if from_line >= total_lines {
            return Ok((Vec::new(), total_lines, cur_max_seq));
        }
        Self::read_lines_from_path(&self.path, from_line)
    }

    /// Apply delta command lines received from peer Primary Hub.
    pub fn apply_delta_lines(&self, raw_lines: &[String]) -> std::io::Result<usize> {
        if !self.enabled || raw_lines.is_empty() {
            return Ok(0);
        }
        let mut inner = self.inner.lock_or_recover();
        let mut applied = 0;
        //--- V1: every valid replicated line is mirrored to disk verbatim; only the
        //--- rows that ADVANCE state are applied to the in-memory map.
        let mut raw_valid: Vec<String> = Vec::new();
        let mut batch_max_seq = 0u64;
        let mut staged_commands: HashMap<String, Command> = HashMap::new();
        let mut staged_seq: HashMap<String, u64> = HashMap::new();

        for line in raw_lines {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                let id = v["id"].as_str().unwrap_or("").to_string();
                let node = v["node"].as_str().unwrap_or("").to_string();
                if id.is_empty() || node.is_empty() {
                    continue;
                }
                //--- same predicate load() uses, so both sides agree on "a line"
                raw_valid.push(line.clone());
                let seq = v["seq"].as_u64().unwrap_or(0);
                if seq > batch_max_seq {
                    batch_max_seq = seq;
                }
                if seq > 0 {
                    let cur_seq = staged_seq
                        .get(&node)
                        .copied()
                        .or_else(|| inner.seq.get(&node).copied())
                        .unwrap_or(0);
                    staged_seq.insert(node.clone(), cur_seq.max(seq));
                }
                let attempts = v["attempts"].as_u64().unwrap_or(0) as u32;
                let step = RETRY_LADDER_SECS
                    [(attempts as usize).min(RETRY_LADDER_SECS.len() - 1)];
                let cmd = Command {
                    id: id.clone(),
                    node: node.clone(),
                    kind: v["kind"].as_str().unwrap_or("").to_string(),
                    rev: v["rev"].as_u64().unwrap_or(0),
                    op: v["op"].as_str().unwrap_or("").to_string(),
                    seq,
                    args: v["args"].as_str().unwrap_or("").to_string(),
                    state: v["state"].as_str().unwrap_or(STATE_PENDING).to_string(),
                    ts: v["ts"].as_u64().unwrap_or(0),
                    actor: v["actor"].as_str().unwrap_or("").to_string(),
                    ip: v["ip"].as_str().unwrap_or("").to_string(),
                    attempts,
                    ack_at: v["ack_at"].as_u64().unwrap_or(0),
                    err: v["err"].as_str().unwrap_or("").to_string(),
                    next_at: Instant::now() + Duration::from_secs(step),
                };
                // N76-04 & N82-05 & N84-01: Evaluate time and attempt order.
                // Replicated lines with strictly newer ts (including revivals) take precedence.
                // For identical ts, higher state_rank wins; for identical ts and state, higher attempts
                // wins so retry lines are appended on Standby without dropping lines, but duplicate
                // identical retransmissions are ignored, preventing Standby journal inflation (N74-04).
                let should_insert = match staged_commands.get(&id).or_else(|| inner.commands.get(&id)) {
                    Some(existing) => {
                        if cmd.ts > existing.ts {
                            true
                        } else if cmd.ts == existing.ts {
                            let rank_new = state_rank(&cmd.state);
                            let rank_old = state_rank(&existing.state);
                            if rank_new > rank_old {
                                true
                            } else if rank_new == rank_old {
                                cmd.attempts > existing.attempts
                            } else {
                                false
                            }
                        } else {
                            false
                        }
                    }
                    None => true,
                };
                if should_insert {
                    staged_commands.insert(id, cmd);
                    applied += 1;
                }
            }
        }
        // F-01: Persist to journal file BEFORE modifying in-memory commands, in_flight, or seq.
        // If append fails, return Err(e) without altering memory state, allowing Standby to report sync_err.
        if !raw_valid.is_empty() {
            inner.append_raw(&raw_valid, batch_max_seq)?;
        }
        for (node, seq) in staged_seq {
            let cur = inner.seq.get(&node).copied().unwrap_or(0);
            inner.seq.insert(node, cur.max(seq));
        }
        for (id, cmd) in staged_commands {
            if cmd.state == STATE_PENDING {
                inner.in_flight.insert(id.clone());
            } else if cmd.is_terminal() {
                inner.in_flight.remove(&id);
            }
            inner.commands.insert(id, cmd);
        }
        //--- N57-11: bound what a standby holds in memory.
        //---
        //--- The primary prunes on every issue_* (COMMAND_KEEP_SECS retention),
        //--- but a standby only ever applies deltas - so without this its command
        //--- map grows for as long as it runs, and every /api/v1/commands clones
        //--- the whole table. replace_all already pruned; this path did not.
        inner.prune_terminal(unix_secs(), COMMAND_KEEP_SECS);
        Ok(applied)
    }

    /// Replace all commands in the store and journal with lines from Primary.
    /// Used when Primary performed compaction or local state is ahead of Primary's lines.
    pub fn replace_all(&self, lines: &[String]) -> std::io::Result<usize> {
        if !self.enabled {
            return Ok(0);
        }
        let tmp = format!("{}.tmp.{}", self.path.display(), std::process::id());
        {
            let mut f = File::create(&tmp)?;
            for l in lines {
                f.write_all(l.as_bytes())?;
                f.write_all(b"\n")?;
            }
            f.sync_all()?;
        }
        {
            let mut inner = self.inner.lock_or_recover();
            inner.file = None; // Drop file handle so Windows allows replacing the file
        }
        let replace_res = crate::cluster::atomic_replace_file(std::path::Path::new(&tmp), &self.path);
        // BUG-85-02 & A86-06: Ensure file handle is reopened and report error if reopen fails
        let file = OpenOptions::new().create(true).append(true).open(&self.path)?;
        {
            let mut inner = self.inner.lock_or_recover();
            inner.file = Some(file);
        }
        replace_res?;
        let (mut commands, seq, torn, line_count, max_seq) = load(&self.path)?;
        let now = unix_secs();
        let mut inner = self.inner.lock_or_recover();
        inner.commands = std::mem::take(&mut commands);
        inner.prune_terminal(now, COMMAND_KEEP_SECS);
        inner.seq = seq;
        inner.torn = torn;
        let pending_ids: Vec<String> = inner
            .commands
            .iter()
            .filter(|(_, c)| c.state == STATE_PENDING)
            .map(|(id, _)| id.clone())
            .collect();
        inner.in_flight.clear();
        for id in pending_ids {
            inner.in_flight.insert(id);
        }
        inner.line_count = line_count;
        inner.max_seq = max_seq;
        Ok(lines.len())
    }

    /// (total commands known, pending, torn lines)
    pub fn stats(&self) -> (usize, usize, u64) {
        let i = self.inner.lock_or_recover();
        //--- `in_flight` IS the pending set (it is populated from the journal at
        //--- load and kept in step by issue/ack/due), so this is O(1) instead of
        //--- walking every command ever issued.
        (i.commands.len(), i.in_flight.len(), i.torn)
    }

    /// Forget terminal commands older than `max_age_secs`.
    ///
    /// Called from the hub's periodic sweep. The journal FILE is not rewritten
    /// (that is `compact_journal`'s job at startup); this bounds what lives in
    /// memory, which is what `stats()`, `/commands` and the alert scan walk.
    pub fn prune(&self, now_secs: u64, max_age_secs: u64) -> usize {
        self.inner.lock_or_recover().prune_terminal(now_secs, max_age_secs)
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
        let mut inner = self.inner.lock_or_recover();

        // HUB-02: When issuing or reviving a config revision `rev`, mark all older
        // in-flight pending config commands for this node as superseded.
        let stale_ids: Vec<String> = inner
            .commands
            .values()
            .filter(|cmd| cmd.node == node && cmd.kind == KIND_CONFIG && cmd.rev < rev && cmd.state == STATE_PENDING)
            .map(|cmd| cmd.id.clone())
            .collect();
        let mut superseded_snaps = Vec::new();
        for sid in stale_ids {
            inner.in_flight.remove(&sid);
            if let Some(sc) = inner.commands.get_mut(&sid) {
                sc.state = STATE_SUPERSEDED.to_string();
                sc.err = format!("superseded by rev {}", rev);
                superseded_snaps.push(sc.clone());
            }
        }
        if !superseded_snaps.is_empty() {
            if let Err(e) = inner.append_many(&superseded_snaps) {
                eprintln!("[hub] COMMAND JOURNAL WRITE FAILED on batch supersede: {}", e);
            }
        }

        let mut revive_cmd: Option<Command> = None;
        if let Some(c) = inner.commands.get_mut(&id) {
            if c.state == STATE_PENDING {
                //--- H-01: Only operator-initiated re-issues should pull the retry clock
                //--- back to `now`. Automated comparison from REG/HBT2 passes an empty actor
                //--- and MUST NOT shorten the existing backoff ladder, otherwise ladder
                //--- attempts are exhausted prematurely in 15s instead of 82s.
                if !actor.is_empty() {
                    c.next_at = Instant::now();
                    if !ip.is_empty() {
                        c.ip = ip.to_string();
                    }
                }
                return c.clone();
            }
            let prev_last = c.ts.max(c.ack_at);
            if c.state == STATE_REJECTED {
                //--- H3: if the NODE rejected this revision, do not endlessly retry it.
                //--- But an operator asking again is a different thing entirely: the usual
                //--- cause is transient (a file lock while the EA was writing its ini), and
                //--- the id is `<node>R<rev>`, so "push the same revision again" was refused
                //--- forever unless the operator edited the config to mint a new revision.
                //--- Honour an explicit (non-empty actor) re-issue by reviving it.
                if actor.is_empty() {
                    return c.clone();
                }
            } else if c.state != STATE_PENDING {
                //--- A command that has ENDED - `unknown` after the ladder - is revived here,
                //--- because the whole point of this call is "this node needs this revision". A node
                //--- that restarts with a stale ini, or one that was simply offline for the whole ladder,
                //--- would otherwise be stuck on the old config forever.
                //---
                //--- BUT NOT ON EVERY HEARTBEAT. This is called from the REG/HBT2
                //--- comparison, which fires every 5 s - so an unconditional
                //--- revival turns a node that keeps REJECTING a bad config into a
                //--- push every 5 seconds, forever, with a log line each time.
                //--- The cooldown makes the self-heal a retry every minute instead:
                //--- fast enough to recover a node that came back, slow enough that
                //--- a refusal is not amplified into a flood.
                //--- H3: an explicit operator re-issue skips the cooldown - they can see
                //--- the node's state and are deliberately asking now.
                if actor.is_empty() && now_secs.saturating_sub(prev_last) < REVIVE_COOLDOWN_SECS {
                    return c.clone();
                }
            }
            c.state = STATE_PENDING.to_string();
            c.attempts = 0;
            c.ack_at = 0;
            c.err = String::new();
            //--- H3: strictly increasing timestamp. Reviving an ACKED/REJECTED command
            //--- inside the same second it was acked would produce `inc.ts == cur.ts`
            //--- with a LOWER state rank, and both `load()` and the standby's
            //--- `apply_delta_lines()` order by `(ts, rank, attempts)` - so the revival
            //--- row would be discarded and the command would stay terminal everywhere.
            c.ts = now_secs.max(prev_last.saturating_add(1));
            c.next_at = Instant::now();
            if !actor.is_empty() {
                c.actor = actor.to_string();
            }
            if !ip.is_empty() {
                c.ip = ip.to_string();
            }
            revive_cmd = Some(c.clone());
        }

        if let Some(updated) = revive_cmd {
            if !inner.append(&updated) {
                eprintln!("[hub] COMMAND JOURNAL WRITE FAILED on revive for {}", id);
                let mut failed = updated;
                failed.state = STATE_UNKNOWN.to_string();
                failed.err = "command journal write failed on revive".to_string();
                return failed;
            }
            inner.in_flight.insert(id);
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
        // N87-05: Defend against journal write failure symmetrically with issue_op
        if !inner.append(&c) {
            let mut failed = c;
            failed.state = STATE_UNKNOWN.to_string();
            failed.err = "command journal write failed - NOT queued".to_string();
            return failed;
        }
        inner.in_flight.insert(id.clone());
        inner.commands.insert(id, c.clone());
        c
    }

    /// Register an operational command. Always a NEW command: an operator
    /// asking for `pause` a second time means it a second time.
    pub fn issue_op(&self, node: &str, op: &str, args: &str, actor: &str, ip: &str) -> Command {
        let mut inner = self.inner.lock_or_recover();
        let seq = inner.seq.get(node).copied().unwrap_or(0) + 1;
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
        //--- N56-12: persist FIRST, advance the sequence SECOND.
        //---
        //--- The old order consumed `seq` in memory before writing, and `append`
        //--- swallowed write failures. A failed write therefore left the id
        //--- consumed in memory but absent from the journal: after a restart the
        //--- next command of the same op got the SAME id, and the node - which
        //--- deduplicates by id - replayed the old ACK instead of executing the
        //--- new order. A risk close that "succeeded" in the audit log and never
        //--- ran. Returning a failed Command instead of a 202 is the honest
        //--- answer: nothing was queued.
        if !inner.append(&c) {
            let mut failed = c;
            failed.state = STATE_UNKNOWN.to_string();
            failed.err = "command journal write failed - NOT queued".to_string();
            return failed;
        }
        inner.seq.insert(node.to_string(), seq);
        inner.in_flight.insert(c.id.clone());
        inner.commands.insert(c.id.clone(), c.clone());
        c
    }

    pub fn command(&self, id: &str) -> Option<Command> {
        self.inner.lock_or_recover().commands.get(id).cloned()
    }

    /// Newest first, with stable tie-breaking on id.
    #[allow(dead_code)]
    pub fn commands(&self) -> Vec<Command> {
        self.commands_recent(usize::MAX)
    }

    /// Newest first up to `limit` entries, with stable tie-breaking on id.
    /// Fast-path returns empty Vec when limit is 0 without grabbing locks or cloning.
    pub fn commands_recent(&self, limit: usize) -> Vec<Command> {
        if limit == 0 {
            return Vec::new();
        }
        let inner = self.inner.lock_or_recover();
        let mut v: Vec<Command> = inner.commands.values().cloned().collect();
        drop(inner);
        v.sort_by(|a, b| b.ts.cmp(&a.ts).then_with(|| b.id.cmp(&a.id)));
        if v.len() > limit {
            v.truncate(limit);
        }
        v
    }

    /// Every command for one node, newest first, with stable tie-breaking on id.
    pub fn for_node(&self, node: &str) -> Vec<Command> {
        let mut v: Vec<Command> = self
            .inner
            .lock_or_recover()
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
    #[allow(dead_code)]
    pub fn due(&self, now: Instant) -> Vec<Command> {
        self.due_gated_with(now, true, |_| true)
    }

    /// N73-01 & N74-01: Takes reachability predicate closure that does not acquire SharedState lock.
    /// This guarantees due_gated never calls back into SharedState under inner lock.
    pub fn due_gated<F>(&self, now: Instant, writes_enabled: bool, is_reachable: F) -> Vec<Command>
    where
        F: Fn(&str) -> bool,
    {
        self.due_gated_with(now, writes_enabled, is_reachable)
    }

    fn due_gated_with<F>(&self, now: Instant, writes_enabled: bool, is_reachable: F) -> Vec<Command>
    where
        F: Fn(&str) -> bool,
    {
        let mut inner = self.inner.lock_or_recover();
        let ids: Vec<String> = inner.in_flight.iter().cloned().collect();
        let mut out = Vec::new();
        // Collected rather than appended inline: the loop below holds a
        // mutable borrow of `inner.commands`, and appending needs `inner`.
        let mut changed: Vec<Command> = Vec::new();
        let mut finished: Vec<String> = Vec::new();
        for id in ids {
            let c = match inner.commands.get_mut(&id) {
                Some(cmd) => cmd,
                None => {
                    finished.push(id);
                    continue;
                }
            };
            if c.state != STATE_PENDING {
                finished.push(id);
                continue;
            }
            if !writes_enabled && !is_read_only_op(&c.op) {
                // When writes are disabled, do not consume retry ladder for write commands;
                // keep them frozen in pending state until restarted with writes on.
                continue;
            }
            if now < c.next_at {
                continue;
            }
            // HUB-02, R60-06 & N72-02: Check reachability BEFORE incrementing attempts or consuming ladder.
            // If node is currently disconnected/offline, defer next check by 2 seconds without burning retry steps.
            if !is_reachable(&c.node) {
                // N76-05 & N78-01: Absolute timeout for persistently unreachable nodes (1800s / 30 mins)
                // Prevents infinite pending accumulation and enables command.unknown alert for dead nodes.
                let now_secs = unix_secs();
                if now_secs.saturating_sub(c.ts) >= 1800 {
                    c.state = STATE_UNKNOWN.to_string();
                    c.ts = now_secs; // N78-01: stamp transition time so recent_unknown does not drop it as stale
                    c.err = "node unreachable for 30m (abandoned after timeout)".to_string();
                    let snapshot = c.clone();
                    out.push(snapshot.clone());
                    changed.push(snapshot);
                    finished.push(id);
                    continue;
                }
                c.next_at = now + Duration::from_secs(2);
                continue;
            }
            let step = RETRY_LADDER_SECS.get(c.attempts as usize).copied();
            match step {
                Some(secs) => {
                    c.attempts += 1;
                    c.next_at = now + Duration::from_secs(secs);
                    out.push(c.clone());
                    changed.push(c.clone());
                }
                None => {
                    // The ladder is exhausted. `unknown`, not `failed` - we do
                    // not know that it did not arrive, only that nobody said.
                    c.state = STATE_UNKNOWN.to_string();
                    c.ts = unix_secs(); // N82-01 & N82-02: Stamp transition time so recent_unknown does not drop it and revive cooldown starts afresh
                    let total_secs: u64 = RETRY_LADDER_SECS.iter().sum();
                    c.err = format!(
                        "no ACK after {} attempts ({}s ladder exhausted)",
                        c.attempts,
                        total_secs
                    );
                    let snapshot = c.clone();
                    out.push(snapshot.clone());
                    changed.push(snapshot);
                    finished.push(id);
                }
            }
        }
        for f in finished {
            inner.in_flight.remove(&f);
        }
        //--- ONE fsync for the whole batch instead of one per command
        if let Err(e) = inner.append_many(&changed) {
            eprintln!("[hub] COMMAND JOURNAL WRITE FAILED in due_gated: {}", e);
        }
        out
    }

    /// Record an `ACK`. Returns false if there was no such command - which is
    /// worth reporting rather than ignoring: it means a node acknowledged
    /// something the hub has no record of sending.
    pub fn ack(&self, id: &str, ok: bool, rev: u64, err: &str) -> bool {
        let mut inner = self.inner.lock_or_recover();
        inner.in_flight.remove(id);
        let updated = match inner.commands.get_mut(id) {
            None => return false,
            Some(c) => {
                //--- R59-04: a terminal command normally ignores further ACKs, but
                //--- REJECTED -> ACKED must be allowed through.
                //---
                //--- closeall reports OK=0/queue_full immediately when its queue is
                //--- full, then retries in the background and sends OK=1 once the
                //--- remainder is closed. That late ACK is the true outcome, and the
                //--- blanket "already terminal, ignore" dropped it - so the
                //--- dashboard and the audit trail said `rejected` forever while
                //--- every position had in fact been closed.
                //---
                //--- The rank check keeps the other directions closed: ACKED ->
                //--- REJECTED (4 -> 3) and duplicate ACKED (4 -> 4) still return
                //--- false, so a retried or replayed frame cannot downgrade a
                //--- command that genuinely succeeded.
                let new_state = if ok { STATE_ACKED } else { STATE_REJECTED };
                if c.is_terminal() && state_rank(new_state) <= state_rank(&c.state) {
                    return false;
                }
                c.state = new_state.to_string();
                c.ack_at = unix_secs();
                c.err = err.to_string();
                if ok && rev > 0 {
                    c.rev = rev;
                }
                c.clone()
            }
        };
        if !inner.append(&updated) {
            eprintln!("[hub] COMMAND JOURNAL WRITE FAILED on ACK for {}", id);
        }
        true
    }

    /// Retrieve recent unknown commands without cloning and sorting the entire history.
    pub fn recent_unknown(&self, max_age_secs: u64, now: u64) -> Vec<Command> {
        let inner = self.inner.lock_or_recover();
        inner
            .commands
            .values()
            .filter(|c| c.state == STATE_UNKNOWN && now.saturating_sub(c.ts) <= max_age_secs)
            .cloned()
            .collect()
    }

    /// Mark an in-flight command as superseded by a newer revision, removing from in_flight.
    pub fn supersede(&self, id: &str, current_rev: u64) {
        let mut inner = self.inner.lock_or_recover();
        inner.in_flight.remove(id);
        if let Some(c) = inner.commands.get_mut(id) {
            if c.state == STATE_PENDING {
                c.state = STATE_SUPERSEDED.to_string();
                c.err = format!("superseded by rev {}", current_rev);
                let snap = c.clone();
                if !inner.append(&snap) {
                    eprintln!("[hub] COMMAND JOURNAL WRITE FAILED on supersede for {}", id);
                }
            }
        }
    }
}

impl Inner {
    fn append(&mut self, c: &Command) -> bool {
        self.append_many(std::slice::from_ref(c)).is_ok()
    }

    /// Append one or more state transitions, then fsync ONCE.
    ///
    /// `sync_data()` per line was the problem: the retry ladder writes a line
    /// for every attempt, and `due()` writes for every command that becomes due
    /// in the same pass - so ten due commands meant ten serial fsyncs on the
    /// hub's main thread, which is also the thread forwarding OPEN/CLOSE. The
    /// durability contract is unchanged (everything written is flushed before
    /// the call returns); only the number of flushes changed.
    ///
    /// N56-12 & F-01: returns Result to ensure callers propagate write failures
    /// and do not commit in-memory state when disk writes fail.
    fn append_many(&mut self, cs: &[Command]) -> io::Result<()> {
        let f = match self.file.as_mut() {
            Some(f) => f,
            None => {
                // A86-05: If store is intentionally disabled (memory-only mode), append is a no-op that updates memory counters.
                if !self.enabled {
                    self.line_count += cs.len();
                    for c in cs {
                        self.max_seq = self.max_seq.max(c.seq);
                    }
                    return Ok(());
                }
                // When enabled but file handle is unexpectedly None, fail-closed
                return Err(io::Error::new(io::ErrorKind::NotConnected, "command journal file handle is not open"));
            }
        };
        let mut buf = String::new();
        self.line_count += cs.len();
        for c in cs {
            self.max_seq = self.max_seq.max(c.seq);
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
            buf.push_str(&serde_json::to_string(&line).unwrap_or_else(|_| "{}".to_string()));
            buf.push('\n');
        }
        if buf.is_empty() {
            return Ok(());
        }
        // Same rule as the audit and the revisions: append, flush, never seek.
        // "What did we tell that node to do" must survive the machine losing
        // power - so the fsync is still there, just not once per line.
        match f.write_all(buf.as_bytes()).and_then(|_| f.sync_data()) {
            Ok(()) => Ok(()),
            Err(e) => {
                eprintln!("[hub] COMMAND JOURNAL WRITE FAILED: {}", e);
                // Keep the in-memory line counter honest: the lines did not land.
                self.line_count -= cs.len();
                Err(e)
            }
        }
    }

    /// V1/C1: append replicated lines VERBATIM.
    ///
    /// The standby used to append only the rows that ADVANCED in-memory state,
    /// and to append them RE-SERIALISED. Both halves were wrong:
    ///  * filtering made the standby's physical line count permanently lower than
    ///    the primary's (load() counts every valid line), which is what produced
    ///    the 1Hz "I am behind" resync loop and the full replace_all behind it;
    ///  * re-serialising meant any field the running build did not model was
    ///    dropped, so after a role swap the promoted node's journal was not a
    ///    faithful copy of the primary's.
    /// Physical replication and state application are now separate: every valid
    /// line lands on disk, while `should_insert` still decides what the in-memory
    /// map believes.
    fn append_raw(&mut self, lines: &[String], max_seq_seen: u64) -> io::Result<()> {
        if lines.is_empty() {
            return Ok(());
        }
        let f = match self.file.as_mut() {
            Some(f) => f,
            None => {
                if !self.enabled {
                    self.line_count += lines.len();
                    self.max_seq = self.max_seq.max(max_seq_seen);
                    return Ok(());
                }
                return Err(io::Error::new(io::ErrorKind::NotConnected, "command journal file handle is not open"));
            }
        };
        let mut buf = String::new();
        let mut written = 0usize;
        for l in lines {
            let t = l.trim_end_matches(['\r', '\n']);
            if t.is_empty() {
                continue;
            }
            buf.push_str(t);
            buf.push('\n');
            written += 1;
        }
        if written == 0 {
            return Ok(());
        }
        self.line_count += written;
        self.max_seq = self.max_seq.max(max_seq_seen);
        match f.write_all(buf.as_bytes()).and_then(|_| f.sync_data()) {
            Ok(()) => Ok(()),
            Err(e) => {
                eprintln!("[hub] COMMAND JOURNAL RAW WRITE FAILED: {}", e);
                self.line_count -= written;
                Err(e)
            }
        }
    }

    /// Drop terminal commands older than `max_age_secs`, and forget the
    /// sequence numbers of nodes that no longer have any command.
    ///
    /// The map is rebuilt from the journal at startup and never otherwise
    /// shrinks, so a hub that runs for months ends up holding every command it
    /// ever issued - and `stats()` walks all of them. PENDING commands are
    /// never dropped: they are the ones still owed an answer.
    fn prune_terminal(&mut self, now_secs: u64, max_age_secs: u64) -> usize {
        //--- H2: never prune away the highest-seq command of a node.
        //--- `load()` rebuilds each node's `seq` (and the global `max_seq`) from
        //--- the rows in the journal. Dropping every row a quiet node ever wrote
        //--- therefore reset that node's sequence to 0 on the NEXT restart, and
        //--- the ids it then minted (`<node>-<op>-1`, `-2`, ...) collided with ids
        //--- the EA still remembered in its dedup ring - so brand-new commands were
        //--- silently discarded as duplicates - while the cluster heartbeat saw
        //--- `max_cmd_seq` go BACKWARDS.
        //--- Keeping exactly one watermark row per node costs a line and makes the
        //--- sequence monotonic across restarts and across compact_journal().
        let mut watermark: HashMap<String, (String, u64)> = HashMap::new();
        for (id, c) in self.commands.iter() {
            let seqt = c.seq;
            match watermark.get(&c.node) {
                Some((_, best)) if *best >= seqt => {}
                _ => {
                    watermark.insert(c.node.clone(), (id.clone(), seqt));
                }
            }
        }
        let keep_ids: std::collections::HashSet<String> =
            watermark.values().map(|(id, _)| id.clone()).collect();

        let before = self.commands.len();
        let now = now_secs;
        self.commands.retain(|id, c| {
            if c.state == STATE_PENDING {
                return true;
            }
            if keep_ids.contains(id) {
                return true;
            }
            now.saturating_sub(c.ts) <= max_age_secs
        });
        self.in_flight.retain(|id| self.commands.contains_key(id));
        // Note: Do NOT prune self.seq - the per-node sequence counter must remain monotonic
        // across terminal command aging so newly minted command IDs never collide with
        // an ID the node still remembers, preventing false deduplication idempotency drops.
        before - self.commands.len()
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

/// Rewrite the journal as one line per live command.
///
/// Write-then-rename, so a crash mid-rewrite leaves the original intact. `load`
/// keeps the LAST line for an id, so a snapshot file and a full history are
/// equivalent inputs - only the size differs.
fn compact_journal(path: &Path, commands: &HashMap<String, Command>) -> std::io::Result<usize> {
    let tmp = path.with_extension("jsonl.compact");
    {
        let mut f = std::fs::File::create(&tmp)?;
        let mut buf = String::new();
        for c in commands.values() {
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
            buf.push_str(&serde_json::to_string(&line).unwrap_or_else(|_| "{}".to_string()));
            buf.push('\n');
        }
        f.write_all(buf.as_bytes())?;
        f.sync_data()?;
    }
    //--- std::fs::rename replaces on Windows (MoveFileEx with REPLACE_EXISTING)
    //--- and on POSIX, so the swap is atomic on both.
    std::fs::rename(&tmp, path)?;
    Ok(commands.len())
}

fn load(path: &Path) -> io::Result<(HashMap<String, Command>, HashMap<String, u64>, u64, usize, u64)> {
    let mut commands: HashMap<String, Command> = HashMap::new();
    let mut seq: HashMap<String, u64> = HashMap::new();
    let mut torn = 0u64;
    let mut line_count = 0usize;
    let mut max_seq = 0u64;
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        // A86-06: Propagate read/permission errors; only treat NotFound as clean empty journal
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok((commands, seq, torn, line_count, max_seq)),
        Err(e) => return Err(e),
    };
    let text = String::from_utf8_lossy(&bytes);
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
        let node = v["node"].as_str().unwrap_or("").to_string();
        if id.is_empty() || node.is_empty() {
            continue;
        }
        // N87-01: Count only valid, parseable command lines, matching read_lines_from_path and apply_delta_lines
        line_count += 1;
        let kind = v["kind"].as_str().unwrap_or(KIND_CONFIG).to_string();
        let seqn = v["seq"].as_u64().unwrap_or(0);
        max_seq = max_seq.max(seqn);
        if kind == KIND_OP {
            let e = seq.entry(node.clone()).or_insert(0);
            if seqn > *e {
                *e = seqn;
            }
        }
        let cmd = Command {
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
            next_at: Instant::now(),
        };
        // P0-03, R60-04, N76-04, N82-05, N84-01 & N87-08: Replicated lines with strictly newer ts take precedence.
        // For identical ts, higher state_rank wins; for identical ts and state, strictly higher attempts wins,
        // matching apply_delta_lines symmetrically.
        let should_insert = match commands.get(id) {
            Some(existing) => {
                if cmd.ts > existing.ts {
                    true
                } else if cmd.ts == existing.ts {
                    let rank_new = state_rank(&cmd.state);
                    let rank_old = state_rank(&existing.state);
                    if rank_new > rank_old {
                        true
                    } else if rank_new == rank_old {
                        cmd.attempts > existing.attempts
                    } else {
                        false
                    }
                } else {
                    false
                }
            }
            None => true,
        };
        if should_insert {
            commands.insert(id.to_string(), cmd);
        }
    }
    Ok((commands, seq, torn, line_count, max_seq))
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
        let finished_cmd = s.command(&cmd.id).unwrap();
        assert_eq!(finished_cmd.state, STATE_UNKNOWN);
        let t_done = finished_cmd.ts;

        // Inside the cooldown an AUTOMATED comparison (empty actor) leaves the
        // command finished: that comparison runs every 5 s, and reviving on every
        // heartbeat would turn a node that keeps REJECTING a config into a
        // permanent flood.
        let early = s.issue_cfg_at("receiver:1", 5, "", "", t_done + 5);
        assert_eq!(early.state, STATE_UNKNOWN, "revived inside the cooldown");

        // An explicit operator re-issue is a different thing: the usual cause of
        // a rejection is transient (a file lock), and the id is <node>R<rev>, so
        // refusing the same revision forever left no way to retry it at all.
        let manual = s.issue_cfg_at("receiver:1", 5, "op", "", t_done + 5);
        assert_eq!(manual.state, STATE_PENDING, "operator re-issue must revive");

        // After it, the re-push must revive the command to pending with 0
        // attempts and due immediately.
        let revived =
            s.issue_cfg_at("receiver:1", 5, "op", "", t_done + REVIVE_COOLDOWN_SECS + 1);
        assert_eq!(revived.state, STATE_PENDING);
        assert_eq!(revived.attempts, 0);

        let due = s.due(Instant::now());
        assert_eq!(due.len(), 1, "revived command must be due immediately");
        assert_eq!(due[0].id, cmd.id);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn automated_heartbeat_comparison_does_not_reset_pending_retry_ladder() {
        let p = tmp("ladder_reset");
        let s = CommandStore::open(&p).unwrap();
        let t0 = 1_700_000_000u64;
        let cmd = s.issue_cfg_at("receiver:1", 5, "admin", "", t0);
        assert_eq!(cmd.state, STATE_PENDING);

        let t_start = Instant::now();
        // First due pass: consumes initial attempt, sets next_at = t_start + 2s
        let due1 = s.due(t_start);
        assert_eq!(due1.len(), 1);
        assert_eq!(due1[0].attempts, 1);

        // At t_start + 1s (before 2s retry ladder fires), REG/HBT2 automated comparison
        // calls issue_cfg with an empty actor.
        let re_called = s.issue_cfg_at("receiver:1", 5, "", "", t0 + 1);
        assert_eq!(re_called.state, STATE_PENDING);

        // At t_start + 1s, the retry ladder must NOT have been pulled back to `now`.
        let due_early = s.due(t_start + Duration::from_secs(1));
        assert_eq!(due_early.len(), 0, "automated re-issue must not reset ladder backoff");

        // At t_start + 2s, the ladder naturally expires and is due.
        let due_natural = s.due(t_start + Duration::from_secs(2));
        assert_eq!(due_natural.len(), 1, "natural ladder expiry must fire");
        assert_eq!(due_natural[0].attempts, 2);

        // However, an explicit operator re-issue with a non-empty actor DOES pull it back to now.
        let op_re_called = s.issue_cfg_at("receiver:1", 5, "operator_user", "", t0 + 3);
        assert_eq!(op_re_called.state, STATE_PENDING);
        let due_op = s.due(t_start + Duration::from_secs(2));
        assert_eq!(due_op.len(), 1, "operator explicit re-issue should be due immediately");

        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn disabled_commands_store_uses_salted_ids() {
        let s1 = CommandStore::disabled();
        let c1 = s1.issue_op("receiver:1", "pause", "", "op", "");
        assert!(c1.id.starts_with("receiver-1-"));
        assert!(c1.id.ends_with("-pause-1"));
        assert!(!s1.salt.is_empty());
        // A86-05: disabled store should correctly track state in memory rather than failing with 500
        assert_eq!(c1.state, STATE_PENDING);
        assert!(c1.err.is_empty());
        assert_eq!(s1.stats().1, 1);
        assert!(s1.command(&c1.id).is_some());
        assert!(s1.ack(&c1.id, true, 0, ""));
        assert_eq!(s1.stats().1, 0);
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

    /// Retention: a terminal command ages out, a PENDING one never does.
    ///
    /// The map used to be rebuilt from the journal at every start and never
    /// shrunk, so a hub up for a year held every command it ever issued - and
    /// `stats()` walked all of them.
    #[test]
    fn terminal_commands_age_out_but_pending_ones_never_do() {
        let p = tmp("prune");
        let s = CommandStore::open(&p).unwrap();
        // One command that will be ACKed (terminal) and one left pending.
        let done = s.issue_op("receiver:1", "pause", "", "op", "");
        let _open = s.issue_op("receiver:1", "resume", "", "op", "");
        assert!(s.ack(&done.id, true, 0, ""));

        // Age everything by a year.
        let far = unix_secs() + 365 * 24 * 3600;
        let dropped = s.prune(far, COMMAND_KEEP_SECS);
        assert_eq!(dropped, 1, "the acked command should have aged out");

        let left = s.commands();
        assert_eq!(left.len(), 1, "the pending command must survive");
        assert_eq!(left[0].state, STATE_PENDING);
        let _ = std::fs::remove_file(&p);
    }

    /// A big journal is rewritten as one line per live command, and `load`
    /// still reconstructs the same map from it.
    #[test]
    fn a_compacted_journal_reloads_to_the_same_state() {
        let p = tmp("compact");
        {
            let s = CommandStore::open(&p).unwrap();
            for _ in 0..5 {
                let c = s.issue_op("receiver:1", "pause", "", "op", "");
                s.ack(&c.id, true, 0, "");
            }
            let _ = s.issue_op("receiver:1", "resume", "", "op", "");
        }
        let before = std::fs::read_to_string(&p).unwrap();
        assert!(before.lines().count() > 6, "expected one line per transition");

        // F-17: Explicitly invoke compact_journal to test compaction
        // Drop CommandStore first so the open file handle is closed on Windows
        let commands = {
            let s = CommandStore::open(&p).unwrap();
            let inner = s.inner.lock().unwrap();
            inner.commands.clone()
        };
        compact_journal(&p, &commands).unwrap();
        let after = std::fs::read_to_string(&p).unwrap();
        assert_eq!(after.lines().count(), 6, "compacted journal must have 1 line per surviving command");

        let s = CommandStore::open(&p).unwrap();
        let (total, pending, _) = s.stats();
        assert_eq!(total, 6);
        assert_eq!(pending, 1);
        let _ = std::fs::remove_file(&p);
    }

    /// N82-01: Exhausting the retry ladder stamps c.ts with the transition time
    /// so recent_unknown does not drop it as stale even if the command was pending for long.
    #[test]
    fn test_ladder_exhaustion_stamps_transition_time_for_recent_unknown() {
        let p = tmp("ladder_ts");
        let s = CommandStore::open(&p).unwrap();
        let c = s.issue_op("receiver:1", "closeall", "", "op", "");
        // Artificially age the original creation timestamp to 5000 seconds ago
        {
            let mut inner = s.inner.lock().unwrap();
            if let Some(cmd) = inner.commands.get_mut(&c.id) {
                cmd.ts = unix_secs().saturating_sub(5000);
            }
        }
        let mut now = Instant::now();
        for _ in 0..10 {
            s.due(now);
            now += Duration::from_secs(120);
        }
        let updated = s.command(&c.id).unwrap();
        assert_eq!(updated.state, STATE_UNKNOWN);
        // The transition timestamp must have been refreshed to current time (within 10s)
        let now_s = unix_secs();
        assert!(now_s.saturating_sub(updated.ts) <= 10, "transition time must be refreshed upon ladder exhaustion");
        // recent_unknown(3600) must pick it up!
        let unknowns = s.recent_unknown(3600, now_s);
        assert_eq!(unknowns.len(), 1);
        assert_eq!(unknowns[0].id, c.id);
        let _ = std::fs::remove_file(&p);
    }

    /// N84-01: Verify that retry delta lines with same ts and same state (pending) but increasing attempts
    /// are accepted and appended on Standby, while exact duplicate transmissions are ignored.
    #[test]
    fn test_retry_delta_replication_accepts_later_attempts_and_rejects_duplicates() {
        let p = tmp("delta_retry");
        let s = CommandStore::open(&p).unwrap();
        let ts = 1700000000;
        let line0 = serde_json::json!({
            "id": "cmd-test-1",
            "node": "receiver:1",
            "seq": 1,
            "op": "pause",
            "args": "",
            "actor": "op",
            "note": "",
            "state": "pending",
            "attempts": 0,
            "ts": ts,
            "err": "",
            "step": 0
        }).to_string();

        let line1 = serde_json::json!({
            "id": "cmd-test-1",
            "node": "receiver:1",
            "seq": 1,
            "op": "pause",
            "args": "",
            "actor": "op",
            "note": "",
            "state": "pending",
            "attempts": 1,
            "ts": ts,
            "err": "",
            "step": 2
        }).to_string();

        // Step 1: Initial pending line is applied
        let applied = s.apply_delta_lines(&[line0.clone()]).unwrap();
        assert_eq!(applied, 1);
        assert_eq!(s.command("cmd-test-1").unwrap().attempts, 0);

        // Step 2: Retry line with attempts=1 (same ts, same state) MUST be accepted (N84-01)
        let applied_retry = s.apply_delta_lines(&[line1.clone()]).unwrap();
        assert_eq!(applied_retry, 1, "retry line with higher attempts must be applied");
        assert_eq!(s.command("cmd-test-1").unwrap().attempts, 1);

        // Step 3: Exact duplicate of line1 must be rejected to prevent inflation
        let applied_dup = s.apply_delta_lines(&[line1]).unwrap();
        assert_eq!(applied_dup, 0, "duplicate identical retry line must not be applied");

        // V1: ...but it must still be MIRRORED to disk. Filtering it out of the
        // physical journal is what made the standby's line count drift below the
        // primary's and drove the 1Hz resync loop.
        let (lines, _seq) = s.sync_stats();
        assert_eq!(lines, 3, "every valid replicated line must be mirrored, applied or not");

        let _ = std::fs::remove_file(&p);
    }

    /// V1 regression lock: the standby's physical journal must contain exactly the
    /// lines the primary sent, byte for byte, including rows the state machine
    /// considers stale. Anything else re-opens the "line count never converges"
    /// loop that forces a full replace_all every second.
    #[test]
    fn replicated_lines_are_mirrored_verbatim_even_when_state_rejects_them() {
        let p = tmp("delta_mirror");
        let s = CommandStore::open(&p).unwrap();
        let ts = 1700000500;
        let mk = |attempts: u32, extra: &str| {
            serde_json::json!({
                "id": "cmd-mirror-1",
                "node": "receiver:2",
                "seq": 7,
                "op": "pause",
                "args": "",
                "actor": "op",
                "state": "pending",
                "attempts": attempts,
                "ts": ts,
                "err": "",
                // a field this build does not model - it must survive verbatim
                "future_field": extra,
            })
            .to_string()
        };
        let a = mk(1, "alpha");
        let b = mk(0, "beta"); // lower attempts -> state rejects it

        let applied = s.apply_delta_lines(&[a.clone(), b.clone()]).unwrap();
        assert_eq!(applied, 1, "only the advancing row changes state");

        let (lines, max_seq) = s.sync_stats();
        assert_eq!(lines, 2, "both lines must be on disk");
        assert_eq!(max_seq, 7);

        // the on-disk journal is the primary's bytes, not a re-serialisation
        let body = std::fs::read_to_string(&p).unwrap();
        assert!(body.contains("future_field"), "unmodelled fields must be preserved verbatim");
        assert!(body.contains("alpha"), "first line must be present verbatim");
        assert!(body.contains("beta"), "rejected line must still be mirrored");

        let _ = std::fs::remove_file(&p);
    }

    /// F-01: Verify that when journal append fails (e.g. read-only file / disk full),
    /// apply_delta_lines returns Err and does NOT mutate in-memory commands or in_flight.
    #[test]
    fn test_apply_delta_lines_propagates_journal_error_without_committing_memory() {
        let p = tmp("delta_err");
        let s = CommandStore::open(&p).unwrap();
        let ts = 1700000000;
        let line = serde_json::json!({
            "id": "cmd-fail-1",
            "node": "receiver:1",
            "seq": 1,
            "op": "pause",
            "args": "",
            "actor": "op",
            "note": "",
            "state": "pending",
            "attempts": 0,
            "ts": ts,
            "err": "",
            "step": 0
        }).to_string();

        // Swap inner file with a read-only file descriptor to simulate write failure
        {
            let mut inner = s.inner.lock().unwrap();
            let ro_file = OpenOptions::new().read(true).open(&p).unwrap();
            inner.file = Some(ro_file);
        }

        let res = s.apply_delta_lines(&[line]);
        assert!(res.is_err(), "must propagate journal write error as Err");
        assert!(s.command("cmd-fail-1").is_none(), "failed write must not mutate commands map in memory");
        assert_eq!(s.stats().1, 0, "failed write must not mutate in_flight collection");

        let _ = std::fs::remove_file(&p);
    }

    /// N87-01: Verify torn (unparseable) lines and empty id lines are NOT counted
    /// in load() line_count or read_lines_from_path() total, ensuring perfect alignment
    /// between Primary and Standby journal watermarks.
    #[test]
    fn test_load_and_read_lines_skip_torn_and_align_line_count() {
        let p = tmp("torn_align");
        let valid_line = serde_json::json!({
            "id": "cmd-valid-1",
            "node": "receiver:1",
            "seq": 1,
            "op": "pause",
            "args": "",
            "actor": "op",
            "note": "",
            "state": "pending",
            "attempts": 0,
            "ts": 1700000000,
            "err": "",
            "step": 0
        }).to_string();

        let torn_line = "{\"id\":\"cmd-incomplete-broken-json...";
        let empty_id_line = "{\"id\":\"\",\"node\":\"receiver:1\",\"state\":\"pending\"}";

        let file_content = format!("{}\n{}\n{}\n", valid_line, torn_line, empty_id_line);
        std::fs::write(&p, file_content.as_bytes()).unwrap();

        // 1. load() should report exactly 1 valid line and 1 torn line
        let (cmds, _seq, torn, line_count, _max_seq) = load(&p).unwrap();
        assert_eq!(line_count, 1, "only valid command lines should be counted");
        assert_eq!(torn, 1, "torn line should be counted in torn counter");
        assert_eq!(cmds.len(), 1);

        // 2. read_lines_from_path() should return total = 1 and only valid_line
        let (lines, total, _max_s) = CommandStore::read_lines_from_path(&p, 0).unwrap();
        assert_eq!(total, 1, "total should match load's line_count");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0], valid_line);

        let _ = std::fs::remove_file(&p);
    }
}
