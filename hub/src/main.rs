//! copier-hub - Phase 1 "transparent proxy" hub.
//!
//! A faithful port of `tools/hub_proto.py`, which was verified against the real
//! EAs first. The Python prototype exists to answer the PROTOCOL questions
//! before a build system is committed to:
//!
//!     * do two-frame messages survive a real round trip through the hub?
//!     * does a receiver really only get the senders it subscribed to?
//!     * does the receiver converge identically to a direct connection?
//!     * what happens to the receiver when the hub is stopped and restarted?
//!
//! Those are answered. This is "implement a behaviour that is already known to
//! work" rather than "implement a design" - and the strongest evidence of that
//! is that `tools/hub_proto_test.py` passes against BOTH binaries unchanged.
//!
//! WHAT IT DOES
//! ============
//!
//!     bind XPUB on --port (default 6000); every EA connects an XSUB to it.
//!
//!     loop:
//!         parts = recv_multipart()
//!         if parts.len() < 2:  ignore          # subscription byte, not data
//!         topic, payload = parts[0], parts[1]
//!         if !payload.starts_with(b"V="):      drop + count   # not an envelope
//!         if topic.starts_with(b"@"):          consume        # control for a node
//!         else:                                republish      # sender data
//!
//! That is the whole thing. Frame 1 is forwarded BYTE FOR BYTE - the hub never
//! re-encodes, never touches SEQ/SSID/TS. That is what makes it structurally
//! incapable of corrupting a trade instruction, and it is the reason the
//! receiver needs no changes to its convergence logic.
//!
//! WHAT IT DELIBERATELY DOES NOT DO
//! ================================
//!
//!   * no config store, no ini, no command tracking by itself - those live in
//!     `config.rs` (revisions) and `commands.rs` (the issue/retry/ack engine),
//!     and the hub only READS them here. The dangerous halves (applying a config,
//!     acting on a command) are the EA's job, never this process's.
//!   * no conflation (it does not parse T= to keep only the newest snapshot)
//!   * no persistence, no auth - the firewall is the trust boundary
//!
//! The ONE thing it originates is a PONG. That is not scope creep: a node
//! cannot otherwise tell a working hub link from a dead one, because ZMQ
//! connect() succeeds immediately whether or not anything is listening. It
//! needs no state - the node's own millisecond value is echoed straight back,
//! so (now - echoed) is a true round trip with no clocks involved.
//!
//! PHASE 2 - THE REGISTRY
//! ======================
//!
//! Phase 1 was adamant that the hub must not know which nodes exist. Phase 2 is
//! exactly that knowledge, so the rule has been replaced by a narrower one:
//!
//!     the hub knows ONLY what nodes tell it.
//!
//! It never probes for nodes, never discovers them, and never writes to one. A
//! node that stays silent stays invisible - silence is not a claim. `REG`
//! announces, `HBT2` says "still here", and `WHO` asks everyone to announce
//! again when the hub has lost its table (which it always has after a restart,
//! because there is no persistence and there should not be: a table restored
//! from disk is a table of nodes that may have died while the hub was down).
//!
//! Everything here is READ-ONLY with respect to the trade path. Phase 2's
//! promise is that the hub can be stopped, or wrong, without affecting a single
//! order - which is why the write path (`CFG`/`ACK`/`CFGR`) is Phase 3, the
//! highest-risk step, and is not in this file.

mod alerts;
mod users;
mod api;
mod audit;
mod commands;
mod config;
mod curve;
mod envelope;
mod lockx;
mod notifications;
mod positions;
mod registry;
mod stats;

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use envelope::{envelope_hdr, envelope_kv, envelope_kv_opt, envelope_payload, envelope_type};
use positions::{parse_snap, Positions};
use registry::Liveness;
use stats::Stats;
use crate::lockx::LockExt;

/// Set by the Ctrl-C handler, read by the loop.
///
/// A `static` rather than something captured, because a signal handler may not
/// touch anything with a destructor - an `Arc` in a handler is a data race
/// waiting for the right day.
static EXIT: AtomicBool = AtomicBool::new(false);

/// Ctrl-C, without a crate.
///
/// `ctrlc` would be the obvious choice, but it drags in windows-sys, which for
/// the windows-gnu target shells out to `dlltool` at build time - and the Rust
/// GNU toolchain ships dlltool without the `as`/`ar` it needs, so that build
/// fails outright. A full mingw-w64 to fix it would be ~100 MB for one signal
/// handler. This is the whole thing.
mod sig {
    use super::EXIT;
    use std::sync::atomic::Ordering;

    #[cfg(windows)]
    mod imp {
        use super::EXIT;
        use std::sync::atomic::Ordering;

        extern "system" {
            fn SetConsoleCtrlHandler(
                handler: Option<extern "system" fn(u32) -> i32>,
                add: i32,
            ) -> i32;
        }

        /// Returning non-zero means "handled, do not run the default handler".
        extern "system" fn on_ctrl(_ctrl_type: u32) -> i32 {
            EXIT.store(true, Ordering::SeqCst);
            1
        }

        pub fn install() -> Result<(), String> {
            //--- SAFETY: the handler only stores to an AtomicBool, which is
            //--- async-signal-safe, and it is a plain fn with no captures.
            let ok = unsafe { SetConsoleCtrlHandler(Some(on_ctrl), 1) };
            if ok == 0 {
                Err("SetConsoleCtrlHandler failed".to_string())
            } else {
                Ok(())
            }
        }
    }

    #[cfg(unix)]
    mod imp {
        use super::EXIT;
        use std::sync::atomic::Ordering;

        const SIGINT: i32 = 2;
        const SIGTERM: i32 = 15;
        type Handler = extern "C" fn(i32);

        extern "C" {
            fn signal(signum: i32, handler: Handler) -> usize;
        }

        extern "C" fn on_signal(_sig: i32) {
            EXIT.store(true, Ordering::SeqCst);
        }

        pub fn install() -> Result<(), String> {
            //--- SAFETY: as above - a store to an AtomicBool and nothing else.
            unsafe {
                signal(SIGINT, on_signal);
                signal(SIGTERM, on_signal);
            }
            Ok(())
        }
    }

    pub fn install() -> Result<(), String> {
        //--- Touching EXIT here keeps the import honest on both branches.
        let _ = EXIT.load(Ordering::SeqCst);
        imp::install()
    }
}

/// Match the EAs' own queue depths (CP_SNDHWM / CP_RCVHWM). A PUB drops when
/// its queue is full, and that is acceptable here ONLY because a snapshot is
/// idempotent full state: whatever is dropped is superseded within
/// SnapshotSeconds. The hub must not be the thing that makes it worse.
const HWM: i32 = 1000;

/// The largest frame this hub will accept, matching the EAs' CP_MAXMSGSIZE
/// (1 MB) so a frame the hub forwards can never be one a node would refuse.
///
/// This is the DoS control that actually works, and it is NOT the same thing as
/// a length check in the application. The hub is the internet-facing end, so a
/// peer can announce a multi-gigabyte frame: without this, libzmq reads and
/// buffers it before a single line of this program runs, and the process dies
/// of the allocation rather than of the parsing. ZMQ_MAXMSGSIZE is enforced
/// during the frame read and the peer is DISCONNECTED instead.
///
/// A hub is also a fan-out: one oversized frame it accepted would be copied to
/// every subscriber, so the cost of being wrong is multiplied by the number of
/// nodes.
const MAXMSGSIZE: i64 = 1024 * 1024;

/// The hub's own SSID. Only ever appears in a PONG or a WHO.
const HUB_SSID: &str = "hubproto";

/// How often to re-ask for registrations while the table is empty.
///
/// A hub that restarts while nodes stay connected has no way to learn who they
/// are: they registered once, at THEIR startup, and will not do it again. WHO
/// is that question. It is repeated while the table is empty because the ask
/// may have gone out before a node finished reconnecting - and it stops the
/// moment anyone answers, so a healthy hub is silent.
const WHO_EVERY_SECS: f64 = 5.0;

/// And a slow sweep once the table is populated.
///
/// Without this there is a hole that is easy to miss: the hub stops asking as
/// soon as ANY node answers, so a node whose initial REG was dropped - which
/// happens, because the EAs open their socket with IMMEDIATE and a send before
/// the TCP connection completes is discarded - would stay invisible until it
/// restarted. One tiny broadcast a minute closes it.
///
/// A node answering a redundant WHO is harmless: REG is idempotent, and the hub
/// only logs a node the first time it sees it.
const WHO_SWEEP_SECS: f64 = 60.0;

/// How often the registry line is printed, independent of --stats-every.
///
/// A node going offline is an EVENT, and an operator should not have to wait
/// for the next stats window to see it. Two seconds, not thirty: this is a
/// handful of numbers, and the "only when the counts change" filter below is
/// what keeps it from becoming noise.
const REGISTRY_EVERY_SECS: f64 = 2.0;

/// How long poll() waits before the loop comes round again.
///
/// A BLOCKING recv here would mean no output at all while the market is shut -
/// exactly when someone is watching it. The timeout is what keeps the stats
/// line appearing on a quiet feed.
const POLL_MS: i64 = 1000;

struct Args {
    bind: String,
    port: u16,
    /// Where the HTTP + WebSocket half listens. DEFAULT 127.0.0.1, unlike
    /// --bind, and that difference is the whole point: the ZMQ port is where
    /// nodes connect and the plan's §19.1 makes the firewall its trust
    /// boundary, while this port exposes EVERY position the hub has seen.
    ///
    /// Binding it to a loopback address by default means the dashboard is
    /// reachable from the machine running the hub and nowhere else. Reaching
    /// it from another machine is a deliberate act - `--http 0.0.0.0:6010` -
    /// and §19.1's reasoning applies to that port exactly as it does to 6000:
    /// whatever can connect can read the book.
    http: String,
    /// Where the M4a config revisions are appended.
    config: String,
    /// Where the M5 command journal is appended (in-flight commands, so a hub
    /// restart does not forget what it told a node to do).
    commands: String,
    /// M9. The user store (admin/operator/viewer, salted hashes). Sessions
    /// are in-memory; users persist here. `--users none` = an empty store,
    /// which bootstraps a fresh admin on the next start.
    users: String,
    /// Whether the ZMQ link is encrypted and machine-authenticated (CURVE).
    ///
    /// ON by default since 2026-10-15, by the owner's call, for the same
    /// reason the write gate was flipped on: every session from here on is a
    /// test session that needs the hub link encrypted, and a flag that has to
    /// be typed every time is a flag somebody forgets - which on THIS flag
    /// means the whole position stream goes out in the clear, silently.
    ///
    /// The cost of the flip is that every node must be configured for CURVE,
    /// which is why the EAs were flipped in the same change and why
    /// `--curve-learn` exists (see below): a node that has not been listed
    /// yet can still join and be recorded, instead of the fleet being locked
    /// out until somebody transcribes 40-character keys by hand.
    ///
    /// `--curve off` is the way back, and it is a one-word change.
    curve: bool,
    /// Learn mode: accept any authenticated keypair AND append its key to the
    /// allow-list file. Bring-up only - it is trust-on-first-use, so it
    /// stops being safe the moment the fleet has connected once.
    curve_learn: bool,
    /// The hub's own CURVE keypair (Z85). Created on first start when
    /// `--curve on`, so the file has to exist somewhere writable.
    curve_keys: String,
    /// The client allow-list: Z85 public keys, one per line, `#` comments,
    /// `*` for "any authenticated keypair". See `curve.rs` for why an empty
    /// list is a refusal to start rather than an open door.
    curve_clients: String,
    /// `--curve-show`: print this hub's CURVE public key and the allow-list's
    /// state, then exit WITHOUT binding anything.
    ///
    /// It exists because of a trap in the obvious procedure. The natural way
    /// to learn the hub's public key is to start it with `--curve on` and read
    /// the banner - but that needs port 6000, and the hub that is already
    /// running holds it. So the moment an operator needs the key is the one
    /// moment that command cannot run. This does the same keypair work and
    /// stops, so the key can be read (and the file created) any time.
    curve_show: bool,
    /// Whether the hub may CHANGE a node's config.
    ///
    /// The plan's §19 requires role checks and an audit trail for the write
    /// path, and M9 (users and roles) does not exist yet - which is why the
    /// shipped default was OFF for a long time. The OWNER flipped the default
    /// to ON (2026-10-14) because every session from here on is a test
    /// session that needs the write path live, and typing the flag each time
    /// invited the "started without it, why is everything 403" detour. The
    /// honest state is unchanged and is printed in the banner either way:
    /// the hub CAN change nodes' configs, the firewall is the only boundary,
    /// and every change is audited. Turn it back off (`--writes off`) - or
    /// flip this default - before the hub faces anything but the owner's own
    /// test bench.
    writes: bool,
    notifications: String,
    /// Where the M7 audit log is appended. Empty string = off (`--audit none`).
    ///
    /// Default sits next to `hub.log`, so `tools\hublog.bat` puts both in one
    /// place and neither is a surprise to find later.
    audit: String,
    verbose: bool,
    stats_every: f64,
    duration: f64,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        bind: "0.0.0.0".to_string(),
        port: 6000,
        http: "127.0.0.1:6010".to_string(),
        config: "config_revisions.jsonl".to_string(),
        commands: "commands.jsonl".to_string(),
        users: "users.json".to_string(),
        curve: true,
        curve_learn: false,
        curve_keys: "curve_hub.keys".to_string(),
        curve_clients: "curve_clients.txt".to_string(),
        curve_show: false,
        //--- Default ON, by the owner's call (2026-10-14): every session from
        //--- here on is a test session, and the flag was being typed every
        //--- time anyway. The struct field's doc comment carries the full
        //--- reasoning and the "flip it back" reminder.
        writes: true,
        notifications: "alert_channels.json".to_string(),
        audit: "audit.jsonl".to_string(),
        verbose: false,
        stats_every: 30.0,
        duration: 0.0,
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < argv.len() {
        let need = |i: usize| -> Result<&String, String> {
            argv.get(i + 1)
                .ok_or_else(|| format!("{} needs a value", argv[i]))
        };
        match argv[i].as_str() {
            "--bind" => {
                a.bind = need(i)?.clone();
                i += 2;
            }
            "--port" => {
                a.port = need(i)?
                    .parse()
                    .map_err(|_| "invalid --port".to_string())?;
                i += 2;
            }
            "--stats-every" => {
                a.stats_every = need(i)?
                    .parse()
                    .map_err(|_| "invalid --stats-every".to_string())?;
                i += 2;
            }
            "--duration" => {
                a.duration = need(i)?
                    .parse()
                    .map_err(|_| "invalid --duration".to_string())?;
                i += 2;
            }
            "--verbose" => {
                a.verbose = true;
                i += 1;
            }
            "--http" => {
                // Accepted for symmetry with --bind/--port, and because
                // "--http none" reads better in a script than an empty value.
                let v = need(i)?;
                if v != "none" {
                    a.http = v.clone();
                } else {
                    a.http = String::new();
                }
                i += 2;
            }
            "--config" => {
                let v = need(i)?;
                a.config = if v == "none" { String::new() } else { v.clone() };
                i += 2;
            }
            "--commands" => {
                let v = need(i)?;
                a.commands = if v == "none" { String::new() } else { v.clone() };
                i += 2;
            }
            "--users" => {
                let v = need(i)?;
                // "none" is passed through verbatim: the bootstrap skips it
                // and the middleware answers as an anonymous viewer.
                a.users = v.clone();
                i += 2;
            }
            "--curve" => {
                // Explicit on|off, like --writes. ON is now the DEFAULT
                // (2026-10-15), because the EAs ship expecting it - a hub
                // without CURVE leaves the position stream in the clear, and
                // a flag that must be typed every time is a flag somebody
                // forgets. `off` is the way back, one word.
                let v = need(i)?;
                a.curve = match v.as_str() {
                    "on" => true,
                    "off" => false,
                    _ => return Err(format!("--curve takes on or off, not {}", v)),
                };
                i += 2;
            }
            "--curve-learn" => {
                // Trust-on-first-use for bring-up: accept any authenticated
                // keypair and write its key into the allow-list file, so the
                // fleet can be brought up without anybody transcribing
                // 40-character keys. Not a resting state - see the Args doc.
                let v = need(i)?;
                a.curve_learn = match v.as_str() {
                    "on" => true,
                    "off" => false,
                    _ => return Err(format!("--curve-learn takes on or off, not {}", v)),
                };
                i += 2;
            }
            "--curve-keys" => {
                let v = need(i)?;
                a.curve_keys = v.clone();
                i += 2;
            }
            "--curve-clients" => {
                let v = need(i)?;
                a.curve_clients = v.clone();
                i += 2;
            }
            "--curve-show" => {
                // A bare flag: no value, because there is nothing to choose.
                a.curve_show = true;
                i += 1;
            }
            "--writes" => {
                // Deliberately requires an explicit value. `--writes` with
                // nothing after it would be the kind of flag somebody adds to
                // a command line "just to see", and this one rewrites
                // receivers' configuration files.
                let v = need(i)?;
                a.writes = match v.as_str() {
                    "on" => true,
                    "off" => false,
                    _ => return Err(format!("--writes takes on or off, not {}", v)),
                };
                i += 2;
            }
            "--audit" => {
                // Same shape as --http: an explicit "none" rather than an
                // empty argument, because `--audit ""` is a typo magnet.
                let v = need(i)?;
                a.audit = if v == "none" { String::new() } else { v.clone() };
                i += 2;
            }
            "--notifications" => {
                let v = need(i)?;
                a.notifications = if v == "none" { String::new() } else { v.clone() };
                i += 2;
            }
            "--help" | "-h" => {
                return Err("help".to_string());
            }
            other => return Err(format!("unknown argument: {}", other)),
        }
    }
    Ok(a)
}

fn usage() {
    println!("copier-hub - Phase 1 transparent-proxy hub");
    println!();
    println!("Usage: copier-hub [--bind IFACE] [--port N] [--http ADDR:PORT]");
    println!("                  [--verbose] [--stats-every SECONDS] [--duration SECONDS]");
    println!();
    println!("  --bind         interface to bind (default 0.0.0.0)");
    println!("  --port         port to bind (default 6000)");
    println!("  --http         address for the HTTP+WS dashboard.");
    println!("                 DEFAULT 127.0.0.1:6010 - loopback, deliberately.");
    println!("                 --http none turns it off.");
    println!("                 Binding anything reachable exposes every position");
    println!("                 the hub has seen; see §19.1 in CENTRAL-HUB-PLAN.md.");
    println!("  --audit        append-only audit log (default audit.jsonl)");
    println!("                 `--audit none` turns it off.");
    println!("  --config       config revision log (default config_revisions.jsonl)");
    println!("  --commands     command journal (default commands.jsonl)");
    println!("                 in-flight CFG/CMD commands are logged here so a hub");
    println!("                 restart does not forget what it told a node to do;");
    println!("                 --commands none keeps them in memory only.");
    println!("  --users        M9 user store (default users.json); sessions are");
    println!("                 always in-memory. --users none = empty store, which");
    println!("                 bootstraps a fresh admin on next start.");
    println!("  --notifications alert channel store (default alert_channels.json);");
    println!("                 --notifications none keeps channels in memory only.");
    println!("  --writes       on | off (default ON since 2026-10-14, owner's");
    println!("                 test-period setting). OFF means the hub cannot");
    println!("                 change any node's config: PUT/POST return 403 and");
    println!("                 no CFG/CMD is ever sent. With M9 the write path also");
    println!("                 needs an operator/admin session - two gates, not one.");
    println!("  --curve        on | off (default ON since 2026-10-15, owner's");
    println!("                 test-period setting: the EAs ship expecting it, and a");
    println!("                 hub without CURVE leaves the position stream in the");
    println!("                 clear). OFF is the way back - one word, nothing else.");
    println!("  --curve-keys   this hub's CURVE keypair, Z85 (default curve_hub.keys;");
    println!("                 generated on first start when --curve on).");
    println!("  --curve-clients  the client allow-list (default curve_clients.txt):");
    println!("                 one 40-char Z85 PUBLIC key per line, # comments, or a");
    println!("                 lone * for 'any authenticated keypair'. An EMPTY list");
    println!("                 refuses to start unless --curve-learn is on.");
    println!("  --curve-learn  on | off (default off). Bring-up mode: accept ANY");
    println!("                 authenticated keypair and append its key to the");
    println!("                 allow-list file, so the fleet registers itself instead");
    println!("                 of somebody transcribing 40-char keys. Trust on first");
    println!("                 use - restart WITHOUT it once every node has joined.");
    println!("  --curve-show   print this hub's CURVE public key (and the allow-list's");
    println!("                 state) and exit WITHOUT binding anything. Use this to");
    println!("                 read the key while the hub is already running -");
    println!("                 '--curve on' would need the port it is holding.");
    println!("  --verbose      log every message, not just events and stats");
    println!("  --stats-every  seconds between stats lines (default 30, 0 = never)");
    println!("  --duration     exit after this many seconds (0 = run until Ctrl-C)");
}

/// The registry's `Liveness` as the word the audit log and the API both use.
/// One spelling, so a reader of either does not have to learn two.
fn live_str(l: Liveness) -> &'static str {
    match l {
        Liveness::Online => "online",
        Liveness::Stale => "stale",
        Liveness::Offline => "offline",
    }
}

fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The little the hub needs to originate a message of its own.
///
/// ONLY the PONG uses this. It is deliberately not a registry: the hub still
/// does not know which nodes exist, which is the line that keeps Phase 1 from
/// quietly absorbing Phase 2.
struct HubState {
    seq: u64,
}

/// Echo a node's probe back, on the two-frame channel.
///
/// The PAYLOAD `MS` is the NODE'S value, echoed untouched - that is what makes
/// (now - echoed) a true round trip with no clock synchronisation involved. The
/// envelope's own `MS` is the hub's clock and nothing reads it for a PONG.
fn send_pong(sock: &zmq::Socket, nid: &str, ms: &str, state: &mut HubState) -> zmq::Result<()> {
    state.seq += 1;
    let env = format!(
        "V=1|SID=hub|SSID={}|SEQ={}|TS={}|MS={}|T=PONG|P=MS={};FROM=hub;TO={}",
        HUB_SSID,
        state.seq,
        unix_secs(),
        unix_millis() % 2147483647,
        ms,
        nid
    );
    sock.send_multipart(
        vec![format!("@{}", nid).into_bytes(), env.into_bytes()],
        0,
    )
}

/// Ask every node to register again, on `@all`.
///
/// The hub's registry is in memory only and is rebuilt from scratch after a
/// restart - a table restored from disk would be a table of nodes that may have
/// died while the hub was down. But nodes only REG at THEIR startup, so a hub
/// that restarts while they stay connected would sit there knowing nobody.
/// This is that question, and it is the only thing the hub broadcasts.
/// Push a whole config to one node.
///
/// The ini is ESCAPED (see `config::escape_ini`): it contains `;`, `=`, `|` and
/// newlines, any of which would end the payload field early and deliver a
/// truncated config - the kind of failure that looks like a successful push
/// until the receiver restarts.
///
/// Sent on `@<nid>`, the hub's own control channel. The hub is the only party
/// that may originate on `@`, which is exactly right here: only the hub is
/// allowed to reconfigure a node.
fn send_cfg(
    sock: &zmq::Socket,
    state: &mut HubState,
    node: &str,
    id: &str,
    rev: u64,
    ini: &str,
) -> zmq::Result<()> {
    state.seq += 1;
    // The node key is `ROLE:ACC`; the topic is the ACC alone, which is the same
    // `nid` the node subscribes to and the same value its ini calls `id=`.
    let nid = node.split(':').nth(1).unwrap_or(node);
    let env = format!(
        "V=1|SID=hub|SSID={}|SEQ={}|TS={}|MS={}|T=CFG|P=ID={};REV={};INI={}",
        HUB_SSID,
        state.seq,
        unix_secs(),
        unix_millis() % 2147483647,
        id,
        rev,
        config::escape_ini(ini)
    );
    sock.send_multipart(vec![format!("@{}", nid).into_bytes(), env.into_bytes()], 0)
}

/// Send one operational command to a node: `T=CMD` on the node's own `@<nid>`
/// control topic, carrying the command id (so the node can dedupe by it) and
/// the operation. There is no payload body - the four operations are
/// self-describing - so `ARGS` is only ever present for a future op that needs
/// one, and the wire format does not change when that day comes.
fn send_cmd(
    sock: &zmq::Socket,
    state: &mut HubState,
    node: &str,
    id: &str,
    op: &str,
    args: &str,
) -> zmq::Result<()> {
    state.seq += 1;
    let nid = node.split(':').nth(1).unwrap_or(node);
    let mut p = format!("ID={};OP={}", id, op);
    if !args.is_empty() {
        p.push_str(&format!(";ARGS={}", args));
    }
    let env = format!(
        "V=1|SID=hub|SSID={}|SEQ={}|TS={}|MS={}|T=CMD|P={}",
        HUB_SSID,
        state.seq,
        unix_secs(),
        unix_millis() % 2147483647,
        p
    );
    sock.send_multipart(vec![format!("@{}", nid).into_bytes(), env.into_bytes()], 0)
}

fn send_who(sock: &zmq::Socket, nonce: u64, state: &mut HubState) -> zmq::Result<()> {
    state.seq += 1;
    let env = format!(
        "V=1|SID=hub|SSID={}|SEQ={}|TS={}|MS={}|T=WHO|P=NONCE={}",
        HUB_SSID,
        state.seq,
        unix_secs(),
        unix_millis() % 2147483647,
        nonce
    );
    sock.send_multipart(vec![b"@all".to_vec(), env.into_bytes()], 0)
}

/// Relay a receiver's snapshot receipt to the sender it is about.
///
/// WHY THE HUB DOES THIS AT ALL
/// ============================
/// In DIRECT mode the receiver's STAT reaches the sender by itself and the
/// receipt rides in it. In CENTRAL mode it cannot: the hub consumes every
/// '@'-prefixed message, and D13 (`doc/CENTRAL-HUB-PLAN.md`) deliberately has
/// the hub keep the receiver's status rather than pass it to a sender. That is
/// the right call for the MONITORING figures - equity, lots, risk - which are
/// a property of the receiver and belong to whoever is watching receivers.
///
/// The receipt is not that. "The snapshot I sent you is / is not the one you
/// hold" is a DELIVERY signal: only the sender can act on it, and no other node
/// can observe it. So it is relayed here, and nothing else from the STAT is -
/// this is a refinement of D13, not an exception to it.
///
/// It also rides the channel that already exists for hub -> node traffic
/// (`@<nid>`, the same one `send_pong` uses), so no new topic namespace and no
/// second identity: the `nid` the sender subscribed to at startup is exactly
/// the id a receiver puts in its ini.
///
/// WHAT IS DELIBERATELY NOT INCLUDED
/// =================================
/// Only `LOGIN` (which receiver this is, so the sender can track them
/// separately), `SID` (which sender this is about, so a sender can ignore a
/// receipt that is not its own) and `H`. No equity, no lot figures, no risk
/// state - those stay with the hub.
fn send_receipt(
    sock: &zmq::Socket,
    sid: &str,
    login: &str,
    h: &str,
    state: &mut HubState,
) -> zmq::Result<()> {
    state.seq += 1;
    let env = format!(
        "V=1|SID=hub|SSID={}|SEQ={}|TS={}|MS={}|T=RCPT|P=LOGIN={};SID={};H={}",
        HUB_SSID,
        state.seq,
        unix_secs(),
        unix_millis() % 2147483647,
        login,
        sid,
        h
    );
    sock.send_multipart(
        vec![format!("@{}", sid).into_bytes(), env.into_bytes()],
        0,
    )
}

fn describe_sub(prefix: &str) -> String {
    if let Some(rest) = prefix.strip_prefix('@') {
        format!("control for {}", rest)
    } else {
        format!("data from sender {}", prefix)
    }
}

/// When an ACK quotes an id the hub has no record of, the command lookup
/// returns nothing - so we have no `kind` to prefix the `unknown_ack` audit
/// action with. But the id is not random: config ids are `<node>R<rev>` and op
/// ids are `<node>-<op>-<seq>` (see commands.rs). The last non-digit in the id
/// is therefore `R` for a config command and `-` for an op command, which is
/// enough to put the unknown ACK in the right audit bucket rather than guess
/// `config` every time. A shape that fits neither (a stray string) defaults to
/// `config`, the dominant write path.
fn unknown_ack_prefix(id: &str) -> &'static str {
    match id.as_bytes().iter().rposition(|b| !b.is_ascii_digit()) {
        Some(p) => match id.as_bytes().get(p) {
            Some(b'R') => "config",
            Some(b'-') => "command",
            _ => "config",
        },
        None => "config",
    }
}

/// A short human note for a control message - Phase 1 only logs these.
fn control_note(payload: &[u8], ty: &str) -> String {
    match ty {
        "REG" => format!(
            "role={} acc={}",
            envelope_kv(payload, "ROLE"),
            envelope_kv(payload, "ACC")
        ),
        "ACK" => format!(
            "id={} ok={}",
            envelope_kv(payload, "ID"),
            envelope_kv(payload, "OK")
        ),
        "PING" => format!("probe from {} - answering", envelope_kv(payload, "FROM")),
        _ => String::new(),
    }
}

/// The M3 position view, as one block under the traffic stats.
///
/// Bounded the same way the rest of the stats are: a hub with a hundred senders
/// must not print a hundred lines every window, or the line that matters is the
/// one nobody finds.
///
/// Read-only in the strongest sense - this is a report ABOUT traffic, it is not
/// traffic. Nothing here can reach a receiver.
fn print_positions(pos: &Positions) {
    if pos.is_empty() {
        return;
    }
    println!(
        "[hub] positions {} sender(s), {} position(s), {} lots total{}",
        pos.senders(),
        pos.total_positions(),
        positions::lots_str(pos.total_lots()),
        if pos.mismatched > 0 {
            format!(
                "   WARNING {} snapshot(s) declared a count they did not carry",
                pos.mismatched
            )
        } else {
            String::new()
        }
    );
    for (sid, v) in pos.top(8) {
        println!(
            "[hub]   {:<12} {:>3} pos  {:>8} lots  h={}  {}",
            sid,
            v.count,
            positions::lots_str(v.lots),
            if v.receipt.is_empty() { "-" } else { v.receipt.as_str() },
            Positions::symbol_note(v)
        );
    }
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            if e != "help" {
                eprintln!("copier-hub: {}", e);
            }
            usage();
            std::process::exit(if e == "help" { 0 } else { 2 });
        }
    };

    //--- `--curve-show`: report this hub's CURVE identity and exit, binding
    //--- NOTHING. Handled here, before the Ctrl-C handler and before any
    //--- socket, so it works while another hub owns port 6000.
    if args.curve_show {
        let keys_path = std::path::PathBuf::from(&args.curve_keys);
        let (keys, created) = match curve::load_or_create_keys(&keys_path) {
            Ok(k) => k,
            Err(e) => {
                eprintln!("copier-hub: cannot read or create {}: {}", keys_path.display(), e);
                std::process::exit(1);
            }
        };
        println!("[hub] CURVE identity for this hub");
        println!("[hub]   key file: {}", keys_path.display());
        if created {
            println!("[hub]             (created just now - it did not exist before)");
        }
        println!("[hub]   PUBLIC KEY - give this to every node's HubPublicKey input:");
        println!("[hub]     {}", keys.public);
        println!("[hub]   the SECRET half stays in that file and is never printed.");
        let clients_path = std::path::PathBuf::from(&args.curve_clients);
        match curve::AllowList::load(&clients_path) {
            Ok(l) if l.is_any() => println!(
                "[hub]   allow-list: {} = ANY authenticated keypair ('*')",
                clients_path.display()
            ),
            Ok(l) if l.is_empty() => println!(
                "[hub]   allow-list: {} is EMPTY - '--curve on' will REFUSE to start",
                clients_path.display()
            ),
            Ok(l) => println!(
                "[hub]   allow-list: {} - {} key(s)",
                clients_path.display(),
                l.len()
            ),
            Err(_) => println!(
                "[hub]   allow-list: {} does not exist yet (create it before --curve on)",
                clients_path.display()
            ),
        }
        std::process::exit(0);
    }

    //--- Ctrl-C sets a flag rather than killing the process, so the final
    //--- stats line still prints. That matters more than it looks: the numbers
    //--- on that line are the only record of what a run did.
    if let Err(e) = sig::install() {
        eprintln!("[hub] cannot install Ctrl-C handler: {}", e);
    }

    //--- NOTE on buffering, because the Python prototype had a real bug here.
    //---
    //--- Python block-buffers stdout when it is not a terminal, so a hub whose
    //--- output was redirected to a file had an EMPTY log - every line still sat
    //--- in a buffer, and a killed process discards it. That reads exactly like
    //--- "it never started".
    //---
    //--- Rust's stdout is line-buffered unconditionally, so the equivalent bug
    //--- cannot happen here. Nothing to do; the difference is worth recording
    //--- so nobody "fixes" it by adding a flush loop.

    let ctx = zmq::Context::new();
    //--- The CURVE identity the API/dashboard will show (see the block below).
    //--- Stashed here and applied to `shared` after it exists, because the
    //--- socket has to be configured before bind and the shared state is not
    //--- built yet at that point.
    let mut curve_for_api: Option<(String, bool)> = None;
    let sock = match ctx.socket(zmq::XPUB) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[hub] cannot create socket: {}", e);
            std::process::exit(1);
        }
    };

    //--- Every one of these is load-bearing. See the constants above.
    let setup = (|| -> zmq::Result<()> {
        sock.set_linger(0)?; // or ctx_term blocks forever on shutdown
        sock.set_sndhwm(HWM)?;
        sock.set_rcvhwm(HWM)?;
        sock.set_maxmsgsize(MAXMSGSIZE)?;
        Ok(())
    })();
    if let Err(e) = setup {
        eprintln!("[hub] cannot configure socket: {}", e);
        std::process::exit(1);
    }

    //--- CURVE (the plan's §19.1 link boundary). Set BEFORE bind: a CURVE
    //--- server that binds first can complete a handshake with a client that
    //--- connects in the window between bind and setsockopt.
    if args.curve {
        let keys_path = std::path::PathBuf::from(&args.curve_keys);
        let (keys, created) = match curve::load_or_create_keys(&keys_path) {
            Ok(k) => k,
            Err(e) => {
                eprintln!("[hub] cannot use CURVE keys: {}", e);
                std::process::exit(1);
            }
        };
        let clients_path = std::path::PathBuf::from(&args.curve_clients);
        let list = match curve::AllowList::load(&clients_path) {
            Ok(l) => l,
            Err(e) if args.curve_learn => {
                //--- Learn mode starts from NOTHING: an absent (or unusable)
                //--- file is the normal bring-up state, not a misconfiguration.
                //--- The fleet populates it as it connects.
                println!(
                    "[hub] LEARN MODE: {} is {} - the fleet will populate it as it connects",
                    clients_path.display(),
                    if e.contains("does not exist") {
                        "absent".to_string()
                    } else {
                        format!("unusable ({})", e)
                    }
                );
                curve::AllowList::parse("")
            }
            Err(e) => {
                eprintln!("[hub] --curve on but the client allow-list is unusable: {}", e);
                eprintln!(
                    "[hub]   create {} with one 40-char Z85 public key per node,",
                    clients_path.display()
                );
                eprintln!("[hub]   or write a lone '*' to accept any keypair, or start");
                eprintln!("[hub]   with --curve-learn on to build the list automatically.");
                eprintln!("[hub]   Every node's public key is printed in its EA log.");
                std::process::exit(1);
            }
        };
        if list.is_empty() && !args.curve_learn {
            //--- REFUSING, not opening. See curve.rs: CURVE proves "has a
            //--- keypair", and only the list turns that into "is authorised".
            //--- LEARN MODE is the one exception, and it is the exception that
            //--- makes bring-up possible: an empty list is exactly what a
            //--- fleet looks like before any node has reported its key.
            eprintln!(
                "[hub] --curve on but {} contains no keys.",
                clients_path.display()
            );
            eprintln!("[hub]   Add each node's 40-char public key (printed in its EA log),");
            eprintln!("[hub]   write a lone '*' to accept any keypair, or start with");
            eprintln!("[hub]   --curve-learn on to build the list automatically.");
            eprintln!("[hub]   Refusing to start: CURVE with no allow-list accepts every");
            eprintln!("[hub]   keypair, which is the same exposure as no CURVE at all.");
            std::process::exit(1);
        }
        if args.curve_learn && !list.is_empty() {
            println!(
                "[hub] LEARN MODE with {} key(s) already in {} - new keys will be",
                list.len(),
                clients_path.display()
            );
            println!("[hub]   appended. Any authenticated keypair is accepted while");
            println!("[hub]   learning: restart WITHOUT --curve-learn once the fleet has");
            println!("[hub]   connected once, and the list is enforced.");
        }
        //--- The socket takes 32 raw bytes; the file and the operator speak
        //--- Z85. Decode here, once, and fail closed if either key is wrong.
        let pub_raw = match zmq::z85_decode(&keys.public) {
            Ok(b) if b.len() == 32 => b,
            _ => {
                eprintln!("[hub] the CURVE public key in {} is not 40-char Z85",
                          keys_path.display());
                std::process::exit(1);
            }
        };
        let sec_raw = match zmq::z85_decode(&keys.secret) {
            Ok(b) if b.len() == 32 => b,
            _ => {
                eprintln!("[hub] the CURVE secret key in {} is not 40-char Z85",
                          keys_path.display());
                std::process::exit(1);
            }
        };
        let applied = (|| -> zmq::Result<()> {
            sock.set_curve_server(true)?;
            sock.set_curve_publickey(&pub_raw)?;
            sock.set_curve_secretkey(&sec_raw)?;
            Ok(())
        })();
        if let Err(e) = applied {
            eprintln!("[hub] cannot enable CURVE on the socket: {}", e);
            std::process::exit(1);
        }

        println!("[hub] CURVE ENABLED - this hub is the CURVE server");
        println!("[hub]   public key (give this to every node):");
        println!("[hub]     {}", keys.public);
        if created {
            println!("[hub]   a new keypair was written to {}", keys_path.display());
        }
        if list.is_any() {
            println!("[hub]   clients: ANY authenticated keypair ('*' in {})",
                     clients_path.display());
            println!("[hub]   ^ this is not an allow-list - it only proves a node");
            println!("[hub]     generated a keypair. Prefer naming the keys.");
        } else {
            println!("[hub]   clients: {} key(s) allowed from {}",
                     list.len(), clients_path.display());
        }
        //--- ZAP is what actually ENFORCES the list, and it must be
        //--- listening before the server socket binds - libzmq asks it
        //--- during the handshake and obeys the answer. See curve.rs.
        let _zap = curve::spawn_zap_handler(&ctx, list, args.curve_learn, clients_path.clone());
        curve_for_api = Some((keys.public.clone(), args.curve_learn));
        std::thread::sleep(std::time::Duration::from_millis(80));
    }

    let endpoint = format!("tcp://{}:{}", args.bind, args.port);
    if let Err(e) = sock.bind(&endpoint) {
        println!("[hub] cannot bind {}: {}", endpoint, e);
        std::process::exit(1);
    }

    println!("[hub] listening on {}", endpoint);
    println!("[hub] EAs connect an XSUB here; the hub needs no other configuration");
    if !args.curve {
        println!("[hub] the link is PLAINTEXT (--curve off). §19.1's firewall is");
        println!("[hub]   the only boundary on this port - keep it on a private");
        println!("[hub]   network or a VPN, or turn --curve on.");
    }
    if args.duration > 0.0 {
        println!("[hub] will exit after {:.0}s", args.duration);
    }
    println!();

    let mut st = Stats::new();
    let mut state = HubState { seq: 0 };
    //--- M2 + M3 state, and M8's view of it.
    //---
    //--- Both now live behind a mutex because the API thread reads them. That
    //--- is the whole cost: a lock taken for the few microseconds a registry
    //--- update or a snapshot parse takes, at a message rate measured in tens
    //--- per second. The alternative - the plan's inproc PAIR bridge - would
    //--- move messages instead of state and cost more code to arrive at the
    //--- same place. See api.rs for why that trade was made.
    //---
    //--- `now` for the registry is passed in by the caller, not taken here, so
    //--- a single message still gets one timestamp across every subsystem that
    //--- looks at it. Taking it twice is how a node ends up online for the
    //--- registry line and stale for the API in the same second.
    //--- The audit log (M7). Opened BEFORE anything else runs, and a failure
    //--- to open it is FATAL rather than a fallback to disabled.
    //---
    //--- That is the one place in this program where refusing to start is the
    //--- right answer. Everywhere else the hub degrades and says so - a broken
    //--- link, a missing node, a bad frame. But an audit log that is silently
    //--- off produces exactly the same output as a hub where nothing ever
    //--- happened, and those two must never look alike. An operator who asked
    //--- for an audit and got none has to be told at startup, not in a report.
    let audit: std::sync::Arc<audit::Audit> = if args.audit.is_empty() {
        println!("[hub] audit DISABLED (--audit none) - nothing will be recorded");
        std::sync::Arc::new(audit::Audit::disabled())
    } else {
        let path = std::path::PathBuf::from(&args.audit);
        match audit::Audit::open(&path) {
            Ok(a) => {
                let (seq, _, _) = a.counts();
                println!(
                    "[hub] audit appending to {} (last seq {})",
                    path.display(),
                    seq
                );
                std::sync::Arc::new(a)
            }
            Err(e) => {
                eprintln!("[hub] cannot open the audit log {}: {}", path.display(), e);
                eprintln!("[hub] refusing to start rather than run unaudited -");
                eprintln!("[hub] pass --audit none if that is really what you want.");
                std::process::exit(1);
            }
        }
    };

    //--- The config revision store (M4a). Same failure policy as the audit,
    //--- for the same reason: a hub that silently cannot remember configs is
    //--- indistinguishable from one that never had any.
    let cfg: std::sync::Arc<config::ConfigStore> = if args.config.is_empty() {
        println!("[hub] config store DISABLED (--config none)");
        std::sync::Arc::new(config::ConfigStore::disabled())
    } else {
        let path = std::path::PathBuf::from(&args.config);
        match config::ConfigStore::open(&path) {
            Ok(c) => {
                let (revs, nodes, torn) = c.stats();
                println!(
                    "[hub] config revisions in {} ({} revision(s), {} node(s){}",
                    path.display(),
                    revs,
                    nodes,
                    if torn > 0 { format!(", {} torn", torn) } else { String::new() }
                );
                if torn > 0 {
                    println!("[hub]   ...a torn line means a crash mid-append; the");
                    println!("[hub]   revisions before it are still valid");
                }
                std::sync::Arc::new(c)
            }
            Err(e) => {
                eprintln!("[hub] cannot open the config store {}: {}", path.display(), e);
                eprintln!("[hub] pass --config none to run without it.");
                std::process::exit(1);
            }
        }
    };

    //--- The M5 command engine. Same failure policy as the audit and the config
    //--- store: an append-only journal of every command the hub issues, so that
    //--- after a restart the hub still knows what it told a node to do (§15).
    let cmds: std::sync::Arc<commands::CommandStore> = if args.commands.is_empty() {
        println!("[hub] command journal DISABLED (--commands none) - in-flight commands will be forgotten if this hub restarts");
        std::sync::Arc::new(commands::CommandStore::disabled())
    } else {
        let path = std::path::PathBuf::from(&args.commands);
        match commands::CommandStore::open(&path) {
            Ok(c) => {
                let (total, pending, torn) = c.stats();
                println!(
                    "[hub] command journal enabled={}, in {} ({} command(s) remembered, {} pending{})",
                    c.enabled(),
                    c.path().display(),
                    total,
                    pending,
                    if torn > 0 { format!(", {} torn", torn) } else { String::new() }
                );
                if torn > 0 {
                    println!("[hub]   ...a torn line means a crash mid-append; the commands before it are still valid");
                }
                std::sync::Arc::new(c)
            }
            Err(e) => {
                eprintln!("[hub] cannot open the command journal {}: {}", path.display(), e);
                eprintln!("[hub] pass --commands none to run without it.");
                std::process::exit(1);
            }
        }
    };

    if args.writes {
        println!("[hub] WRITES ENABLED (default) - this hub may change a node's config");
        println!("[hub]   every change is audited; see --audit and --config");
    } else {
        println!("[hub] writes disabled (--writes off): PUT returns 403 and no CFG is sent");
    }

    let notif_path = if args.notifications.is_empty() {
        None
    } else {
        Some(std::path::Path::new(&args.notifications))
    };
    let shared: api::SharedState = std::sync::Arc::new(std::sync::Mutex::new(
        api::Shared::new(args.port, audit.clone(), cfg.clone(), cmds.clone(), args.writes, notif_path),
    ));
    //--- Hand the CURVE identity (set up above, before bind) to the API so the
    //--- dashboard can show the public key - the one value every node's
    //--- HubPublicKey input needs, and public by definition.
    if let Some((pubkey, learn)) = &curve_for_api {
        let mut s = shared.lock_or_recover();
        s.curve_public = pubkey.clone();
        s.curve_learn = *learn;
    }
    //--- Wake signal for the WebSocket clients. Created by the API, held by
    //--- the ZMQ thread, and used ONLY after a state change - never on a
    //--- timer. A timer would mean a push per second per node for no new
    //--- information, and "the dashboard woke up again to tell me nothing" is
    //--- how a page gets closed and left closed.
    let mut poke_tx: Option<tokio::sync::broadcast::Sender<()>> = None;
    let started = Instant::now();
    let mut last_stats = Instant::now();
    let mut last_alerts = Instant::now();
    let mut last_who = Instant::now();
    let mut last_registry = Instant::now();
    let mut who_nonce: u64 = 0;
    //--- Last counts printed, so the registry line only appears when something
    //--- actually changed. A line repeated every 5 s saying the same thing is
    //--- a line an operator learns to skip - and then misses the one that
    //--- mattered.
    let mut last_counts = (usize::MAX, usize::MAX, usize::MAX);
    //--- Per-node liveness as of the last sweep, so a TRANSITION can be
    //--- detected rather than the state being re-observed. Without this the
    //--- audit would get an `offline` record every two seconds for as long as
    //--- a node stayed down - which is how an audit log becomes unreadable and
    //--- then unread.
    let mut last_liveness: std::collections::HashMap<String, Liveness> =
        std::collections::HashMap::new();

    //--- Rate limiting for DROP console logs and wire-triggered audit fsync entries
    let mut last_drop_log = Instant::now() - Duration::from_secs(10);
    let mut dropped_since_log = 0u64;
    //--- Last time a STAT named a sender the hub does not know. Rate-limited
    //--- because a misconfigured receiver emits one a second.
    let mut last_rcpt_drop = Instant::now() - Duration::from_secs(60);
    let mut wire_audit_throttle: std::collections::HashMap<(String, String), Instant> =
        std::collections::HashMap::new();
    let mut last_cfg_pull: std::collections::HashMap<String, (Instant, u32)> = std::collections::HashMap::new();

    //--- The API thread, if it was asked for. Spawned before the loop so a
    //--- bind failure is reported before the first frame is forwarded rather
    //--- than after - and so that `--http none` really means off, with no
    //--- runtime built and no port touched.
    if !args.http.is_empty() {
        match api::spawn(args.http.clone(), shared.clone()) {
            Ok(tx) => poke_tx = Some(tx),
            Err(e) => eprintln!("[hub] cannot start the API: {}", e),
        }
    }
    //--- Notify the dashboards. The `let _` is the whole error policy: a
    //--- channel with no subscribers is the normal case for a hub nobody is
    //--- watching, and it is not worth a line per message.
    let poke = || {
        if let Some(tx) = &poke_tx {
            let _ = tx.send(());
        }
    };

    //--- The restart marker. Without it a gap in the log is indistinguishable
    //--- from a gap in the record-keeping, and an audit whose silences cannot
    //--- be told apart from its omissions is not evidence of anything.
    audit.record(
        "",
        "",
        "hub.started",
        "",
        None,
        Some(serde_json::json!({
            "zmq_port": args.port,
            "http": if args.http.is_empty() { "none".to_string() } else { args.http.clone() },
            "pid": std::process::id(),
        })),
        "ok",
    );

    //--- M9: load the user store, and bootstrap the first admin when there is
    //--- none. The password is printed ONCE and never stored in the clear: a
    //--- fresh hub that says nothing about how to log in is a fresh hub nobody
    //--- can use, and one that ships a known password is one nobody should.
    //--- This is also the last time the hub can talk about its own first user
    //--- without the user in question - every later answer is "ask an admin".
    //--- Runs AFTER the restart marker on purpose: that marker is the first
    //--- record of every hub's life, and "started, then bootstrapped" is the
    //--- order a reader of the audit log expects.
    if args.users == "none" {
        //--- --users none: no login at all. Every request is answered as an
        //--- anonymous viewer - read-only by construction, since every write
        //--- endpoint demands operator/admin and the role gate still runs.
        //--- For throwaway local runs; a real hub never starts this way.
        shared.lock_or_recover().auth_enabled = false;
        println!("[hub] M9 login DISABLED (--users none): all requests are");
        println!("[hub]     anonymous viewers. Write endpoints still 403.");
        audit.record("hub", "", "user.auth_disabled", "", None, None, "ok");
    } else {
        let users_path = std::path::PathBuf::from(if args.users.is_empty() {
            crate::users::USERS_PATH.to_string()
        } else {
            args.users.clone()
        });
        let mut store = match crate::users::UserStore::load_at(&users_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[hub] {} is unreadable ({}), refusing to start",
                          users_path.display(), e);
                std::process::exit(1);
            }
        };
        if store.users().is_empty() {
            //--- MTC_ADMIN_PASSWORD overrides the random one. That is not a
            //--- back door: the file still stores only the salted hash, and
            //--- the env is for the test suites - a harness cannot read a
            //--- password out of the console of a hub it also controls.
            let (pw, from_env) = match std::env::var("MTC_ADMIN_PASSWORD") {
                Ok(p) if !p.is_empty() => (p, true),
                _ => (crate::users::random_password(), false),
            };
            let salt = crate::users::random_token()[..16].to_string();
            let u = crate::users::User {
                id: "admin".to_string(),
                pass: crate::users::hash_password(&pw, &salt),
                role: crate::users::Role::Admin,
                disabled: false,
            };
            if store.upsert(u).is_ok() && store.save().is_ok() {
                if from_env {
                    println!("[hub] M9 first run: user 'admin' created with the password");
                    println!("[hub]     from MTC_ADMIN_PASSWORD (testing; not a back door -");
                    println!("[hub]     only the salted hash is stored).");
                } else {
                    println!("[hub] M9 first run: created user 'admin' (password printed ONCE):");
                    println!("[hub]     {}", pw);
                    println!("[hub]     it is stored salted+hashed; log in and change the");
                    println!("[hub]     password from the dashboard (or POST /api/v1/users).");
                }
                audit.record("hub", "", "user.bootstrap", "admin", None, None, "ok");
            } else {
                eprintln!("[hub] could not write {} - the hub cannot start unauthenticated",
                          users_path.display());
                std::process::exit(1);
            }
        }
        shared.lock_or_recover().users = store;
    } //--- end of the M9 bootstrap (or its --users none bypass)

    let mut last_rcpt_relayed: std::collections::HashMap<(String, String), (String, Instant)> =
        std::collections::HashMap::new();
    let mut last_rcpt_prune = Instant::now();

    while !EXIT.load(Ordering::SeqCst) {
        match sock.poll(zmq::POLLIN, POLL_MS) {
            Ok(0) => {} // timeout - nothing to do, fall through to stats
            Ok(_) => {
                let parts = match sock.recv_multipart(zmq::DONTWAIT) {
                    Ok(p) => p,
                    //--- raced away between poll and recv; not an error
                    Err(zmq::Error::EAGAIN) => Vec::new(),
                    Err(e) => {
                        eprintln!("[hub] recv failed: {}", e);
                        Vec::new()
                    }
                };

                if parts.len() == 1 {
                    //--- a subscription change, NOT data. XPUB delivers these on
                    //--- the same socket, so they must be told apart by SHAPE
                    //--- (one frame) rather than assumed to be data.
                    let b = &parts[0];
                    if !b.is_empty() && (b[0] == 1 || b[0] == 0) {
                        let prefix: String = b[1..].iter().map(|c| *c as char).collect();
                        if b[0] == 1 {
                            if st.subs.insert(prefix.clone()) {
                                println!("[hub] +sub {:<24} {}", prefix, describe_sub(&prefix));
                            }
                        } else {
                            st.subs.remove(&prefix);
                            println!(
                                "[hub] -sub {:<24} (last subscriber for this prefix left)",
                                prefix
                            );
                        }
                    } else {
                        //--- One frame, and not a subscription. The hub cannot
                        //--- route it - it has no topic to route BY - so it is
                        //--- dropped. Counted rather than swallowed: a node
                        //--- sending its uplink the direct way (one frame) is a
                        //--- real protocol mismatch, and until this counter
                        //--- existed it produced NO symptom whatsoever.
                        st.note_single_dropped();
                    }
                } else if parts.len() >= 2 {
                    let topic = parts[0].clone();
                    let payload = parts[1].clone();
                    let ts: String = topic.iter().map(|c| *c as char).collect();

                    if !payload.starts_with(b"V=") {
                        st.note_dropped();
                        dropped_since_log += 1;
                        if args.verbose || last_drop_log.elapsed() >= Duration::from_secs(2) {
                            if dropped_since_log > 1 && !args.verbose {
                                println!(
                                    "[hub] DROP  topic={}  {} bytes, does not start with 'V=' ({} dropped in last {:.1}s)",
                                    ts,
                                    payload.len(),
                                    dropped_since_log,
                                    last_drop_log.elapsed().as_secs_f32()
                                );
                            } else {
                                println!(
                                    "[hub] DROP  topic={}  {} bytes, does not start with 'V='",
                                    ts,
                                    payload.len()
                                );
                            }
                            last_drop_log = Instant::now();
                            dropped_since_log = 0;
                        }
                    } else if topic.starts_with(b"@") {
                        let ty = envelope_type(&payload);
                        st.note_control(&ty);

                        //--- ROUTINE TRAFFIC IS NOT LOGGED BY DEFAULT.
                        //---
                        //--- PING fires every 2 s per sender and HBT2 every 5 s
                        //--- per node, so logging them buries everything that
                        //--- is NOT routine under a wall of lines - which is
                        //--- precisely the failure this project keeps having to
                        //--- un-learn: an operator who cannot see the signal
                        //--- stops reading the log at all.
                        //---
                        //--- They are still COUNTED (the stats line shows the
                        //--- rate), and --verbose prints them. Events - REG,
                        //--- ACK, CFGR, and anything unrecognised - always
                        //--- print, because those are the ones worth reading.
                        //---
                        //--- STAT IS ON THE LIST, AND WHY IS WORTH KEEPING. It
                        //--- used to be a once-a-minute monitoring report and was
                        //--- correctly NOT routine. It now also carries a
                        //--- snapshot receipt every `SyncHeartbeatSeconds`
                        //--- (default 1) **per mirrored sender**, so a receiver
                        //--- mirroring two senders emits two a second.
                        //---
                        //--- Measured live before this line changed: 1612 lines
                        //--- in 390 s, ~4/s, on a deployment of two senders and
                        //--- two receivers - and the rate scales linearly with
                        //--- receivers x senders, which is exactly the axis a
                        //--- hundred-node hub grows along. ~28 MB/day here.
                        //---
                        //--- Nothing was lost by suppressing it: `control_note`
                        //--- answers "" for STAT, so the entire line was
                        //--- "[hub] up @hub T=STAT" - the type and nothing else.
                        //--- The rate and per-type totals remain on the stats
                        //--- line, and the receipt relay is counted separately
                        //--- as `receipts`. --verbose still prints every one.
                        let routine = ty == "PING" || ty == "HBT2" || ty == "STAT";
                        if args.verbose || !routine {
                            println!(
                                "[hub] up    {:<14} T={:<5} {}",
                                ts,
                                ty,
                                control_note(&payload, &ty)
                            );
                        }

                        //--- ANSWER PINGS. This is the one thing the hub
                        //--- originates, and it is not scope creep: a node
                        //--- cannot otherwise tell a working hub link from a
                        //--- dead one. ZMQ connect() succeeds immediately
                        //--- whether or not anything is listening, so without
                        //--- an echo the sender's panel would show "connected"
                        //--- against a hub that does not exist.
                        if ty == "PING" {
                            let nid = envelope_kv(&payload, "FROM");
                            let ms = envelope_kv(&payload, "MS");
                            if !nid.is_empty() && !ms.is_empty() {
                                if let Err(e) = send_pong(&sock, &nid, &ms, &mut state) {
                                    eprintln!("[hub] PONG failed: {}", e);
                                }
                            }
                        }

                        //--- REGISTRY. The hub learns who exists ONLY from
                        //--- these two messages. It never probes for nodes,
                        //--- never guesses, and never writes to one - a node
                        //--- that stays silent stays invisible, which is the
                        //--- right failure: silence is not a claim.
                        if ty == "REG" || ty == "HBT2" {
                            let role = envelope_kv(&payload, "ROLE");
                            let acc = envelope_kv(&payload, "ACC");
                            if acc.is_empty() {
                                //--- ACC is the identity. Without it the node
                                //--- cannot even be addressed, so it is not a
                                //--- node - it is a message with no return
                                //--- address, and saying so beats filing it
                                //--- under an empty key forever.
                                println!("[hub] WARN  {} with no ACC - not registered", ty);
                                audit.record(
                                    "", "",
                                    "node.malformed",
                                    "",
                                    None,
                                    Some(serde_json::json!({ "type": ty, "role": role })),
                                    "rejected",
                                );
                            } else {
                                let ver = envelope_kv(&payload, "VER");
                                let up: u64 = envelope_kv(&payload, "UP").parse().unwrap_or(0);
                                let now = Instant::now();
                                //--- The node's own config revision, if it has
                                //--- one. Recorded for every REG and HBT2 so
                                //--- the view stays current, and used below to
                                //--- decide whether the hub owes it a push.
                                let node_rev: u64 =
                                    envelope_kv(&payload, "REV").parse().unwrap_or(0);
                                if node_rev > 0 {
                                    let mut s = shared.lock_or_recover();
                                    s.node_rev
                                        .insert(format!("{}:{}", role, acc), node_rev);
                                }
                                //--- M6: the node's own clock, for drift
                                //--- detection. REG and HBT2 both carry TS.
                                //--- Captured here but APPLIED BELOW, after
                                //--- on_reg/on_hbt has had its say: note_ts
                                //--- deliberately does not create nodes (a
                                //--- STAT must not), and a call that lands
                                //--- before the registration would silently
                                //--- no-op on a node's very first REG - the
                                //--- baseline would never be set and no drift
                                //--- could ever fire.
                                let node_ts: i64 =
                                    envelope_hdr(&payload, "TS").parse().unwrap_or(0);
                                if ty == "REG" {
                                    let name = envelope_kv(&payload, "NAME");
                                    let node_key = format!("{}:{}", role, acc);
                                    let ih = envelope_kv(&payload, "IH");
                                    let ini_esc = envelope_kv(&payload, "INI");

                                    if role == "receiver" {
                                        if !ini_esc.is_empty() {
                                            // Backward compatibility: legacy receiver reporting full INI on REG
                                            let current_ini = config::unescape_ini(&ini_esc);
                                            let chash = config::cfg_hash(&current_ini);
                                            let mut s = shared.lock_or_recover();
                                            s.node_current_ini.insert(node_key.clone(), api::CurrentSetting {
                                                ini: current_ini,
                                                ts: unix_secs(),
                                                hash: chash,
                                            });
                                        } else if !ih.is_empty() {
                                            // Modern receiver: 32-byte content hash comparison
                                            let needs_pull = {
                                                let s = shared.lock_or_recover();
                                                match s.node_current_ini.get(&node_key) {
                                                    Some(cur) => cur.hash != ih,
                                                    None => true, // hub has no record yet (e.g. freshly restarted)
                                                }
                                            };
                                            if needs_pull {
                                                let (throttled, attempts) = match last_cfg_pull.get(&node_key) {
                                                    Some(&(last_t, attempts)) => {
                                                        // First retry allowed after 5s for fast bootstrap/reconnect recovery;
                                                        // subsequent retries back off to 60s to prevent command flood.
                                                        let delay = if attempts <= 1 {
                                                            Duration::from_secs(5)
                                                        } else {
                                                            Duration::from_secs(60)
                                                        };
                                                        (last_t.elapsed() < delay, attempts)
                                                    }
                                                    None => (false, 0),
                                                };
                                                if !throttled {
                                                    last_cfg_pull.insert(node_key.clone(), (Instant::now(), attempts + 1));
                                                    println!("[hub] {} reports IH={} (mismatch or empty) - requesting full config via reqcfg (attempt {})", node_key, ih, attempts + 1);
                                                    cmds.issue_op(&node_key, "reqcfg", "", "hub", "127.0.0.1");
                                                }
                                            }
                                        }
                                    }
                                    //--- captured BEFORE the update, because
                                    //--- "it had no name and now it does" is
                                    //--- the event worth reporting.
                                    let was_unnamed = {
                                        let s = shared.lock_or_recover();
                                        s.reg.is_unnamed(&role, &acc)
                                    };
                                    let is_new = {
                                        let mut s = shared.lock_or_recover();
                                        let n = s.reg.on_reg(&role, &acc, &ver, &name, up, now);
                                        n
                                    };
                                    poke();
                                    if is_new {
                                        println!(
                                            "[hub] +node {:<20} {:<16} ver {} up {}s",
                                            format!("{}:{}", role, acc),
                                            if name.is_empty() { "-" } else { name.as_str() },
                                            if ver.is_empty() { "?" } else { ver.as_str() },
                                            up
                                        );
                                        audit.record(
                                            "", "",
                                            "node.registered",
                                            &format!("{}:{}", role, acc),
                                            None,
                                            Some(serde_json::json!({
                                                "role": role,
                                                "acc": acc,
                                                "name": name,
                                                "ver": ver,
                                                "up_secs": up,
                                            })),
                                            "ok",
                                        );
                                    } else if was_unnamed && !name.is_empty() {
                                        //--- The lost-REG race resolving. Worth a
                                        //--- line: until this arrives the node is
                                        //--- a row nobody can identify.
                                        println!(
                                            "[hub] named {:<20} {}",
                                            format!("{}:{}", role, acc),
                                            name
                                        );
                                        audit.record(
                                            "", "",
                                            "node.named",
                                            &format!("{}:{}", role, acc),
                                            Some(serde_json::json!({ "name": "" })),
                                            Some(serde_json::json!({ "name": name })),
                                            "ok",
                                        );
                                    }
                                } else {
                                    // NAME too, since the HBT2 change: a node
                                    // that only heartbeats used to be visible
                                    // but anonymous until a WHO sweep made it
                                    // re-REG - ten to fifteen seconds of blank
                                    // Name cells after a hub restart with the
                                    // EAs already attached.
                                    //
                                    // Read OUTSIDE the lock and outside the
                                    // block, because the reporting below needs
                                    // it as well as the registry does.
                                    let nm = envelope_kv(&payload, "NAME");
                                    let is_new = {
                                        let mut s = shared.lock_or_recover();
                                        s.reg.on_hbt(&role, &acc, &ver, &nm, up, now)
                                    };
                                    poke();
                                    //--- A node introduced by its HEARTBEAT means its
                                    //--- REG never arrived - the EAs' socket is
                                    //--- IMMEDIATE, so a send made before the TCP
                                    //--- connection completes is discarded rather
                                    //--- than queued. The node is real, so it is
                                    //--- reported; but it is ANONYMOUS, and saying
                                    //--- so is the difference between a row nobody
                                    //--- can identify and a known race.
                                    if is_new {
                                        //--- The old wording here said "no NAME
                                        //--- yet, its REG was lost", which was
                                        //--- true until HBT2 started carrying
                                        //--- NAME. What is lost is the REG, not
                                        //--- the name, and the distinction is
                                        //--- the whole point of the HBT2 change.
                                        println!(
                                            "[hub] +node {:<20} {:<16} ver {} up {}s  \
                                             (from HBT2 - its REG was lost)",
                                            format!("{}:{}", role, acc),
                                            if nm.is_empty() { "-" } else { nm.as_str() },
                                            if ver.is_empty() { "?" } else { ver.as_str() },
                                            up
                                        );
                                        audit.record(
                                            "", "",
                                            "node.registered",
                                            &format!("{}:{}", role, acc),
                                            None,
                                            Some(serde_json::json!({
                                                "role": role,
                                                "acc": acc,
                                                "name": nm,
                                                "via": "heartbeat",
                                                "note": "its REG was lost",
                                            })),
                                            "ok",
                                        );
                                    } else if args.verbose {
                                        println!(
                                            "[hub] hbt   {:<20} up {}s",
                                            format!("{}:{}", role, acc),
                                            up
                                        );
                                    }
                                }

                                //--- M6: the node's clock, now that the node
                                //--- exists (REG created it, or HBT2 implies
                                //--- it registered earlier). Baseline on the
                                //--- first observation, jump-detect ever after.
                                if node_ts > 0 {
                                    let mut s = shared.lock_or_recover();
                                    s.reg.note_ts(&role, &acc, node_ts, unix_secs() as i64);
                                }
                                //--- M5b on the dashboard: the node's own
                                //--- hub-pause report (PAUSED= on REG/HBT2).
                                //--- A sender never sends it, and a missing
                                //--- field means "not paused" - an old EA
                                //--- simply predates the flag.
                                {
                                    let paused = envelope_kv(&payload, "PAUSED");
                                    if !paused.is_empty() {
                                        let mut s = shared.lock_or_recover();
                                        s.reg.note_paused(&role, &acc, paused == "1");
                                    }
                                }
                                if let Ok(ping_ms) = envelope_kv(&payload, "PING").parse::<u64>() {
                                    let mut s = shared.lock_or_recover();
                                    s.reg.note_ping(&role, &acc, ping_ms);
                                }

                                //--- THE CONFIG COMPARISON (§7.3). Only for a
                                //--- receiver: a sender has no ini to manage.
                                //---
                                //--- Three outcomes, and the middle one is the
                                //--- one that must NOT be silent:
                                //---   node < hub  -> the node is behind; push
                                //---   node = hub  -> in step, nothing to do
                                //---   node > hub  -> DRIFT. Somebody edited
                                //---                    the node by hand.
                                //--- §7.4 is explicit that this is reported,
                                //--- not silently overwritten: the hub being
                                //--- the source of truth does not make an
                                //--- unexplained difference something to
                                //--- erase.
                                if role == "receiver" && node_rev > 0 {
                                    let key = format!("{}:{}", role, acc);
                                    let hub_rev = cfg.current(&key).map(|r| r.rev).unwrap_or(0);
                                    if hub_rev > 0 && node_rev > hub_rev {
                                        println!(
                                            "[hub] WARN  {} reports config REV {} but this hub \
                                             issued {} - drifted, not overwriting",
                                            key, node_rev, hub_rev
                                        );
                                        audit.record(
                                            "",
                                            "",
                                            "config.drift",
                                            &key,
                                            Some(serde_json::json!({ "hub_rev": hub_rev })),
                                            Some(serde_json::json!({ "node_rev": node_rev })),
                                            "drift",
                                        );
                                    } else if hub_rev > 0 && node_rev < hub_rev && args.writes {
                                        //--- Behind, and the hub is allowed to
                                        //--- act. Registers the command (which
                                        //--- the retry loop below will send) and
                                        //--- nudges it to fire immediately.
                                        if let Some(r) = cfg.current(&key) {
                                            let c = cmds.issue_cfg(&key, r.rev, "", "");
                                            println!(
                                                "[hub] {} is behind (rev {} < {}) - pushing CFG {}",
                                                key, node_rev, r.rev, c.id
                                            );
                                            audit.record(
                                                "",
                                                "",
                                                "config.repush",
                                                &key,
                                                Some(serde_json::json!({ "node_rev": node_rev })),
                                                Some(serde_json::json!({ "hub_rev": r.rev })),
                                                "ok",
                                            );
                                        }
                                    }
                                }
                            }
                        }

                        //--- SNAPSHOT RECEIPT RELAY.
                        //---
                        //--- A receiver's STAT arrives here on '@hub' and is
                        //--- consumed, like every other '@' message - the hub
                        //--- does not forward it, by D13. But the receipt
                        //--- inside it is the one part that has to reach the
                        //--- sender, so it is extracted and relayed alone.
                        //---
                        //--- SID is read from the PAYLOAD section, never from
                        //--- the envelope header: a receiver's STAT carries
                        //--- `SID=receiver` in the header and `SID=<sender nid>`
                        //--- in the payload, and `envelope_kv` searches only
                        //--- after '|P=' precisely so this cannot go wrong.
                        //--- (see the `kv_does_not_read_the_envelope_header`
                        //--- test in envelope.rs).
                        //---
                        //--- A STAT with no SID is an older receiver that
                        //--- predates the receipt: there is no sender to
                        //--- address it to and no hash in it, so it is left
                        //--- alone. H may legitimately be empty - that means
                        //--- "no snapshot ingested yet", which the sender is
                        //--- told, because it is not the same as a wrong hash.
                        //--- ACK: a node confirming it applied a CFG.
                        //---
                        //--- An ACK for a command the hub does not know about
                        //--- is REPORTED, not ignored. It means a node acted on
                        //--- something this hub has no record of sending, which
                        //--- in the §11 primary/standby arrangement is a normal
                        //--- race - and anywhere else is worth knowing about.
                        if ty == "ACK" {
                            let id = envelope_kv(&payload, "ID");
                            let ok = envelope_kv(&payload, "OK") == "1";
                            let rev: u64 = envelope_kv(&payload, "REV").parse().unwrap_or(0);
                            let err = envelope_kv(&payload, "ERR");
                            //--- The node and the KIND are derived from the
                            //--- COMMAND, not from the message. An ACK carries no
                            //--- ACC - it does not need one, because the id it
                            //--- quotes already encodes the node (`<node>R<rev>`
                            //--- or `<node>-<op>-<seq>`). Reading the node back
                            //--- out of the command also means an ACK can only
                            //--- ever be attributed to a node the hub actually
                            //--- sent something to. The KIND decides which audit
                            //--- action names the result.
                            let (who, kind, op) = cmds
                                .command(&id)
                                .map(|c| (c.node, c.kind, c.op))
                                .unwrap_or_else(|| ("?".to_string(), String::new(), String::new()));
                            let prefix = if kind == commands::KIND_OP { "command" } else { "config" };
                            if id.is_empty() {
                                println!("[hub] WARN  ACK with no ID");
                            } else if cmds.ack(&id, ok, rev, &err) {
                                println!(
                                    "[hub] {} {} {} ({} {}) rev {}",
                                    who,
                                    if ok { "applied" } else { "REJECTED" },
                                    id,
                                    prefix,
                                    op,
                                    rev
                                );
                                let action = if ok {
                                    format!("{}.acked", prefix)
                                } else {
                                    format!("{}.rejected", prefix)
                                };
                                audit.record(
                                    "",
                                    "",
                                    &action,
                                    &who,
                                    None,
                                    Some(serde_json::json!({
                                        "id": id, "kind": kind, "op": op, "rev": rev, "err": err,
                                    })),
                                    if ok { "ok" } else { "rejected" },
                                );
                            } else {
                                println!(
                                    "[hub] WARN  {} ACKed {} which this hub never sent",
                                    who, id
                                );
                                // `prefix` is "config" here only because the
                                // unknown id left `kind` empty - derive it from
                                // the id's shape instead (see unknown_ack_prefix).
                                let action = format!("{}.unknown_ack", unknown_ack_prefix(&id));
                                let throttle_key = (who.clone(), action.clone());
                                let should_audit = match wire_audit_throttle.get(&throttle_key) {
                                    Some(t) => t.elapsed() >= Duration::from_secs(10),
                                    None => true,
                                };
                                if should_audit {
                                    wire_audit_throttle.insert(throttle_key, Instant::now());
                                    audit.record(
                                        "",
                                        "",
                                        &action,
                                        &who,
                                        None,
                                        Some(serde_json::json!({ "id": id })),
                                        "unknown",
                                    );
                                }
                            }
                        }

                        //--- CFGR: a node asking for its config again.
                        //---
                        //--- This is the self-heal path (§7.3). A node that
                        //--- restarted with a stale ini, or lost a push, can ask
                        //--- rather than wait for the next REG comparison.
                        if ty == "CFGR" {
                            //--- CFGR DOES carry ACC (the plan's §5.2), because
                            //--- unlike an ACK there is no command id to derive
                            //--- the node from - the node is asking for
                            //--- something the hub may not have sent yet.
                            let crole = envelope_kv(&payload, "ROLE");
                            let cacc = envelope_kv(&payload, "ACC");
                            let key = if crole.is_empty() {
                                format!("receiver:{}", cacc)
                            } else {
                                format!("{}:{}", crole, cacc)
                            };
                            match cfg.current(&key) {
                                Some(r) => {
                                    let c = cmds.issue_cfg(&key, r.rev, "", "");
                                    println!(
                                        "[hub] {} asked for its config - sending {} (rev {})",
                                        key, c.id, r.rev
                                    );
                                    if let Err(e) =
                                        send_cfg(&sock, &mut state, &key, &c.id, r.rev, &r.ini)
                                    {
                                        eprintln!("[hub] CFG send failed: {}", e);
                                    }
                                }
                                None => println!(
                                    "[hub] {} asked for its config but this hub has none",
                                    key
                                ),
                            }
                        }

                        //--- CFGRPT: a receiver reporting its current live/effective configuration
                        if ty == "CFGRPT" {
                            let crole = envelope_kv(&payload, "ROLE");
                            let cacc = envelope_kv(&payload, "ACC");
                            let ini_esc = envelope_kv(&payload, "INI");
                            let rev: u64 = envelope_kv(&payload, "REV").parse().unwrap_or(0);
                            let key = if crole.is_empty() {
                                format!("receiver:{}", cacc)
                            } else {
                                format!("{}:{}", crole, cacc)
                            };
                            if !ini_esc.is_empty() {
                                let current_ini = config::unescape_ini(&ini_esc);
                                let chash = config::cfg_hash(&current_ini);
                                let mut s = shared.lock_or_recover();
                                s.node_current_ini.insert(key.clone(), api::CurrentSetting {
                                    ini: current_ini,
                                    ts: unix_secs(),
                                    hash: chash,
                                });
                                if rev > 0 {
                                    s.node_rev.insert(key.clone(), rev);
                                }
                            }
                            println!("[hub] {} reported current effective config (rev {})", key, rev);
                            last_cfg_pull.remove(&key);
                            poke();
                        }

                        if ty == "STAT" {
                            let sid = envelope_kv(&payload, "SID");
                            if !sid.is_empty() {
                                let login = envelope_kv(&payload, "LOGIN");
                                let h = envelope_kv(&payload, "H");
                                //--- M6: the risk state rides the SAME STAT the
                                //--- receipt does. BLOCKED counts entries the
                                //--- receiver's risk gate is holding back;
                                //--- RISK names the limit when one tripped.
                                //--- The node is LOGIN, and a sender's STAT is
                                //--- not relayed here - receivers only.
                                let blocked: u32 =
                                    envelope_kv(&payload, "BLOCKED").parse().unwrap_or(0);
                                let risk = envelope_kv(&payload, "RISK");
                                //--- Position figures ride receipt heartbeats
                                //--- (default 1s); full RISK/BLOCKED data is
                                //--- only included in the minute report.
                                let held: Option<u32> =
                                    envelope_kv(&payload, "HELD").parse().ok();
                                let held_lots: f64 =
                                    envelope_kv(&payload, "LOTS").parse().unwrap_or(0.0);
                                let orphaned: Option<u32> =
                                    envelope_kv(&payload, "ORPHAN").parse().ok();
                                let wait_total: Option<u32> =
                                    envelope_kv(&payload, "WAIT").parse().ok();
                                let wait_lots: f64 =
                                    envelope_kv(&payload, "WLOTS").parse().unwrap_or(0.0);
                                let wait_queued: Option<u32> =
                                    envelope_kv(&payload, "WQUEUED").parse().ok();
                                let wait_delayed: Option<u32> =
                                    envelope_kv(&payload, "WDELAYED").parse().ok();
                                let wait_mkt: Option<u32> =
                                    envelope_kv(&payload, "WMKT").parse().ok();
                                let equity: Option<f64> =
                                    envelope_kv(&payload, "EQ").parse().ok();
                                let balance: Option<f64> =
                                    envelope_kv(&payload, "BL").parse().ok();
                                let held_items = envelope_kv_opt(&payload, "POS")
                                    .map(|s| registry::parse_receiver_positions(&s));
                                let wait_items = envelope_kv_opt(&payload, "WAITLIST")
                                    .map(|s| registry::parse_receiver_waitlist(&s));
                                //--- One lock for both: note_stat and the
                                //--- mirror edge are written by the same
                                //--- frame, and acquiring the shared mutex
                                //--- twice per STAT (1/s per receiver) is two
                                //--- round trips through a contended lock for
                                //--- one line of state.
                                if !login.is_empty() {
                                    let mut s = shared.lock_or_recover();
                                    if !risk.is_empty() || held.is_some() || wait_total.is_some() || equity.is_some() {
                                        s.reg.note_stat(
                                            "receiver",
                                            &login,
                                            blocked,
                                            &risk,
                                            held,
                                            held_lots,
                                            orphaned,
                                            wait_total,
                                            wait_lots,
                                            wait_queued,
                                            wait_delayed,
                                            wait_mkt,
                                            equity,
                                            balance,
                                            held_items,
                                            wait_items,
                                        );
                                    }
                                    if let Ok(ping_ms) = envelope_kv(&payload, "PING").parse::<u64>() {
                                        s.reg.note_ping("receiver", &login, ping_ms);
                                    }
                                    //--- LOGIN is the receiver's own account
                                    //--- and must be PRESENT: a STAT without
                                    //--- it (an old EA build, a forged frame)
                                    //--- would otherwise register the empty
                                    //--- string as a mirroring account, which
                                    //--- shows up in /topology as an edge to
                                    //--- "". A missing LOGIN means "this frame
                                    //--- says nothing about who mirrored",
                                    //--- never "somebody with no name".
                                    s.mirrors
                                        .entry(sid.clone())
                                        .or_default()
                                        .insert(login.clone(), Instant::now());
                                }
                                //--- THE RECEIPT IS RELAYED ONLY TO A REAL
                                //--- SENDER.
                                //---
                                //--- `SID` is a field the RECEIVER chooses, so
                                //--- without this check a receiver could make
                                //--- the hub unicast a `RCPT` to any nid on the
                                //--- fleet - including another receiver's -
                                //--- with any hash it liked. A sender acts on a
                                //--- receipt ("the snapshot I sent is the one
                                //--- you hold"), so a forged one either
                                //--- suppresses a real repair or triggers a
                                //--- repair flood. The hub already knows which
                                //--- nodes registered as senders; asking it is
                                //--- one short lookup.
                                //--- ...and the check is SKIPPED for the first
                                //--- minute and while the hub knows of no
                                //--- sender at all. Right after a restart the
                                //--- registry is rebuilt from HBT2/WHO, and a
                                //--- receiver's STAT can easily arrive before
                                //--- its sender's first heartbeat - measured
                                //--- live: one receipt was refused in that
                                //--- window on a 6 s run. Dropping it is
                                //--- harmless (a receipt only ever CONFIRMS),
                                //--- but the warning is noise, and a hub that
                                //--- cries wolf at every restart teaches the
                                //--- operator to ignore the line.
                                let warm = started.elapsed() < Duration::from_secs(60);
                                let (sid_is_sender, any_sender_known) = {
                                    let s = shared.lock_or_recover();
                                    let key = format!("sender:{}", sid);
                                    let nodes = s.reg.nodes();
                                    (
                                        nodes.iter().any(|n| n.key == key),
                                        nodes.iter().any(|n| n.key.starts_with("sender:")),
                                    )
                                };
                                if sid_is_sender || !any_sender_known || warm {
                                    //--- Count what ARRIVED, before the
                                    //--- de-duplication decides what to relay:
                                    //--- the difference between the two is the
                                    //--- saving, and reporting only the relays
                                    //--- would look like lost heartbeats.
                                    st.note_receipt_seen();
                                    //--- Forget pairs that stopped reporting.
                                    //--- A receiver that is renamed or moved
                                    //--- leaves its old key behind forever
                                    //--- otherwise, and this map has no other
                                    //--- eviction path.
                                    if last_rcpt_prune.elapsed() >= Duration::from_secs(60) {
                                        last_rcpt_prune = Instant::now();
                                        last_rcpt_relayed.retain(|_, (_, t)| {
                                            t.elapsed() < Duration::from_secs(600)
                                        });
                                    }
                                    let rcpt_key = (login.clone(), sid.clone());
                                    let should_relay = match last_rcpt_relayed.get(&rcpt_key) {
                                        Some((prev_h, last_t)) => {
                                            // Relay immediately if hash changed or empty (new node/change), or throttle to 3s in steady state
                                            prev_h != &h || h.is_empty() || last_t.elapsed() >= Duration::from_secs(3)
                                        }
                                        None => true, // First time seen
                                    };

                                    if should_relay {
                                        if let Err(e) =
                                            send_receipt(&sock, &sid, &login, &h, &mut state)
                                        {
                                            eprintln!("[hub] receipt relay failed: {}", e);
                                        } else {
                                            st.note_receipt();
                                            last_rcpt_relayed.insert(rcpt_key, (h.clone(), Instant::now()));
                                        }
                                    }
                                } else if last_rcpt_drop.elapsed() >= Duration::from_secs(60) {
                                    //--- Rate-limited: a misconfigured receiver
                                    //--- emits one STAT a second, and a line a
                                    //--- second buries everything else.
                                    last_rcpt_drop = Instant::now();
                                    println!(
                                        "[hub] WARN  STAT from {} names SID={} which is not a \
                                         registered sender - receipt NOT relayed \
                                         (further reports suppressed for 60s)",
                                        login, sid
                                    );
                                }
                                poke();
                            }
                        }
                    } else {
                        //--- THE FORWARD. Two frames, byte for byte. Zero-copy slice transmission.
                        //---
                        //--- Two frames are ONE message to ZeroMQ, which is why a
                        //--- failure between them cannot be shrugged off: the
                        //--- first part is already queued, so every later send on
                        //--- this socket would be appended to that same broken
                        //--- frame. A blocking send only fails here when the
                        //--- context is terminating, so the honest response is to
                        //--- stop rather than to keep writing into a torn message.
                        let fwd_res = sock.send(&topic, zmq::SNDMORE).and_then(|_| sock.send(&payload, 0));
                        if let Err(e) = fwd_res {
                            eprintln!(
                                "[hub] FATAL forward failed mid-message ({}): the socket is \
                                 left inside a multipart message - shutting down rather \
                                 than forwarding a torn frame",
                                e
                            );
                            EXIT.store(true, Ordering::SeqCst);
                            continue;
                        }

                        let ty = envelope_type(&payload);
                        st.note_forward(&ts, &ty);

                        //--- M3 POSITION VIEW - read-only, and deliberately
                        //--- AFTER the forward above.
                        //---
                        //--- Keyed by the envelope's SID, never by the topic:
                        //--- a targeted repair is published on the RECEIVER's
                        //--- nid, and keying by topic would file that receiver
                        //--- as a sender holding somebody else's positions.
                        if ty == "SNAP" {
                            let sid = envelope_hdr(&payload, "SID");
                            let snap_payload = envelope_payload(&payload);
                            let new_receipt = crate::positions::extract_receipt(snap_payload);
                            let pos_now = Instant::now();

                            let should_parse = {
                                let s = shared.lock_or_recover();
                                match s.pos.view_for(&sid) {
                                    Some(existing) => existing.receipt != new_receipt || new_receipt.is_empty(),
                                    None => true, // First snapshot seen from this sender
                                }
                            };

                            if should_parse {
                                let view = parse_snap(snap_payload);
                                let (declared, carried, mismatched_now) = {
                                    let mut s = shared.lock_or_recover();
                                    let before = s.pos.mismatched;
                                    s.pos.on_snap(&sid, &view, pos_now);
                                    (view.declared, view.records, s.pos.mismatched - before)
                                };
                                if mismatched_now > 0 {
                                    //--- A snapshot whose N= disagreed with what
                                    //--- arrived. This is a DATA-INTEGRITY event,
                                    //--- not a transport one - the frame was
                                    //--- whole, its own header was wrong - so it
                                    //--- belongs in the audit rather than in a
                                    //--- counter nobody watches.
                                    let throttle_key = (format!("sender:{}", sid), "snapshot.mismatch".to_string());
                                    let should_audit = match wire_audit_throttle.get(&throttle_key) {
                                        Some(t) => t.elapsed() >= Duration::from_secs(10),
                                        None => true,
                                    };
                                    if should_audit {
                                        wire_audit_throttle.insert(throttle_key, Instant::now());
                                        audit.record(
                                            "", "",
                                            "snapshot.mismatch",
                                            &format!("sender:{}", sid),
                                            None,
                                            Some(serde_json::json!({
                                                "declared": declared,
                                                "carried": carried,
                                            })),
                                            "mismatch",
                                        );
                                    }
                                }
                            } else {
                                // Touch timestamp so eviction does not prune it while unchanged
                                let mut s = shared.lock_or_recover();
                                s.pos.touch(&sid, pos_now);
                            }
                            poke();
                        }

                        //--- events are rare and worth seeing by default; SNAP
                        //--- and HBT fire continuously and are what the stats
                        //--- line is for
                        if args.verbose || ty == "OPEN" || ty == "CLOSE" {
                            println!(
                                "[hub] fwd   {:<14} T={:<5} {}",
                                ts,
                                ty,
                                envelope_kv(&payload, "SYM")
                            );
                        }
                    }
                }
            }
            Err(e) => eprintln!("[hub] poll failed: {}", e),
        }

        if args.stats_every > 0.0 && last_stats.elapsed().as_secs_f64() >= args.stats_every {
            last_stats = Instant::now();
            st.print_and_reset();
            let snap = { let s = shared.lock_or_recover(); s.clone_view() };
            print_positions(&snap);
        }

        //--- M6: the alert tick. Separate from --stats-every ON PURPOSE:
        //--- alerts are an operational signal, not a console summary, and a
        //--- 30 s cadence is too slow to notice a dead node in. The engine
        //--- dedups and silences, so a 5 s tick does not mean a line every
        //--- 5 s - it means a missed event is under 5 s old.
        if last_alerts.elapsed().as_secs_f64() >= alerts::EVERY_SECS {
            last_alerts = Instant::now();
            let fired = {
                let mut s = shared.lock_or_recover();
                alerts::evaluate(&mut s, unix_secs())
            };
            for a in fired {
                println!(
                    "[hub] ALERT {:<20} {:<22} {}",
                    a.kind,
                    if a.node.is_empty() { "-" } else { a.node.as_str() },
                    a.detail
                );
                audit.record("hub", "", &a.action(), &a.node, None, Some(a.detail.clone()), "firing");
                //--- Dispatch alert to external notification channels
                {
                    let s = shared.lock_or_recover();
                    if let Some(tx) = &s.notif_tx {
                        let _ = tx.send(a.clone());
                    }
                }
                //--- Wake the dashboards: an alert is exactly the state
                //--- change the WebSocket exists for.
                poke();
            }
        }

        //--- Ask for registrations. Fast while nobody has answered - the first
        //--- ask may go out before a node has finished reconnecting - and then
        //--- a slow sweep, because a node whose one REG was dropped is
        //--- otherwise invisible for the rest of its life.
        let who_every = {
            let s = shared.lock_or_recover();
            if s.reg.is_empty() {
                WHO_EVERY_SECS
            } else {
                WHO_SWEEP_SECS
            }
        };
        if last_who.elapsed().as_secs_f64() >= who_every {
            last_who = Instant::now();
            who_nonce += 1;
            if let Err(e) = send_who(&sock, who_nonce, &mut state) {
                eprintln!("[hub] WHO failed: {}", e);
            }
        }

        //--- Report node state, but only when it CHANGES. A node going offline
        //--- is an event and should not have to wait for the next stats window.
        if last_registry.elapsed().as_secs_f64() >= REGISTRY_EVERY_SECS {
            last_registry = Instant::now();
            wire_audit_throttle.retain(|_, t| t.elapsed() < Duration::from_secs(60));
            let now = Instant::now();
            let counts = {
                let mut s = shared.lock_or_recover();
                //--- Liveness transitions are recorded BEFORE eviction, so a
                //--- node that goes straight from online to forgotten still
                //--- leaves both records in order.
                let mut transitions: Vec<(String, Liveness, Liveness)> = Vec::new();
                //--- Nodes this sweep sees for the FIRST time: every node the
                //--- sweep right after a hub restart, and a node that
                //--- re-appears after eviction. They get a silent baseline.
                //---
                //--- Without this seed the map NEVER populates: the first
                //--- observation is the only thing that can add an entry, and
                //--- it used to add nothing - so no transition could ever be
                //--- observed for any node and node.offline/node.online were
                //--- dead code (found by review, not by a test: the
                //--- transitions themselves were correct, the map just stayed
                //--- empty). A baseline is exactly what a transition detector
                //--- needs, and the first sweep after start is no less a
                //--- baseline than any other.
                let mut seed: Vec<(String, Liveness)> = Vec::new();
                for n in s.reg.nodes() {
                    let live = n.liveness(now);
                    match last_liveness.get(&n.key) {
                        Some(prev) if *prev != live => {
                            transitions.push((n.key.clone(), *prev, live));
                        }
                        None => seed.push((n.key.clone(), live)),
                        _ => {}
                    }
                }
                let forgotten = s.reg.evict(now);
                //--- Retain the per-node side tables that are keyed by the
                //--- SAME "<role>:<acc>" the registry just forgot. They used
                //--- to be written forever: node_rev grew on every CFGRPT of
                //--- every node, node_current_ini on every CFGRPT/CFG, and a
                //--- hub that runs for weeks against a pilot that keeps
                //--- re-imaging its chart accounts grew them without bound.
                //--- Eviction is the one place the hub decides a node is gone,
                //--- so it is the one place they can be reclaimed.
                for key in &forgotten {
                    s.node_rev.remove(key);
                    s.node_current_ini.remove(key);
                    //--- The alert engine's per-node state goes with the node,
                    //--- for the same reason: it was written per node seen and
                    //--- never reclaimed. A key reused after eviction must not
                    //--- inherit the old `was_offline` latch, or the next
                    //--- observation looks like a recovery and reports one.
                    s.alerts.forget(key);
                    //--- mirrors is keyed by the SENDER, so an evicted sender
                    //--- takes its whole edge map with it.
                    if let Some((role, acc)) = key.split_once(':') {
                        if role == "sender" {
                            s.mirrors.remove(acc);
                        }
                    }
                }
                //--- `last_liveness` lives outside `s` and grew the same way:
                //--- one row per node ever seen, never removed.
                for key in &forgotten {
                    last_liveness.remove(key);
                }
                //--- Age the mirror EDGES by their own timestamps. The registry
                //--- can keep a receiver online on heartbeats alone while its
                //--- STATs - the frames that carry the edge - stopped, and a
                //--- forged SID nobody ever registered would otherwise keep a
                //--- key forever. The inner timestamps are refreshed by every
                //--- receipt heartbeat (default 1/s), so a live edge is never
                //--- more than a second or two old; one 30 minutes old is a
                //--- receiver that stopped mirroring.
                for recvs in s.mirrors.values_mut() {
                    recvs.retain(|_, ts| {
                        now.saturating_duration_since(*ts) < crate::registry::EVICT_AFTER
                    });
                }
                s.mirrors.retain(|_, recvs| !recvs.is_empty());
                //--- The position view ages out on the same sweep, so a hub left
                //--- running for weeks does not keep a row per sender that ever
                //--- existed. Silent: a sender going quiet is already reported
                //--- by the registry line above, and one event should not
                //--- print twice.
                s.pos.evict(now);
                drop(s);

                for (key, live) in seed {
                    last_liveness.insert(key, live);
                }
                for (key, prev, now_live) in transitions {
                    last_liveness.insert(key.clone(), now_live);
                    //--- Only the two that a reader acts on. ONLINE->STALE is
                    //--- also a transition and is NOT recorded: it is a
                    //--- halfway house on the way to offline, it is normal on
                    //--- any brief hiccup, and recording it would triple the
                    //--- log to say the same thing twice.
                    if now_live == Liveness::Offline {
                        audit.record(
                            "", "",
                            "node.offline",
                            &key,
                            Some(serde_json::json!({ "liveness": live_str(prev) })),
                            Some(serde_json::json!({ "liveness": "offline" })),
                            "ok",
                        );
                    } else if now_live == Liveness::Online && prev == Liveness::Offline {
                        audit.record(
                            "", "",
                            "node.online",
                            &key,
                            Some(serde_json::json!({ "liveness": "offline" })),
                            Some(serde_json::json!({ "liveness": "online" })),
                            "ok",
                        );
                    }
                }
                for key in forgotten {
                    last_liveness.remove(&key);
                    audit.record(
                        "", "",
                        "node.evicted",
                        &key,
                        Some(serde_json::json!({ "liveness": "offline" })),
                        None,
                        "ok",
                    );
                }

                let s = shared.lock_or_recover();
                (
                    s.reg.count(Liveness::Online, now),
                    s.reg.count(Liveness::Stale, now),
                    s.reg.count(Liveness::Offline, now),
                    s.reg.len(),
                )
            };
            if (counts.0, counts.1, counts.2) != last_counts {
                last_counts = (counts.0, counts.1, counts.2);
                println!(
                    "[hub] nodes online {}  stale {}  offline {}  (total {})",
                    counts.0, counts.1, counts.2, counts.3
                );
            }
        }

        //--- The CFG retry ladder. `due` advances the ladder as it hands a
        //--- command out, so a node that never answers walks 2 → 5 → 15 → 60 →
        //--- unknown without needing anything else to happen.
        //---
        //--- Gated on `writes` as well as on there being a command, except for
        //--- read-only telemetry queries like `reqpos` which are safe to dispatch.
        for c in cmds.due(Instant::now()) {
            if !args.writes && !commands::is_read_only_op(&c.op) {
                continue;
            }
            match c.kind.as_str() {
                    commands::KIND_CONFIG => {
                        match cfg.current(&c.node) {
                            Some(r) if r.rev == c.rev => {
                                if let Err(e) =
                                    send_cfg(&sock, &mut state, &c.node, &c.id, c.rev, &r.ini)
                                {
                                    eprintln!("[hub] CFG retry failed: {}", e);
                                }
                            }
                            //--- The command is for a revision that is no longer
                            //--- current: a newer config superseded it while it
                            //--- was in flight. Sending the OLD one now would
                            //--- undo the newer change on that node, which is the
                            //--- one way this loop could do harm. Drop it
                            //--- instead, and say so.
                            Some(r) => {
                                println!(
                                    "[hub] dropping stale CFG {} (rev {} superseded by {})",
                                    c.id, c.rev, r.rev
                                );
                            }
                            None => {}
                        }
                    }
                    commands::KIND_OP => {
                        if let Err(e) =
                            send_cmd(&sock, &mut state, &c.node, &c.id, &c.op, &c.args)
                        {
                            eprintln!("[hub] CMD retry failed: {}", e);
                        }
                    }
                    _ => {}
                }
                if c.state == commands::STATE_UNKNOWN {
                    let prefix = if c.kind == commands::KIND_OP { "command" } else { "config" };
                    println!(
                        "[hub] ALERT {} never acknowledged {} ({} {}) after {} attempt(s): {}",
                        c.node, c.id, prefix, c.op, c.attempts, c.err
                    );
                    let action = format!("{}.timeout", prefix);
                    audit.record(
                        "",
                        "",
                        &action,
                        &c.node,
                        None,
                        Some(serde_json::json!({
                            "id": c.id, "kind": c.kind, "op": c.op, "attempts": c.attempts,
                        })),
                        "unknown",
                    );
                }
            }

        if args.duration > 0.0 && started.elapsed().as_secs_f64() >= args.duration {
            println!("[hub] duration reached, exiting");
            break;
        }
    }

    audit.record(
        "",
        "",
        "hub.stopped",
        "",
        None,
        Some(serde_json::json!({ "pid": std::process::id() })),
        "ok",
    );

    println!();
    println!("[hub] final stats");
    //--- The last window, then the whole run. Both, because they answer
    //--- different questions and a reader wants the second one here.
    st.print_and_reset();
    st.print_totals();
    //--- last chance to see what the senders were carrying
    let final_view = { let s = shared.lock_or_recover(); s.clone_view() };
    print_positions(&final_view);

    //--- The node table, in full. On a hub that is being shut down this is the
    //--- last chance to see who was connected, and it costs nothing.
    //---
    //--- The lock IS held across the printing here, which violates the rule
    //--- `clone_view` exists for - and it is safe for a reason that is worth
    //--- stating rather than assuming: this runs after the loop has exited, so
    //--- nothing is updating the registry and nothing is waiting on the API.
    //--- There is no third thread to stall. When that stops being true, this
    //--- needs the same treatment `print_positions` got.
    let now = Instant::now();
    {
        let s = shared.lock_or_recover();
        let nodes = s.reg.nodes();
        if nodes.is_empty() {
            println!("[hub] no node ever registered");
        } else {
            println!("[hub] nodes seen this run: {}", nodes.len());
            for n in nodes {
                println!(
                    "[hub]   {:<8} {:<10} {:<16} {:<8} up {}s, connected {}s",
                    n.role.as_str(),
                    n.acc,
                    if n.name.is_empty() { "-" } else { n.name.as_str() },
                    format!("{:?}", n.liveness(now)).to_lowercase(),
                    n.up_secs,
                    now.saturating_duration_since(n.first_seen).as_secs()
                );
            }
        }
    }

    //--- LINGER is 0, so this returns immediately instead of waiting for
    //--- undelivered messages that a hub has no reason to hold on to.
    drop(sock);
    drop(ctx);
}
