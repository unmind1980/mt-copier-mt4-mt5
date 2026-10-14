//! CURVE for the hub link (the plan's §19.1 gap).
//!
//! §19.1 decided the ZMQ port's trust boundary is the firewall, and was
//! explicit that CURVE "can be turned on independently" - it is a LINK-layer
//! control: it encrypts the connection and proves that the machine on the
//! other end holds a keypair this hub was told to accept. It does not know
//! about accounts, and it does not replace the firewall; it removes the
//! sentence "anything that can reach port 6000 can read every position the
//! hub has seen" from the risk register.
//!
//! WHAT THIS ADDS, IN ONE PARAGRAPH
//!
//! With `--curve on` the hub becomes a CURVE **server**: it holds a keypair,
//! every node must present its own, and the connection is encrypted with a
//! key neither end ever sends. On top of that the hub keeps an **allow-list**
//! of client public keys: CURVE alone proves "has a keypair", and an
//! allow-list is what turns that into "is a machine we authorised".
//!
//! The allow-list is enforced by a **ZAP handler** (RFC 27) - see
//! `spawn_zap_handler` for why that, and not a check on incoming messages,
//! is the only place it can work.
//!
//! THE THREE FILES, AND WHY EACH IS WHERE IT IS
//!
//!   curve_hub.keys     the hub's keypair, Z85, written on first start.
//!                      A SECRET lives here, so the file is not versioned and
//!                      not shared; it is only ever read by this process.
//!   curve_clients.txt  the allow-list: one 40-character Z85 PUBLIC key per
//!                      line, `#` comments, blank lines ignored. A lone `*`
//!                      means "any authenticated keypair" - deliberately
//!                      explicit, never a default.
//! WHY THE ALLOW-LIST IS NOT OPTIONAL
//!
//! libzmq's CURVE authenticates the *handshake*; it has no opinion about
//! which keys are welcome. Without a list, any machine that generates a
//! keypair is in - which is the same exposure as no CURVE at all, with more
//! CPU spent. So `--curve on` with an empty list is a REFUSAL TO START, not
//! a hub that quietly accepts everyone. The only way to say "any keypair" is
//! to write `*`, and writing it is a decision somebody has to make on
//! purpose.
//!
//! WHAT THIS DOES NOT DO
//!
//! Key ROTATION (the plan's G15, P2) is not implemented: rotating a client
//! key is "stop that node, delete its key file, restart it, add the new
//! public key here, reload the hub". Reloading the allow-list without a
//! restart is not implemented either - the file is read once at startup.

use std::path::Path;

/// The hub's own keypair, as Z85 (40 characters each).
///
/// Z85 rather than raw bytes because this is the form that goes in a file
/// and in front of an operator: 40 printable characters, no padding, no way
/// to be off by one silently. The conversion to the 32 raw bytes that
/// `zmq_setsockopt` wants happens at the socket, once.
pub struct HubKeys {
    pub public: String,
    pub secret: String,
}

/// First line of the key file. A magic string rather than a comment, for the
/// same reason the EAs' `copier_curve.key` has one: a file left by a future
/// build - or by a different tool - must be recognised as "not mine" and
/// replaced, instead of being parsed on a best-effort basis into a handshake
/// that never completes.
pub const KEY_FILE_MAGIC: &str = "copier-hub-curve v1";

const KEY_LEN: usize = 40;

fn shape_ok(k: &str) -> bool {
    k.len() == KEY_LEN && zmq::z85_decode(k).map(|b| b.len() == 32).unwrap_or(false)
}

/// Read the hub keypair, or create and write one when the file is absent or
/// unusable. Returns `(keys, created)`.
///
/// The asymmetry is deliberate, and copied from the EAs' key module: a file
/// that does not LOAD is replaced without asking, while a file that loads is
/// never touched. A keypair has no history and no meaning outside this hub,
/// so the cost of discarding a bad one is one regenerated key; the cost of
/// keeping a broken one is a hub that silently never accepts a client.
pub fn load_or_create_keys(path: &Path) -> Result<(HubKeys, bool), String> {
    if let Ok(text) = std::fs::read_to_string(path) {
        let mut lines = text.lines();
        if lines.next().map(|l| l.trim()) == Some(KEY_FILE_MAGIC) {
            let mut public = String::new();
            let mut secret = String::new();
            for line in lines {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                if let Some(v) = line.strip_prefix("PUBLIC=") {
                    public = v.trim().to_string();
                } else if let Some(v) = line.strip_prefix("SECRET=") {
                    secret = v.trim().to_string();
                }
            }
            if shape_ok(&public) && shape_ok(&secret) {
                return Ok((HubKeys { public, secret }, false));
            }
            eprintln!(
                "[hub] {} exists but is not a usable key file - replacing it",
                path.display()
            );
        } else if !text.trim().is_empty() {
            eprintln!(
                "[hub] {} is not a hub key file (wrong magic) - replacing it",
                path.display()
            );
        }
    }

    let pair = zmq::CurveKeyPair::new()
        .map_err(|e| format!("zmq_curve_keypair failed: {}", e))?;
    let public = zmq::z85_encode(&pair.public_key).map_err(|e| format!("z85: {:?}", e))?;
    let secret = zmq::z85_encode(&pair.secret_key).map_err(|e| format!("z85: {:?}", e))?;
    if !shape_ok(&public) || !shape_ok(&secret) {
        return Err("generated key has the wrong length - faulty libzmq?".to_string());
    }

    let text = format!(
        "{magic}\n\
         # This hub's CURVE keypair, used only when --curve on.\n\
         # To rotate it: stop the hub, delete this file, start it again, and\n\
         # update every node's HubPublicKey with the new PUBLIC line below.\n\
         #\n\
         # PUBLIC is what each node puts in its HubPublicKey input.\n\
         # SECRET never leaves this machine and is never logged.\n\
         PUBLIC={public}\n\
         SECRET={secret}\n",
        magic = KEY_FILE_MAGIC,
        public = public,
        secret = secret
    );
    //--- temp + rename, the same shape the receiver's ini writer and the M9
    //--- user store use: a crash mid-write must not leave half a keypair.
    let tmp = path.with_extension("keys.tmp");
    std::fs::write(&tmp, &text).map_err(|e| format!("{}: {}", tmp.display(), e))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {}", path.display(), e))?;

    Ok((HubKeys { public, secret }, true))
}

/// Which client public keys this hub will accept.
#[derive(Debug, PartialEq)]
pub struct AllowList {
    /// `*` was written on its own line: accept any authenticated keypair.
    any: bool,
    keys: Vec<String>,
}

impl AllowList {
    pub fn parse(text: &str) -> AllowList {
        let mut any = false;
        let mut keys: Vec<String> = Vec::new();
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line == "*" {
                any = true;
                continue;
            }
            //--- A line that is not a well-formed key is an ERROR the
            //--- operator must see, not a silently ignored one: an allow-list
            //--- that quietly drops the entry you just added is
            //--- indistinguishable from a node whose key is wrong, and the
            //--- debugging would start at the wrong end.
            if shape_ok(line) {
                if !keys.iter().any(|k| k == line) {
                    keys.push(line.to_string());
                }
            } else {
                eprintln!(
                    "[hub] WARN  allow-list line is not a 40-character Z85 key, ignored: {:?}",
                    line
                );
            }
        }
        AllowList { any, keys }
    }

    pub fn load(path: &Path) -> Result<AllowList, String> {
        match std::fs::read_to_string(path) {
            Ok(t) => Ok(AllowList::parse(&t)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Err(format!("{} does not exist", path.display()))
            }
            Err(e) => Err(format!("{}: {}", path.display(), e)),
        }
    }

    pub fn is_empty(&self) -> bool {
        !self.any && self.keys.is_empty()
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_any(&self) -> bool {
        self.any
    }

    /// Is this exact key already named in the list? Used by learn mode, which
    /// must not append the same key twice.
    pub fn has_key(&self, z85: &str) -> bool {
        self.keys.iter().any(|k| k == z85)
    }

    /// Remember a key we just learned, in memory.
    pub fn add_key(&mut self, z85: &str) {
        if !self.has_key(z85) {
            self.keys.push(z85.to_string());
        }
    }

    /// Does this ZAP credential belong to a permitted client?
    ///
    /// The credential a CURVE ZAP request carries is the client's public
    /// key. Measured, not assumed: the libzmq in `third_party/zmq-prefix`
    /// hands it over as the **32 raw bytes** (see `describe_credential`,
    /// which re-encodes them to Z85 for the log). Other versions have been
    /// known to send the 40-character Z85 spelling, so both are accepted -
    /// getting this wrong in the strict direction locks out every legitimate
    /// node, and the *set* of accepted keys is still exactly the list either
    /// way.
    pub fn permits_credential(&self, cred: &[u8]) -> bool {
        if self.any {
            return true;
        }
        if cred.len() == 32 {
            for k in &self.keys {
                if let Ok(raw) = zmq::z85_decode(k) {
                    if raw == cred {
                        return true;
                    }
                }
            }
        }
        if let Ok(text) = std::str::from_utf8(cred) {
            let t = text.trim();
            if !t.is_empty() && self.keys.iter().any(|k| k == t) {
                return true;
            }
        }
        false
    }
}

/// Append a freshly-learned key to the allow-list FILE, so the list an
/// operator reads is the list the hub is actually enforcing.
///
/// Re-reads the file first rather than trusting the in-memory copy: the
/// operator may have edited it since the hub started, and appending to a
/// stale view is how a hand-added key disappears.
pub fn append_learned_key(path: &Path, z85: &str) -> Result<bool, String> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    if AllowList::parse(&existing).has_key(z85) {
        return Ok(false); // already there - nothing to do
    }
    let mut text = existing;
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text.push_str(&format!(
        "{}   # learned {} (delete this line to revoke)\n",
        z85,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    ));
    std::fs::write(path, text).map_err(|e| format!("{}: {}", path.display(), e))?;
    Ok(true)
}

/// Render a ZAP credential the way an operator can compare it with the
/// allow-list: as the 40-character Z85 spelling.
///
/// This libzmq hands the credential over as the client's **32 raw bytes**,
/// and printing those as text produces mojibake that matches nothing in
/// `curve_clients.txt` - which is the one thing this line exists to be
/// matched against. A 32-byte credential is therefore re-encoded to Z85; a
/// credential that is already text (other libzmq versions send the Z85 form)
/// is printed as-is.
fn describe_credential(cred: &[u8]) -> String {
    if cred.len() == 32 {
        if let Ok(z) = zmq::z85_encode(cred) {
            return z;
        }
    }
    match std::str::from_utf8(cred) {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => "(unprintable)".to_string(),
    }
}

/// Run the ZAP handler (RFC 27) for CURVE connections, on `ctx`.
///
/// WHY THIS AND NOT A CHECK IN THE MAIN LOOP
///
/// The main loop only ever sees messages the hub RECEIVES. A subscriber that
/// completed a CURVE handshake but is not on the allow-list would still be
/// delivered every position the hub publishes - the hub would simply never
/// learn it was there, because publishing is libzmq's job, not the
/// application's. Checking uplink messages would therefore protect the hub
/// from forged data while leaving the position stream readable, which is the
/// half of §19.1's exposure that matters most.
///
/// ZAP is the one place libzmq asks the application a question it then
/// obeys: it calls the handler *during the handshake*, before the connection
/// exists, and a DENY means the peer never becomes a subscriber. So the
/// allow-list is enforced where it can actually stop delivery.
///
/// The handler must be listening before the CURVE server socket binds, hence
/// the small sleep at the call site.
///
/// LEARN MODE (`learn`)
///
/// The hub already knows every node's public key - libzmq hands it over with
/// the handshake, which is the whole reason this handler can decide anything.
/// So the operator does not have to carry 40-character keys by hand: with
/// learn mode on, any authenticated keypair is accepted AND its key is
/// appended to the allow-list file, marked `# learned <ts>`. The list builds
/// itself; deleting a line revokes that node; and once the fleet has
/// connected once, the hub is restarted without learn mode and the list is
/// enforced.
///
/// It is trust-on-first-use, and worth naming as such: the first machine to
/// connect is trusted. That is why learn mode is a bring-up tool and not a
/// resting state - and why the port's firewall still matters.
pub fn spawn_zap_handler(
    ctx: &zmq::Context,
    list: AllowList,
    learn: bool,
    clients_path: std::path::PathBuf,
) -> std::thread::JoinHandle<()> {
    let ctx = ctx.clone();
    let shared = std::sync::Arc::new(std::sync::Mutex::new(list));
    std::thread::spawn(move || {
        let sock = match ctx.socket(zmq::REP) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[hub] cannot create the ZAP socket: {}", e);
                return;
            }
        };
        let _ = sock.set_linger(0);
        if let Err(e) = sock.bind("inproc://zeromq.zap.01") {
            eprintln!("[hub] cannot bind inproc://zeromq.zap.01: {}", e);
            eprintln!("[hub]   CURVE cannot authorise anyone without it - refusing");
            std::process::exit(1);
        }

        let mut denied: u64 = 0;
        loop {
            //--- 7 frames: version, request_id, domain, address, identity,
            //--- mechanism, credentials.
            let req = match sock.recv_multipart(0) {
                Ok(r) => r,
                Err(_) => break, // context gone: the hub is shutting down
            };
            let version = req.first().cloned().unwrap_or_else(|| b"1.0".to_vec());
            let request_id = req.get(1).cloned().unwrap_or_default();
            let mechanism = req
                .get(5)
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default();
            let cred = req.get(6).cloned().unwrap_or_default();

            //--- A CURVE-enabled server must not also accept plaintext. A
            //--- NULL handshake here means somebody reached a CURVE port
            //--- without CURVE, which is exactly the case the boundary
            //--- exists for.
            let (code, text, user): (&str, &str, Vec<u8>) = if mechanism != "CURVE" {
                denied += 1;
                println!(
                    "[hub] ZAP DENY  a {} client tried to connect to a CURVE hub",
                    if mechanism.is_empty() { "plaintext" } else { mechanism.as_str() }
                );
                ("400", "this hub requires CURVE", Vec::new())
            } else {
                let key = describe_credential(&cred);
                let mut l = shared.lock().unwrap();
                //--- Learn mode means "accept anyone who can authenticate,
                //--- and write down who they were".
                let known = l.permits_credential(&cred);
                if known || learn {
                    if learn && !l.has_key(&key) && key.len() == 40 {
                        match append_learned_key(&clients_path, &key) {
                            Ok(true) => println!(
                                "[hub] ZAP LEARNED {} -> appended to {}",
                                key,
                                clients_path.display()
                            ),
                            Ok(false) => {}
                            Err(e) => eprintln!(
                                "[hub] ZAP LEARNED {} but could not write {}: {}",
                                key,
                                clients_path.display(),
                                e
                            ),
                        }
                        l.add_key(&key);
                    }
                    if known {
                        println!("[hub] ZAP ALLOW {}", key);
                    } else {
                        println!("[hub] ZAP ALLOW {} (learn mode - not on the list yet)", key);
                    }
                    drop(l);
                    ("200", "OK", cred.clone())
                } else {
                    denied += 1;
                    println!(
                        "[hub] ZAP DENY  unknown client key {} ({} denied so far)",
                        key, denied
                    );
                    drop(l);
                    ("400", "key is not on this hub's allow-list", Vec::new())
                }
            };

            let reply = vec![
                version,
                request_id,
                code.as_bytes().to_vec(),
                text.as_bytes().to_vec(),
                user,
                Vec::new(), // metadata
            ];
            if sock.send_multipart(reply, 0).is_err() {
                break;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_allow_list_skips_comments_and_blanks() {
        let k1 = zmq::z85_encode(&zmq::CurveKeyPair::new().unwrap().public_key).unwrap();
        let k2 = zmq::z85_encode(&zmq::CurveKeyPair::new().unwrap().public_key).unwrap();
        let text = format!(
            "# my nodes\n\n  {}  \n# another comment\n{}\n{}\n",
            k1, k2, k1
        );
        let l = AllowList::parse(&text);
        assert_eq!(l.len(), 2, "duplicates collapse");
        // Both credential encodings, because libzmq has used both: the Z85
        // text form, and the 32 raw bytes this build actually sends.
        assert!(l.permits_credential(k1.as_bytes()));
        assert!(l.permits_credential(k2.as_bytes()));
        assert!(l.permits_credential(&zmq::z85_decode(&k1).unwrap()));
        assert!(!l.permits_credential(b"nope"));
        // A key that is NOT on the list, in its binary form, is still out.
        let k3 = zmq::z85_encode(&zmq::CurveKeyPair::new().unwrap().public_key).unwrap();
        assert!(!l.permits_credential(&zmq::z85_decode(&k3).unwrap()));
        assert!(!l.is_any());
        assert!(!l.is_empty());
    }

    #[test]
    fn a_star_means_any_and_an_empty_list_means_nobody() {
        let star = AllowList::parse("*\n");
        assert!(star.is_any());
        assert!(star.permits_credential(b"anything at all"));

        let empty = AllowList::parse("# nothing yet\n\n");
        assert!(empty.is_empty());
        assert!(!empty.permits_credential(b"anything"));

        // A malformed line is warned about and dropped, not fatal - but it
        // must NOT be treated as a wildcard.
        let junk = AllowList::parse("this-is-not-a-key\n");
        assert!(junk.is_empty());
        assert!(!junk.permits_credential(b"this-is-not-a-key"));
    }

    #[test]
    fn a_key_file_round_trips_and_repairs_itself() {
        let dir = std::env::temp_dir().join(format!("hub_curve_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("curve_hub.keys");
        let _ = std::fs::remove_file(&path);

        // Absent -> generated and written.
        let (k1, created) = load_or_create_keys(&path).unwrap();
        assert!(created);
        assert!(shape_ok(&k1.public) && shape_ok(&k1.secret));

        // Present and valid -> read back, unchanged.
        let (k2, created2) = load_or_create_keys(&path).unwrap();
        assert!(!created2);
        assert_eq!(k1.public, k2.public);
        assert_eq!(k1.secret, k2.secret);

        // Damaged -> replaced (the file loads as garbage, so it is discarded).
        std::fs::write(&path, "copier-hub-curve v1\nPUBLIC=short\nSECRET=short\n").unwrap();
        let (k3, created3) = load_or_create_keys(&path).unwrap();
        assert!(created3, "a file that does not load is replaced");
        assert!(shape_ok(&k3.public));

        // A foreign file (wrong magic) is replaced too.
        std::fs::write(&path, "something else entirely\n").unwrap();
        let (_k4, created4) = load_or_create_keys(&path).unwrap();
        assert!(created4);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
