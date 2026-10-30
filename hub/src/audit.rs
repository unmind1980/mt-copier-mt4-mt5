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

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use flate2::read::GzDecoder;
use crate::lockx::LockExt;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde_json::{json, Value};

/// Record format version. Present so a future change to the shape is
/// detectable in old records rather than guessed at.
pub const AUDIT_V: u64 = 1;

/// Default threshold for audit log rotation: 10 MB.
pub const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Default maximum number of compressed archives (.jsonl.gz) to retain: 10 copies.
pub const DEFAULT_MAX_BACKUPS: usize = 10;

/// How much of the tail to read when finding the last `seq`. One record is a
/// few hundred bytes, so this is thousands of records - and if it is somehow
/// not enough, the reader walks further back rather than giving up.
const TAIL_CHUNK: u64 = 256 * 1024;

struct Inner {
    file: Option<File>,
    current_size: u64,
    seq: u64,
    /// Records written, and writes that failed. Both are reported, because the
    /// second is the one that would otherwise be invisible.
    wrote: u64,
    failed: u64,
    rotations: u64,
}

pub struct Audit {
    inner: Mutex<Inner>,
    /// The slow half of a rotation (gzip + archive shift). Kept here, not in
    /// `Inner`, so a background thread can clone it and run outside the
    /// writer lock — see `ArchiveShift`.
    shifter: ArchiveShift,
    path: PathBuf,
    max_bytes: u64,
    max_backups: usize,
    enabled: bool,
}

/// The slow half of a rotation: gzip the just-renamed file and shift the
/// numbered archives.
///
/// This is a struct of its own, separate from the writer state, because the
/// split IS the design: `record()` releases the writer lock the moment the
/// swap (rename + reopen, microseconds) completes, and gzipping 10 MB of
/// audit while holding that lock would stall every `record()` — including the
/// ones the hub's ZMQ thread makes — for hundreds of milliseconds.
///
/// The internal `lock` serializes shifts against each other: a manual
/// `rotate()` completing in one thread and a background completion in another
/// would otherwise interleave their renames of `.1.gz`/`.2.gz`. It is a
/// different mutex from the writer's, and never held by the fast path.
#[derive(Clone)]
struct ArchiveShift {
    path: PathBuf,
    max_backups: usize,
    lock: Arc<Mutex<()>>,
    active_worker: Arc<Mutex<Option<std::thread::JoinHandle<()>>>>,
}

impl ArchiveShift {
    /// Path to a numbered compressed archive, e.g. `audit.jsonl.1.gz`.
    fn archive_path(&self, idx: usize) -> PathBuf {
        PathBuf::from(format!("{}.{}.gz", self.path.display(), idx))
    }

    /// gzip `rotating` into place as `.1.gz`, shifting older archives up one
    /// and pruning past `max_backups`. Deletes the uncompressed scratch file
    /// either way. The writer's active file is untouched by all of this.
    fn finish(&self, rotating: &Path, file_len: u64) -> io::Result<()> {
        let _serial = self.lock.lock_or_recover();

        let is_already_gz = rotating.to_string_lossy().contains(".gz.tmp.");
        let gz_tmp = if is_already_gz {
            // BUG-04 & N80-03: If rotating is already a .gz.tmp file from an interrupted rotation,
            // verify it is fully valid Gzip by decoding all the way to EOF (ensuring CRC/footer are intact).
            let is_valid = (|| -> bool {
                let src = match File::open(rotating) {
                    Ok(f) => f,
                    Err(_) => return false,
                };
                let mut decoder = GzDecoder::new(BufReader::new(src));
                let mut sink = std::io::sink();
                io::copy(&mut decoder, &mut sink).is_ok()
            })();

            if !is_valid {
                eprintln!("[hub] AUDIT RECOVER: corrupted or truncated .gz.tmp leftover {}; discarding", rotating.display());
                let _ = fs::remove_file(rotating);
                return Ok(());
            }
            rotating.to_path_buf()
        } else {
            // 4. Compress the scratch file into a temporary .gz
            let gz = PathBuf::from(format!(
                "{}.gz.tmp.{}",
                rotating.display(),
                std::process::id()
            ));
            let _ = fs::remove_file(&gz);

            let compress_res = (|| -> io::Result<()> {
                let src = File::open(rotating)?;
                let mut reader = BufReader::new(src);
                let dst = File::create(&gz)?;
                let writer = BufWriter::new(dst);
                let mut encoder = GzEncoder::new(writer, Compression::default());
                io::copy(&mut reader, &mut encoder)?;
                encoder.finish()?;
                Ok(())
            })();

            if let Err(e) = compress_res {
                eprintln!("[hub] AUDIT ROTATE: compression failed: {}", e);
                let _ = fs::remove_file(&gz);
                // The scratch file stays: its records are still on disk and the
                // next start-up finishes the shift (see open_with_rotation).
                return Err(e);
            }

            // The uncompressed scratch has been safely copied into the .gz tmp.
            let _ = fs::remove_file(rotating);
            gz
        };

        // 5. Shift existing archives up (.9.gz -> .10.gz), prune, then land
        // the new one at .1.gz.
        if self.max_backups > 0 {
            let oldest = self.archive_path(self.max_backups);
            let _ = fs::remove_file(&oldest);

            for extra in (self.max_backups + 1)..=(self.max_backups + 5) {
                let _ = fs::remove_file(self.archive_path(extra));
            }

            for idx in (1..self.max_backups).rev() {
                let from = self.archive_path(idx);
                let to = self.archive_path(idx + 1);
                if from.exists() {
                    let _ = fs::rename(&from, &to);
                }
            }

            let target = self.archive_path(1);
            let _ = fs::rename(&gz_tmp, &target);
        } else {
            let _ = fs::remove_file(&gz_tmp);
        }

        println!(
            "[hub] audit log rotated: {} bytes archived to {}",
            file_len,
            self.archive_path(1).display()
        );

        Ok(())
    }
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
        Self::open_with_rotation(path, DEFAULT_MAX_BYTES, DEFAULT_MAX_BACKUPS)
    }

    /// Open with custom size rotation threshold and max compressed archive count.
    pub fn open_with_rotation(
        path: &Path,
        max_bytes: u64,
        max_backups: usize,
    ) -> std::io::Result<Audit> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        let current_size = file.metadata().map(|m| m.len()).unwrap_or(0);
        let shifter = ArchiveShift {
            path: path.to_path_buf(),
            max_backups,
            lock: Arc::new(Mutex::new(())),
            active_worker: Arc::new(Mutex::new(None)),
        };

        // A hub that died between the swap and the archive leaves a
        // `<name>.rotating.<oldpid>` scratch file behind. Finish that
        // rotation NOW: gzip it into `.1.gz` and the `last_seq` below
        // recovers the sequence from the archive. Without this, a crash in
        // that window would restart the log at an OLD sequence — later
        // records reusing numbers the log already spent, which is exactly the
        // gap-masking this module exists to prevent.
        for leftover in leftover_rotations(path) {
            let len = fs::metadata(&leftover).map(|m| m.len()).unwrap_or(0);
            if len > 0 {
                if let Err(e) = shifter.finish(&leftover, len) {
                    eprintln!(
                        "[hub] AUDIT: could not archive a leftover rotation {}: {}",
                        leftover.display(),
                        e
                    );
                }
            } else {
                let _ = fs::remove_file(&leftover);
            }
        }

        let seq = last_seq(path, max_backups).unwrap_or(0);
        Ok(Audit {
            inner: Mutex::new(Inner {
                file: Some(file),
                current_size,
                seq,
                wrote: 0,
                failed: 0,
                rotations: 0,
            }),
            shifter,
            path: path.to_path_buf(),
            max_bytes,
            max_backups,
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
                current_size: 0,
                seq: 0,
                wrote: 0,
                failed: 0,
                rotations: 0,
            }),
            shifter: ArchiveShift {
                path: PathBuf::new(),
                max_backups: DEFAULT_MAX_BACKUPS,
                lock: Arc::new(Mutex::new(())),
                active_worker: Arc::new(Mutex::new(None)),
            },
            path: PathBuf::new(),
            max_bytes: DEFAULT_MAX_BYTES,
            max_backups: DEFAULT_MAX_BACKUPS,
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
        let i = self.inner.lock_or_recover();
        (i.seq, i.wrote, i.failed)
    }

    pub fn rotations(&self) -> u64 {
        self.inner.lock_or_recover().rotations
    }

    #[allow(dead_code)]
    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }

    #[allow(dead_code)]
    pub fn max_backups(&self) -> usize {
        self.max_backups
    }

    /// Wait for any in-flight background rotation/compression to finish.
    #[allow(dead_code)]
    pub fn wait_for_rotation(&self) {
        let handle = {
            let mut worker = self.shifter.active_worker.lock_or_recover();
            worker.take()
        };
        if let Some(h) = handle {
            let _ = h.join();
        }
    }

    /// Path to a numbered compressed archive: e.g. `audit.jsonl.1.gz`
    pub fn archive_path(&self, idx: usize) -> PathBuf {
        PathBuf::from(format!("{}.{}.gz", self.path.display(), idx))
    }

    /// Manually trigger a rotation and gzip compression of the active log.
    ///
    /// Synchronous on purpose: tests and operators expect `.1.gz` to exist
    /// when the call returns, and this path is never on the router thread.
    /// The automatic rotation in `record()` uses the same swap but finishes
    /// the archive on a background thread instead.
    #[allow(dead_code)]
    pub fn rotate(&self) -> std::io::Result<()> {
        let mut inner = self.inner.lock_or_recover();
        if let Some((rotating, len)) = self.swap_locked(&mut inner)? {
            // Drop the writer lock before the slow half: the swap already
            // made the log writable again, so there is no reason to hold it.
            drop(inner);
            return self.shifter.finish(&rotating, len);
        }
        Ok(())
    }

    /// The FAST half of a rotation, safe under the writer lock: flush, rename
    /// the active file to a `.rotating.<pid>` scratch name, reopen a fresh
    /// active file in its place, reset the size. Rename + reopen are
    /// microseconds; the multi-hundred-millisecond gzip lives in
    /// `ArchiveShift::finish`, which the caller runs OUTSIDE this lock.
    ///
    /// Returns the scratch path (and its size) when there is something to
    /// archive, or `None` when the log was empty and no archive is needed.
    /// `rotations` counts SWAPS: the active file was replaced, and whether
    /// the archive lands now or in a moment does not change that fact.
    fn swap_locked(&self, inner: &mut Inner) -> std::io::Result<Option<(PathBuf, u64)>> {
        if !self.enabled || self.path.as_os_str().is_empty() {
            return Ok(None);
        }

        // 1. Sync and close active file descriptor
        if let Some(mut f) = inner.file.take() {
            let _ = f.flush();
            let _ = f.sync_data();
        }

        let file_len = match fs::metadata(&self.path) {
            Ok(m) => m.len(),
            Err(_) => 0,
        };

        if file_len == 0 {
            let fresh = OpenOptions::new()
                .create(true)
                .append(true)
                .read(true)
                .open(&self.path)?;
            inner.file = Some(fresh);
            inner.current_size = 0;
            return Ok(None);
        }

        // 2. Rename active file to a scratch name. From this moment the
        // active path no longer exists — step 3 must succeed or the log is
        // unwritable, which is why it comes immediately after.
        let rotating_path = PathBuf::from(format!(
            "{}.rotating.{}.{}",
            self.path.display(),
            std::process::id(),
            inner.rotations + 1
        ));
        let _ = fs::remove_file(&rotating_path);

        if let Err(e) = fs::rename(&self.path, &rotating_path) {
            eprintln!(
                "[hub] AUDIT ROTATE: cannot rename {} to {}: {}",
                self.path.display(),
                rotating_path.display(),
                e
            );
            let fresh = OpenOptions::new()
                .create(true)
                .append(true)
                .read(true)
                .open(&self.path)?;
            inner.current_size = file_len;
            inner.file = Some(fresh);
            return Err(e);
        }

        // 3. Immediately re-open a fresh empty active file so appends proceed
        inner.file = Some(OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(&self.path)?);
        inner.current_size = 0;
        inner.rotations += 1;

        Ok(Some((rotating_path, file_len)))
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
        let mut inner = self.inner.lock_or_recover();

        // Check if rotation is needed before appending.
        // Fast swap runs under this writer lock (microseconds); the slow
        // gzip compression + archive shifting runs on a background thread so
        // the router thread resumes appending immediately.
        if self.enabled && inner.file.is_some() && inner.current_size >= self.max_bytes {
            if let Ok(Some((rotating_path, file_len))) = self.swap_locked(&mut inner) {
                let shifter = self.shifter.clone();
                let worker_slot = Arc::clone(&self.shifter.active_worker);
                let rotating_bg = rotating_path.clone();
                let spawn_res = std::thread::Builder::new()
                    .name("audit-rotate".to_string())
                    .spawn(move || {
                        let _ = shifter.finish(&rotating_bg, file_len);
                    });
                match spawn_res {
                    Ok(handle) => {
                        let mut slot = worker_slot.lock_or_recover();
                        *slot = Some(handle);
                    }
                    Err(e) => {
                        eprintln!("[hub] AUDIT: cannot spawn background rotate thread, running synchronously: {}", e);
                        let _ = self.shifter.finish(&rotating_path, file_len);
                    }
                }
            }
        }

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

        // M-07: If audit is enabled but file handle was lost (e.g. rotation reopen failed), try to heal
        if self.enabled && inner.file.is_none() {
            if let Ok(fresh) = OpenOptions::new()
                .create(true)
                .append(true)
                .read(true)
                .open(&self.path)
            {
                inner.current_size = std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0);
                inner.file = Some(fresh);
            }
        }

        let Some(f) = inner.file.as_mut() else {
            // Disabled or failed to open: still advance `seq` so the caller's view is consistent,
            // and count it so "the audit is off" is visible in the totals.
            inner.seq = seq;
            if self.enabled {
                inner.failed += 1;
            }
            return seq;
        };

        let bytes = line.as_bytes();
        match f.write_all(bytes).and_then(|_| f.sync_data()) {
            Ok(()) => {
                inner.seq = seq;
                inner.wrote += 1;
                inner.current_size += bytes.len() as u64;
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

        // 1. Read active file
        let mut raw_bytes = Vec::new();
        if let Ok(mut f) = File::open(&self.path) {
            let _ = f.read_to_end(&mut raw_bytes);
        }
        let text = String::from_utf8_lossy(&raw_bytes);

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

        // 2. Inspect compressed archives if needed.
        // For since == 0: inspect archives when active file records do not satisfy `limit`.
        // For since > 0: inspect archives whenever active file's oldest seq is greater than `since + 1`
        // or total records do not satisfy `limit`, ensuring forward pagination across archives never skips records.
        let oldest_active_seq = out.first().and_then(|r| r["seq"].as_u64()).unwrap_or(u64::MAX);
        let need_archive = if since == 0 {
            out.len() < limit
        } else {
            oldest_active_seq > since.saturating_add(1) || out.len() < limit
        };

        if need_archive {
            self.wait_for_rotation();
            if since == 0 {
                // When since == 0: backwards inspection from newest archive .1.gz to oldest
                for idx in 1..=self.max_backups {
                    if out.len() >= limit {
                        break;
                    }
                    let archive_p = self.archive_path(idx);
                    if !archive_p.exists() {
                        break;
                    }
                    if let Ok(f) = File::open(&archive_p) {
                        let decoder = GzDecoder::new(f);
                        let reader = std::io::BufReader::new(decoder);
                        use std::io::BufRead;
                        let mut archive_recs: std::collections::VecDeque<Value> = std::collections::VecDeque::new();
                        let max_archive_needed = limit.saturating_sub(out.len());
                        for line_res in reader.lines() {
                            if let Ok(line) = line_res {
                                if line.trim().is_empty() {
                                    continue;
                                }
                                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                                    stats.lines += 1;
                                    let s = v["seq"].as_u64().unwrap_or(0);
                                    if s > 0 && s < oldest_active_seq {
                                        // Sliding window: keep only the latest records from archive
                                        if archive_recs.len() >= max_archive_needed {
                                            archive_recs.pop_front();
                                        }
                                        archive_recs.push_back(v);
                                    }
                                }
                            }
                        }
                        let mut combined: Vec<Value> = archive_recs.into();
                        combined.extend(out);
                        out = combined;
                    }
                }
            } else {
                // HUB-03: When since > 0: inspect archives in chronological order (oldest to newest)
                // so forward pagination across rotations collects all consecutive records.
                let mut archive_recs: Vec<Value> = Vec::new();
                for idx in (1..=self.max_backups).rev() {
                    let archive_p = self.archive_path(idx);
                    if !archive_p.exists() {
                        continue;
                    }
                    if let Ok(f) = File::open(&archive_p) {
                        let decoder = GzDecoder::new(f);
                        let reader = std::io::BufReader::new(decoder);
                        use std::io::BufRead;
                        for line_res in reader.lines() {
                            if let Ok(line) = line_res {
                                if line.trim().is_empty() {
                                    continue;
                                }
                                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                                    stats.lines += 1;
                                    let s = v["seq"].as_u64().unwrap_or(0);
                                    if s > since && s < oldest_active_seq {
                                        archive_recs.push(v);
                                    }
                                }
                            }
                        }
                    }
                }
                archive_recs.sort_by_key(|r| r["seq"].as_u64().unwrap_or(0));
                archive_recs.extend(out);
                out = archive_recs;
            }
        }

        // If since == 0 (latest N records), truncate from the front so caller gets the newest `limit`.
        // If since > 0 (forward pagination/continuation), truncate from the back so caller gets
        // the next `limit` consecutive records after `since`.
        if out.len() > limit {
            if since == 0 {
                out.drain(0..out.len() - limit);
            } else {
                out.truncate(limit);
            }
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

/// Discover any leftover uncompressed scratch files from a previous hub run
/// that was killed between the swap and the archive completion.
fn leftover_rotations(path: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let dir = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    let file_name = match path.file_name().and_then(|f| f.to_str()) {
        Some(n) => n,
        None => return out,
    };
    let prefix = format!("{}.rotating.", file_name);

    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if let Some(name) = p.file_name().and_then(|f| f.to_str()) {
                if name.starts_with(&prefix) {
                    if name.contains(".gz.tmp.") {
                        // P2-16: If uncompressed rotating file still exists, this tmp gz can be deleted.
                        // If uncompressed rotating file was already deleted, do NOT discard the sole surviving copy.
                        let uncompressed_name = name.split(".gz.tmp.").next().unwrap_or("");
                        let uncompressed_path = dir.join(uncompressed_name);
                        if uncompressed_path.exists() {
                            let _ = fs::remove_file(&p);
                        } else {
                            out.push(p);
                        }
                    } else {
                        out.push(p);
                    }
                }
            }
        }
    }
    out.sort();
    out
}

/// The highest `seq` in the file, or None if there is none to be found.
/// If the active file has no records (e.g. freshly rotated), walks the
/// compressed archives (`audit.jsonl.1.gz` .. `max_backups`) and keeps the
/// highest seq any of them yields, to preserve sequence monotonicity across
/// restarts.
///
/// WHY EVERY ARCHIVE, NOT JUST `.1.gz`: the fallback exists for the restart
/// that lands right after a rotation, and it used to read exactly one
/// archive. If THAT archive was unreadable - a truncated gz from the crash
/// the rotation itself was surviving, a permissions error - the function
/// returned None and the hub renumbered from 1, silently re-using seqs the
/// archives still hold. A gap detector that depends on monotonicity then
/// sees the same seq twice and the log's one integrity property is gone.
/// Walking all of them and taking the max costs a few hundred ms at STARTUP
/// only, which is the cheapest possible price for "seq never repeats".
fn last_seq(path: &Path, max_backups: usize) -> Option<u64> {
    if let Ok(mut f) = File::open(path) {
        if let Ok(m) = f.metadata() {
            let len = m.len();
            if len > 0 {
                if let Some(s) = last_seq_from_file(&mut f, len) {
                    return Some(s);
                }
            }
        }
    }

    // Active file is empty or unreadable - fall back to the archives.
    let mut best: Option<u64> = None;
    for idx in 1..=max_backups {
        let arc = PathBuf::from(format!("{}.{}.gz", path.display(), idx));
        if !arc.exists() {
            continue;
        }
        if let Some(s) = last_seq_from_gz(&arc) {
            best = Some(best.map_or(s, |b| b.max(s)));
        }
    }
    best
}

fn last_seq_from_gz(path: &Path) -> Option<u64> {
    let f = File::open(path).ok()?;
    let mut decoder = GzDecoder::new(f);
    let mut text = String::new();
    decoder.read_to_string(&mut text).ok()?;
    for line in text.lines().rev() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if let Some(s) = v["seq"].as_u64() {
                return Some(s);
            }
        }
    }
    None
}

fn last_seq_from_file(f: &mut File, len: u64) -> Option<u64> {
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

    fn cleanup(p: &Path) {
        let _ = std::fs::remove_file(p);
        for idx in 1..=15 {
            let _ = std::fs::remove_file(format!("{}.{}.gz", p.display(), idx));
        }
        let _ = std::fs::remove_file(format!("{}.rotating.{}", p.display(), std::process::id()));
    }

    #[test]
    fn rotation_triggers_at_threshold_and_compresses_to_gz() {
        let p = tmp("rot_thresh");
        cleanup(&p);
        {
            let a = Audit::open_with_rotation(&p, 300, 5).unwrap();
            for i in 0..5 {
                a.record("admin", "127.0.0.1", "test.event", &format!("node:{}", i), None, None, "ok");
            }
            assert!(a.rotations() >= 1, "expected at least one rotation to have occurred");
            a.wait_for_rotation();
            let arc1 = a.archive_path(1);
            assert!(arc1.exists(), "archive 1 must exist");
            assert!(std::fs::metadata(&arc1).unwrap().len() > 0);

            // Read back across both the compressed archive and active file
            let (recs, stats) = a.read(100, 0);
            assert_eq!(recs.len(), 5, "all 5 records must be returned across rotation");
            assert_eq!(stats.lines, 5);
            let seqs: Vec<u64> = recs.iter().map(|r| r["seq"].as_u64().unwrap()).collect();
            assert_eq!(seqs, vec![1, 2, 3, 4, 5]);

            // Active file must be smaller than threshold after rotation
            let active_len = std::fs::metadata(&p).unwrap().len();
            assert!(active_len < 300, "active file should have been reset and small");
        }
        cleanup(&p);
    }

    #[test]
    fn max_backups_retention_and_oldest_pruned() {
        let p = tmp("max_backups");
        cleanup(&p);
        {
            let a = Audit::open_with_rotation(&p, 50, 3).unwrap();
            for i in 0..6 {
                a.record("operator", "", "action", &format!("n{}", i), None, None, "ok");
                a.rotate().unwrap();
            }

            assert!(a.archive_path(1).exists(), "archive 1 must exist");
            assert!(a.archive_path(2).exists(), "archive 2 must exist");
            assert!(a.archive_path(3).exists(), "archive 3 must exist");
            assert!(!a.archive_path(4).exists(), "archive 4 must be pruned");
            assert!(!a.archive_path(5).exists(), "archive 5 must be pruned");
        }
        cleanup(&p);
    }

    #[test]
    fn restart_after_rotation_preserves_monotonic_seq() {
        let p = tmp("restart_rot");
        cleanup(&p);
        {
            let a = Audit::open_with_rotation(&p, 500, 3).unwrap();
            a.record("", "", "ev1", "", None, None, "ok");
            a.record("", "", "ev2", "", None, None, "ok");
            a.rotate().unwrap();
            // Active file p is now freshly opened and empty
            assert_eq!(std::fs::metadata(&p).unwrap().len(), 0);
        }
        {
            let b = Audit::open_with_rotation(&p, 500, 3).unwrap();
            let (seq, _, _) = b.counts();
            assert_eq!(seq, 2, "must recover seq from archive 1 when active file is empty");
            let s3 = b.record("", "", "ev3", "", None, None, "ok");
            assert_eq!(s3, 3);
        }
        cleanup(&p);
    }

    #[test]
    fn manual_rotate_works_on_demand() {
        let p = tmp("manual_rot");
        cleanup(&p);
        {
            let a = Audit::open_with_rotation(&p, 100_000, 5).unwrap();
            a.record("", "", "manual1", "", None, None, "ok");
            a.rotate().unwrap();
            assert!(a.archive_path(1).exists());

            a.record("", "", "manual2", "", None, None, "ok");
            let (recs, _) = a.read(10, 0);
            assert_eq!(recs.len(), 2);
            assert_eq!(recs[0]["action"], "manual1");
            assert_eq!(recs[1]["action"], "manual2");
        }
        cleanup(&p);
    }

    #[test]
    fn restart_recovers_leftover_scratch_rotation() {
        let p = tmp("scratch_recovery");
        cleanup(&p);
        let scratch = PathBuf::from(format!("{}.rotating.99999", p.display()));
        {
            // Simulate crash: active file empty, but scratch file has records
            let a = Audit::open_with_rotation(&scratch, 500, 3).unwrap();
            a.record("", "", "crash1", "", None, None, "ok");
            a.record("", "", "crash2", "", None, None, "ok");
        }
        assert!(scratch.exists());
        {
            let b = Audit::open_with_rotation(&p, 500, 3).unwrap();
            assert!(!scratch.exists(), "scratch should be archived");
            assert!(b.archive_path(1).exists());
            let (seq, _, _) = b.counts();
            assert_eq!(seq, 2);
            let s3 = b.record("", "", "after_crash", "", None, None, "ok");
            assert_eq!(s3, 3);
        }
        cleanup(&p);
    }

    #[test]
    fn restart_recovers_leftover_gz_tmp_without_double_compression() {
        let p = tmp("gztmp_recovery");
        cleanup(&p);
        let gz_tmp = PathBuf::from(format!("{}.rotating.99999.1.gz.tmp.99999", p.display()));
        {
            // BUG-04 test: uncompressed .rotating was deleted, only valid .gz.tmp exists
            let f = File::create(&gz_tmp).unwrap();
            let mut enc = GzEncoder::new(BufWriter::new(f), Compression::default());
            let line = json!({
                "v": 1, "seq": 10, "ts": 1700000000u64, "utc": "2023-11-14T22:13:20Z",
                "actor": "admin", "ip": "127.0.0.1", "action": "test.leftover",
                "target": "node:1", "status": "ok"
            });
            serde_json::to_writer(&mut enc, &line).unwrap();
            enc.write_all(b"\n").unwrap();
            enc.finish().unwrap();
        }
        assert!(gz_tmp.exists());
        {
            let b = Audit::open_with_rotation(&p, 500, 3).unwrap();
            assert!(!gz_tmp.exists(), "gz.tmp should be moved to archive");
            assert!(b.archive_path(1).exists(), "archive 1 must exist");
            // Must be decodable by standard GzDecoder and not double-compressed
            let (recs, _) = b.read(10, 0);
            assert_eq!(recs.len(), 1);
            assert_eq!(recs[0]["action"], "test.leftover");
            assert_eq!(recs[0]["seq"], 10);
            let (seq, _, _) = b.counts();
            assert_eq!(seq, 10, "must recover seq=10 from archive 1");
        }
        cleanup(&p);
    }

    #[test]
    fn restart_discards_truncated_gz_tmp_leftover() {
        let p = tmp("truncated_gztmp_recovery");
        cleanup(&p);
        let gz_tmp = PathBuf::from(format!("{}.rotating.88888.1.gz.tmp.88888", p.display()));
        {
            // N80-03 test: gz.tmp file is truncated (missing valid gzip footer/EOF)
            let mut f = File::create(&gz_tmp).unwrap();
            f.write_all(&[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x01, 0x00, 0x00]).unwrap();
        }
        assert!(gz_tmp.exists());
        {
            let b = Audit::open_with_rotation(&p, 500, 3).unwrap();
            assert!(!gz_tmp.exists(), "truncated gz.tmp should be cleanly removed");
            assert!(!b.archive_path(1).exists(), "corrupted archive should not be created");
        }
        cleanup(&p);
    }

    #[test]
    fn read_pagination_since_and_saturation() {
        let p = tmp("since_pagination");
        cleanup(&p);
        {
            let a = Audit::open(&p).unwrap();
            for i in 1..=10 {
                a.record("", "", &format!("act_{}", i), "", None, None, "ok");
            }
            // Read with since=0 (latest 3)
            let (recs_latest, _) = a.read(3, 0);
            assert_eq!(recs_latest.len(), 3);
            assert_eq!(recs_latest[0]["seq"], 8);
            assert_eq!(recs_latest[2]["seq"], 10);

            // Read with since=5, limit=3 (forward from since: seq 6, 7, 8)
            let (recs_since, _) = a.read(3, 5);
            assert_eq!(recs_since.len(), 3);
            assert_eq!(recs_since[0]["seq"], 6);
            assert_eq!(recs_since[1]["seq"], 7);
            assert_eq!(recs_since[2]["seq"], 8);

            // Read with since=u64::MAX (should not panic or overflow)
            let (recs_max, _) = a.read(10, u64::MAX);
            assert_eq!(recs_max.len(), 0);
        }
        cleanup(&p);
    }
}
