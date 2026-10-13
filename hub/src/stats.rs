//! Counters, and the stats line they feed.
//!
//! Kept in its own file mostly so the loop in `main.rs` stays readable, and so
//! the loop detector - the one piece of this that is a genuine safety net -
//! has somewhere to live with its reasoning attached.

use std::collections::{BTreeSet, HashMap};
use std::time::Instant;

/// A topic emitting faster than this is not traffic, it is a LOOP: some node is
/// echoing a data topic back up and the hub is forwarding it again.
///
/// The intended design cannot produce that - receivers only ever send UP with
/// an `@hub` topic - so it can only be a bug. And an infinite forward loop is
/// otherwise invisible until the network bill arrives.
const LOOP_WARN_PER_SEC: f64 = 200.0;

/// Above this REG rate, the hub says so out loud.
///
/// The legitimate steady-state figure is one reply per 60s WHO sweep, so
/// ~0.017/s. The only way to exceed one per second is a node that has stopped
/// settling into `HBT2` - and since the hub logs a node only the first time it
/// appears, such a node's extra REGs would otherwise be entirely silent. See
/// the warning in `print_and_reset` for the measurement that motivated this.
const REG_WARN_PER_SEC: f64 = 1.0;

pub struct Stats {
    pub forwarded: u64,
    pub control: u64,
    pub dropped: u64,
    /// Single-frame messages that are NOT subscription bytes.
    ///
    /// The hub has no use for one - but it must not be INVISIBLE, which is what
    /// it was until this counter existed. The direct channel's convention is one
    /// frame, so a node that speaks it at the hub (a receiver sending its STAT
    /// up the wrong way, say) produces a message that is read, matched against
    /// the subscription shape, found not to be one, and dropped - with no log
    /// line, no counter, and no trace. A silent discard is the worst possible
    /// treatment for a protocol mismatch.
    pub single_dropped: u64,

    /// Snapshot receipts relayed from a receiver back to its sender.
    ///
    /// The hub ORIGINATES these, so none of the other counters can see them:
    /// they are not forwarded (nothing came in on a data topic), not control
    /// (nothing came in on '@'), and not dropped. Without this counter the
    /// relay would be completely invisible on a hub whose entire design
    /// principle is that nothing should be silent.
    ///
    /// It is also the only way to answer "is the receipt path alive?" from
    /// outside: the sender logs only when a receipt is BEHIND, so a working
    /// relay in a healthy system prints nothing at all.
    pub receipts: u64,

    //--- WHOLE RUN, kept separately from the window figures above.
    //---
    //--- These used to be the SAME counters, which made the periodic line
    //--- wrong in a way that cost real time: it announced "--- last 30 s ---"
    //--- and then printed a figure that covered the entire run, next to
    //--- breakdowns that really were per-window. So `forwarded 203` sat above
    //--- `by topic 53203697:60 252033316:57` - numbers that do not reconcile,
    //--- in a line whose whole purpose is to be read at a glance.
    //---
    //--- The window is what the periodic line reports; the totals are for the
    //--- final line. Different questions, different counters.
    pub total_forwarded: u64,
    pub total_control: u64,
    pub total_dropped: u64,
    pub total_single_dropped: u64,
    pub total_receipts: u64,

    by_topic: HashMap<String, u64>,
    by_type: HashMap<String, u64>,
    /// Control broken down by type, for the same reason `by_type` exists for
    /// data - and its ABSENCE was a real blind spot.
    ///
    /// The stats line reported forwarded-by-type and control as a single
    /// number, so "control 201 in 75 s" was visible while "and 100 of those
    /// were X" was not. That asymmetry is exactly what makes a rate you cannot
    /// explain, and the first thing anyone does with it is guess.
    control_by_type: HashMap<String, u64>,
    /// Prefixes currently subscribed, so the line can say who is listening.
    /// A BTreeSet because the output should be stable between runs - a stats
    /// line that reshuffles is one nobody can diff.
    pub subs: BTreeSet<String>,
    window_start: Instant,
}

impl Stats {
    pub fn new() -> Self {
        Stats {
            forwarded: 0,
            control: 0,
            dropped: 0,
            single_dropped: 0,
            receipts: 0,
            total_forwarded: 0,
            total_control: 0,
            total_dropped: 0,
            total_single_dropped: 0,
            total_receipts: 0,
            by_topic: HashMap::new(),
            by_type: HashMap::new(),
            control_by_type: HashMap::new(),
            subs: BTreeSet::new(),
            window_start: Instant::now(),
        }
    }

    pub fn window_secs(&self) -> f64 {
        self.window_start.elapsed().as_secs_f64().max(0.001)
    }

    pub fn note_forward(&mut self, topic: &str, ty: &str) {
        self.forwarded += 1;
        self.total_forwarded += 1;
        *self.by_topic.entry(topic.to_string()).or_insert(0) += 1;
        *self.by_type.entry(ty.to_string()).or_insert(0) += 1;
    }

    pub fn note_control(&mut self, ty: &str) {
        self.control += 1;
        self.total_control += 1;
        *self.control_by_type.entry(ty.to_string()).or_insert(0) += 1;
    }

    /// A two-frame message whose payload is not an envelope.
    pub fn note_dropped(&mut self) {
        self.dropped += 1;
        self.total_dropped += 1;
    }

    /// A single frame that is not a subscription byte - unroutable, see above.
    pub fn note_single_dropped(&mut self) {
        self.single_dropped += 1;
        self.total_single_dropped += 1;
    }

    /// A snapshot receipt relayed back to its sender. See the field docs.
    pub fn note_receipt(&mut self) {
        self.receipts += 1;
        self.total_receipts += 1;
    }

    /// Print the window and start a new one.
    pub fn print_and_reset(&mut self) {
        let w = self.window_secs();
        println!("[hub] --- last {:.0}s ---", w);
        println!(
            "[hub]   forwarded {}   control {}   dropped {}   (this window)",
            self.forwarded, self.control, self.dropped
        );

        //--- Only when it happens. A permanent "single-dropped 0" would be one
        //--- more line nobody reads; a non-zero one means somebody is speaking
        //--- the direct convention at a hub, and that is worth a sentence.
        if self.single_dropped > 0 {
            println!(
                "[hub]   single-frame {} - a message with no topic frame, which this \
                 hub has no way to route. The direct channel is one frame; the \
                 central channel is two. Something is speaking direct at the hub.",
                self.single_dropped
            );
        }

        //--- Only when it happens, for the same reason as single_dropped above:
        //--- a permanent "receipts 0" is noise, and the figure only means
        //--- something once a receiver is actually mirroring through this hub.
        if self.receipts > 0 {
            println!(
                "[hub]   receipts {} relayed back to senders (snapshot delivery \
                 receipts; see D13 in CENTRAL-HUB-PLAN.md)",
                self.receipts
            );
        }

        let topics = top(&self.by_topic, 8);
        if !topics.is_empty() {
            println!("[hub]   by topic  {}", join(&topics));
        }
        let types = top(&self.by_type, 8);
        if !types.is_empty() {
            println!("[hub]   by type   {}", join(&types));
        }
        let ctl = top(&self.control_by_type, 8);
        if !ctl.is_empty() {
            println!("[hub]   control by type  {}", join(&ctl));
        }

        //--- REG is a STARTUP message, not a heartbeat. A node sends a small
        //--- burst of them when it attaches and then switches to HBT2 forever;
        //--- the only legitimate steady-state REG is one reply per 60s WHO
        //--- sweep, i.e. 1/60 per node per second.
        //---
        //--- So a REG rate that scales with the number of NODES rather than
        //--- with the sweep is a bug, and an expensive one: REG carries NAME,
        //--- so every one of them is a log line here and a full announce on the
        //--- wire. Measured live: a node re-arming its REG burst on every WHO
        //--- reply produced ~6x the correct REG count, and because the hub only
        //--- LOGS a node the first time it sees it, every extra REG printed
        //--- NOTHING. The only place it showed was this counter.
        //---
        //--- Hence the warning: it is the one line that can say "this is more
        //--- REGs than the protocol can explain" without a single extra REG
        //--- needing to be logged.
        if let Some(regs) = self.control_by_type.get("REG") {
            let per_node_per_sec = *regs as f64 / w;
            //--- The sweep explains 1/60 = 0.017 per node per second. Anything
            //--- past a whole one per second per node is a node that has stopped
            //--- settling, not a node that is registering.
            if per_node_per_sec > REG_WARN_PER_SEC {
                println!(
                    "[hub]   WARNING REG is doing {:.1} msg/s. REG is a STARTUP \
                     message - a settled node sends HBT2. A steady REG stream means \
                     a node is re-announcing instead of settling (check the WHO \
                     reply path in the EAs), and each one carries a NAME.",
                    per_node_per_sec
                );
            }
        }

        let subs: Vec<&str> = self.subs.iter().map(|s| s.as_str()).collect();
        if subs.is_empty() {
            println!("[hub]   subscribers 0");
        } else {
            println!("[hub]   subscribers {} {}", subs.len(), subs.join(","));
        }

        //--- The loop detector. Reported as a rate, not a count, because a
        //--- count tells you nothing about whether it is growing.
        let mut hot: Vec<(&String, f64)> = self
            .by_topic
            .iter()
            .map(|(k, v)| (k, *v as f64 / w))
            .filter(|(_, r)| *r > LOOP_WARN_PER_SEC)
            .collect();
        hot.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        for (k, rate) in hot {
            println!(
                "[hub]   WARNING topic {} is doing {:.0} msg/s - that is not traffic, \
                 it looks like a forwarding LOOP",
                k, rate
            );
        }

        //--- New window: EVERYTHING in this line is per-window, including the
        //--- three headline figures. The run totals live in print_totals().
        //--- Mixing the two - which this used to do - produces a line whose
        //--- own numbers contradict each other.
        self.forwarded = 0;
        self.control = 0;
        self.dropped = 0;
        self.single_dropped = 0;
        self.receipts = 0;
        self.by_topic.clear();
        self.by_type.clear();
        self.control_by_type.clear();
        self.window_start = Instant::now();
    }

    /// The whole run, for the final line.
    ///
    /// Separate from the window on purpose: "what happened in the last 30 s"
    /// and "what has this hub done" are different questions, and answering both
    /// with one number answers neither.
    pub fn print_totals(&self) {
        println!(
            "[hub]   totals    forwarded {}   control {}   dropped {}   single-frame {}   receipts {}",
            self.total_forwarded,
            self.total_control,
            self.total_dropped,
            self.total_single_dropped,
            self.total_receipts
        );
    }
}

fn top(m: &HashMap<String, u64>, n: usize) -> Vec<(String, u64)> {
    let mut v: Vec<(String, u64)> = m.iter().map(|(k, c)| (k.clone(), *c)).collect();
    //--- count desc, then name asc: deterministic output for the same input
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    v.truncate(n);
    v
}

fn join(v: &[(String, u64)]) -> String {
    v.iter()
        .map(|(k, c)| format!("{}:{}", k, c))
        .collect::<Vec<_>>()
        .join("  ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forwarding_is_counted_by_topic_and_type() {
        let mut s = Stats::new();
        s.note_forward("111111", "SNAP");
        s.note_forward("111111", "SNAP");
        s.note_forward("222222", "OPEN");
        assert_eq!(s.forwarded, 3);
        assert_eq!(top(&s.by_topic, 8)[0], ("111111".to_string(), 2));
        assert_eq!(top(&s.by_type, 8)[0], ("SNAP".to_string(), 2));
    }

    #[test]
    fn top_breaks_ties_by_name_so_output_is_stable() {
        let mut s = Stats::new();
        s.note_forward("bbb", "X");
        s.note_forward("aaa", "X");
        let t = top(&s.by_topic, 8);
        assert_eq!(t[0].0, "aaa");
        assert_eq!(t[1].0, "bbb");
    }

    #[test]
    fn a_new_window_clears_the_window_but_not_the_run_totals() {
        let mut s = Stats::new();
        s.note_forward("111111", "SNAP");
        s.note_control("PING");
        assert_eq!(s.forwarded, 1);
        assert_eq!(s.total_forwarded, 1);

        s.print_and_reset();

        //--- the window starts empty again...
        assert_eq!(s.forwarded, 0, "the window counter must reset");
        assert_eq!(s.control, 0, "the window counter must reset");
        assert!(s.by_topic.is_empty(), "the window breakdown must reset");

        //--- ...and the run totals are untouched, so the final line can report
        //--- the whole run rather than the last 30 seconds.
        //
        //--- These were the SAME counters until recently, which made the
        //--- periodic line print a whole-run figure under a "last 30 s" header
        //--- beside per-window breakdowns. The numbers contradicted each other
        //--- in a line whose entire purpose is to be read at a glance.
        assert_eq!(s.total_forwarded, 1, "the run total must survive");
        assert_eq!(s.total_control, 1, "the run total must survive");
    }

    #[test]
    fn the_window_and_the_run_disagree_once_a_second_window_starts() {
        //--- The specific shape of the bug: after two windows, a cumulative
        //--- counter and a per-window breakdown cannot both be right.
        let mut s = Stats::new();
        s.note_forward("111111", "SNAP");
        s.note_forward("111111", "SNAP");
        s.print_and_reset();
        s.note_forward("222222", "OPEN");
        s.print_and_reset();

        assert_eq!(s.total_forwarded, 3, "three messages over the whole run");
        assert_eq!(s.forwarded, 0, "and the last window is already reset");
    }

    #[test]
    fn an_implausible_reg_rate_is_over_the_warn_threshold() {
        //--- REG is a STARTUP message. A settled node sends HBT2, and the only
        //--- legitimate steady REG is one reply per 60s WHO sweep, i.e. ~0.017/s.
        //--- The threshold must clear that with room to spare - otherwise a
        //--- healthy hub with many nodes would cry wolf - and still catch a node
        //--- that has stopped settling, which is ~1/s.
        let legitimate = 1.0 / 60.0;
        assert!(
            legitimate < REG_WARN_PER_SEC,
            "a healthy hub must not warn: the sweep is {:.3}/s, the bar {:.3}/s",
            legitimate,
            REG_WARN_PER_SEC
        );
        //--- The check fires on STRICTLY greater than the bar, so 1.0/s exactly
        //--- sits on the line. Ask the same question the code asks rather than
        //--- restating the constant.
        assert!(
            !(1.0 > REG_WARN_PER_SEC) && (1.5 > REG_WARN_PER_SEC),
            "the bar must sit at 1.0/s: a single node at 1.5/s must trip it"
        );

        //--- And the counter the warning reads must actually be filled.
        let mut s = Stats::new();
        for _ in 0..40 {
            s.note_control("REG");
        }
        assert_eq!(s.control_by_type.get("REG").copied(), Some(40));
    }
}
