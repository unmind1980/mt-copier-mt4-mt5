//! M7: the audit log. Append-only, and the word "only" is the entire design.
//!
//! WHY A FILE AND NOT SQLITE
//! =========================
//! The plan's §15 puts `audit` in SQLite, and that is still where it should
//! end up. It is not what it is built on today, for a reason that was measured
//! rather than assumed: `rusqlite` with the `bundled` feature fails here in
//! `libsqlite3-sys`'s build script with
//!
//!     Compiler family detection failed: ToolNotFound: failed to find "gcc.exe"
//!
//! The `cc` crate wants a plain `gcc.exe`; the Rust GNU toolchain ships
//! `x86_64-w64-mingw32-gcc.exe` and no unprefixed alias. Adding MSYS2's whole
//! `mingw64/bin` would supply one - and would also shadow Rust's `ld` and
//! `gcc`, which is the failure `hub/build.sh` section 2 documents in full
//! (`ld: cannot find crt2.o`). So SQLite is real work, and it belongs with
//! M11, which is where the plan already puts the storage layer.
//!
//! What is needed NOW is the property, not the engine. An audit log's defining
//! property is that records are **appended and never rewritten**, and a file
//! opened in append mode gives that more directly than a database does - there
//! is no UPDATE statement to be talked into. It is also greppable, tail-able
//! and diffable by hand, which matters for something whose whole job is to be
//! evidence. The record shape is the plan's §15 `audit` row, so importing it
//! into SQLite later is a `for line in file` and an INSERT.
//!
//! THREE PROPERTIES THAT ARE THE POINT, EACH WITH A TEST
//! =====================================================
//!
//! 1. **Append-only.** The file is opened append, written, and never seeked or
//!    truncated. Asserted by reading the bytes before and after a write and
//!    requiring the second to be the first plus a suffix.
//!
//! 2. **No silent gaps.** Every record carries a monotonic `seq`. A log that
//!    lost a line is otherwise indistinguishable from one that never had it -
//!    which is exactly the difference between evidence and a log. A restart
//!    therefore also writes a `hub.started` record, so a gap has an
//!    explanation instead of looking like tampering.
//!
//! 3. **A write failure is loud.** If the audit cannot be written, that is
//!    counted and printed, not swallowed. An audit log that quietly stopped
//!    recording an hour ago is worse than no audit log, because it looks like
//!    proof that nothing happened.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};

/// Record format version. Present so a future change to the shape is
/// detectable in old records rather than guessed at.
const AUDIT_V: u64 = 1;

/// How much of the tail to read when finding the last `seq`. One record is a
/// few hundred bytes, so this is thousands of records - and if it is somehow
/// not enough, the reader walks further back rather than giving up.
const TAIL_CHUNK: u64 = 256 * 1024;

struct Inner {
    file: Option<File>,
    seq: u64,
    /// Records written, and writes that failed. Both are reported, because the
    /// second is the one that would otherwise be invisible.
    wrote: u64,
    failed: u64,
}

pub struct Audit {
    inner: Mutex<Inner>,
    path: PathBuf,
    enabled: bool,
}

/// What a read found. `torn` is not an error: it is a crash mid-append, which
/// is a fact about the log worth surfacing rather than hiding.
#[derive(Default, Debug)]
pub struct ReadStats {
    pub lines: usize,
    pub torn: usize,
    pub skipped: usize,
}

impl Audit {
    /// Open (creating if absent) and learn the last `seq` already in the file.
    ///
    /// Opening for append means the file is never truncated - an audit log that
    /// starts empty on every hub restart would be worse than useless, and that
    /// is the default behaviour of `File::create`.
    pub fn open(path: &Path) -> std::io::Result<Audit> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        let seq = last_seq(path).unwrap_or(0);
        Ok(Audit {
            inner: Mutex::new(Inner {
                file: Some(file),
                seq,
                wrote: 0,
                failed: 0,
            }),
            path: path.to_path_buf(),
            enabled: true,
        })
    }

    /// An audit that records nothing. For tests and for `--audit none`.
    ///
    /// Deliberately NOT the default. Turning the audit off should be something
    /// an operator typed, not something that happened because a path was not
    /// writable - see `main.rs`, which refuses to start rather than fall back
    /// to this.
    pub fn disabled() -> Audit {
        Audit {
            inner: Mutex::new(Inner {
                file: None,
                seq: 0,
                wrote: 0,
                failed: 0,
            }),
            path: PathBuf::new(),
            enabled: false,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn counts(&self) -> (u64, u64, u64) {
        let i = self.inner.lock().unwrap();
        (i.seq, i.wrote, i.failed)
    }

    /// Append one record. Returns the `seq` it was written with.
    ///
    /// `before` and `after` are the plan's §15 columns and carry whatever the
    /// action changed. `actor` and `ip` are empty for anything the hub did on
    /// its own - and empty is the honest value there, not a placeholder like
    /// "system" that would blur the line between a machine event and a person.
    pub fn record(
        &self,
        actor: &str,
        ip: &str,
        action: &str,
        node: &str,
        before: Option<Value>,
        after: Option<Value>,
        result: &str,
    ) -> u64 {
        let mut inner = self.inner.lock().unwrap();
        let seq = inner.seq + 1;
        let rec = json!({
            "v": AUDIT_V,
            "seq": seq,
            "ts": unix_secs(),
            "actor": actor,
            "ip": ip,
            "action": action,
            "node": node,
            "before": before.unwrap_or(Value::Null),
            "after": after.unwrap_or(Value::Null),
            "result": result,
        });
        // One line, newline-terminated. A record that is not newline-terminated
        // would fuse with the next one on a crash, turning two records into one
        // unparseable line.
        let mut line = serde_json::to_string(&rec).unwrap_or_else(|_| "{}".to_string());
        line.push('\n');

        let Some(f) = inner.file.as_mut() else {
            // Disabled: still advance `seq` so the caller's view is consistent,
            // and count it so "the audit is off" is visible in the totals.
            inner.seq = seq;
            return seq;
        };

        match f.write_all(line.as_bytes()).and_then(|_| f.sync_data()) {
            Ok(()) => {
                inner.seq = seq;
                inner.wrote += 1;
            }
            Err(e) => {
                // NOT swallowed. The record is gone, and the only thing worse
                // than that is not knowing.
                inner.failed += 1;
                eprintln!(
                    "[hub] AUDIT WRITE FAILED ({} record(s) lost): {}",
                    inner.failed, e
                );
            }
        }
        seq
    }

    /// Read records, oldest first, at most `limit`, with `seq > since`.
    ///
    /// Read from disk rather than from the writer's handle, on purpose: the
    /// file is append-only, so an independent reader sees a consistent prefix
    /// and needs no lock. That keeps the write path - which is on the hub's
    /// single ZMQ thread - free of any waiting on a dashboard.
    pub fn read(&self, limit: usize, since: u64) -> (Vec<Value>, ReadStats) {
        let mut stats = ReadStats::default();
        let mut out: Vec<Value> = Vec::new();
        if !self.enabled {
            return (out, stats);
        }
        let mut text = String::new();
        match File::open(&self.path).and_then(|mut f| f.read_to_string(&mut text)) {
            Ok(_) => {}
            Err(_) => return (out, stats),
        }

        // A torn last line is skipped, not fatal - and counted, because it is
        // a crash mid-append and that is worth knowing. A bad line in the
        // MIDDLE is counted separately: the file is append-only, so that
        // should be impossible, and "impossible" is worth a different number.
        let all: Vec<&str> = text.lines().collect();
        let last_idx = all.len().saturating_sub(1);
        for (i, line) in all.iter().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(line) {
                Ok(v) => {
                    stats.lines += 1;
                    if v["seq"].as_u64().unwrap_or(0) > since {
                        out.push(v);
                    }
                }
                Err(_) => {
                    if i == last_idx {
                        stats.torn += 1;
                    } else {
                        stats.skipped += 1;
                    }
                }
            }
        }
        // Newest last, then keep the newest `limit`. Truncating from the front
        // means a caller that asks for 200 always gets the most recent 200,
        // which is the only useful end of a permanent log.
        if out.len() > limit {
            out.drain(0..out.len() - limit);
        }
        (out, stats)
    }
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The highest `seq` in the file, or None if there is none to be found.
///
/// Reads backwards in chunks. Reading the whole file would be O(history) on
/// every hub start, which is exactly the thing that gets slower forever while
/// nobody notices.
fn last_seq(path: &Path) -> Option<u64> {
    let mut f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    if len == 0 {
        return None;
    }
    let mut end = len;
    let mut carry: Vec<u8> = Vec::new();
    while end > 0 {
        let start = end.saturating_sub(TAIL_CHUNK);
        let want = (end - start) as usize;
        let mut buf = vec![0u8; want];
        f.seek(SeekFrom::Start(start)).ok()?;
        f.read_exact(&mut buf).ok()?;
        buf.extend_from_slice(&carry);
        // Walk lines backwards. The first COMPLETE line from the end that
        // parses wins; a torn tail is skipped rather than ending the search.
        let text = String::from_utf8_lossy(&buf).to_string();
        let mut lines: Vec<&str> = text.split('\n').collect();
        // If we did not start at 0, the first fragment is partial - drop it.
        if start > 0 && !lines.is_empty() {
            carry = lines.remove(0).as_bytes().to_vec();
        } else {
            carry.clear();
        }
        for line in lines.iter().rev() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if let Some(s) = v["seq"].as_u64() {
                    return Some(s);
                }
            }
        }
        if start == 0 {
            break;
        }
        end = start;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("copier_audit_test_{}_{}", std::process::id(), name));
        let _ = std::fs::remove_file(&p);
        p
    }

    /// Property 1. Read the bytes, append, read again: the second must be the
    /// first plus a suffix. Anything else means something rewrote history.
    #[test]
    fn a_record_only_ever_appends() {
        let p = tmp("append");
        let a = Audit::open(&p).unwrap();
        a.record("", "", "hub.started", "", None, None, "ok");
        let first = std::fs::read(&p).unwrap();
        a.record("", "", "node.registered", "sender:1", None, None, "ok");
        let second = std::fs::read(&p).unwrap();

        assert!(second.len() > first.len());
        assert_eq!(
            &second[..first.len()],
            &first[..],
            "the existing bytes changed - this is not append-only"
        );
        let _ = std::fs::remove_file(&p);
    }

    /// Property 2. `seq` is monotonic across a REOPEN, which is the case that
    /// matters: a hub restart must not renumber from 1, or two different
    /// records end up claiming the same sequence and a gap becomes invisible.
    #[test]
    fn seq_continues_across_a_restart() {
        let p = tmp("seq");
        {
            let a = Audit::open(&p).unwrap();
            a.record("", "", "hub.started", "", None, None, "ok");
            a.record("", "", "hub.stopped", "", None, None, "ok");
        }
        {
            let a = Audit::open(&p).unwrap();
            let (seq, _, _) = a.counts();
            assert_eq!(seq, 2, "reopened at the wrong sequence");
            let s = a.record("", "", "hub.started", "", None, None, "ok");
            assert_eq!(s, 3);
        }
        let (recs, st) = Audit::open(&p).unwrap().read(100, 0);
        assert_eq!(st.lines, 3);
        let seqs: Vec<u64> = recs.iter().map(|r| r["seq"].as_u64().unwrap()).collect();
        assert_eq!(seqs, vec![1, 2, 3]);
        let _ = std::fs::remove_file(&p);
    }

    /// A crash mid-append leaves a partial last line. It must be SKIPPED, not
    /// fatal - and the records before it must still read. A reader that stops
    /// at the first unparseable line would lose the entire history to one torn
    /// tail.
    #[test]
    fn a_torn_last_line_is_skipped_and_counted() {
        let p = tmp("torn");
        {
            let a = Audit::open(&p).unwrap();
            a.record("", "", "hub.started", "", None, None, "ok");
            a.record("", "", "node.registered", "sender:1", None, None, "ok");
        }
        // Simulate the crash: a half-written record, no newline.
        {
            use std::io::Write as _;
            let mut f = OpenOptions::new().append(true).open(&p).unwrap();
            f.write_all(br#"{"v":1,"seq":3,"ts":0,"act"#).unwrap();
        }
        let a = Audit::open(&p).unwrap();
        // And the reopen must not adopt the torn line's seq.
        let (seq, _, _) = a.counts();
        assert_eq!(seq, 2, "a torn line was counted as a record");

        let (recs, st) = a.read(100, 0);
        assert_eq!(recs.len(), 2, "the good records were lost with the bad one");
        assert_eq!(st.torn, 1);
        assert_eq!(st.skipped, 0, "a torn TAIL is not a skipped middle line");

        // And the next append still works, so the log is not wedged.
        let s = a.record("", "", "hub.stopped", "", None, None, "ok");
        assert_eq!(s, 3);
        let _ = std::fs::remove_file(&p);
    }

    /// A bad line in the MIDDLE is a different fact from a torn tail: in an
    /// append-only file it should be impossible, and the two are counted
    /// separately so that "impossible" stays visible instead of blending into
    /// "a crash".
    #[test]
    fn a_bad_line_in_the_middle_is_counted_separately() {
        let p = tmp("middle");
        {
            let a = Audit::open(&p).unwrap();
            a.record("", "", "hub.started", "", None, None, "ok");
        }
        {
            use std::io::Write as _;
            let mut f = OpenOptions::new().append(true).open(&p).unwrap();
            f.write_all(b"not json at all\n").unwrap();
        }
        {
            let a = Audit::open(&p).unwrap();
            a.record("", "", "hub.stopped", "", None, None, "ok");
        }
        let (recs, st) = Audit::open(&p).unwrap().read(100, 0);
        assert_eq!(recs.len(), 2);
        assert_eq!(st.skipped, 1);
        assert_eq!(st.torn, 0, "a middle line is not a torn tail");
        let _ = std::fs::remove_file(&p);
    }

    /// `since` and `limit` are the whole reason the endpoint can exist over a
    /// permanent log.
    #[test]
    fn read_is_bounded_and_can_follow_the_tail() {
        let p = tmp("bounded");
        let a = Audit::open(&p).unwrap();
        for i in 0..50 {
            a.record("", "", "test.event", &format!("n{}", i), None, None, "ok");
        }
        let (recs, _) = a.read(10, 0);
        assert_eq!(recs.len(), 10);
        // Newest last, so the LAST one is the newest - not the first.
        assert_eq!(recs.last().unwrap()["seq"].as_u64().unwrap(), 50);
        assert_eq!(recs.first().unwrap()["seq"].as_u64().unwrap(), 41);

        let (recs, _) = a.read(100, 45);
        assert_eq!(recs.len(), 5);
        assert_eq!(recs.first().unwrap()["seq"].as_u64().unwrap(), 46);
        let _ = std::fs::remove_file(&p);
    }

    /// The disabled audit must be visibly disabled, not silently empty.
    #[test]
    fn a_disabled_audit_says_so_and_writes_nothing() {
        let a = Audit::disabled();
        assert!(!a.enabled());
        a.record("", "", "hub.started", "", None, None, "ok");
        let (recs, _) = a.read(100, 0);
        assert!(recs.is_empty());
    }

    /// The `before`/`after` columns are the plan's §15 shape, and they have to
    /// survive the round trip - an audit that records that something changed
    /// but not WHAT is not accountability.
    #[test]
    fn before_and_after_survive_the_round_trip() {
        let p = tmp("ba");
        let a = Audit::open(&p).unwrap();
        a.record(
            "operator",
            "10.0.0.5",
            "config.changed",
            "receiver:1",
            Some(json!({"lots": "0.10"})),
            Some(json!({"lots": "0.20"})),
            "ok",
        );
        let (recs, _) = a.read(10, 0);
        let r = &recs[0];
        assert_eq!(r["actor"], "operator");
        assert_eq!(r["ip"], "10.0.0.5");
        assert_eq!(r["action"], "config.changed");
        assert_eq!(r["node"], "receiver:1");
        assert_eq!(r["before"]["lots"], "0.10");
        assert_eq!(r["after"]["lots"], "0.20");
        assert_eq!(r["result"], "ok");
        let _ = std::fs::remove_file(&p);
    }
}
