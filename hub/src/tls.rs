//! TLS & HTTPS management module for MT-Copier Central Hub.
//!
//! Provides native TLS termination, automated ACME (Let's Encrypt) certificate
//! enrollment via sslip.io (or custom domains), zero-downtime certificate hot-reloading,
//! and fail-safe recovery controls.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use p256::SecretKey;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use yasna::models::ObjectIdentifier;
use yasna::tags::TAG_UTCTIME;

pub const DEFAULT_TLS_CONFIG_PATH: &str = "tls_config.json";
pub const DEFAULT_HTTPS_PORT: u16 = 443;
pub const DEFAULT_HTTP_PORT: u16 = 80;

/// Certificate management mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    /// Automatic mode: detect public IP and assign `<ip>.sslip.io` with Let's Encrypt.
    Auto,
    /// User provided their own registered domain name (e.g. `hub.example.com`).
    CustomDomain,
    /// User manually uploaded fullchain.pem and privkey.pem.
    Import,
    /// Offline local self-signed certificate.
    SelfSigned,
}

impl Default for TlsMode {
    fn default() -> Self {
        TlsMode::Auto
    }
}

/// Runtime status of the TLS certificate.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TlsStatus {
    /// Whether a valid certificate is currently loaded and ready for TLS handshakes.
    pub cert_valid: bool,
    /// The issuer of the certificate (e.g. "Let's Encrypt", "Self-Signed", "Custom").
    pub issuer: String,
    /// Subject Common Name or SAN (domain name).
    pub subject: String,
    /// Unix timestamp when the certificate was issued.
    pub issued_at: u64,
    /// Unix timestamp when the certificate will expire.
    pub expires_at: u64,
    /// Days remaining until expiration. Negative if already expired.
    pub days_remaining: i64,
    /// Last error encountered during issuance or renewal.
    pub last_error: Option<String>,
    /// Whether an ACME enrollment or renewal job is currently running in background.
    pub in_progress: bool,
    /// Step description of current operation (e.g. "idle", "requesting_challenges", "validating").
    pub progress_step: String,
}

/// Persistent configuration for TLS/HTTPS.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TlsConfig {
    /// Schema version for future evolution.
    pub version: u32,
    /// Global switch for HTTPS/WSS.
    pub enabled: bool,
    /// Mode of operation (Auto, CustomDomain, Import, SelfSigned).
    pub mode: TlsMode,
    /// Domain name assigned or configured.
    pub domain: String,
    /// Port for HTTPS traffic (e.g. 443 or custom like 6010 / 8443).
    pub https_port: u16,
    /// Port for HTTP traffic (for ACME HTTP-01 challenges and optional 301 redirect).
    pub http_port: u16,
    /// Optional administrator contact email for Let's Encrypt expiry notices.
    pub email: Option<String>,
    /// Whether to redirect all incoming HTTP traffic on `http_port` to HTTPS.
    pub enable_http_redirect: bool,
    /// Whether to automatically renew certificates within 30 days of expiry.
    pub auto_renew: bool,
    /// Whether to use Let's Encrypt staging directory (for testing without rate limits).
    pub staging_mode: bool,
    /// Current certificate status.
    pub status: TlsStatus,
}

impl Default for TlsConfig {
    fn default() -> Self {
        TlsConfig {
            version: 1,
            enabled: false,
            mode: TlsMode::Auto,
            domain: String::new(),
            https_port: DEFAULT_HTTPS_PORT,
            http_port: DEFAULT_HTTP_PORT,
            email: None,
            enable_http_redirect: true,
            auto_renew: true,
            staging_mode: false,
            status: TlsStatus {
                cert_valid: false,
                issuer: String::new(),
                subject: String::new(),
                issued_at: 0,
                expires_at: 0,
                days_remaining: 0,
                last_error: None,
                in_progress: false,
                progress_step: "idle".to_string(),
            },
        }
    }
}

/// Convert an IPv4 address (e.g. `123.45.67.89`) into a valid sslip.io domain (`123-45-67-89.sslip.io`).
pub fn format_sslip_domain(ip: &str) -> String {
    let clean = ip.trim();
    if clean.parse::<std::net::Ipv4Addr>().is_ok() {
        let dashed = clean.replace('.', "-");
        format!("{}.sslip.io", dashed)
    } else {
        clean.to_string()
    }
}

/// Query outbound IP probe services with a short timeout to discover the host's public IP.
pub async fn detect_public_ip(client: &reqwest::Client) -> Option<String> {
    let endpoints = [
        "https://api.ipify.org",
        "https://icanhazip.com",
        "https://ifconfig.me/ip",
        "https://checkip.amazonaws.com",
    ];
    for ep in endpoints {
        if let Ok(res) = client
            .get(ep)
            .timeout(Duration::from_secs(4))
            .send()
            .await
        {
            if res.status().is_success() {
                if let Ok(body) = res.text().await {
                    let candidate = body.trim();
                    if candidate.parse::<std::net::Ipv4Addr>().is_ok() {
                        return Some(candidate.to_string());
                    }
                }
            }
        }
    }
    None
}

/// Load `tls_config.json`, falling back to safe defaults if missing or corrupted.
pub fn load_config(path: &Path) -> TlsConfig {
    if let Ok(mut f) = File::open(path) {
        let mut buf = String::new();
        if f.read_to_string(&mut buf).is_ok() {
            if let Ok(cfg) = serde_json::from_str::<TlsConfig>(&buf) {
                return cfg;
            }
        }
    }
    TlsConfig::default()
}

/// Save `tls_config.json` atomically via write-and-rename.
pub fn save_config(path: &Path, cfg: &TlsConfig) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    let json_bytes = serde_json::to_vec_pretty(cfg)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    {
        let mut f = File::create(&tmp)?;
        f.write_all(&json_bytes)?;
        f.sync_all()?;
    }

    match fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(_) => {
            // Windows file-lock fallback
            let _ = fs::remove_file(path);
            fs::rename(&tmp, path)
        }
    }
}

/// Certificate file paths managed by the hub.
#[derive(Clone, Debug)]
pub struct CertPaths {
    pub cert_dir: PathBuf,
    pub fullchain_pem: PathBuf,
    pub privkey_pem: PathBuf,
    pub account_key: PathBuf,
    pub pfx_file: PathBuf,
}

impl CertPaths {
    pub fn new(base_dir: &Path) -> Self {
        let cert_dir = base_dir.join("data").join("certs");
        CertPaths {
            fullchain_pem: cert_dir.join("fullchain.pem"),
            privkey_pem: cert_dir.join("privkey.pem"),
            account_key: cert_dir.join("account.key"),
            pfx_file: cert_dir.join("hub.pfx"),
            cert_dir,
        }
    }

    pub fn ensure_dir(&self) -> io::Result<()> {
        fs::create_dir_all(&self.cert_dir)
    }
}

/// Helper to get current unix seconds.
pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Simple PEM parser to extract DER bytes between headers.
pub fn extract_pem_blocks(pem_str: &str, tag: &str) -> Vec<Vec<u8>> {
    let start_marker = format!("-----BEGIN {}-----", tag);
    let end_marker = format!("-----END {}-----", tag);
    let mut out = Vec::new();
    let mut remaining = pem_str;

    while let Some(start_pos) = remaining.find(&start_marker) {
        let after_start = &remaining[start_pos + start_marker.len()..];
        if let Some(end_pos) = after_start.find(&end_marker) {
            let b64_text = &after_start[..end_pos];
            let clean: String = b64_text.chars().filter(|c| !c.is_whitespace()).collect();
            use base64::Engine;
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(&clean) {
                out.push(bytes);
            }
            remaining = &after_start[end_pos + end_marker.len()..];
        } else {
            break;
        }
    }
    out
}

/// Convert PEM certificate chain and PEM private key into standard PKCS#12 (PFX) bytes.
pub fn pem_to_pkcs12(cert_pem: &str, key_pem: &str, password: &str) -> Result<Vec<u8>, String> {
    let cert_blocks = extract_pem_blocks(cert_pem, "CERTIFICATE");
    if cert_blocks.is_empty() {
        return Err("No CERTIFICATE blocks found in certificate PEM".to_string());
    }
    let leaf_cert = &cert_blocks[0];
    let ca_refs: Vec<&[u8]> = cert_blocks[1..].iter().map(|b| b.as_slice()).collect();

    // Extract private key in PKCS#8 or EC/RSA format
    let key_der = if let Some(block) = extract_pem_blocks(key_pem, "PRIVATE KEY").into_iter().next() {
        block
    } else if let Some(block) = extract_pem_blocks(key_pem, "EC PRIVATE KEY").into_iter().next() {
        // Convert SEC1 EC private key to PKCS#8
        if let Ok(sk) = SecretKey::from_sec1_der(&block) {
            if let Ok(pkcs8) = sk.to_pkcs8_der() {
                pkcs8.to_bytes().to_vec()
            } else {
                block
            }
        } else {
            block
        }
    } else if let Some(block) = extract_pem_blocks(key_pem, "RSA PRIVATE KEY").into_iter().next() {
        block
    } else {
        return Err("No recognized private key found in key PEM".to_string());
    };

    let pfx = p12::PFX::new_with_cas(leaf_cert, &key_der, &ca_refs, password, "mt-copier-hub")
        .ok_or_else(|| "Failed to construct PKCS#12 payload with provided cert and key".to_string())?;

    let pfx_der = yasna::construct_der(|w| pfx.write(w));
    Ok(pfx_der)
}

/// Build a tokio-native-tls Acceptor from PKCS#12 bytes.
pub fn create_tls_acceptor(pfx_bytes: &[u8], password: &str) -> Result<tokio_native_tls::TlsAcceptor, String> {
    let identity = native_tls::Identity::from_pkcs12(pfx_bytes, password)
        .map_err(|e| format!("Failed to parse PKCS#12 identity: {}", e))?;
    let native_acceptor = native_tls::TlsAcceptor::new(identity)
        .map_err(|e| format!("Failed to initialize native TLS acceptor: {}", e))?;
    Ok(tokio_native_tls::TlsAcceptor::from(native_acceptor))
}

/// Generate a pure-Rust self-signed X.509 v3 certificate and P-256 private key for local/testing use.
pub fn generate_self_signed(domain: &str) -> Result<(String, String), String> {
    // 1. Generate P-256 secret key via OS CSPRNG
    let mut raw = [0u8; 32];
    if !crate::users::os_random_bytes(&mut raw) {
        return Err("Failed to obtain OS CSPRNG entropy".to_string());
    }
    raw[0] &= 0x7f; // ensure within field order
    raw[31] |= 1;  // non-zero
    let sec_key = SecretKey::from_slice(&raw).map_err(|e| format!("Invalid secret key scalar: {}", e))?;
    let sign_key = SigningKey::from(&sec_key);
    let verify_key = sign_key.verifying_key();
    let pub_sec1 = verify_key.to_sec1_bytes(); // 65-byte uncompressed SEC1 (0x04 || X || Y)

    // 2. PKCS#8 DER & PEM for private key
    let pkcs8_der = sec_key
        .to_pkcs8_der()
        .map_err(|e| format!("Failed to export pkcs8 der: {}", e))?;
    use base64::Engine;
    let b64_key = base64::engine::general_purpose::STANDARD.encode(pkcs8_der.to_bytes());
    let key_pem = format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
        b64_key.chars().collect::<Vec<_>>().chunks(64).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("\n")
    );

    // 3. Construct TBSCertificate
    let tbs_der = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            // Version [0] EXPLICIT INTEGER 2 (v3)
            w.next().write_tagged(yasna::Tag::context(0), |w| {
                w.write_u8(2);
            });
            // Serial Number
            w.next().write_u64(unix_now());
            // Signature Algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
            w.next().write_sequence(|w| {
                w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 4, 3, 2]));
            });
            // Issuer Name
            w.next().write_sequence(|w| {
                w.next().write_set_of(|w| {
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&ObjectIdentifier::from_slice(&[2, 5, 4, 3])); // commonName
                        w.next().write_utf8_string(domain);
                    });
                });
            });
            // Validity
            w.next().write_sequence(|w| {
                w.next().write_tagged_implicit(TAG_UTCTIME, |w| {
                    w.write_bytes(b"240101000000Z");
                });
                w.next().write_tagged_implicit(TAG_UTCTIME, |w| {
                    w.write_bytes(b"350101000000Z");
                });
            });
            // Subject Name
            w.next().write_sequence(|w| {
                w.next().write_set_of(|w| {
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&ObjectIdentifier::from_slice(&[2, 5, 4, 3])); // commonName
                        w.next().write_utf8_string(domain);
                    });
                });
            });
            // SubjectPublicKeyInfo: id-ecPublicKey + prime256v1
            w.next().write_sequence(|w| {
                w.next().write_sequence(|w| {
                    w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 2, 1])); // id-ecPublicKey
                    w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 3, 1, 7])); // prime256v1
                });
                let pub_bytes = pub_sec1.as_ref();
                w.next().write_bitvec_bytes(pub_bytes, pub_bytes.len() * 8);
            });
            // Extensions [3] EXPLICIT: SubjectAlternativeName
            w.next().write_tagged(yasna::Tag::context(3), |w| {
                w.write_sequence(|w| {
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&ObjectIdentifier::from_slice(&[2, 5, 29, 17])); // id-ce-subjectAltName
                        let san_ext = yasna::construct_der(|w| {
                            w.write_sequence(|w| {
                                // context [2] dNSName
                                w.next().write_tagged_implicit(yasna::Tag::context(2), |w| {
                                    w.write_ia5_string(domain);
                                });
                            });
                        });
                        w.next().write_bytes(&san_ext);
                    });
                });
            });
        });
    });

    // 4. Sign TBSCertificate with ECDSA P-256
    let sig: Signature = sign_key.sign(&tbs_der);
    let sig_der = sig.to_der();

    // 5. Wrap into Certificate SEQUENCE
    let cert_der = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            w.next().write_der(&tbs_der);
            w.next().write_sequence(|w| {
                w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 4, 3, 2]));
            });
            w.next().write_bitvec_bytes(sig_der.as_bytes(), sig_der.as_bytes().len() * 8);
        });
    });

    let b64_cert = base64::engine::general_purpose::STANDARD.encode(&cert_der);
    let cert_pem = format!(
        "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
        b64_cert.chars().collect::<Vec<_>>().chunks(64).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("\n")
    );

    Ok((cert_pem, key_pem))
}

/// Comprehensive manager coordinating TLS certificate lifecycle, file storage,
/// hot reloading, and ACME HTTP-01 challenge response tokens.
pub struct TlsManager {
    pub config: Mutex<TlsConfig>,
    pub config_path: PathBuf,
    pub cert_paths: CertPaths,
    /// Hot-reloaded TLS acceptor. None if TLS is disabled or certificate is not loaded.
    pub acceptor: Arc<RwLock<Option<tokio_native_tls::TlsAcceptor>>>,
    /// In-memory ACME challenge tokens: token -> key_authorization
    pub acme_tokens: Arc<RwLock<HashMap<String, String>>>,
}

impl TlsManager {
    pub fn new(base_dir: &Path, config_path: &Path) -> Self {
        let cert_paths = CertPaths::new(base_dir);
        let cfg = load_config(config_path);
        TlsManager {
            config: Mutex::new(cfg),
            config_path: config_path.to_path_buf(),
            cert_paths,
            acceptor: Arc::new(RwLock::new(None)),
            acme_tokens: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Read persistent certificate files from disk and reload TlsAcceptor without restarting the hub.
    pub fn reload_from_disk(&self) -> Result<(), String> {
        let cfg = self.config.lock().unwrap().clone();
        if !cfg.enabled {
            let mut acc = self.acceptor.write().unwrap();
            *acc = None;
            return Ok(());
        }

        if !self.cert_paths.fullchain_pem.exists() || !self.cert_paths.privkey_pem.exists() {
            return Err("Certificate or private key files not found on disk".to_string());
        }

        let cert_pem = fs::read_to_string(&self.cert_paths.fullchain_pem)
            .map_err(|e| format!("Failed to read fullchain.pem: {}", e))?;
        let key_pem = fs::read_to_string(&self.cert_paths.privkey_pem)
            .map_err(|e| format!("Failed to read privkey.pem: {}", e))?;

        let pfx_bytes = pem_to_pkcs12(&cert_pem, &key_pem, "mtc_tls_pass")?;
        // Persist PFX cache file for fast native reload
        let _ = fs::write(&self.cert_paths.pfx_file, &pfx_bytes);

        let new_acceptor = create_tls_acceptor(&pfx_bytes, "mtc_tls_pass")?;

        {
            let mut acc = self.acceptor.write().unwrap();
            *acc = Some(new_acceptor);
        }

        // Update in-memory status
        {
            let mut c = self.config.lock().unwrap();
            c.status.cert_valid = true;
            c.status.subject = c.domain.clone();
            c.status.issuer = match c.mode {
                TlsMode::Auto => "Let's Encrypt (sslip.io)".to_string(),
                TlsMode::CustomDomain => "Let's Encrypt".to_string(),
                TlsMode::Import => "Custom Imported".to_string(),
                TlsMode::SelfSigned => "Self-Signed".to_string(),
            };
            if c.status.issued_at == 0 {
                c.status.issued_at = unix_now();
                c.status.expires_at = unix_now() + 90 * 86400;
            }
            c.status.days_remaining = ((c.status.expires_at as i64) - (unix_now() as i64)) / 86400;
            c.status.last_error = None;
            let _ = save_config(&self.config_path, &c);
        }

        println!("[hub] TLS: certificate reloaded successfully for domain '{}'", cfg.domain);
        Ok(())
    }

    /// Import and activate an external certificate/key pair.
    pub fn apply_imported_cert(&self, cert_pem: &str, key_pem: &str, domain: &str, https_port: u16) -> Result<(), String> {
        let pfx_bytes = pem_to_pkcs12(cert_pem, key_pem, "mtc_tls_pass")?;
        let new_acceptor = create_tls_acceptor(&pfx_bytes, "mtc_tls_pass")?;

        self.cert_paths.ensure_dir().map_err(|e| e.to_string())?;
        fs::write(&self.cert_paths.fullchain_pem, cert_pem).map_err(|e| e.to_string())?;
        fs::write(&self.cert_paths.privkey_pem, key_pem).map_err(|e| e.to_string())?;
        let _ = fs::write(&self.cert_paths.pfx_file, &pfx_bytes);

        {
            let mut acc = self.acceptor.write().unwrap();
            *acc = Some(new_acceptor);
        }

        {
            let mut c = self.config.lock().unwrap();
            c.enabled = true;
            c.mode = TlsMode::Import;
            c.domain = domain.to_string();
            c.https_port = https_port;
            c.status.cert_valid = true;
            c.status.issuer = "Custom Imported".to_string();
            c.status.subject = domain.to_string();
            c.status.issued_at = unix_now();
            c.status.expires_at = unix_now() + 365 * 86400;
            c.status.days_remaining = 365;
            c.status.last_error = None;
            let _ = save_config(&self.config_path, &c);
        }

        Ok(())
    }

    /// Generate and activate a self-signed certificate.
    pub fn apply_self_signed(&self, domain: &str, https_port: u16) -> Result<(), String> {
        let (cert_pem, key_pem) = generate_self_signed(domain)?;
        let pfx_bytes = pem_to_pkcs12(&cert_pem, &key_pem, "mtc_tls_pass")?;
        let new_acceptor = create_tls_acceptor(&pfx_bytes, "mtc_tls_pass")?;

        self.cert_paths.ensure_dir().map_err(|e| e.to_string())?;
        fs::write(&self.cert_paths.fullchain_pem, &cert_pem).map_err(|e| e.to_string())?;
        fs::write(&self.cert_paths.privkey_pem, &key_pem).map_err(|e| e.to_string())?;
        let _ = fs::write(&self.cert_paths.pfx_file, &pfx_bytes);

        {
            let mut acc = self.acceptor.write().unwrap();
            *acc = Some(new_acceptor);
        }

        {
            let mut c = self.config.lock().unwrap();
            c.enabled = true;
            c.mode = TlsMode::SelfSigned;
            c.domain = domain.to_string();
            c.https_port = https_port;
            c.status.cert_valid = true;
            c.status.issuer = "Self-Signed".to_string();
            c.status.subject = domain.to_string();
            c.status.issued_at = unix_now();
            c.status.expires_at = unix_now() + 365 * 86400;
            c.status.days_remaining = 365;
            c.status.last_error = None;
            let _ = save_config(&self.config_path, &c);
        }

        Ok(())
    }

    /// Register an ACME challenge token for HTTP-01 verification.
    pub fn register_acme_token(&self, token: &str, key_auth: &str) {
        let mut tokens = self.acme_tokens.write().unwrap();
        tokens.insert(token.to_string(), key_auth.to_string());
    }

    /// Remove an ACME challenge token after verification completes.
    pub fn unregister_acme_token(&self, token: &str) {
        let mut tokens = self.acme_tokens.write().unwrap();
        tokens.remove(token);
    }

    /// Retrieve key authorization string for a requested ACME challenge token.
    pub fn get_acme_token(&self, token: &str) -> Option<String> {
        let tokens = self.acme_tokens.read().unwrap();
        tokens.get(token).cloned()
    }
}

/// Serve a single async stream (plain or TLS decrypted) with an Axum router,
/// supporting HTTP/1.1, HTTP/2, and WebSocket upgrades.
pub async fn serve_stream_with_router<I>(stream: I, router: axum::Router)
where
    I: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    use hyper::service::service_fn;
    use hyper_util::rt::{TokioExecutor, TokioIo};
    use hyper_util::server::conn::auto::Builder as AutoConnBuilder;
    use tower::Service;

    let io = TokioIo::new(stream);
    let builder = AutoConnBuilder::new(TokioExecutor::new());
    let _ = builder
        .serve_connection_with_upgrades(
            io,
            service_fn(move |req| {
                let mut r = router.clone();
                async move { r.call(req).await }
            }),
        )
        .await;
}

/// Spawn a background listener on `http_port` (e.g. 80) to answer ACME HTTP-01 challenges
/// and optionally issue 301 Permanent Redirects to the HTTPS endpoint.
pub fn spawn_http_challenge_and_redirect_server(tls_mgr: Arc<TlsManager>, http_port: u16) {
    tokio::spawn(async move {
        let addr = std::net::SocketAddr::from(([0, 0, 0, 0], http_port));
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                println!(
                    "[hub] TLS: HTTP challenge/redirect listener on port {} could not be bound: {}",
                    http_port, e
                );
                return;
            }
        };
        println!("[hub] TLS: HTTP-01 challenge & redirect listener active on http://0.0.0.0:{}", http_port);

        let mgr = Arc::clone(&tls_mgr);
        let app = axum::Router::new()
            .route(
                "/.well-known/acme-challenge/:token",
                axum::routing::get({
                    let mgr = Arc::clone(&mgr);
                    move |axum::extract::Path(token): axum::extract::Path<String>| {
                        let res = mgr.get_acme_token(&token);
                        async move {
                            use axum::response::IntoResponse;
                            match res {
                                Some(auth) => (
                                    axum::http::StatusCode::OK,
                                    [(axum::http::header::CONTENT_TYPE, "text/plain")],
                                    auth,
                                )
                                    .into_response(),
                                None => (axum::http::StatusCode::NOT_FOUND, "Token not found").into_response(),
                            }
                        }
                    }
                }),
            )
            .fallback({
                let mgr = Arc::clone(&mgr);
                move |uri: axum::http::Uri, headers: axum::http::HeaderMap| {
                    let cfg = mgr.config.lock().unwrap().clone();
                    async move {
                        use axum::response::IntoResponse;
                        if cfg.enabled && cfg.enable_http_redirect {
                            let host_hdr = headers
                                .get(axum::http::header::HOST)
                                .and_then(|h| h.to_str().ok())
                                .unwrap_or("localhost");
                            let host_without_port = host_hdr.split(':').next().unwrap_or(host_hdr);
                            let target_url = if cfg.https_port == 443 {
                                format!("https://{}{}", host_without_port, uri)
                            } else {
                                format!("https://{}:{}{}", host_without_port, cfg.https_port, uri)
                            };
                            return (
                                axum::http::StatusCode::MOVED_PERMANENTLY,
                                [(axum::http::header::LOCATION, target_url.as_str())],
                                "",
                            )
                                .into_response();
                        }
                        (axum::http::StatusCode::NOT_FOUND, "Not Found").into_response()
                    }
                }
            });

        let _ = axum::serve(listener, app).await;
    });
}

// ============================================================================
// ACME (RFC 8555) Protocol Client & Background Auto-Renewal Engine
// ============================================================================

pub const LETS_ENCRYPT_PRODUCTION_DIR: &str = "https://acme-v02.api.letsencrypt.org/directory";
pub const LETS_ENCRYPT_STAGING_DIR: &str = "https://acme-staging-v02.api.letsencrypt.org/directory";

/// Directory endpoints returned by an ACME server.
#[derive(Clone, Debug, Deserialize)]
pub struct AcmeDirectory {
    #[serde(rename = "newNonce")]
    pub new_nonce: String,
    #[serde(rename = "newAccount")]
    pub new_account: String,
    #[serde(rename = "newOrder")]
    pub new_order: String,
}

/// Helper for Base64-URL-without-padding encoding per RFC 7515 / RFC 8555.
pub fn b64url(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

/// Sign a JWS payload with ECDSA P-256 (ES256) per RFC 8555.
pub fn sign_jws_es256(
    sign_key: &SigningKey,
    key_id_or_jwk: serde_json::Value,
    nonce: &str,
    url: &str,
    payload_json: Option<&serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let mut protected_header = serde_json::json!({
        "alg": "ES256",
        "nonce": nonce,
        "url": url,
    });
    if let Some(kid) = key_id_or_jwk.as_str() {
        protected_header.as_object_mut().unwrap().insert("kid".to_string(), serde_json::json!(kid));
    } else {
        protected_header.as_object_mut().unwrap().insert("jwk".to_string(), key_id_or_jwk);
    }

    let protected_str = serde_json::to_string(&protected_header).map_err(|e| e.to_string())?;
    let protected_b64 = b64url(protected_str.as_bytes());

    let payload_b64 = match payload_json {
        Some(p) => {
            let p_str = serde_json::to_string(p).map_err(|e| e.to_string())?;
            b64url(p_str.as_bytes())
        }
        None => String::new(),
    };

    let signing_input = format!("{}.{}", protected_b64, payload_b64);
    let sig: Signature = sign_key.sign(signing_input.as_bytes());
    // Convert to IEEE P1363 (r || s each 32 bytes) for ES256
    let sig_bytes = sig.to_bytes();
    let sig_b64 = b64url(sig_bytes.as_slice());

    Ok(serde_json::json!({
        "protected": protected_b64,
        "payload": payload_b64,
        "signature": sig_b64,
    }))
}

/// Compute canonical JWK and thumbprint for an ECDSA P-256 verifying key per RFC 7638.
pub fn compute_jwk_thumbprint(verify_key: &p256::ecdsa::VerifyingKey) -> (serde_json::Value, String) {
    let pub_sec1 = verify_key.to_sec1_bytes();
    let x_b64 = b64url(&pub_sec1[1..33]);
    let y_b64 = b64url(&pub_sec1[33..65]);
    let jwk = serde_json::json!({
        "crv": "P-256",
        "kty": "EC",
        "x": x_b64,
        "y": y_b64,
    });
    let canonical = format!(
        "{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{}\",\"y\":\"{}\"}}",
        x_b64, y_b64
    );
    let mut hasher = Sha256::new();
    hasher.update(canonical.as_bytes());
    let hash = hasher.finalize();
    let thumbprint = b64url(&hash);
    (jwk, thumbprint)
}

/// Generate a PKCS#10 Certificate Signing Request (CSR) in DER format for a P-256 key and domain.
pub fn generate_csr_der(sign_key: &SigningKey, domain: &str) -> Result<Vec<u8>, String> {
    let verify_key = sign_key.verifying_key();
    let pub_sec1 = verify_key.to_sec1_bytes();

    let cri_der = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            // Version 0
            w.next().write_u8(0);
            // Subject: CommonName = domain
            w.next().write_sequence(|w| {
                w.next().write_set_of(|w| {
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&ObjectIdentifier::from_slice(&[2, 5, 4, 3])); // commonName
                        w.next().write_utf8_string(domain);
                    });
                });
            });
            // SubjectPublicKeyInfo
            w.next().write_sequence(|w| {
                w.next().write_sequence(|w| {
                    w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 2, 1])); // id-ecPublicKey
                    w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 3, 1, 7])); // prime256v1
                });
                w.next().write_bitvec_bytes(pub_sec1.as_ref(), pub_sec1.len() * 8);
            });
            // Attributes [0] EXPLICIT: extensionRequest containing SubjectAlternativeName
            w.next().write_tagged(yasna::Tag::context(0), |w| {
                w.write_sequence(|w| {
                    w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 113549, 1, 9, 14])); // extensionRequest
                    w.next().write_set_of(|w| {
                        w.next().write_sequence(|w| {
                            w.next().write_sequence(|w| {
                                w.next().write_oid(&ObjectIdentifier::from_slice(&[2, 5, 29, 17])); // id-ce-subjectAltName
                                let san_der = yasna::construct_der(|w| {
                                    w.write_sequence(|w| {
                                        w.next().write_tagged_implicit(yasna::Tag::context(2), |w| {
                                            w.write_ia5_string(domain);
                                        });
                                    });
                                });
                                w.next().write_bytes(&san_der);
                            });
                        });
                    });
                });
            });
        });
    });

    let sig: Signature = sign_key.sign(&cri_der);
    let sig_der = sig.to_der();

    let csr_der = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            w.next().write_der(&cri_der);
            w.next().write_sequence(|w| {
                w.next().write_oid(&ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 4, 3, 2])); // ecdsa-with-SHA256
            });
            w.next().write_bitvec_bytes(sig_der.as_bytes(), sig_der.as_bytes().len() * 8);
        });
    });

    Ok(csr_der)
}

/// Asynchronous RFC 8555 ACME Client.
pub struct AcmeClient {
    pub http: reqwest::Client,
    pub directory_url: String,
}

impl AcmeClient {
    pub fn new(directory_url: String) -> Self {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(15))
            .build()
            .unwrap_or_default();
        AcmeClient {
            http,
            directory_url,
        }
    }

    /// Load or create an account private key on disk.
    fn get_or_create_account_key(&self, key_path: &Path) -> Result<SigningKey, String> {
        if key_path.exists() {
            if let Ok(pem) = fs::read_to_string(key_path) {
                if let Some(der) = extract_pem_blocks(&pem, "PRIVATE KEY").into_iter().next() {
                    if let Ok(sk) = SecretKey::from_pkcs8_der(&der) {
                        return Ok(SigningKey::from(&sk));
                    }
                }
            }
        }
        let mut raw = [0u8; 32];
        if !crate::users::os_random_bytes(&mut raw) {
            return Err("Failed to obtain OS CSPRNG entropy".to_string());
        }
        raw[0] &= 0x7f;
        raw[31] |= 1;
        let sec_key = SecretKey::from_slice(&raw).map_err(|e| e.to_string())?;
        if let Ok(pkcs8) = sec_key.to_pkcs8_der() {
            let b64_key = base64::engine::general_purpose::STANDARD.encode(pkcs8.to_bytes());
            let key_pem = format!(
                "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
                b64_key.chars().collect::<Vec<_>>().chunks(64).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("\n")
            );
            if let Some(p) = key_path.parent() {
                let _ = fs::create_dir_all(p);
            }
            let _ = fs::write(key_path, key_pem);
        }
        Ok(SigningKey::from(&sec_key))
    }

    /// Fetch ACME Directory.
    pub async fn fetch_directory(&self) -> Result<AcmeDirectory, String> {
        let res = self
            .http
            .get(&self.directory_url)
            .send()
            .await
            .map_err(|e| format!("Failed to reach ACME directory {}: {}", self.directory_url, e))?;
        if !res.status().is_success() {
            return Err(format!("ACME directory returned error status {}", res.status()));
        }
        res.json::<AcmeDirectory>()
            .await
            .map_err(|e| format!("Failed to parse ACME directory: {}", e))
    }

    /// Obtain a fresh anti-replay nonce from the ACME server.
    pub async fn get_nonce(&self, new_nonce_url: &str) -> Result<String, String> {
        let res = self
            .http
            .head(new_nonce_url)
            .send()
            .await
            .map_err(|e| format!("Failed to fetch nonce from {}: {}", new_nonce_url, e))?;
        res.headers()
            .get("replay-nonce")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .ok_or_else(|| "Server response did not include replay-nonce header".to_string())
    }

    /// Send a signed JWS POST request and return the JSON response along with next nonce.
    pub async fn post_signed(
        &self,
        url: &str,
        sign_key: &SigningKey,
        key_id_or_jwk: serde_json::Value,
        nonce: &str,
        payload: Option<&serde_json::Value>,
    ) -> Result<(reqwest::Response, String), String> {
        let jws = sign_jws_es256(sign_key, key_id_or_jwk, nonce, url, payload)?;
        let res = self
            .http
            .post(url)
            .header("content-type", "application/jose+json")
            .json(&jws)
            .send()
            .await
            .map_err(|e| format!("POST to {} failed: {}", url, e))?;

        let next_nonce = res
            .headers()
            .get("replay-nonce")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .unwrap_or_default();

        Ok((res, next_nonce))
    }

    /// Execute end-to-end ACME order, HTTP-01 challenge completion, and certificate enrollment.
    pub async fn enroll_certificate(
        &self,
        tls_mgr: &TlsManager,
        domain: &str,
        email: Option<&str>,
    ) -> Result<(), String> {
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.in_progress = true;
            c.status.progress_step = "fetching_directory".to_string();
            c.status.last_error = None;
            let _ = save_config(&tls_mgr.config_path, &c);
        }

        let dir = self.fetch_directory().await?;
        let mut nonce = self.get_nonce(&dir.new_nonce).await?;
        let account_key = self.get_or_create_account_key(&tls_mgr.cert_paths.account_key)?;
        let (jwk, thumbprint) = compute_jwk_thumbprint(&account_key.verifying_key());

        // Step 1: Create or fetch account (newAccount)
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.progress_step = "registering_account".to_string();
        }
        let mut account_payload = serde_json::json!({
            "termsOfServiceAgreed": true,
        });
        if let Some(em) = email {
            if !em.trim().is_empty() {
                account_payload.as_object_mut().unwrap().insert(
                    "contact".to_string(),
                    serde_json::json!([format!("mailto:{}", em.trim())]),
                );
            }
        }

        let (acc_res, next_nonce) = self
            .post_signed(
                &dir.new_account,
                &account_key,
                jwk,
                &nonce,
                Some(&account_payload),
            )
            .await?;
        nonce = next_nonce;

        let account_url = acc_res
            .headers()
            .get("location")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
            .ok_or_else(|| "ACME account creation response missing Location header".to_string())?;

        // Step 2: Create new order (newOrder)
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.progress_step = "submitting_order".to_string();
        }
        let order_payload = serde_json::json!({
            "identifiers": [
                { "type": "dns", "value": domain }
            ]
        });

        if nonce.is_empty() {
            nonce = self.get_nonce(&dir.new_nonce).await?;
        }
        let (order_res, next_nonce) = self
            .post_signed(
                &dir.new_order,
                &account_key,
                serde_json::json!(account_url),
                &nonce,
                Some(&order_payload),
            )
            .await?;
        nonce = next_nonce;

        let order_data = order_res
            .json::<serde_json::Value>()
            .await
            .map_err(|e| format!("Failed to parse order response: {}", e))?;

        let auth_urls = order_data["authorizations"]
            .as_array()
            .ok_or_else(|| "Order response missing authorizations list".to_string())?;
        let finalize_url = order_data["finalize"]
            .as_str()
            .ok_or_else(|| "Order response missing finalize URL".to_string())?
            .to_string();

        // Step 3: Complete HTTP-01 challenges for each authorization
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.progress_step = "answering_challenges".to_string();
        }
        for auth_url_val in auth_urls {
            let auth_url = auth_url_val.as_str().unwrap_or_default();
            if nonce.is_empty() {
                nonce = self.get_nonce(&dir.new_nonce).await?;
            }
            // POST-as-GET to fetch authorization object
            let (auth_resp, next_nonce) = self
                .post_signed(auth_url, &account_key, serde_json::json!(account_url), &nonce, None)
                .await?;
            nonce = next_nonce;

            let auth_data = auth_resp
                .json::<serde_json::Value>()
                .await
                .map_err(|e| format!("Failed to parse authorization: {}", e))?;

            let challenges = auth_data["challenges"]
                .as_array()
                .ok_or_else(|| "Authorization missing challenges array".to_string())?;

            let http_challenge = challenges
                .iter()
                .find(|c| c["type"].as_str() == Some("http-01"))
                .ok_or_else(|| "No http-01 challenge available in authorization".to_string())?;

            let token = http_challenge["token"].as_str().unwrap_or_default();
            let challenge_url = http_challenge["url"].as_str().unwrap_or_default();
            let key_auth = format!("{}.{}", token, thumbprint);

            // Register challenge token in TlsManager so port 80 listener answers it
            tls_mgr.register_acme_token(token, &key_auth);

            // Notify server that challenge is ready
            if nonce.is_empty() {
                nonce = self.get_nonce(&dir.new_nonce).await?;
            }
            let (chal_resp, next_nonce) = self
                .post_signed(
                    challenge_url,
                    &account_key,
                    serde_json::json!(account_url),
                    &nonce,
                    Some(&serde_json::json!({})),
                )
                .await?;
            nonce = next_nonce;

            if !chal_resp.status().is_success() {
                tls_mgr.unregister_acme_token(token);
                return Err(format!("Challenge trigger returned error {}", chal_resp.status()));
            }

            // Poll challenge status until valid
            let mut validated = false;
            for _ in 0..15 {
                tokio::time::sleep(Duration::from_secs(2)).await;
                if nonce.is_empty() {
                    nonce = self.get_nonce(&dir.new_nonce).await?;
                }
                let (poll_res, next_nonce) = self
                    .post_signed(challenge_url, &account_key, serde_json::json!(account_url), &nonce, None)
                    .await?;
                nonce = next_nonce;
                if let Ok(c_data) = poll_res.json::<serde_json::Value>().await {
                    let st = c_data["status"].as_str().unwrap_or("");
                    if st == "valid" {
                        validated = true;
                        break;
                    } else if st == "invalid" {
                        tls_mgr.unregister_acme_token(token);
                        let err_detail = c_data["error"]["detail"].as_str().unwrap_or("unknown challenge error");
                        return Err(format!("Challenge validation failed: {}", err_detail));
                    }
                }
            }
            tls_mgr.unregister_acme_token(token);
            if !validated {
                return Err("Timed out waiting for ACME http-01 challenge verification".to_string());
            }
        }

        // Step 4: Generate site key, CSR, and finalize order
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.progress_step = "generating_csr_and_finalizing".to_string();
        }
        let site_key = {
            let mut raw = [0u8; 32];
            if !crate::users::os_random_bytes(&mut raw) {
                return Err("Failed to obtain OS CSPRNG entropy".to_string());
            }
            raw[0] &= 0x7f;
            raw[31] |= 1;
            SecretKey::from_slice(&raw).map_err(|e| e.to_string())?
        };
        let site_sign_key = SigningKey::from(&site_key);
        let csr_der = generate_csr_der(&site_sign_key, domain)?;
        let csr_b64 = b64url(&csr_der);

        if nonce.is_empty() {
            nonce = self.get_nonce(&dir.new_nonce).await?;
        }
        let (finalize_res, next_nonce) = self
            .post_signed(
                &finalize_url,
                &account_key,
                serde_json::json!(account_url),
                &nonce,
                Some(&serde_json::json!({ "csr": csr_b64 })),
            )
            .await?;
        nonce = next_nonce;

        let mut order_obj = finalize_res
            .json::<serde_json::Value>()
            .await
            .map_err(|e| format!("Failed to parse finalize response: {}", e))?;

        // Poll order until status is valid
        let order_poll_url = order_obj["finalize"].as_str().unwrap_or(&finalize_url).to_string();
        for _ in 0..15 {
            if order_obj["status"].as_str() == Some("valid") {
                break;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
            if nonce.is_empty() {
                nonce = self.get_nonce(&dir.new_nonce).await?;
            }
            let (poll_res, next_nonce) = self
                .post_signed(&order_poll_url, &account_key, serde_json::json!(account_url), &nonce, None)
                .await?;
            nonce = next_nonce;
            if let Ok(v) = poll_res.json::<serde_json::Value>().await {
                order_obj = v;
            }
        }

        let cert_url = order_obj["certificate"]
            .as_str()
            .ok_or_else(|| "Order did not yield certificate URL".to_string())?;

        // Step 5: Download certificate chain
        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.status.progress_step = "downloading_certificate".to_string();
        }
        if nonce.is_empty() {
            nonce = self.get_nonce(&dir.new_nonce).await?;
        }
        let (cert_resp, _) = self
            .post_signed(cert_url, &account_key, serde_json::json!(account_url), &nonce, None)
            .await?;

        let cert_pem = cert_resp
            .text()
            .await
            .map_err(|e| format!("Failed to read certificate PEM from {}: {}", cert_url, e))?;

        let site_pkcs8 = site_key.to_pkcs8_der().map_err(|e| e.to_string())?;
        let site_b64 = base64::engine::general_purpose::STANDARD.encode(site_pkcs8.to_bytes());
        let site_key_pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            site_b64.chars().collect::<Vec<_>>().chunks(64).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("\n")
        );

        // Save certificate files to data/certs
        tls_mgr.cert_paths.ensure_dir().map_err(|e| e.to_string())?;
        fs::write(&tls_mgr.cert_paths.fullchain_pem, &cert_pem).map_err(|e| e.to_string())?;
        fs::write(&tls_mgr.cert_paths.privkey_pem, &site_key_pem).map_err(|e| e.to_string())?;

        // Step 6: Reload into active acceptor
        tls_mgr.reload_from_disk()?;

        {
            let mut c = tls_mgr.config.lock().unwrap();
            c.enabled = true;
            c.domain = domain.to_string();
            c.status.in_progress = false;
            c.status.progress_step = "ready".to_string();
            c.status.last_error = None;
            let _ = save_config(&tls_mgr.config_path, &c);
        }

        println!("[hub] TLS: ACME certificate issued and activated for {}", domain);
        Ok(())
    }
}

/// Spawn a background worker that checks certificate expiration every 12 hours
/// and automatically triggers renewal within 30 days of expiry.
pub fn spawn_auto_renewal_worker(tls_mgr: Arc<TlsManager>) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(12 * 3600)).await;

            let (should_renew, domain, email, staging) = {
                let c = tls_mgr.config.lock().unwrap();
                if c.enabled && c.auto_renew && (c.mode == TlsMode::Auto || c.mode == TlsMode::CustomDomain) {
                    let now = unix_now();
                    let days_left = if c.status.expires_at > now {
                        ((c.status.expires_at - now) / 86400) as i64
                    } else {
                        -1
                    };
                    (days_left <= 30 && !c.status.in_progress, c.domain.clone(), c.email.clone(), c.staging_mode)
                } else {
                    (false, String::new(), None, false)
                }
            };

            if should_renew && !domain.is_empty() {
                println!("[hub] TLS: Certificate for {} expires within 30 days. Initiating automatic renewal...", domain);
                let dir_url = if staging {
                    LETS_ENCRYPT_STAGING_DIR
                } else {
                    LETS_ENCRYPT_PRODUCTION_DIR
                };
                let client = AcmeClient::new(dir_url.to_string());
                if let Err(e) = client.enroll_certificate(&tls_mgr, &domain, email.as_deref()).await {
                    eprintln!("[hub] TLS ERR: Automatic renewal failed for {}: {}", domain, e);
                    let mut c = tls_mgr.config.lock().unwrap();
                    c.status.in_progress = false;
                    c.status.last_error = Some(e);
                    let _ = save_config(&tls_mgr.config_path, &c);
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_sslip_domain_converts_ipv4_correctly() {
        assert_eq!(format_sslip_domain("123.45.67.89"), "123-45-67-89.sslip.io");
        assert_eq!(format_sslip_domain(" 10.0.0.1\n"), "10-0-0-1.sslip.io");
        // Non-IP domains remain unchanged
        assert_eq!(format_sslip_domain("hub.myfirm.com"), "hub.myfirm.com");
    }

    #[test]
    fn config_roundtrip_save_and_load() {
        let tmp_dir = std::env::temp_dir().join(format!("mtc_tls_test_{}", std::process::id()));
        let cfg_path = tmp_dir.join("tls_config.json");

        let mut cfg = TlsConfig::default();
        cfg.enabled = true;
        cfg.domain = "123-45-67-89.sslip.io".to_string();
        cfg.https_port = 8443;
        cfg.email = Some("test@example.com".to_string());
        cfg.status.cert_valid = true;
        cfg.status.issuer = "Let's Encrypt".to_string();

        save_config(&cfg_path, &cfg).unwrap();
        let loaded = load_config(&cfg_path);

        assert!(loaded.enabled);
        assert_eq!(loaded.domain, "123-45-67-89.sslip.io");
        assert_eq!(loaded.https_port, 8443);
        assert_eq!(loaded.email, Some("test@example.com".to_string()));
        assert!(loaded.status.cert_valid);
        assert_eq!(loaded.status.issuer, "Let's Encrypt");

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn extract_pem_blocks_decodes_certificates() {
        let sample = "\
-----BEGIN CERTIFICATE-----
AQIDBA==
-----END CERTIFICATE-----
Some other text
-----BEGIN CERTIFICATE-----
BQYHCA==
-----END CERTIFICATE-----";
        let blocks = extract_pem_blocks(sample, "CERTIFICATE");
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0], vec![1, 2, 3, 4]);
        assert_eq!(blocks[1], vec![5, 6, 7, 8]);
    }

    #[test]
    fn generate_self_signed_cert_and_pkcs12_roundtrip() {
        let domain = "127-0-0-1.sslip.io";
        let (cert_pem, key_pem) = generate_self_signed(domain).expect("self signed gen failed");
        assert!(cert_pem.contains("BEGIN CERTIFICATE"));
        assert!(key_pem.contains("BEGIN PRIVATE KEY"));

        let pfx_bytes = pem_to_pkcs12(&cert_pem, &key_pem, "testpass").expect("pem to pkcs12 failed");
        assert!(!pfx_bytes.is_empty());

        let acceptor = create_tls_acceptor(&pfx_bytes, "testpass");
        assert!(acceptor.is_ok(), "acceptor creation failed: {:?}", acceptor.err());
    }

    #[test]
    fn tls_manager_apply_self_signed_and_reload() {
        let tmp_dir = std::env::temp_dir().join(format!("mtc_tls_mgr_test_{}", std::process::id()));
        let cfg_path = tmp_dir.join("tls_config.json");
        let mgr = TlsManager::new(&tmp_dir, &cfg_path);

        assert!(!mgr.config.lock().unwrap().enabled);
        assert!(mgr.acceptor.read().unwrap().is_none());

        mgr.apply_self_signed("test.sslip.io", 8443).unwrap();
        assert!(mgr.config.lock().unwrap().enabled);
        assert!(mgr.acceptor.read().unwrap().is_some());

        // Verify disk files
        assert!(mgr.cert_paths.fullchain_pem.exists());
        assert!(mgr.cert_paths.privkey_pem.exists());

        // Test reload from disk
        mgr.reload_from_disk().unwrap();
        assert!(mgr.acceptor.read().unwrap().is_some());

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn jws_and_jwk_thumbprint_generation() {
        let mut raw = [0u8; 32];
        raw[31] = 1; // simple valid scalar
        let sk = SecretKey::from_slice(&raw).unwrap();
        let sign_key = SigningKey::from(&sk);
        let (jwk, thumbprint) = compute_jwk_thumbprint(&sign_key.verifying_key());

        assert_eq!(jwk["crv"], "P-256");
        assert_eq!(jwk["kty"], "EC");
        assert!(!thumbprint.is_empty());

        let jws = sign_jws_es256(
            &sign_key,
            jwk,
            "nonce12345",
            "https://example.com/acme/order",
            Some(&serde_json::json!({"test": true})),
        )
        .expect("jws sign failed");

        assert!(jws["protected"].is_string());
        assert!(jws["payload"].is_string());
        assert!(jws["signature"].is_string());
    }

    #[test]
    fn csr_generation_der() {
        let mut raw = [0u8; 32];
        raw[31] = 2;
        let sk = SecretKey::from_slice(&raw).unwrap();
        let sign_key = SigningKey::from(&sk);
        let csr_der = generate_csr_der(&sign_key, "hub.test.sslip.io").expect("csr generation failed");
        assert!(!csr_der.is_empty());
        assert_eq!(csr_der[0], 0x30); // ASN.1 SEQUENCE
    }
}
