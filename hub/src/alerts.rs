//! alerts.rs - M6: the hub's alert engine.
//!
//! The plan's §13 describes M6 as "disconnection, risk trigger, orphan
//! positions, clock drift; dedup and silence windows". What exists today
//! covers four of those five honestly - orphan-position detection belongs to
//! the receiver's panel (the plan itself files it there, §10 layer 2), and
//! the hub cannot see a receiver's mirror table. What the hub CAN see, it now
//! evaluates on a 5-second tick:
//!
//! | kind                | from                                    | severity |
//! |---------------------|-----------------------------------------|----------|
//! | `node.offline`      | registry liveness (60 s of quiet)       | critical |
//! | `node.clock.drift`  | a CHANGE in the node's clock offset vs ours | warning |
//! | `risk.blocked`      | `BLOCKED=` on the receiver's STAT       | warning  |
//! | `risk.tripped`      | `RISK=<trip key>` on the receiver's STAT| critical |
//! | `command.unknown`   | a recent command that exhausted its ladder | warning |
//!
//! WHY DRIFT MEANS A JUMP, NOT AN OFFSET
//! =====================================
//! The rule started as "node clock far from hub clock" and the first live
//! run fired it for all four nodes at exactly 10800 s - the offset between
//! the hub host's timezone (GMT+11) and the brokers' server time (GMT+3).
//! A STABLE offset is a deployment fact, not a fault, and an alert that is
//! right about all four nodes at once has said nothing. What is alertable is
//! a node whose offset CHANGES - a clock stepped or a broker migrated - which
//! is what the rule measures now, against the previous drift as its baseline.
//!
//! THE SECOND RULE: recent, not ancient
//! ====================================
//! `command.unknown` is filtered to commands issued within the last hour.
//! The journal is append-only and remembers a ladder's corpse forever, so
//! without the filter every hub restart re-announced every command that ever
//! exhausted - nine alerts on each start, all about history.
//!
//! THE TWO RULES THAT MAKE THIS USABLE
//! ===================================
//! 1. **Dedup by (kind, key) with a silence window.** Once `node.offline` has
//!    fired for a node it stays quiet for ten minutes - an alert log that
//!    repeats itself is a log nobody reads (the same rule the receiver's
//!    CopierOnceLog already lives by).
//! 2. **Re-arm when the condition clears.** A node that was offline, comes
//!    back, and dies again fires a second `node.offline` immediately - the
//!    silence window covers repetition DURING one incident, not across
//!    incidents. Without re-arm, a flapping link alerts once and is then
//!    invisible for ten minutes per flap.
//!
//! Every fired alert is written to BOTH surfaces: the M7 audit log
//! (`alert.<kind>`, actor `hub`) so the sequence is durable and greppable,
//! and an in-memory ring (bounded) that `GET /api/v1/alerts` and the
//! dashboard banner read - the audit file is append-only and unbounded, and
//! a page that has to scan it to render is a page that stops rendering.

use std::collections::{HashMap, VecDeque};

use serde_json::{json, Value};

use crate::registry::Liveness;
use crate::api::Shared;

/// How many recent alerts the ring keeps. Bounded like every other table in
/// this codebase: 2000 is days of a flapping-link worst case at one command
/// per minute per node, and the audit file holds the rest.
const ALERT_RECENT: usize = 2000;

/// The silence window per kind, in seconds.
mod silence {
    pub const NODE_OFFLINE: u64 = 600; // 10 min of repetition during one outage
    pub const CLOCK_DRIFT: u64 = 1800; // 30 min; a skewed clock is not an emergency
    pub const RISK: u64 = 300; // 5 min; risk STATs arrive once a minute
    /// Command ids are unique per issue, so the "window" is only a
    /// belt-and-braces guard against the same id being evaluated by two
    /// overlapping ticks.
    pub const COMMAND_UNKNOWN: u64 = 600;
}

/// How far the node's clock may MOVE between messages before it is
/// interesting. Five minutes: a broker timezone or a stepped server clock
/// shows up as exactly this, while ordinary jitter is under a second.
pub const DRIFT_ALERT_SECS: i64 = 300;

/// A `command.unknown` older than this is history, not news. The journal
/// remembers exhausted ladders forever, and without an age filter every hub
/// restart re-announced all of them.
pub const COMMAND_MAX_AGE_SECS: u64 = 3600;

/// How often the rules are evaluated, in seconds. Deliberately NOT
/// `--stats-every` (30 s): the engine is cheap scans over two in-memory
/// tables, and a dead node is worth noticing in five seconds rather than
/// thirty. The dedup windows are what keep this from meaning five lines a
/// second of noise.
pub const EVERY_SECS: f64 = 5.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    Critical,
    Warning,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Critical => "critical",
            Severity::Warning => "warning",
        }
    }
}

/// One fired alert. `ts` is the HUB's unix seconds, never the node's - the
/// hub is the thing writing the log.
#[derive(Clone, Debug)]
pub struct Alert {
    pub ts: u64,
    pub kind: &'static str,
    pub severity: Severity,
    /// The node key (`receiver:123`) the alert is about, or "" for a
    /// hub-wide event.
    pub node: String,
    pub detail: Value,
}

impl Alert {
    pub fn action(&self) -> String {
        format!("alert.{}", self.kind)
    }
}

/// The engine: the recent ring plus the dedup/re-arm state.
pub struct AlertEngine {
    recent: VecDeque<Alert>,
    /// Last fire time per (kind, key). Present = "fired at least once",
    /// consulted against the kind's silence window.
    fired: HashMap<(&'static str, String), u64>,
    /// The liveness we last SAW per node, so an offline -> online ->
    /// offline cycle is two incidents, not one.
    was_offline: HashMap<String, bool>,
}

impl Default for AlertEngine {
    fn default() -> Self {
        AlertEngine::new()
    }
}

impl AlertEngine {
    pub fn new() -> Self {
        AlertEngine {
            recent: VecDeque::new(),
            fired: HashMap::new(),
            was_offline: HashMap::new(),
        }
    }

    /// The recent ring, newest first, for the API and the snapshot.
    pub fn recent_json(&self, limit: usize) -> Vec<Value> {
        self.recent
            .iter()
            .rev()
            .take(limit)
            .map(|a| {
                json!({
                    "ts": a.ts,
                    "kind": a.kind,
                    "severity": a.severity.as_str(),
                    "node": a.node,
                    "detail": a.detail,
                })
            })
            .collect()
    }

    fn push(&mut self, a: Alert) {
        if self.recent.len() == ALERT_RECENT {
            self.recent.pop_front();
        }
        self.recent.push_back(a);
    }

    /// Is this (kind, key) allowed to fire now? Records the fire when it is.
    /// A window of 0 means "key is unique by construction" (a command id) -
    /// it fires once, period; the map entry is what makes a second evaluation
    /// of the same key a no-op rather than a zero-length comparison.
    fn allow(&mut self, kind: &'static str, key: &str, now: u64, window: u64) -> bool {
        let k = (kind, key.to_string());
        if let Some(t) = self.fired.get(&k) {
            if window == 0 || now.saturating_sub(*t) < window {
                return false;
            }
        }
        self.fired.insert(k, now);
        true
    }
}

/// Did the node's clock offset MOVE by enough to matter? The first
/// measurement establishes the baseline and never fires - a node's opening
/// position in its own timezone is a fact, not an event.
pub fn drift_jumped(prev: Option<i64>, cur: i64, threshold: i64) -> bool {
    match prev {
        Some(p) => (cur - p).abs() >= threshold,
        None => false,
    }
}

/// Evaluate every rule against the hub's current state, return what fired
/// (already pushed into the ring). The caller writes them to the audit log.
///
/// Takes `&mut Shared` rather than the pieces because every input it reads -
/// registry, commands - is already inside it, and a snapshot of "everything
/// minus the engine" is exactly the data shape this function wants.
pub fn evaluate(s: &mut Shared, now: u64) -> Vec<Alert> {
    let mut fired: Vec<Alert> = Vec::new();
    let instant_now = std::time::Instant::now();

    //--- Snapshot the node view first. The loop mutates the engine (a
    //--- different field of `s`), but borrowing `s.reg` for the iteration
    //--- and `s.alerts` inside it is clearer to read - and to prove correct
    //--- - as an owned list.
    let nodes: Vec<crate::registry::Node> = s.reg.nodes().into_iter().cloned().collect();

    for n in &nodes {
        //--- liveness, with re-arm. `insert` returns the PREVIOUS value, so
        //--- the first evaluation of a node establishes its baseline and
        //--- never fires on its own.
        let offline = matches!(n.liveness(instant_now), Liveness::Offline);
        let was = s.alerts.was_offline.insert(n.key.clone(), offline);
        if offline && !was.unwrap_or(false) {
            let a = Alert {
                ts: now,
                kind: "node.offline",
                severity: Severity::Critical,
                node: n.key.clone(),
                detail: json!({
                    "role": n.role_str(),
                    "name": n.name,
                    "quiet_secs": instant_now.saturating_duration_since(n.last_seen).as_secs(),
                }),
            };
            if s.alerts.allow(a.kind, &n.key, now, silence::NODE_OFFLINE) {
                s.alerts.push(a.clone());
                fired.push(a);
            }
        }

        //--- clock drift, as a JUMP against the previous offset. A stable
        //--- offset is a timezone fact (see the module docs); a change is
        //--- a broken clock.
        if let (Some(cur), Some(prev)) = (n.drift_secs, n.drift_prev_secs) {
            if drift_jumped(Some(prev), cur, DRIFT_ALERT_SECS) {
                let a = Alert {
                    ts: now,
                    kind: "node.clock.drift",
                    severity: Severity::Warning,
                    node: n.key.clone(),
                    detail: json!({
                        "drift_secs": cur,
                        "was_secs": prev,
                        "changed_by_secs": (cur - prev).abs(),
                        "node_ts": n.node_ts,
                    }),
                };
                if s.alerts.allow(a.kind, &n.key, now, silence::CLOCK_DRIFT) {
                    s.alerts.push(a.clone());
                    fired.push(a);
                }
            }
        }

        //--- risk: entries the receiver's risk gates are blocking right now.
        if n.blocked > 0 {
            let a = Alert {
                ts: now,
                kind: "risk.blocked",
                severity: Severity::Warning,
                node: n.key.clone(),
                detail: json!({ "blocked_entries": n.blocked }),
            };
            if s.alerts.allow(a.kind, &n.key, now, silence::RISK) {
                s.alerts.push(a.clone());
                fired.push(a);
            }
        }

        //--- risk: a limit actually TRIPPED (the receiver flattened or is
        //--- flattening - CopierRisk's BlockKey names which one).
        if !n.risk.is_empty() && n.risk != "ok" {
            let a = Alert {
                ts: now,
                kind: "risk.tripped",
                severity: Severity::Critical,
                node: n.key.clone(),
                detail: json!({ "trip": n.risk }),
            };
            if s.alerts.allow(a.kind, &n.key, now, silence::RISK) {
                s.alerts.push(a.clone());
                fired.push(a);
            }
        }
    }

    //--- commands: every RECENT command the ladder gave up on. Keyed by the
    // id, so it fires exactly once per command, forever - and filtered by
    // age so a hub restart replays only last hour's corpses.
    for c in s.cmds.commands() {
        if c.state != crate::commands::STATE_UNKNOWN {
            continue;
        }
        if now.saturating_sub(c.ts) > COMMAND_MAX_AGE_SECS {
            continue;
        }
        let a = Alert {
            ts: now,
            kind: "command.unknown",
            severity: Severity::Warning,
            node: c.node.clone(),
            detail: json!({ "command_id": c.id, "op": c.op, "attempts": c.attempts }),
        };
        if s.alerts.allow(a.kind, &c.id, now, silence::COMMAND_UNKNOWN) {
            s.alerts.push(a.clone());
            fired.push(a);
        }
    }

    fired
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_fire_during_the_silence_window_is_refused() {
        let mut e = AlertEngine::new();
        assert!(e.allow("node.offline", "receiver:1", 1000, 600));
        assert!(!e.allow("node.offline", "receiver:1", 1000 + 599, 600));
        // ...and allowed again once the window closes.
        assert!(e.allow("node.offline", "receiver:1", 1000 + 600, 600));
    }

    #[test]
    fn different_keys_are_independent() {
        let mut e = AlertEngine::new();
        assert!(e.allow("node.offline", "receiver:1", 1000, 600));
        assert!(e.allow("node.offline", "receiver:2", 1000, 600));
        assert!(!e.allow("node.offline", "receiver:2", 1001, 600));
    }

    #[test]
    fn a_zero_window_still_dedupes_immediately() {
        // Command ids are unique, but two overlapping ticks must not
        // double-fire the same one.
        let mut e = AlertEngine::new();
        assert!(e.allow("command.unknown", "receiver-1-pause-1", 1000, 0));
        assert!(!e.allow("command.unknown", "receiver-1-pause-1", 1000, 0));
        // A different command is a different alert.
        assert!(e.allow("command.unknown", "receiver-1-pause-2", 1000, 0));
    }

    #[test]
    fn the_ring_is_bounded_and_newest_first() {
        let mut e = AlertEngine::new();
        for i in 0..(ALERT_RECENT as u64 + 10) {
            e.push(Alert {
                ts: 1000 + i,
                kind: "node.offline",
                severity: Severity::Critical,
                node: format!("receiver:{}", i),
                detail: json!({}),
            });
        }
        let j = e.recent_json(ALERT_RECENT + 20);
        assert_eq!(j.len(), ALERT_RECENT);
        // The newest is first ...
        assert_eq!(j[0]["ts"], 1000 + (ALERT_RECENT as u64 + 9));
        // ... and the oldest was evicted, not duplicated.
        assert_eq!(j[j.len() - 1]["ts"], 1000 + 10);
    }

    #[test]
    fn severity_serialises_as_strings() {
        assert_eq!(Severity::Critical.as_str(), "critical");
        assert_eq!(Severity::Warning.as_str(), "warning");
    }

    #[test]
    fn drift_is_a_jump_not_an_offset() {
        // No baseline yet: the opening offset is a fact, not an event.
        assert!(!drift_jumped(None, -10800, 300));
        // A stable offset never fires, however large.
        assert!(!drift_jumped(Some(-10800), -10800, 300));
        // The same clock stepping three hours IS a broken clock.
        assert!(drift_jumped(Some(-10800), 0, 300));
        // Jitter does not fire.
        assert!(!drift_jumped(Some(-10800), -10799, 300));
        // Exactly at the threshold fires (>=).
        assert!(drift_jumped(Some(0), 300, 300));
    }
}
