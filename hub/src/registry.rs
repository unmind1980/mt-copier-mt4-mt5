//! Who is connected, and how alive they are.
//!
//! This is the module that makes the hub stateful, and it is worth being
//! explicit about why that is allowed now when Phase 1 was adamant that it was
//! not. Phase 1's rule was: *if the hub needs to know which nodes exist, that
//! is Phase 2 leaking in.* Phase 2 is here, so the hub now knows - but it knows
//! only what nodes TELL it. It never discovers anything, never configures
//! anything, and never writes to a node. A node that never sends REG is
//! invisible, which is the correct failure: silence is not a claim.
//!
//! The registry is rebuilt from scratch after every hub restart. There is no
//! persistence and there does not need to be - REG is cheap, and a table
//! restored from disk would be a table of nodes that may have died while the
//! hub was down. WHO exists to ask for fresh ones.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// No word from a node for this long and it is STALE: still counted, no longer
/// trusted. Deliberately the same 15 s the EAs use between peers
/// (`CP_PEER_TIMEOUT_MS`), so a hub and an EA looking at the same node draw the
/// same conclusion at the same moment.
pub const STALE_AFTER: Duration = Duration::from_secs(15);

/// And this long and it is OFFLINE. Longer than STALE by enough that a node
/// flapping on a bad link does not churn in and out of the operator's view.
pub const OFFLINE_AFTER: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Sender,
    Receiver,
    /// A node that registered with a role this build does not know. Kept rather
    /// than dropped: an unrecognised role is still a node that exists, and
    /// silently discarding it is how "why is my node missing" starts.
    Unknown,
}

impl Role {
    pub fn parse(s: &str) -> Role {
        match s {
            "sender" => Role::Sender,
            "receiver" => Role::Receiver,
            _ => Role::Unknown,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Role::Sender => "sender",
            Role::Receiver => "receiver",
            Role::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Liveness {
    Online,
    Stale,
    Offline,
}

#[derive(Clone, Debug)]
pub struct Node {
    /// `ROLE:ACC` - the plan's D3. The role is part of the key because one
    /// account can legitimately run both a sender and a receiver, and they are
    /// two different nodes with two different jobs.
    pub key: String,
    pub acc: String,
    pub role: Role,
    /// Protocol version the node reported. A hub that cannot talk to a node
    /// should be able to say so instead of just looking broken.
    pub ver: String,
    /// Only REG carries a name; an HBT2 must not clear one that REG set.
    pub name: String,
    /// The node's OWN uptime. Lets the hub distinguish "reconnected after a
    /// blip" from "has been up for a week" without keeping state of its own.
    pub up_secs: u64,
    pub first_seen: Instant,
    pub last_seen: Instant,
    pub regs: u64,
    pub hbts: u64,
    /// M6: the node's own clock as its latest message reported it (the
    /// envelope's `TS`, unix seconds), and the drift that implies against
    /// the hub's clock at receipt. `None` until a message with a parsable
    /// TS is seen - never 0, which would read as "drifts by the epoch".
    /// The PREVIOUS drift is kept beside it: a stable offset is a deployment
    /// fact (brokers in another timezone), a CHANGE in the offset is a
    /// broken clock, and only the second is alertable.
    pub node_ts: Option<i64>,
    pub drift_secs: Option<i64>,
    pub drift_prev_secs: Option<i64>,
    /// M5b on the dashboard: the node's own report of hub-pause (PAUSED= on
    /// its REG/HBT2). A receiver sets it when `closeall` paused it or a
    /// `pause` landed; the operator should be able to SEE that a node is
    /// paused without grepping a log. A sender never sets it.
    pub paused: bool,
    /// The receiver's own held-mirror count, from the `HELD=`/`LOTS=` fields
    /// of its STAT. `None` until the first STAT with figures arrives - which
    /// is "nothing to report yet", not zero, exactly like a sender whose
    /// first SNAP has not landed. This is what gives a RECEIVER a Pos column:
    /// the hub is a transparent proxy (§10) and never sees the receiver's
    /// account, but the receiver counts its own mirrors and says so.
    pub held: Option<u32>,
    pub held_lots: f64,
    /// The count of copier-tagged positions under an unconfigured magic,
    /// reported with HELD in a receiver's full STAT. None until reported.
    pub orphaned: Option<u32>,
    /// M6: record the risk state from the node's STAT - how many entries it
    /// is blocking and which limit (if any) tripped. Position summary keys
    /// may arrive more often on receipt heartbeats, so an empty risk string
    /// means this frame carries positions only and must preserve risk state.
    pub blocked: u32,
    pub risk: String,
    /// Receiver waiting figures: how many mirrors are waiting to open
    /// (queued at broker, delayed by wait gates, or held by market closed).
    pub wait_total: Option<u32>,
    pub wait_lots: f64,
    pub wait_queued: Option<u32>,
    pub wait_delayed: Option<u32>,
    pub wait_mkt: Option<u32>,
    /// Receiver financial snapshot: equity and balance reported by the terminal.
    pub equity: Option<f64>,
    pub balance: Option<f64>,
}

impl Node {
    pub fn liveness(&self, now: Instant) -> Liveness {
        let quiet = now.saturating_duration_since(self.last_seen);
        if quiet >= OFFLINE_AFTER {
            Liveness::Offline
        } else if quiet >= STALE_AFTER {
            Liveness::Stale
        } else {
            Liveness::Online
        }
    }

    /// The role as the wire spells it, for alerts and logs that talk about
    /// nodes rather than about this enum.
    pub fn role_str(&self) -> &'static str {
        match self.role {
            Role::Sender => "sender",
            Role::Receiver => "receiver",
            Role::Unknown => "unknown",
        }
    }
}

#[derive(Default)]
pub struct Registry {
    nodes: HashMap<String, Node>,
    /// Nodes dropped because they had been offline long enough to be
    /// forgotten. Counted so the hub can say it happened rather than quietly
    /// shrinking - a table that only ever grows is a leak, and one that shrinks
    /// invisibly is a mystery.
    pub evicted: u64,
}

/// How long an OFFLINE node is kept before being forgotten entirely.
///
/// Kept for a while on purpose: an operator looking at a dashboard five minutes
/// after a node died should see "offline", not nothing at all. "It vanished"
/// and "it is down" are different sentences and only one of them is useful.
pub const EVICT_AFTER: Duration = Duration::from_secs(30 * 60);

impl Registry {
    pub fn new() -> Self {
        Registry::default()
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// A node announced itself (`REG`).
    pub fn on_reg(
        &mut self,
        role: &str,
        acc: &str,
        ver: &str,
        name: &str,
        up_secs: u64,
        now: Instant,
    ) -> bool {
        //--- First sight of this key, as opposed to a re-registration.
        let is_new = !self.nodes.contains_key(&key_of(role, acc));
        let e = self.entry(role, acc, now);
        e.ver = ver.to_string();
        //--- An empty NAME must not wipe one we already have: a node that
        //--- registered with a name and later re-registers without one (an
        //--- older build, a stripped config) would otherwise lose it.
        if !name.is_empty() {
            e.name = name.to_string();
        }
        e.up_secs = up_secs;
        e.last_seen = now;
        e.regs += 1;
        is_new
    }

    /// A node is still there (`HBT2`).
    ///
    /// Returns true when this HEARTBEAT is what introduced the node - which
    /// happens whenever the node's `REG` was lost, and must be reported rather
    /// than swallowed. A node that appears without anyone saying so is a row
    /// the operator cannot identify, and "why is there a node with no name"
    /// is a worse question than "why did its REG not arrive".
    pub fn on_hbt(
        &mut self,
        role: &str,
        acc: &str,
        ver: &str,
        name: &str,
        up_secs: u64,
        now: Instant,
    ) -> bool {
        let is_new = !self.nodes.contains_key(&key_of(role, acc));
        let e = self.entry(role, acc, now);
        //--- A heartbeat is evidence of liveness first and everything else
        //--- second - but it now carries a name too, so it is no longer
        //--- silence on that subject.
        //---
        //--- THE RULE THAT MATTERS: an empty name must never blank one that
        //--- REG already set. That is the old rule, unchanged, and it is what
        //--- makes adding NAME to HBT2 safe on a live link: a hub running this
        //--- build talking to an OLD EA gets an empty name here forever, and
        //--- the name REG supplied has to survive that.
        //---
        //--- A NON-empty name does update, which is also what makes a rename
        //--- propagate without waiting for the next REG - and it is why the
        //--- blank rule has to be "empty", not "different".
        if !name.is_empty() {
            e.name = name.to_string();
        }
        if !ver.is_empty() {
            e.ver = ver.to_string();
        }
        e.up_secs = up_secs;
        e.last_seen = now;
        e.hbts += 1;
        is_new
    }

    /// M6: record the node's own reported clock (the `TS` field of its
    /// envelope) and the drift against ours at receipt. Sent alongside a
    /// REG/HBT2, so `last_seen` is theirs to set - this only reads the
    /// clock and stores the difference. The previous drift is kept: what
    /// matters is not the offset (a stable one is a timezone fact) but a
    /// CHANGE in it.
    ///
    /// UPDATE-ONLY, never `entry()`: a first REG is still in flight when
    /// this runs, and pre-creating the node would make the REG's `is_new`
    /// false - the registry would log "named" instead of "registered",
    /// and a node the hub never heard REG from would be visible anyway.
    /// The hub learns who exists ONLY from REG/HBT2, as it always has.
    pub fn note_ts(&mut self, role: &str, acc: &str, node_ts: i64, hub_now: i64) {
        if let Some(e) = self.nodes.get_mut(&key_of(role, acc)) {
            e.drift_prev_secs = e.drift_secs;
            e.node_ts = Some(node_ts);
            e.drift_secs = Some(node_ts - hub_now);
        }
    }

    /// M6: record the risk state from the node's STAT - how many entries it
    /// is blocking and which limit (if any) tripped. Update-only, for the
    /// same reason as note_ts: a STAT is not a registration, and a hub that
    /// learned nodes from STATs would be a hub that trusts the wire.
    pub fn note_stat(
        &mut self,
        role: &str,
        acc: &str,
        blocked: u32,
        risk: &str,
        held: Option<u32>,
        held_lots: f64,
        orphaned: Option<u32>,
        wait_total: Option<u32>,
        wait_lots: f64,
        wait_queued: Option<u32>,
        wait_delayed: Option<u32>,
        wait_mkt: Option<u32>,
        equity: Option<f64>,
        balance: Option<f64>,
    ) {
        if let Some(e) = self.nodes.get_mut(&key_of(role, acc)) {
            if !risk.is_empty() {
                e.blocked = blocked;
                e.risk = risk.to_string();
            }
            //--- HELD/LOTS/ORPHAN arrive on receipt heartbeats as well as the
            //--- full status report. Missing fields mean "no figures in THIS
            //--- frame", never "zero" - hence Option.
            if let Some(h) = held {
                e.held = Some(h);
                e.held_lots = held_lots;
                e.orphaned = orphaned;
            }
            if let Some(w) = wait_total {
                e.wait_total = Some(w);
                e.wait_lots = wait_lots;
                e.wait_queued = wait_queued;
                e.wait_delayed = wait_delayed;
                e.wait_mkt = wait_mkt;
            }
            if let Some(eq) = equity {
                e.equity = Some(eq);
            }
            if let Some(bl) = balance {
                e.balance = Some(bl);
            }
        }
    }

    /// M5b on the dashboard: record the node's own hub-pause report (the
    /// `PAUSED=` field of its REG/HBT2). Update-only like note_ts/note_stat:
    /// the flag is a property of a node the hub already knows.
    pub fn note_paused(&mut self, role: &str, acc: &str, paused: bool) {
        if let Some(e) = self.nodes.get_mut(&key_of(role, acc)) {
            e.paused = paused;
        }
    }

    fn entry(&mut self, role: &str, acc: &str, now: Instant) -> &mut Node {
        let key = key_of(role, acc);
        self.nodes.entry(key.clone()).or_insert_with(|| Node {
            key,
            acc: acc.to_string(),
            role: Role::parse(role),
            ver: String::new(),
            name: String::new(),
            up_secs: 0,
            first_seen: now,
            last_seen: now,
            regs: 0,
            hbts: 0,
            node_ts: None,
            drift_secs: None,
            drift_prev_secs: None,
            paused: false,
            held: None,
            held_lots: 0.0,
            orphaned: None,
            blocked: 0,
            risk: String::new(),
            wait_total: None,
            wait_lots: 0.0,
            wait_queued: None,
            wait_delayed: None,
            wait_mkt: None,
            equity: None,
            balance: None,
        })
    }

    /// Drop nodes that have been offline long enough to be forgotten.
    /// Drop nodes that have been offline long enough to be forgotten.
    ///
    /// Returns the keys forgotten, not just a count: forgetting a node is the
    /// one registry event that cannot be recovered by asking the node, so the
    /// audit log needs to say WHICH one rather than that it happened.
    pub fn evict(&mut self, now: Instant) -> Vec<String> {
        let mut gone: Vec<String> = Vec::new();
        self.nodes.retain(|k, n| {
            let keep = now.saturating_duration_since(n.last_seen) < EVICT_AFTER;
            if !keep {
                gone.push(k.clone());
            }
            keep
        });
        self.evicted += gone.len() as u64;
        gone
    }

    #[allow(dead_code)]
    pub fn get(&self, key: &str) -> Option<&Node> {
        self.nodes.get(key)
    }

    #[allow(dead_code)]
    pub fn get_mut(&mut self, key: &str) -> Option<&mut Node> {
        self.nodes.get_mut(key)
    }

    /// Every node, newest activity first. The order is fixed so the output is
    /// diffable between runs.
    pub fn nodes(&self) -> Vec<&Node> {
        let mut v: Vec<&Node> = self.nodes.values().collect();
        v.sort_by(|a, b| {
            b.last_seen
                .cmp(&a.last_seen)
                .then_with(|| a.key.cmp(&b.key))
        });
        v
    }

    /// Every node, ordered by `ROLE:ACC` - for anything a HUMAN reads.
    ///
    /// `nodes` orders by `last_seen`, which is the right question for a log
    /// line that just printed something ("who was it") and the WRONG one for
    /// anything with rows: a heartbeat bumps `last_seen`, so the row that
    /// just moved is the one that did nothing worth noticing, and it jumped to
    /// the top. On a live feed that is every few seconds, forever.
    ///
    /// This was found on the dashboard, not in review: the nodes table and the
    /// topology diagram reshuffled continuously, and the REST endpoints were
    /// already sorting correctly - only the WebSocket push used `nodes`. One
    /// path sorted by account, the other by recency, and the page preferred
    /// the second. Hence this function existing at all: the order a reader
    /// sees should be defined ONCE.
    ///
    /// Ordering by account is stable because an account does not change.
    pub fn sorted(&self) -> Vec<&Node> {
        let mut v: Vec<&Node> = self.nodes.values().collect();
        v.sort_by(|a, b| a.key.cmp(&b.key));
        v
    }

    pub fn count(&self, l: Liveness, now: Instant) -> usize {
        self.nodes.values().filter(|n| n.liveness(now) == l).count()
    }

    /// Count by role, ignoring liveness.
    ///
    /// Separate from `count` on purpose: liveness answers "is it still
    /// talking", role answers "what does it do", and a page showing
    /// "4 senders online" has conflated the two. The API wants both, so it
    /// gets both.
    pub fn count_by_role(&self, r: Role) -> usize {
        self.nodes.values().filter(|n| n.role == r).count()
    }

    /// Does this node exist and still have no name?
    ///
    /// Used to report the moment a lost-REG race resolves: a node introduced by
    /// its heartbeat is anonymous, and the REG that finally arrives is worth
    /// saying out loud. "A node with no name" and "a node that has just been
    /// identified" are very different things to be looking at.
    pub fn is_unnamed(&self, role: &str, acc: &str) -> bool {
        match self.nodes.get(&key_of(role, acc)) {
            Some(n) => n.name.is_empty(),
            None => false,
        }
    }
}

fn key_of(role: &str, acc: &str) -> String {
    format!("{}:{}", role, acc)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn receiver_position_heartbeat_updates_counts_without_erasing_risk_state() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("receiver", "777777", "2.0", "MT5-B", 1, now);

        // Full minute report sets risk + counts + waiting + equity.
        r.note_stat(
            "receiver", "777777", 2, "daily-loss",
            Some(4), 0.87, Some(1),
            Some(3), 0.30, Some(1), Some(0), Some(2),
            Some(10050.25), Some(10000.00),
        );
        // More frequent sync heartbeat carries counts and waiting figures, preserving risk.
        r.note_stat(
            "receiver", "777777", 0, "",
            Some(5), 1.12, Some(2),
            Some(9), 0.09, Some(0), Some(0), Some(9),
            Some(10015.99), Some(10022.01),
        );

        let n = &r.nodes()[0];
        assert_eq!(n.blocked, 2);
        assert_eq!(n.risk, "daily-loss");
        assert_eq!(n.held, Some(5));
        assert_eq!(n.held_lots, 1.12);
        assert_eq!(n.orphaned, Some(2));
        assert_eq!(n.wait_total, Some(9));
        assert_eq!(n.wait_lots, 0.09);
        assert_eq!(n.wait_queued, Some(0));
        assert_eq!(n.wait_delayed, Some(0));
        assert_eq!(n.wait_mkt, Some(9));
        assert_eq!(n.equity, Some(10015.99));
        assert_eq!(n.balance, Some(10022.01));
    }

    #[test]
    fn is_unnamed_tracks_the_lost_reg_race() {
        let mut r = Registry::new();
        let now = t0();
        // not seen at all -> not "unnamed", just absent
        assert!(!r.is_unnamed("sender", "555001"));
        // introduced by a heartbeat -> unnamed
        r.on_hbt("sender", "555001", "2.0", "", 1, now);
        assert!(r.is_unnamed("sender", "555001"));
        // the REG finally lands -> named, and NOT a new node
        assert!(!r.on_reg("sender", "555001", "2.0", "MT5-A", 2, now));
        assert!(!r.is_unnamed("sender", "555001"));
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn a_registration_creates_a_node() {
        let mut r = Registry::new();
        let now = t0();
        assert!(r.on_reg("sender", "888888", "2.0", "MT5-A", 10, now));
        assert_eq!(r.len(), 1);
        let n = &r.nodes()[0];
        assert_eq!(n.key, "sender:888888");
        assert_eq!(n.name, "MT5-A");
        assert_eq!(n.liveness(now), Liveness::Online);
    }

    #[test]
    fn the_same_account_as_two_roles_is_two_nodes() {
        // One account can run a sender AND a receiver. They are different
        // nodes with different jobs and must not overwrite each other.
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "888888", "2.0", "A", 1, now);
        r.on_reg("receiver", "888888", "2.0", "B", 1, now);
        assert_eq!(r.len(), 2);
    }

    #[test]
    fn re_registration_is_not_a_new_node() {
        let mut r = Registry::new();
        let now = t0();
        assert!(r.on_reg("sender", "888888", "2.0", "A", 1, now));
        assert!(!r.on_reg("sender", "888888", "2.0", "A", 2, now));
        assert_eq!(r.len(), 1);
        assert_eq!(r.nodes()[0].regs, 2);
    }

    #[test]
    fn an_empty_heartbeat_name_must_not_blank_a_name() {
        // The rule that HBT2 carrying a name depends on, and the reason the
        // old "HBT2 must carry no name at all" design could be retired.
        //
        // That old design was right about the hazard and wrong about where to
        // fix it: it kept the name OFF the wire so that a hub taking
        // name-at-face-value could not erase what REG had established. The hub
        // now never does that - an empty name is not an instruction - so the
        // name can travel with the liveness evidence instead, which is what
        // stops a node being visible-but-anonymous after a hub restart.
        //
        // Mixed versions are the case this protects in practice: a new hub
        // reading an OLD EA's heartbeat gets an empty name here forever, and
        // REG's name has to survive that.
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "888888", "2.0", "MT5-A", 1, now);
        for i in 0..50 {
            r.on_hbt("sender", "888888", "2.0", "", i, now);
        }
        assert_eq!(r.nodes()[0].name, "MT5-A");
        assert_eq!(r.nodes()[0].hbts, 50);
    }

    #[test]
    fn a_heartbeat_name_arrives_without_waiting_for_a_reg() {
        // The bug this test exists for, stated as a behaviour: a node
        // introduced by its heartbeat is NAMED, because HBT2 carries one.
        //
        // Measured on a live hub before the wire change: restart the hub with
        // the EAs already attached and they are past CP_REG_REPEATS, so they
        // send HBT2 only - the node appeared with a blank Name and stayed blank
        // for the ten to fifteen seconds until the WHO sweep made it re-REG.
        let mut r = Registry::new();
        let now = t0();
        r.on_hbt("receiver", "777777", "2.0", "MT5-B", 12, now);
        assert_eq!(r.nodes()[0].name, "MT5-B");
        assert!(!r.is_unnamed("receiver", "777777"));
    }

    #[test]
    fn a_rename_propagates_on_the_heartbeat() {
        // A non-empty name updates, which is why the blank rule has to be
        // "empty" and not "different". A renamed terminal then propagates
        // within one heartbeat instead of waiting for a re-REG.
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "888888", "2.0", "MT5-A", 1, now);
        r.on_hbt("sender", "888888", "2.0", "MT5-A-renamed", 2, now);
        assert_eq!(r.nodes()[0].name, "MT5-A-renamed");
    }

    #[test]
    fn a_heartbeat_that_introduces_a_node_says_so() {
        // The startup REG can genuinely be lost: the EAs open their socket with
        // IMMEDIATE, so a send made before the TCP connection completes is
        // DISCARDED rather than queued. When that happens the node is still
        // real and HBT2 is what introduces it.
        //
        // Reporting that is the whole difference between "a node with no name"
        // and "a node whose REG was lost" - and only one of those is something
        // an operator can act on. It is also the bug that made a working hub
        // look broken: nodes counted, no lines explaining them.
        let mut r = Registry::new();
        let now = t0();
        assert!(r.on_hbt("sender", "555001", "2.0", "", 42, now), "first HBT2 is new");
        assert!(!r.on_hbt("sender", "555001", "2.0", "", 43, now), "second is not");
        assert_eq!(r.len(), 1);
        assert_eq!(r.nodes()[0].name, "", "an OLD EA sends no name in HBT2");
    }

    #[test]
    fn a_re_registration_without_a_name_keeps_the_old_one() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "888888", "2.0", "MT5-A", 1, now);
        r.on_reg("sender", "888888", "2.0", "", 2, now);
        assert_eq!(r.nodes()[0].name, "MT5-A");
    }

    #[test]
    fn liveness_moves_online_stale_offline() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "888888", "2.0", "A", 1, now);
        let n = &r.nodes()[0];
        assert_eq!(n.liveness(now), Liveness::Online);
        assert_eq!(n.liveness(now + STALE_AFTER), Liveness::Stale);
        assert_eq!(n.liveness(now + OFFLINE_AFTER), Liveness::Offline);
    }

    #[test]
    fn counts_are_per_liveness() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "111111", "2.0", "A", 1, now);
        r.on_reg("sender", "222222", "2.0", "B", 1, now - OFFLINE_AFTER);
        assert_eq!(r.count(Liveness::Online, now), 1);
        assert_eq!(r.count(Liveness::Offline, now), 1);
    }

    #[test]
    fn an_unknown_role_is_kept_not_dropped() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("router", "888888", "9.9", "X", 1, now);
        assert_eq!(r.len(), 1);
        assert_eq!(r.nodes()[0].role, Role::Unknown);
    }

    #[test]
    fn eviction_forgets_only_the_long_gone() {
        let mut r = Registry::new();
        let now = t0();
        r.on_reg("sender", "111111", "2.0", "A", 1, now);
        r.on_reg("sender", "222222", "2.0", "B", 1, now - EVICT_AFTER - Duration::from_secs(1));
        r.evict(now);
        assert_eq!(r.len(), 1);
        assert_eq!(r.evicted, 1);
        assert_eq!(r.nodes()[0].acc, "111111");
    }

    #[test]
    fn node_order_is_deterministic() {
        let mut r = Registry::new();
        let now = t0();
        // same timestamp -> ties broken by key, so the list does not reshuffle
        r.on_reg("sender", "222222", "2.0", "B", 1, now);
        r.on_reg("sender", "111111", "2.0", "A", 1, now);
        let keys: Vec<&str> = r.nodes().iter().map(|n| n.key.as_str()).collect();
        assert_eq!(keys, vec!["sender:111111", "sender:222222"]);
    }
}
