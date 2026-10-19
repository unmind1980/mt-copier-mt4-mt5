//! A read-only view of what each sender says it holds (M3).
//!
//! THE ONE RULE THIS MODULE MUST NOT BREAK
//! =======================================
//! The hub forwards data messages BYTE FOR BYTE and that is what makes it
//! structurally incapable of corrupting a trade instruction. This module parses
//! those same bytes, so it is the first thing in the hub that reads a payload
//! rather than moving it - and the boundary has to be explicit:
//!
//!     the parse is READ-ONLY and produces a SEPARATE structure.
//!
//! Nothing here returns a modified frame, nothing here is on the forward path,
//! and the bytes that go out are the bytes that came in. If that ever stops
//! being true, the hub's central safety property stops being true with it.
//!
//! WHY IT PARSES AT ALL
//! ====================
//! M3's position view. An operator needs to see, from the hub, which senders are
//! carrying what - and the hub is the only place that sees every sender. The
//! alternative (asking each EA to report separately) is a second source of truth
//! for something the wire already carries on every snapshot.
//!
//! NO NEW DEPENDENCIES. The hub has exactly one (`zmq`), for reasons that are
//! documented in Cargo.toml and are not negotiable on this machine. So this is
//! hand-rolled byte scanning, in the same style and with the same rules as
//! `envelope.rs`: find the FIRST match rather than parsing properly, and never
//! panic on hostile input.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Records read from one snapshot at most.
///
/// `N=` is a number a hostile peer chooses, and the record list is what actually
/// arrives - so the count is bounded by what is THERE, not by what is claimed.
/// A frame is already capped at 1 MB by `MAXMSGSIZE`, so this is a second,
/// cheaper bound that also keeps the per-frame work predictable.
const MAX_RECORDS: usize = 4096;

/// Distinct symbols kept per sender. A sender quoting more than this is either
/// pathological or hostile; either way the view stays bounded.
const MAX_SYMBOLS: usize = 64;

/// Drop a sender's view once nothing has refreshed it for this long.
///
/// Generous on purpose: a sender that has stopped is worth still seeing, and the
/// registry already reports liveness. This is only here so a hub that runs for
/// weeks does not accumulate a row per sender that ever existed.
pub const POSITIONS_TTL: Duration = Duration::from_secs(600);

/// One position record parsed from a sender's snapshot.
#[derive(Default, Debug, PartialEq, Clone)]
pub struct PositionItem {
    pub ticket: u64,
    pub uid: String,
    pub symbol: String,
    pub side: u8,
    pub lots: f64,
    pub open_px: f64,
    pub sl: f64,
    pub tp: f64,
    pub magic: i64,
    pub open_time: u64,
}

/// What one snapshot said, read-only.
#[derive(Default, Debug, PartialEq, Clone)]
pub struct SnapView {
    /// The `N=` the sender declared, if present. Kept only so a mismatch is visible; the
    /// truth used downstream is `records`, which is what actually arrived.
    pub declared: Option<usize>,
    /// Records actually parsed.
    pub records: usize,
    /// Sum of the LOT column over the records parsed.
    pub lots: f64,
    /// (symbol, count, lots), in first-seen order.
    pub symbols: Vec<(String, usize, f64)>,
    /// The `H=` receipt, so the hub can show which state a sender is at.
    pub receipt: String,
    /// Detailed position records.
    pub items: Vec<PositionItem>,
}

/// One sender's last known book.
#[derive(Debug, Clone)]
pub struct SenderView {
    pub count: usize,
    pub lots: f64,
    pub symbols: Vec<(String, usize, f64)>,
    pub receipt: String,
    pub updated: Instant,
    /// Snapshots seen from this sender, so a view that is one snapshot old can
    /// be told from one that has been steady for an hour.
    pub snaps: u64,
    /// Detailed position records.
    pub items: Vec<PositionItem>,
}

#[derive(Default, Clone)]
pub struct Positions {
    by_sender: HashMap<String, SenderView>,
    /// Snapshots parsed, and those whose `N=` disagreed with what arrived.
    pub parsed: u64,
    pub mismatched: u64,
}

impl Positions {
    pub fn new() -> Self {
        Positions::default()
    }

    /// Fold one snapshot into the view, keyed by the SENDER from the envelope
    /// header - never by the topic.
    ///
    /// The topic would be wrong and quietly so: a targeted repair is published
    /// on the RECEIVER's nid, so keying by topic would file that receiver's
    /// account as a sender holding somebody else's positions.
    pub fn on_snap(&mut self, sid: &str, v: &SnapView, now: Instant) {
        if sid.is_empty() {
            return; // no identity, no row
        }
        self.parsed += 1;
        if let Some(dec) = v.declared {
            if dec != v.records {
                self.mismatched += 1;
            }
        }
        let e = self.by_sender.entry(sid.to_string()).or_insert_with(|| SenderView {
            count: 0,
            lots: 0.0,
            symbols: Vec::new(),
            receipt: String::new(),
            updated: now,
            snaps: 0,
            items: Vec::new(),
        });
        e.count = v.records;
        e.lots = v.lots;
        e.symbols = v.symbols.clone();
        e.receipt = v.receipt.clone();
        e.updated = now;
        e.snaps += 1;
        e.items = v.items.clone();
    }

    /// Forget senders whose view has not been refreshed.
    pub fn evict(&mut self, now: Instant) -> usize {
        let before = self.by_sender.len();
        self.by_sender
            .retain(|_, v| now.duration_since(v.updated) < POSITIONS_TTL);
        before - self.by_sender.len()
    }

    pub fn senders(&self) -> usize {
        self.by_sender.len()
    }

    pub fn total_positions(&self) -> usize {
        self.by_sender.values().map(|v| v.count).sum()
    }

    pub fn total_lots(&self) -> f64 {
        self.by_sender.values().map(|v| v.lots).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.by_sender.is_empty()
    }

    /// Rows for the stats block: busiest senders first, ties broken by name so
    /// the output is stable between runs - a line that reshuffles cannot be
    /// diffed, which is the same rule the rest of the stats follow.
    pub fn top(&self, n: usize) -> Vec<(&str, &SenderView)> {
        let mut v: Vec<(&str, &SenderView)> =
            self.by_sender.iter().map(|(k, s)| (k.as_str(), s)).collect();
        v.sort_by(|a, b| {
            b.1.count
                .cmp(&a.1.count)
                .then_with(|| a.0.cmp(b.0))
        });
        v.truncate(n);
        v
    }

    /// Every sender, ordered by account - for anything a HUMAN reads.
    ///
    /// `top` orders by size, which is right for a capped log line: the
    /// busiest sender is the one worth seeing, and the cap keeps it to eight
    /// rows. It is wrong for a table, because "ordered by a number that
    /// changes every snapshot" IS the bug: two senders swap places the moment
    /// either opens or closes a position, and a row that moves when nothing
    /// about it changed is a row nobody can read.
    ///
    /// So the same data, two orders, and the rule is: a log line wants the
    /// interesting one first, a table wants the one that stays put. Ordering
    /// by account is stable because an account does not change.
    ///
    /// Not capped. `top(8)` exists because eighty lines in a stats window is
    /// noise; a table the caller asked for is not a stats window.
    pub fn sorted(&self) -> Vec<(&str, &SenderView)> {
        let mut v: Vec<(&str, &SenderView)> =
            self.by_sender.iter().map(|(k, s)| (k.as_str(), s)).collect();
        v.sort_by(|a, b| a.0.cmp(b.0));
        v
    }

    /// `EURUSD:3:0.06` - symbol, count, lots. Bounded by MAX_SYMBOLS already.
    pub fn symbol_note(v: &SenderView) -> String {
        v.symbols
            .iter()
            .map(|(s, c, l)| format!("{}:{}:{}", s, c, lots_str(*l)))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// Lots with the trailing zeros trimmed, so a line of them stays readable and
/// two runs that mean the same thing render the same way.
pub fn lots_str(l: f64) -> String {
    let s = format!("{:.2}", l);
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// Read one snapshot payload. Never panics; malformed input yields what could be
/// read and no more.
pub fn parse_snap(payload: &[u8]) -> SnapView {
    let mut v = SnapView::default();

    if let Some((s, e)) = value_span(payload, b"H") {
        v.receipt = latin1(&payload[s..e]);
    }

    if let Some((s, e)) = value_span(payload, b"N") {
        v.declared = Some(parse_usize(&payload[s..e]));
    }

    let (rs, re) = match value_span(payload, b"R") {
        Some(x) => x,
        None => return v, // N=0, or not a snapshot at all
    };
    let body_raw = &payload[rs..re];
    if body_raw.is_empty() {
        return v;
    }
    let body_str = crate::envelope::decompress_field(body_raw);
    let body = body_str.as_bytes();

    let mut order: Vec<String> = Vec::new();
    for rec in body.split(|b| *b == b'~') {
        if v.records >= MAX_RECORDS {
            break;
        }
        let sym = latin1(rec_field(rec, 2));
        if sym.is_empty() {
            continue; // a record without a symbol is not a position
        }
        let uid = latin1(rec_field(rec, 0));
        let ticket = parse_u64(rec_field(rec, 1));
        let side = parse_u8(rec_field(rec, 3));
        let lots = parse_f64(rec_field(rec, 4));
        let open_px = parse_f64(rec_field(rec, 5));
        let sl = parse_f64(rec_field(rec, 6));
        let tp = parse_f64(rec_field(rec, 7));
        let magic = parse_i64(rec_field(rec, 8));
        let open_time = parse_u64(rec_field(rec, 9));

        v.records += 1;
        v.lots += lots;
        v.items.push(PositionItem {
            ticket,
            uid,
            symbol: sym.clone(),
            side,
            lots,
            open_px,
            sl,
            tp,
            magic,
            open_time,
        });

        if let Some(slot) = v.symbols.iter_mut().find(|(s, _, _)| *s == sym) {
            slot.1 += 1;
            slot.2 += lots;
        } else if v.symbols.len() < MAX_SYMBOLS {
            order.push(sym.clone());
            v.symbols.push((sym, 1, lots));
        }
        // past MAX_SYMBOLS the record still counts toward records/lots - only
        // the per-symbol breakdown is capped, so the totals stay honest.
    }
    v
}

/// The value span of `key=` in a `;`-separated payload.
///
/// `key` must start the payload or follow a `;`, which is the same rule the EA
/// side uses and the reason `OTS` cannot be found inside `LOTS`. Getting this
/// wrong is silent: it would report a position count read out of some other
/// field's text.
fn value_span(p: &[u8], key: &[u8]) -> Option<(usize, usize)> {
    if key.is_empty() {
        return None;
    }
    let mut i = 0usize;
    while i < p.len() {
        if i == 0 || p[i - 1] == b';' {
            let after = i + key.len();
            if p.len() > after && p[i..].starts_with(key) && p[after] == b'=' {
                let start = after + 1;
                let mut j = start;
                while j < p.len() && p[j] != b';' {
                    j += 1;
                }
                return Some((start, j));
            }
        }
        i += 1;
    }
    None
}

/// The `idx`-th `,`-separated field of one record, or empty.
fn rec_field(rec: &[u8], idx: usize) -> &[u8] {
    let mut n = 0usize;
    let mut start = 0usize;
    let mut i = 0usize;
    while i <= rec.len() {
        if i == rec.len() || rec[i] == b',' {
            if n == idx {
                return &rec[start..i];
            }
            n += 1;
            start = i + 1;
        }
        i += 1;
    }
    &[]
}

fn parse_usize(b: &[u8]) -> usize {
    let mut n: usize = 0;
    for c in b {
        if !c.is_ascii_digit() {
            return n;
        }
        n = n.saturating_mul(10).saturating_add((c - b'0') as usize);
    }
    n
}

fn parse_u64(b: &[u8]) -> u64 {
    let mut n: u64 = 0;
    for c in b {
        if !c.is_ascii_digit() {
            return n;
        }
        n = n.saturating_mul(10).saturating_add((c - b'0') as u64);
    }
    n
}

fn parse_i64(b: &[u8]) -> i64 {
    std::str::from_utf8(b).ok().and_then(|s| s.parse().ok()).unwrap_or(0)
}

fn parse_u8(b: &[u8]) -> u8 {
    parse_usize(b) as u8
}

fn parse_f64(b: &[u8]) -> f64 {
    // Only the ASCII of a number is accepted; anything else is 0.0 rather than
    // an error, because a single bad field must not discard the whole snapshot.
    if b.is_empty() || b.len() > 32 {
        return 0.0;
    }
    if !b.iter().all(|c| c.is_ascii_digit() || *c == b'.' || *c == b'-' || *c == b'+') {
        return 0.0;
    }
    std::str::from_utf8(b).ok().and_then(|s| s.parse().ok()).unwrap_or(0.0)
}

/// Bytes as text for display. The wire is ASCII by construction, but a hostile
/// peer is not, and nothing here may panic on it.
fn latin1(b: &[u8]) -> String {
    b.iter().map(|c| *c as char).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(recs: &[&str]) -> Vec<u8> {
        let mut p = format!("N={}", recs.len());
        if !recs.is_empty() {
            p.push_str(";R=");
            p.push_str(&recs.join("~"));
        }
        p.push_str(";H=a1b2c3d4");
        p.into_bytes()
    }

    /// A 10-field market record, exactly as the wire writes it:
    /// `UID,TICKET,SYMBOL,SIDE,LOTS,OPENPX,SL,TP,MAGIC,OPENTIME` - no spaces.
    fn rec(uid: &str, sym: &str, side: i32, lots: &str) -> String {
        format!(
            "{},9918271,{},{},{},1.08450000,1.08000000,1.09000000,0,1780000000",
            uid, sym, side, lots
        )
    }

    #[test]
    fn reads_count_lots_symbols_and_receipt() {
        let p = snap(&[
            &rec("AAAA", "EURUSD", 1, "0.50000000"),
            &rec("BBBB", "EURUSD", -1, "0.10000000"),
            &rec("CCCC", "XAUUSD", 1, "0.02000000"),
        ]);
        let v = parse_snap(&p);
        assert_eq!(v.declared, Some(3));
        assert_eq!(v.records, 3);
        assert!((v.lots - 0.62).abs() < 1e-9, "{}", v.lots);
        assert_eq!(v.receipt, "a1b2c3d4");
        let eur = v.symbols.iter().find(|(s, _, _)| s == "EURUSD").unwrap();
        assert_eq!(eur.1, 2);
        assert!((eur.2 - 0.6).abs() < 1e-9);
    }

    #[test]
    fn an_empty_account_is_not_an_error() {
        let v = parse_snap(b"N=0;H=a1b2c3d4");
        assert_eq!(v.declared, Some(0));
        assert_eq!(v.records, 0);
        assert_eq!(v.lots, 0.0);
        assert!(v.symbols.is_empty());
        assert_eq!(v.receipt, "a1b2c3d4");
    }

    #[test]
    fn the_declared_count_is_not_trusted() {
        // N= says 99, one record arrives. records is what actually came.
        let p = format!("N=99;R={};H=x", rec("AAAA", "EURUSD", 1, "0.01"));
        let v = parse_snap(p.as_bytes());
        assert_eq!(v.declared, Some(99));
        assert_eq!(v.records, 1);
    }

    #[test]
    fn absent_n_is_not_a_mismatch() {
        let p = format!("R={};H=x", rec("AAAA", "EURUSD", 1, "0.01"));
        let v = parse_snap(p.as_bytes());
        assert_eq!(v.declared, None);
        assert_eq!(v.records, 1);
        let mut pos = Positions::new();
        pos.on_snap("1", &v, Instant::now());
        assert_eq!(pos.mismatched, 0);
    }

    #[test]
    fn a_pending_record_with_fifteen_fields_still_reads() {
        // the last five fields are appended only for a pending entry
        let r = format!(
            "{},{},{},{},{},{}",
            rec("AAAA", "EURUSD", 1, "0.25"),
            "0",
            "1",
            "1.1",
            "0",
            "0"
        );
        let v = parse_snap(&snap(&[&r]));
        assert_eq!(v.records, 1);
        assert!((v.lots - 0.25).abs() < 1e-9);
        assert_eq!(v.symbols[0].0, "EURUSD");
    }

    #[test]
    fn h_is_not_read_out_of_a_symbol_that_contains_it() {
        // 'H' as a suffix of another key is the OTS-inside-LOTS trap again
        let v = parse_snap(b"N=0;WIDTH=zzz;H=deadbeef");
        assert_eq!(v.receipt, "deadbeef");
    }

    #[test]
    fn a_record_without_a_symbol_is_skipped_not_counted() {
        // field 2 is the symbol; empty there means this is not a position
        let v = parse_snap(b"N=1;R=AAAA,9918271,,1,0.5;H=x");
        assert_eq!(v.records, 0);
        assert_eq!(v.lots, 0.0);
    }

    #[test]
    fn hostile_input_does_not_panic() {
        let cases: Vec<Vec<u8>> = vec![
            b"".to_vec(),
            b"N".to_vec(),
            b"N=".to_vec(),
            b"N=;R=".to_vec(),
            b"R=~".to_vec(),
            b"N=1;R=~~~~~~~~~~".to_vec(),
            b"N=1;R=".to_vec(),
            b"N=1;R=a,b,c".to_vec(),
            vec![0xff, 0xfe, b';', b'R', b'=', 0x00],
            b"N=999999999999999999999999;R=x".to_vec(),
            b"N=1;R=AAAA,1,EURUSD,1,not-a-number,0,0,0,0,0".to_vec(),
        ];
        for c in cases {
            let v = parse_snap(&c); // must not panic
            assert!(v.records <= MAX_RECORDS);
        }
    }

    #[test]
    fn the_record_count_is_capped() {
        let one = rec("AAAA", "EURUSD", 1, "0.01");
        let many: Vec<String> = (0..(MAX_RECORDS + 50)).map(|_| one.clone()).collect();
        let refs: Vec<&str> = many.iter().map(|s| s.as_str()).collect();
        let v = parse_snap(&snap(&refs));
        assert_eq!(v.records, MAX_RECORDS);
    }

    #[test]
    fn the_symbol_breakdown_is_capped_but_the_totals_are_not() {
        let many: Vec<String> = (0..(MAX_SYMBOLS + 20))
            .map(|i| rec("AAAA", &format!("S{:03}", i), 1, "0.01"))
            .collect();
        let refs: Vec<&str> = many.iter().map(|s| s.as_str()).collect();
        let v = parse_snap(&snap(&refs));
        assert_eq!(v.symbols.len(), MAX_SYMBOLS);
        assert_eq!(v.records, MAX_SYMBOLS + 20, "totals must stay honest");
    }

    #[test]
    fn the_view_is_keyed_by_sid_not_by_topic() {
        let mut p = Positions::new();
        let now = Instant::now();
        let v = parse_snap(&snap(&[&rec("AAAA", "EURUSD", 1, "0.5")]));
        // a broadcast arrives on the sender's nid...
        p.on_snap("252033316", &v, now);
        // ...and a targeted repair on the RECEIVER's nid. Both carry the same
        // SID, so both land on the same row - and no receiver ever appears as a
        // sender holding somebody else's book.
        p.on_snap("252033316", &v, now);
        assert_eq!(p.senders(), 1);
        assert_eq!(p.total_positions(), 1);
        assert_eq!(p.by_sender["252033316"].snaps, 2);
    }

    #[test]
    fn a_snapshot_with_no_identity_is_ignored() {
        let mut p = Positions::new();
        let v = parse_snap(&snap(&[&rec("AAAA", "EURUSD", 1, "0.5")]));
        p.on_snap("", &v, Instant::now());
        assert_eq!(p.senders(), 0);
    }

    #[test]
    fn a_newer_snapshot_replaces_the_old_one() {
        let mut p = Positions::new();
        let now = Instant::now();
        p.on_snap("A", &parse_snap(&snap(&[&rec("U1", "EURUSD", 1, "0.5")])), now);
        assert_eq!(p.total_positions(), 1);
        p.on_snap("A", &parse_snap(&snap(&[])), now); // the position closed
        assert_eq!(p.total_positions(), 0);
        assert_eq!(p.senders(), 1, "the sender row stays, its book is empty");
    }

    #[test]
    fn eviction_is_by_age() {
        let mut p = Positions::new();
        let now = Instant::now();
        p.on_snap("A", &parse_snap(&snap(&[])), now);
        assert_eq!(p.evict(now), 0);
        assert_eq!(p.evict(now + POSITIONS_TTL + Duration::from_secs(1)), 1);
        assert_eq!(p.senders(), 0);
    }

    #[test]
    fn top_is_ordered_by_count_then_name() {
        let mut p = Positions::new();
        let now = Instant::now();
        let one = snap(&[&rec("U1", "EURUSD", 1, "0.1")]);
        let two = snap(&[&rec("U1", "EURUSD", 1, "0.1"), &rec("U2", "EURUSD", 1, "0.1")]);
        p.on_snap("bbb", &parse_snap(&one), now);
        p.on_snap("aaa", &parse_snap(&two), now);
        p.on_snap("ccc", &parse_snap(&one), now);
        let t = p.top(8);
        assert_eq!(t[0].0, "aaa");
        // the two one-position senders tie, so the name decides - and it is
        // stable, which is what makes the line diffable
        assert_eq!(t[1].0, "bbb");
        assert_eq!(t[2].0, "ccc");
    }
}
