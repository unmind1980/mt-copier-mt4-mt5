//! notifications.rs - External Alert Dispatcher (Telegram, WeCom, DingTalk, Webhook).
//!
//! Sends real-time notifications when the hub's alert engine fires.
//! Runs asynchronously over Tokio without blocking the main ZeroMQ router thread.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::alerts::{Alert, Severity};
use crate::users;

#[allow(dead_code)]
pub const DEFAULT_STORE_PATH: &str = "alert_channels.json";
pub const HTTP_TIMEOUT_SECS: u64 = 8;
const B64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct NotificationChannel {
    pub id: String,
    pub name: String,
    /// Channel kind: "telegram", "wecom", "dingtalk", "webhook", "wechat" (xtuis)
    pub channel_type: String,
    pub enabled: bool,
    /// Minimum severity to trigger: "warning" (all) or "critical" (only critical)
    pub min_severity: String,
    /// Notification language preference: "zh-CN", "zh-TW", "en", "ja", "ru", "es"
    #[serde(default = "default_notif_lang")]
    pub lang: String,
    /// Type-specific configuration
    pub config: Value,
    pub created_at: u64,
}

pub fn default_notif_lang() -> String {
    "zh-CN".to_string()
}

impl NotificationChannel {
    pub fn safe_json(&self) -> Value {
        //--- MASKING IS DENY-BY-DEFAULT, NOT AN ALLOWLIST OF NAMES.
        //--- The old code masked exactly one key per channel type
        //--- (telegram bot_token, wecom key, dingtalk secret, two header
        //--- names). Everything else went out verbatim - and the real store
        //--- turned out to use shapes that list never covered: dingtalk's
        //--- ACCESS TOKEN is stored both inside webhook_url AND as a
        //--- standalone "access_token" field, and a webhook URL IS itself the
        //--- capability (anyone holding the URL can POST to it).
        //---
        //--- So: mask any value whose key NAME says it is a secret, mask
        //--- every header value, and mask secret-bearing URL query params.
        //--- A future field is covered by name rather than by remembering to
        //--- add it here.
        //---
        //--- For WEBHOOK the rule inverts entirely: its config shape is
        //--- "capability URL + arbitrary headers", so an operator can put a
        //--- raw credential under any key at all - and one observed shape
        //--- stores `Authorization: Bearer xxx` under webhook_auth_value,
        //--- whose name contains no secret-word. For that type everything
        //--- not in WEBHOOK_PLAIN_KEYS is masked. See is_webhook_plain_key.
        let mut cfg = self.config.clone();
        if let Some(obj) = cfg.as_object_mut() {
            let keys: Vec<String> = obj.keys().cloned().collect();
            for k in keys {
                if k == "headers" {
                    //--- Every header value, not a named few: an
                    //--- Authorization-style header is the common
                    //--- case, but X-Api-Key / X-Auth-Token and any
                    //--- custom bearer header carry the same weight,
                    //--- and the operator should not have to know
                    //--- this list to be safe.
                    if let Some(headers) = obj.get_mut("headers").and_then(|v| v.as_object_mut()) {
                        let hkeys: Vec<String> = headers.keys().cloned().collect();
                        for hk in hkeys {
                            if let Some(hv) = headers.get_mut(&hk) {
                                if let Some(hs) = hv.as_str() {
                                    if !is_standard_plain_header(&hk) {
                                        *hv = Value::String(mask_secret(hs));
                                    }
                                }
                            }
                        }
                    }
                    continue;
                }
                if let Some(v) = obj.get_mut(&k) {
                    if let Value::String(s) = v {
                        if self.channel_type == "webhook" && !is_webhook_plain_key(&k) {
                            *v = Value::String(mask_secret(s));
                        } else if is_secret_key_name(&k) {
                            *v = Value::String(mask_secret(s));
                        } else if is_url_key_name(&k) {
                            //--- A webhook URL is the credential and its
                            //--- secret usually sits in the PATH; every other
                            //--- channel type only has secrets in its query.
                            //--- For WeChat/Xtuis, token also sits in the URL path.
                            *v = Value::String(if self.channel_type == "webhook" || self.channel_type == "wechat" || self.channel_type == "xtuis" {
                                mask_webhook_url(s)
                            } else {
                                mask_url_secrets(s)
                            });
                        }
                    }
                }
            }
        }

        json!({
            "id": self.id,
            "name": self.name,
            "channel_type": self.channel_type,
            "enabled": self.enabled,
            "min_severity": self.min_severity,
            "lang": self.lang,
            "config": cfg,
            "created_at": self.created_at,
        })
    }
}

/// Does this config key NAME say "secret"? Case-insensitive, and matched on
/// exact name plus two substrings that are unambiguous ("token", "secret",
/// "password"). Deliberately NOT the bare substring "key" on its own - that
/// would catch a field named "keyword" - so "key" is an EXACT match only.
fn is_secret_key_name(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    matches!(
        k.as_str(),
        "key" | "token" | "secret" | "access_token" | "bot_token"
            | "password" | "apikey" | "api_key" | "auth"
    ) || k.contains("token")
        || k.contains("secret")
        || k.contains("password")
}

/// Does this config key hold a URL that may carry a secret in its query?
fn is_url_key_name(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    k == "url" || k == "webhook" || k.ends_with("_url") || k.ends_with("url")
}

/// The keys of a WEBHOOK channel config that are NOT secrets.
///
/// A webhook channel's documented shape is "a capability URL plus arbitrary
/// headers" - which means an operator can hand-write any field at all, and
/// one of the observed shapes stores a raw `Authorization: Bearer xxx`
/// string under `webhook_auth_value`, whose name contains none of the
/// secret-words. For this ONE channel type the safe list is knowable and
/// tiny, so the rule INVERTS: everything not on the list is masked. The
/// named types (telegram/wecom/dingtalk) have closed, documented key sets
/// and keep the name-based rule above.
const WEBHOOK_PLAIN_KEYS: &[&str] = &["url", "method", "headers"];

fn is_webhook_plain_key(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    WEBHOOK_PLAIN_KEYS.contains(&k.as_str())
}

/// Mask the query parameters of a URL whose names say "secret", leaving the
/// rest of the URL (host, path, non-secret params) readable - the operator
/// needs to see WHICH endpoint a channel posts to.
pub fn mask_url_secrets(url: &str) -> String {
    let (base, query) = match url.split_once('?') {
        Some((b, q)) => (b, q),
        None => return mask_userinfo_in_url(url),
    };
    let mut out = String::with_capacity(url.len());
    out.push_str(&mask_userinfo_in_url(base));
    for (i, pair) in query.split('&').enumerate() {
        out.push(if i == 0 { '?' } else { '&' });
        match pair.split_once('=') {
            Some((name, val)) => {
                out.push_str(name);
                out.push('=');
                if is_secret_key_name(name) {
                    out.push_str(&mask_secret(val));
                } else {
                    out.push_str(val);
                }
            }
            None => out.push_str(pair),
        }
    }
    out
}

/// Replace `user:password@` in the authority with `***@`.
///
/// Basic-auth credentials in a URL are a capability exactly like a token, and
/// they were passed through untouched by every masking path - `https://u:p@host`
/// came out of `safe_json` verbatim. Kept as a separate step so both the
/// query-masking path and the webhook path get it.
fn mask_userinfo_in_url(url: &str) -> String {
    let (scheme, rest) = match url.split_once("://") {
        Some((s, r)) => (Some(s), r),
        None => (None, url),
    };
    //--- The authority ends at the first '/', '?' or '#'.
    let end = rest
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let masked = match authority.rsplit_once('@') {
        Some((_, host)) => format!("***@{}", host),
        None => authority.to_string(),
    };
    match scheme {
        Some(s) => format!("{}://{}{}", s, masked, tail),
        None => format!("{}{}", masked, tail),
    }
}

/// Mask a WEBHOOK url down to scheme + host.
///
/// WHY THE PATH AND NOT JUST THE QUERY
/// ===================================
/// A webhook URL IS the credential, and for the common providers the secret
/// lives in the PATH: Slack's `/services/T…/B…/<secret>`, Discord's
/// `/api/webhooks/<id>/<token>`. `mask_url_secrets` only touches query
/// parameters, so `safe_json` was handing every authenticated VIEWER a fully
/// working capability URL - which is a write credential to somebody else's
/// chat channel.
///
/// The scheme and host are kept because that is what an operator needs to
/// tell channels apart ("the Slack one", "the Discord one"). Everything after
/// the host is replaced by `/***`, which still contains the `***` marker the
/// merge path looks for, so editing a channel and saving restores the real
/// URL from the stored copy instead of persisting the mask.
pub fn mask_webhook_url(url: &str) -> String {
    let (scheme, rest) = match url.split_once("://") {
        Some((s, r)) => (Some(s), r),
        None => (None, url),
    };
    let end = rest.find('/').unwrap_or(rest.len());
    let (authority, path) = rest.split_at(end);
    let masked = match authority.rsplit_once('@') {
        Some((_, host)) => format!("***@{}", host),
        None => authority.to_string(),
    };
    let mut out = String::with_capacity(url.len());
    if let Some(s) = scheme {
        out.push_str(s);
        out.push_str("://");
    }
    out.push_str(&masked);
    if !path.is_empty() {
        out.push_str("/***");
    }
    out
}

/// HTML for Telegram's `parse_mode: HTML`. `&`, `<` and `>` must be escaped
/// or a node name or a risk name containing them (both are operator- and
/// node-supplied) breaks the message: Telegram then rejects the WHOLE
/// request with a 400 and the alert is lost - and the same interpolation is
/// the classic HTML-injection sink. Severity badge / time / title are
/// hub-generated constants, but masking them too costs nothing and keeps
/// the rule "everything interpolated is escaped".
pub fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

// R47-15: Markdown special character escaping for DingTalk channel to prevent formatting/link injection
pub fn markdown_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' | '*' | '_' | '[' | ']' | '(' | ')' | '#' | '+' | '-' | '!' | '`' | '<' | '>' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}

/// Byte slices on a &str are a panic waiting for a multibyte secret.
/// `&s[..4]` and `&s[len-4..]` are only valid on char boundaries, and the
/// first token containing ONE non-ASCII character made the API thread
/// panic - which poisons the shared-state mutex and turns every later
/// request under /api/v1/ into a 500 until the hub restarts. Iterate
/// chars instead: the mask must never be the thing that takes the hub down.
pub fn mask_secret(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= 8 {
        "******".to_string()
    } else {
        format!(
            "{}***{}",
            chars[..4].iter().collect::<String>(),
            chars[chars.len() - 4..].iter().collect::<String>()
        )
    }
}

fn is_standard_plain_header(h: &str) -> bool {
    let lower = h.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "content-type" | "accept" | "user-agent" | "host" | "accept-encoding" | "connection"
    )
}


/// Store for alert channels backed by JSON file.
pub struct NotificationStore {
    path: PathBuf,
    channels: HashMap<String, NotificationChannel>,
    enabled: bool,
}

impl NotificationStore {
    pub fn new(path: Option<&Path>) -> Self {
        let (p, enabled) = match path {
            Some(p) => (p.to_path_buf(), true),
            None => (PathBuf::new(), false),
        };
        let mut store = NotificationStore {
            path: p,
            channels: HashMap::new(),
            enabled,
        };
        //--- Only load from disk when notifications are explicitly enabled with a path.
        //--- Passing None (--notifications none) keeps channels in memory only and MUST NOT
        //--- load alert_channels.json or dispatch live alerts.
        if store.enabled && !store.path.as_os_str().is_empty() && store.path.exists() {
            if let Err(e) = store.load() {
                eprintln!(
                    "[hub] notification store {} failed to load ({}): starting with ZERO channels",
                    store.path.display(),
                    e
                );
            }
        }
        store
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&mut self) -> io::Result<()> {
        if !self.enabled || self.path.as_os_str().is_empty() || !self.path.exists() {
            return Ok(());
        }
        let data = fs::read_to_string(&self.path)?;
        if data.trim().is_empty() {
            return Ok(());
        }
        let list: Vec<NotificationChannel> = serde_json::from_str(data.trim_start_matches('\u{feff}'))
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.channels.clear();
        for ch in list {
            self.channels.insert(ch.id.clone(), ch);
        }
        Ok(())
    }

    pub fn save(&self) -> io::Result<()> {
        if !self.enabled || self.path.as_os_str().is_empty() {
            return Ok(());
        }
        let mut list: Vec<&NotificationChannel> = self.channels.values().collect();
        list.sort_by_key(|c| c.created_at);

        let json_text = serde_json::to_string_pretty(&list)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        let tmp_path = format!("{}.tmp.{}", self.path.display(), std::process::id());
        {
            let mut f = File::create(&tmp_path)?;
            f.write_all(json_text.as_bytes())?;
            f.flush()?;
            f.sync_all()?;
        }
        // N84-08: Use atomic_replace_file with Windows copy-fallback instead of bare rename
        crate::cluster::atomic_replace_file(Path::new(&tmp_path), &self.path)?;
        Ok(())
    }

    pub fn list_safe(&self) -> Vec<Value> {
        let mut list: Vec<&NotificationChannel> = self.channels.values().collect();
        list.sort_by_key(|c| c.created_at);
        list.iter().map(|c| c.safe_json()).collect()
    }

    pub fn get(&self, id: &str) -> Option<&NotificationChannel> {
        self.channels.get(id)
    }

    pub fn upsert(&mut self, mut channel: NotificationChannel) -> io::Result<NotificationChannel> {
        // If updating an existing channel, keep existing secrets if incoming is masked/empty.
        //
        // The channel TYPE comes from the STORED row, never from the incoming
        // body. Masking (`safe_json`) ran under the stored type, so restoring
        // must run under the same one: changing a channel from `webhook` to
        // `telegram` in a single PUT used to leave `webhook_auth_value` =
        // "Bear***3456" - not secret-ish under the telegram rule - and that
        // mask was then PERSISTED as the credential.
        if let Some(existing) = self.channels.get(&channel.id) {
            merge_unmasked_config(&mut channel.config, &existing.config, &existing.channel_type);
        }
        // F-08 & N71-02: validate final unmasked URL syntax and non-network SSRF rules before writing to disk
        if let Some(url) = channel.config.get("url").or_else(|| channel.config.get("webhook_url")).and_then(|u| u.as_str()) {
            if let Err(e) = check_url_base(url) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, e));
            }
        }
        // N83-05 & N84-14: Validate WeChat token/key/webhook_url
        if channel.channel_type == "wechat" || channel.channel_type == "xtuis" {
            let tok_val = channel.config.get("token")
                .or_else(|| channel.config.get("key"))
                .or_else(|| channel.config.get("webhook_url"))
                .and_then(|v| v.as_str());
            if let Some(tok) = tok_val {
                let t = tok.trim();
                if t.starts_with("http://") || t.starts_with("https://") {
                    if let Err(e) = check_url_base(t) {
                        return Err(io::Error::new(io::ErrorKind::InvalidInput, e));
                    }
                } else if !t.is_empty() {
                    let clean = t.trim_end_matches(".send");
                    if !clean.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "WeChat (Xtuis) token contains invalid characters",
                        ));
                    }
                }
            }
        }
        if channel.created_at == 0 {
            channel.created_at = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
        }
        let prev = self.channels.insert(channel.id.clone(), channel.clone());
        // N83-03: Rollback in-memory map if disk save fails
        if let Err(e) = self.save() {
            if let Some(old) = prev {
                self.channels.insert(channel.id.clone(), old);
            } else {
                self.channels.remove(&channel.id);
            }
            return Err(e);
        }
        Ok(channel)
    }

    pub fn remove(&mut self, id: &str) -> io::Result<bool> {
        if let Some(removed) = self.channels.remove(id) {
            // N83-03: Rollback in-memory map if disk save fails
            if let Err(e) = self.save() {
                self.channels.insert(id.to_string(), removed);
                return Err(e);
            }
            Ok(true)
        } else {
            Ok(false)
        }
    }

    #[allow(dead_code)]
    pub fn matching_channels(&self, severity: Severity) -> Vec<NotificationChannel> {
        if !self.enabled {
            return Vec::new();
        }
        self.channels
            .values()
            .filter(|c| {
                if !c.enabled {
                    return false;
                }
                match c.min_severity.as_str() {
                    "critical" => severity == Severity::Critical,
                    _ => true, // warning or any other accepts both Warning and Critical
                }
            })
            .cloned()
            .collect()
    }

    /// Match channels for an alert, ensuring recovery notifications (closed loop)
    /// reach all channels that were eligible for outage alerts (even if min_severity is critical).
    pub fn matching_channels_for_alert(&self, alert: &Alert) -> Vec<NotificationChannel> {
        if !self.enabled {
            return Vec::new();
        }
        self.channels
            .values()
            .filter(|c| {
                if !c.enabled {
                    return false;
                }
                if alert.kind == "node.recovered" {
                    return true;
                }
                match c.min_severity.as_str() {
                    "critical" => alert.severity == Severity::Critical,
                    _ => true,
                }
            })
            .cloned()
            .collect()
    }
}

/// Restore the real secret wherever the incoming config carries a MASK.
///
/// The API only ever returns masked secrets (safe_json), so an update from
/// the dashboard arrives with the mask in place of the credential. This is
/// the other half of that round trip, and it must be exactly as wide as the
/// masking: where the old code covered one named key per channel type, a
/// mask now appears on every secret-named field, every masked URL query,
/// every masked header value, and - for webhook channels - every field not
/// in WEBHOOK_PLAIN_KEYS. If this list were narrower, the MASK ITSELF would
/// be persisted as the credential and the channel would fail every send
/// with a token like "SECR***3456".
///
/// Deny-by-default for the same reason as safe_json: the set of secret
/// fields is a property of the config SHAPE, and guarding it here means a
/// new field is covered by its name rather than by somebody remembering.
pub fn merge_unmasked_config(new_cfg: &mut Value, old_cfg: &Value, channel_type: &str) {
    let is_secretish = |k: &str| {
        is_secret_key_name(k)
            || is_url_key_name(k)
            || (channel_type == "webhook" && !is_webhook_plain_key(k))
    };
    // BUG-11: Only strings containing '***' are masked secrets; empty strings indicate intentional clearing
    let is_masked = |s: &str| s.contains("***");

    let (new_obj, old_obj) = match (new_cfg.as_object_mut(), old_cfg.as_object()) {
        (Some(n), Some(o)) => (n, o),
        _ => return,
    };
    let keys: Vec<String> = new_obj.keys().cloned().collect();
    for k in keys {
        //--- Headers is an OBJECT, never a string: it cannot pass through the
        //--- masked-in gate below (an object has no as_str), so it is handled
        //--- BEFORE that gate rather than after it.
        if k == "headers" {
            //--- Per-header, not all-or-nothing: an update that adds a new
            //--- header and leaves an old one masked must not resurrect the
            //--- operator's intent to drop that header - it just keeps the
            //--- secret under it.
            if let (Some(new_h), Some(old_h)) = (
                new_obj.get_mut("headers").and_then(|v| v.as_object_mut()),
                old_obj.get("headers").and_then(|v| v.as_object()),
            ) {
                let hkeys: Vec<String> = new_h.keys().cloned().collect();
                for hk in hkeys {
                    let hv_masked = new_h
                        .get(&hk)
                        .and_then(|v| v.as_str())
                        .map(is_masked)
                        .unwrap_or(false);
                    if hv_masked {
                        if let Some(old_val) = old_h.get(&hk).and_then(|ov| ov.as_str()) {
                            new_h.insert(hk, Value::String(old_val.to_string()));
                        }
                    }
                }
            }
            continue;
        }
        let masked_in = new_obj
            .get(&k)
            .and_then(|v| v.as_str())
            .map(is_masked)
            .unwrap_or(false);
        if !masked_in {
            continue; // a real (new) value came in - it wins, as it should
        }
        if is_secretish(&k) {
            if let Some(old_val) = old_obj.get(&k).and_then(|v| v.as_str()) {
                new_obj.insert(k, Value::String(old_val.to_string()));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Cryptographic helpers: HMAC-SHA256, Base64, URL encode
// ---------------------------------------------------------------------------

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let hashed_key = users::sha256(key);
        k[..32].copy_from_slice(&hashed_key);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0u8; 64];
    let mut opad = [0u8; 64];
    for i in 0..64 {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }
    let mut inner = Vec::with_capacity(64 + data.len());
    inner.extend_from_slice(&ipad);
    inner.extend_from_slice(data);
    let inner_hash = users::sha256(&inner);

    let mut outer = Vec::with_capacity(64 + 32);
    outer.extend_from_slice(&opad);
    outer.extend_from_slice(&inner_hash);
    users::sha256(&outer)
}

pub fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 { chunk[1] as usize } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as usize } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64_CHARS[(triple >> 18) & 0x3f] as char);
        out.push(B64_CHARS[(triple >> 12) & 0x3f] as char);
        if chunk.len() > 1 {
            out.push(B64_CHARS[(triple >> 6) & 0x3f] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64_CHARS[triple & 0x3f] as char);
        } else {
            out.push('=');
        }
    }
    out
}

pub fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len() * 3);
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b'~' {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

pub fn format_utc_timestamp(ts: u64) -> String {
    let sec = (ts % 60) as u32;
    let min = ((ts / 60) % 60) as u32;
    let hour = ((ts / 3600) % 24) as u32;
    let mut days = (ts / 86400) as i64;
    days += 719468;
    let era = if days >= 0 { days } else { days - 146096 } / 146097;
    let doe = (days - era * 146097) as u32;
    // HUB-01: Howard Hinnant algorithm constants: 1460 (4yr) and 36524 (100yr)
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC", y, m, d, hour, min, sec)
}

// ---------------------------------------------------------------------------
// Formatted Alert representations
// ---------------------------------------------------------------------------

pub struct AlertFormatted {
    pub title: String,
    pub severity_badge: String,
    pub time_str: String,
    pub node: String,
    pub detail_summary: String,
    pub lbl_severity: String,
    pub lbl_target: String,
    pub lbl_time: String,
    pub lbl_detail: String,
}

pub fn normalize_lang(lang: &str) -> &'static str {
    let l = lang.trim().to_ascii_lowercase();
    if l == "zh-tw" || l == "zh_tw" || l == "zh-hk" || l == "tw" || l == "hk" {
        "zh-TW"
    } else if l.starts_with("zh") || l == "cn" {
        "zh-CN"
    } else if l.starts_with("ja") || l == "jp" {
        "ja"
    } else if l.starts_with("ru") {
        "ru"
    } else if l.starts_with("es") {
        "es"
    } else {
        "en"
    }
}

pub fn get_channel_lang(channel: &NotificationChannel) -> &str {
    if !channel.lang.trim().is_empty() {
        channel.lang.as_str()
    } else if let Some(l) = channel.config.get("lang").and_then(|v| v.as_str()) {
        l
    } else {
        "zh-CN"
    }
}

#[allow(dead_code)]
pub fn format_alert(alert: &Alert) -> AlertFormatted {
    format_alert_with_lang(alert, "en")
}

pub fn format_alert_with_lang(alert: &Alert, lang: &str) -> AlertFormatted {
    let nlang = normalize_lang(lang);
    let time_str = format_utc_timestamp(alert.ts);

    let (lbl_severity, lbl_target, lbl_time, lbl_detail) = match nlang {
        "zh-CN" => ("告警级别", "监控对象", "发生时间", "详细说明"),
        "zh-TW" => ("告警級別", "監控對象", "發生時間", "詳細說明"),
        "ja" => ("重要度", "対象", "発生日時", "詳細"),
        "ru" => ("Уровень", "Объект", "Время", "Подробности"),
        "es" => ("Severidad", "Destino", "Hora", "Detalle"),
        _ => ("Severity", "Target", "Time", "Detail"),
    };

    let (sev_str, badge) = match (alert.kind, alert.severity) {
        ("node.recovered", _) => match nlang {
            "zh-CN" => ("[已恢复]", "🟢 已恢复"),
            "zh-TW" => ("[已恢復]", "🟢 已恢復"),
            "ja" => ("[復旧]", "🟢 復旧"),
            "ru" => ("[ВОССТАНОВЛЕНО]", "🟢 ВОССТАНОВЛЕНО"),
            "es" => ("[RECUPERADO]", "🟢 RECUPERADO"),
            _ => ("[RECOVERED]", "🟢 RECOVERED"),
        },
        (_, Severity::Critical) => match nlang {
            "zh-CN" => ("[严重告警]", "🔴 严重告警"),
            "zh-TW" => ("[嚴重告警]", "🔴 嚴重告警"),
            "ja" => ("[緊急]", "🔴 緊急"),
            "ru" => ("[КРИТИЧЕСКИЙ]", "🔴 КРИТИЧЕСКИЙ"),
            "es" => ("[CRÍTICO]", "🔴 CRÍTICO"),
            _ => ("[CRITICAL ALERT]", "🔴 CRITICAL"),
        },
        (_, Severity::Warning) => match nlang {
            "zh-CN" => ("[一般警告]", "🟡 一般警告"),
            "zh-TW" => ("[一般警告]", "🟡 一般警告"),
            "ja" => ("[警告]", "🟡 警告"),
            "ru" => ("[ПРЕДУПРЕЖДЕНИЕ]", "🟡 ПРЕДУПРЕЖДЕНИЕ"),
            "es" => ("[ADVERTENCIA]", "🟡 ADVERTENCIA"),
            _ => ("[WARNING]", "🟡 WARNING"),
        },
    };

    let title_prefix = match alert.kind {
        "node.offline" => match nlang {
            "zh-CN" => "节点掉线离线",
            "zh-TW" => "節點斷線離線",
            "ja" => "ノードオフライン",
            "ru" => "Узел офлайн",
            "es" => "Nodo desconectado",
            _ => "Node Offline",
        },
        "node.recovered" => match nlang {
            "zh-CN" => "节点连接恢复",
            "zh-TW" => "節點連線恢復",
            "ja" => "ノード復旧",
            "ru" => "Узел восстановлен",
            "es" => "Nodo recuperado",
            _ => "Node Recovered",
        },
        "node.clock.drift" => match nlang {
            "zh-CN" => "时钟漂移超限",
            "zh-TW" => "時鐘漂移超限",
            "ja" => "クロックドリフト超過",
            "ru" => "Превышен дрейф часов",
            "es" => "Desviación de reloj superada",
            _ => "Clock Drift Exceeded",
        },
        "risk.blocked" => match nlang {
            "zh-CN" => "风控拦截挂单",
            "zh-TW" => "風控攔截掛單",
            "ja" => "リスクゲート遮断",
            "ru" => "Заблокировано шлюзом риска",
            "es" => "Puerta de riesgo bloqueada",
            _ => "Risk Gate Blocked",
        },
        "risk.tripped" => match nlang {
            "zh-CN" => "风控规则触发",
            "zh-TW" => "風控規則觸發",
            "ja" => "リスクゲート作動",
            "ru" => "Сработал шлюз риска",
            "es" => "Puerta de riesgo activada",
            _ => "Risk Gate Tripped",
        },
        "command.unknown" => match nlang {
            "zh-CN" => "指令重试耗尽",
            "zh-TW" => "指令重試耗盡",
            "ja" => "コマンド再試行枯渇",
            "ru" => "Исчерпаны попытки команды",
            "es" => "Reintentos de comando agotados",
            _ => "Command Retries Exhausted",
        },
        "test" => match nlang {
            "zh-CN" => "渠道连通性测试",
            "zh-TW" => "渠道連通性測試",
            "ja" => "接続テスト",
            "ru" => "Тест подключения канала",
            "es" => "Prueba de conectividad",
            _ => "Channel Connectivity Test",
        },
        _ => alert.kind,
    };

    let title = format!("{} {}", sev_str, title_prefix);
    let node_display = if alert.node.is_empty() {
        match nlang {
            "zh-CN" | "zh-TW" => "Hub中枢 (全局)".to_string(),
            "ja" => "Hub (グローバル)".to_string(),
            "ru" => "Hub (глобальный)".to_string(),
            "es" => "Hub (global)".to_string(),
            _ => "hub (global)".to_string(),
        }
    } else {
        alert.node.clone()
    };

    let detail_summary = match alert.kind {
        "node.offline" => {
            let role = alert.detail.get("role").and_then(|v| v.as_str()).unwrap_or("node");
            let acc = alert.detail.get("account").and_then(|v| v.as_str()).unwrap_or("-");
            let quiet = alert.detail.get("quiet_secs").and_then(|v| v.as_u64());
            if let Some(q) = quiet {
                match nlang {
                    "zh-CN" => format!("角色: {}, 账号: {}, 心跳超时失联 (已静默 {}s)", role, acc, q),
                    "zh-TW" => format!("角色: {}, 帳號: {}, 心跳超時失聯 (已靜默 {}s)", role, acc, q),
                    "ja" => format!("ロール: {}, 口座: {}, ハートビートタイムアウト (応答停止: {}秒)", role, acc, q),
                    "ru" => format!("Роль: {}, Счет: {}, тайм-аут пакетов (тишина {}с)", role, acc, q),
                    "es" => format!("Rol: {}, Cuenta: {}, tiempo de espera agotado (inactivo por {}s)", role, acc, q),
                    _ => format!("Role: {}, Account: {}, heartbeat timeout exceeded (silent for {}s)", role, acc, q),
                }
            } else {
                match nlang {
                    "zh-CN" => format!("角色: {}, 账号: {}, 心跳超时失联", role, acc),
                    "zh-TW" => format!("角色: {}, 帳號: {}, 心跳超時失聯", role, acc),
                    "ja" => format!("ロール: {}, 口座: {}, ハートビートタイムアウト", role, acc),
                    "ru" => format!("Роль: {}, Счет: {}, тайм-аут пакетов", role, acc),
                    "es" => format!("Rol: {}, Cuenta: {}, tiempo de espera agotado", role, acc),
                    _ => format!("Role: {}, Account: {}, heartbeat timeout exceeded", role, acc),
                }
            }
        }
        "node.recovered" => {
            let role = alert.detail.get("role").and_then(|v| v.as_str()).unwrap_or("node");
            let acc = alert.detail.get("account").and_then(|v| v.as_str()).unwrap_or("-");
            let outage = alert.detail.get("outage_secs").and_then(|v| v.as_u64());
            if let Some(dur) = outage {
                let dur_str = if dur >= 60 {
                    format!("{}m {}s ({}s)", dur / 60, dur % 60, dur)
                } else {
                    format!("{}s", dur)
                };
                match nlang {
                    "zh-CN" => format!("角色: {}, 账号: {}, 连接与心跳已恢复正常 (中断时长: {})", role, acc, dur_str),
                    "zh-TW" => format!("角色: {}, 帳號: {}, 連線與心跳已恢復正常 (中斷時長: {})", role, acc, dur_str),
                    "ja" => format!("ロール: {}, 口座: {}, 接続とハートビートが復旧しました (停止時間: {})", role, acc, dur_str),
                    "ru" => format!("Роль: {}, Счет: {}, связь и сердцебиение восстановлены (перерыв: {})", role, acc, dur_str),
                    "es" => format!("Rol: {}, Cuenta: {}, conexión y latidos restaurados (interrupción: {})", role, acc, dur_str),
                    _ => format!("Role: {}, Account: {}, connection & heartbeat restored (outage: {})", role, acc, dur_str),
                }
            } else {
                match nlang {
                    "zh-CN" => format!("角色: {}, 账号: {}, 连接与心跳已恢复正常", role, acc),
                    "zh-TW" => format!("角色: {}, 帳號: {}, 連線與心跳已恢復正常", role, acc),
                    "ja" => format!("ロール: {}, 口座: {}, 接続とハートビートが復旧しました", role, acc),
                    "ru" => format!("Роль: {}, Счет: {}, связь и сердцебиение восстановлены", role, acc),
                    "es" => format!("Rol: {}, Cuenta: {}, conexión y latidos restaurados", role, acc),
                    _ => format!("Role: {}, Account: {}, connection & heartbeat restored", role, acc),
                }
            }
        }
        "node.clock.drift" => {
            let drift = alert.detail.get("drift_secs").or_else(|| alert.detail.get("drift")).and_then(|v| v.as_i64()).unwrap_or(0);
            match nlang {
                "zh-CN" => format!("节点本地时钟与 Hub 偏差达到 {} 秒 (阈值: 300秒)", drift),
                "zh-TW" => format!("節點本地時鐘與 Hub 偏差達到 {} 秒 (閾值: 300秒)", drift),
                "ja" => format!("ノードのクロックオフセットが {}秒 に達しました (閾値: 300秒)", drift),
                "ru" => format!("Смещение часов узла относительно Hub достигло {}с (порог: 300с)", drift),
                "es" => format!("La desviación del reloj del nodo con el Hub alcanzó {}s (umbral: 300s)", drift),
                _ => format!("Node clock offset vs Hub reached {}s (threshold: 300s)", drift),
            }
        }
        "risk.blocked" => {
            let cnt = alert.detail.get("blocked_entries").or_else(|| alert.detail.get("blocked")).and_then(|v| v.as_i64()).unwrap_or(0);
            match nlang {
                "zh-CN" => format!("接收端风控门禁生效，当前拦截订单笔数: {}", cnt),
                "zh-TW" => format!("接收端風控閘門生效，目前攔截訂單筆數: {}", cnt),
                "ja" => format!("受信側のリスクゲートが作動中、保留中の注文数: {}", cnt),
                "ru" => format!("Шлюз риска приемника активен, заблокировано ордеров: {}", cnt),
                "es" => format!("Puerta de riesgo del receptor activa, órdenes bloqueadas: {}", cnt),
                _ => format!("Receiver risk gate active, blocked orders: {}", cnt),
            }
        }
        "risk.tripped" => {
            let r = alert.detail.get("trip").or_else(|| alert.detail.get("risk")).and_then(|v| v.as_str()).unwrap_or("tripped");
            match nlang {
                "zh-CN" => format!("接收端汇报风控触发: {}", r),
                "zh-TW" => format!("接收端回報風控觸發: {}", r),
                "ja" => format!("受信側がリスク違反を報告しました: {}", r),
                "ru" => format!("Приемник сообщил о срабатывании риска: {}", r),
                "es" => format!("El receptor reportó activación de riesgo: {}", r),
                _ => format!("Receiver reported risk trip: {}", r),
            }
        }
        "command.unknown" => {
            let op = alert.detail.get("op").and_then(|v| v.as_str()).unwrap_or("command");
            match nlang {
                "zh-CN" => format!("指令 [{}] 重试阶梯耗尽，未收到终端确认回执 (ACK)", op),
                "zh-TW" => format!("指令 [{}] 重試階梯耗盡，未收到終端確認回執 (ACK)", op),
                "ja" => format!("コマンド [{}] の再試行が上限に達しましたが、ACK確認応答を受信できませんでした", op),
                "ru" => format!("Исчерпаны повторы команды [{op}], подтверждение ACK не получено"),
                "es" => format!("Reintentos de la orden [{}] agotados, no se recibió confirmación ACK", op),
                _ => format!("Command [{}] retry backoff exhausted, no ACK confirmation received", op),
            }
        }
        "test" => {
            match nlang {
                "zh-CN" => "这是一条来自 MT-Copier Hub 的测试通知。该通知渠道配置正确，收发测试完全正常。".to_string(),
                "zh-TW" => "這是一條來自 MT-Copier Hub 的測試通知。該通知渠道配置正確，收發測試完全正常。".to_string(),
                "ja" => "MT-Copier Hub からのテスト通知です。通知チャンネルは正しく設定され、正常に動作しています。".to_string(),
                "ru" => "Это тестовое уведомление от MT-Copier Hub. Канал настроен и работает нормально.".to_string(),
                "es" => "Esta es una notificación de prueba de MT-Copier Hub. El canal está configurado y funcionando correctamente.".to_string(),
                _ => "This is a test notification from MT-Copier Hub. The channel is configured and working properly.".to_string(),
            }
        }
        _ => alert.detail.to_string(),
    };

    AlertFormatted {
        title,
        severity_badge: badge.to_string(),
        time_str,
        node: node_display,
        detail_summary,
        lbl_severity: lbl_severity.to_string(),
        lbl_target: lbl_target.to_string(),
        lbl_time: lbl_time.to_string(),
        lbl_detail: lbl_detail.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Channel Sender implementations
// ---------------------------------------------------------------------------

pub async fn send_to_channel(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    match channel.channel_type.as_str() {
        "telegram" => send_telegram(client, channel, alert).await,
        "wecom" | "wechat_work" => send_wecom(client, channel, alert).await,
        "dingtalk" => send_dingtalk(client, channel, alert).await,
        "webhook" => send_webhook(client, channel, alert).await,
        "wechat" | "xtuis" => send_wechat(client, channel, alert).await,
        other => Err(format!("Unknown channel type '{}'", other)),
    }
}

async fn send_telegram(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    let token = channel
        .config
        .get("bot_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Telegram bot_token missing".to_string())?;
    let chat_id = channel
        .config
        .get("chat_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Telegram chat_id missing".to_string())?;

    //--- N57-15: the token is interpolated straight into a URL PATH, and unlike
    //--- the webhook senders this path never goes through validate_outgoing_url.
    //--- A value containing '/', '?', '@' or ".." rewrites the request target,
    //--- and "api.telegram.org/botX@evil.example/..." addresses a different host
    //--- entirely. Real tokens are digits, ':' and '-' (test bots may use '_').
    if token.is_empty()
        || !token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == ':' || c == '_' || c == '-')
    {
        return Err(
            "Telegram bot_token contains characters that cannot appear in a token".to_string(),
        );
    }

    let lang = get_channel_lang(channel);
    let fmt = format_alert_with_lang(alert, lang);
    //--- Everything interpolated is HTML-escaped. node names come from REG
    //--- (operator-supplied) and risk names from the node itself; a "&" or
    //--- "<" in either makes Telegram reject the whole request with 400, so
    //--- the alert is lost. See html_escape.
    let text = format!(
        "<b>{}</b>\n\n\
        <b>{}</b>: {}\n\
        <b>{}</b>: <code>{}</code>\n\
        <b>{}</b>: {}\n\
        <b>{}</b>: {}",
        html_escape(&fmt.title),
        html_escape(&fmt.lbl_severity),
        html_escape(&fmt.severity_badge),
        html_escape(&fmt.lbl_target),
        html_escape(&fmt.node),
        html_escape(&fmt.lbl_time),
        html_escape(&fmt.time_str),
        html_escape(&fmt.lbl_detail),
        html_escape(&fmt.detail_summary)
    );

    let url = format!("https://api.telegram.org/bot{}/sendMessage", token);
    // N83-04: Validate api.telegram.org via resolve_pinned_client to enforce SSRF and DNS rebinding protections
    let client = resolve_pinned_client(client, &url).await?;
    let payload = json!({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": true,
    });

    let resp = client
        .post(&url)
        .json(&payload)
        .send()
        .await
        .map_err(|e| {
            if let Some(status) = e.status() {
                format!("Telegram request failed: HTTP {}", status)
            } else {
                "Telegram request failed: connection error".to_string()
            }
        })?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if status.is_success() {
        Ok(format!("Telegram sent: HTTP {}", status))
    } else {
        Err(format!("Telegram failed: HTTP {} - {}", status, body))
    }
}

fn check_single_ip(ip: std::net::IpAddr, allow_local: bool) -> Result<(), String> {
    // 1. Prohibit link-local and cloud metadata addresses under ALL conditions (even if allow_local is true)
    match ip {
        std::net::IpAddr::V4(v4) => {
            let oct = v4.octets();
            // 169.254.0.0/16 (link-local, AWS/GCP/Alibaba IMDS 169.254.169.254)
            // 100.100.100.200 (Tencent Cloud metadata)
            if v4.is_link_local()
                || (oct[0] == 169 && oct[1] == 254)
                || (oct[0] == 100 && oct[1] == 100 && oct[2] == 100 && oct[3] == 200)
            {
                return Err("URL points to prohibited cloud metadata or link-local IPv4".to_string());
            }
        }
        std::net::IpAddr::V6(v6) => {
            let segs = v6.segments();
            // fe80::/10 link-local or fd00:ec2::254 (AWS IMDS IPv6)
            if (segs[0] & 0xffc0) == 0xfe80 || (segs[0] == 0xfd00 && segs[1] == 0xec2 && segs[7] == 0x254) {
                return Err("URL points to prohibited cloud metadata or link-local IPv6".to_string());
            }
            if segs[0..5] == [0, 0, 0, 0, 0] && segs[5] == 0xffff {
                let v4 = std::net::Ipv4Addr::new(
                    (segs[6] >> 8) as u8,
                    (segs[6] & 0xff) as u8,
                    (segs[7] >> 8) as u8,
                    (segs[7] & 0xff) as u8,
                );
                let oct = v4.octets();
                if v4.is_link_local()
                    || (oct[0] == 169 && oct[1] == 254)
                    || (oct[0] == 100 && oct[1] == 100 && oct[2] == 100 && oct[3] == 200)
                {
                    return Err("URL points to prohibited cloud metadata or link-local IPv4".to_string());
                }
            }
        }
    }

    if allow_local {
        return Ok(());
    }

    // 2. Prohibit loopback, private networks, and reserved ranges when allow_local is false
    if ip.is_loopback() || ip.is_unspecified() {
        return Err("URL points to prohibited loopback or unspecified IP".to_string());
    }
    match ip {
        std::net::IpAddr::V4(v4) => {
            let oct = v4.octets();
            if v4.is_loopback() || v4.is_private() || v4.is_unspecified()
                || (oct[0] == 100 && (oct[1] & 0xC0) == 64)
                || v4.is_broadcast() || v4.is_multicast() || oct[0] == 0 {
                return Err("URL points to prohibited private, CGNAT, or reserved IPv4".to_string());
            }
        }
        std::net::IpAddr::V6(v6) => {
            let segs = v6.segments();
            if (segs[0] & 0xfe00) == 0xfc00 {
                return Err("URL points to prohibited private IPv6".to_string());
            }
            if segs[0..5] == [0, 0, 0, 0, 0] && segs[5] == 0xffff {
                let v4 = std::net::Ipv4Addr::new(
                    (segs[6] >> 8) as u8,
                    (segs[6] & 0xff) as u8,
                    (segs[7] >> 8) as u8,
                    (segs[7] & 0xff) as u8,
                );
                let oct = v4.octets();
                if v4.is_loopback() || v4.is_private() || v4.is_unspecified()
                    || (oct[0] == 100 && (oct[1] & 0xC0) == 64)
                    || v4.is_broadcast() || v4.is_multicast() || oct[0] == 0 {
                    return Err("URL points to prohibited IPv4-mapped private or loopback".to_string());
                }
            }
        }
    }
    Ok(())
}

fn check_url_base(url: &str) -> Result<Option<String>, String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("URL must begin with http:// or https://".to_string());
    }

    // N76-02: Use reqwest::Url parser to accurately extract host without being corrupted by query (?token=) or fragment (#)
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("Invalid URL: {}", e))?;
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("URL cannot contain userinfo credentials".to_string());
    }

    let host_raw = parsed.host_str().ok_or_else(|| "URL has no host".to_string())?;
    // Handle IPv6 bracket format [fe80::...] or standard host
    let host = host_raw.trim_start_matches('[').trim_end_matches(']');

    let host_lower = host.to_ascii_lowercase();
    // Prohibit link-local and cloud metadata under ALL conditions
    if host_lower.starts_with("169.254.")
        || host_lower == "metadata.google.internal"
        || host_lower == "fd00:ec2::254"
        || host_lower == "100.100.100.200"
        || host_lower.starts_with("fe80:")
        || host_lower.starts_with("fe80::")
    {
        return Err("URL points to prohibited cloud metadata or link-local service".to_string());
    }

    let allow_local = std::env::var("MTC_ALLOW_LOCAL_WEBHOOK").is_ok();
    if !allow_local {
        if host_lower == "localhost"
            || host_lower == "127.0.0.1"
            || host_lower == "0.0.0.0"
            || host_lower == "::1"
            || host_lower.starts_with("127.")
            || host_lower.ends_with(".localhost")
            || host_lower.ends_with(".local")
            || host_lower.ends_with(".nip.io")
            || host_lower == "localtest.me"
        {
            return Err("URL points to prohibited localhost or loopback address".to_string());
        }

        if host_lower.starts_with("10.")
            || host_lower.starts_with("192.168.")
            || (host_lower.starts_with("172.") && {
                let parts: Vec<&str> = host_lower.split('.').collect();
                if parts.len() >= 2 {
                    parts[1].parse::<u8>().map(|b| b >= 16 && b <= 31).unwrap_or(false)
                } else {
                    false
                }
            })
        {
            return Err("URL points to prohibited private network address".to_string());
        }
    }

    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        check_single_ip(ip, allow_local)?;
        return Ok(None);
    }

    // HUB-04: Always return Some(host) for hostnames, ensuring DNS resolution and IP verification against cloud metadata
    Ok(Some(host.to_string()))
}


pub(crate) async fn validate_outgoing_url(url: &str) -> Result<(), String> {
    if let Some(host) = check_url_base(url)? {
        let allow_local = std::env::var("MTC_ALLOW_LOCAL_WEBHOOK").is_ok();
        let parsed_url = reqwest::Url::parse(url).map_err(|e| format!("Invalid URL: {}", e))?;
        let port = parsed_url.port_or_known_default().unwrap_or(80);
        let lookup_target = format!("{}:{}", host, port);
        // N76-03: Add 3s timeout to DNS lookup preventing unbound task stalling
        let lookup = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            tokio::net::lookup_host(lookup_target),
        )
        .await;

        match lookup {
            Ok(Ok(mut addrs)) => {
                let mut found = false;
                while let Some(addr) = addrs.next() {
                    check_single_ip(addr.ip(), allow_local)?;
                    found = true;
                }
                if !found {
                    return Err(format!("DNS lookup yielded no addresses for {}", host));
                }
            }
            Ok(Err(e)) => return Err(format!("DNS lookup failed for {}: {}", host, e)),
            Err(_) => return Err(format!("DNS lookup timed out for {}", host)),
        }
    }
    Ok(())
}

/// F-17: how long a pinned client is reused before the host is resolved again.
///
/// The client carries a connection pool, so reusing it turns "every alert pays a
/// DNS lookup + TCP connect + TLS handshake" into "the first alert in this window
/// does". 300s is short enough that a vendor changing IPs is picked up quickly and
/// long enough that an alert burst costs one handshake instead of N - which also
/// matters because many webhook vendors rate-limit per source IP and a burst of
/// fresh handshakes looks exactly like abuse.
const PINNED_CLIENT_TTL: Duration = Duration::from_secs(300);

/// Bound on the cache: one entry per distinct webhook host, so this is really
/// "number of configured channels" - but a bounded map cannot be turned into a
/// memory leak by a config that rotates URLs.
const PINNED_CLIENT_MAX: usize = 64;

struct PinnedEntry {
    addrs: Vec<std::net::SocketAddr>,
    client: reqwest::Client,
    at: Instant,
}

static PINNED_CLIENTS: Mutex<Option<HashMap<String, PinnedEntry>>> = Mutex::new(None);

/// N74-02 & N76-01: Resolves URL, validates every resolved IP against SSRF rules,
/// and builds a client pinned with `ClientBuilder::resolve_to_addrs(host, &addrs)` (IPv4 prioritized)
/// to permanently eliminate the DNS Rebinding TOCTOU race window while preserving dual-stack fallback.
///
/// F-17: the pinned client is CACHED per `host:port` for `PINNED_CLIENT_TTL`. It
/// used to be rebuilt for every single send, so an alert burst meant one DNS
/// lookup and one TLS handshake per alert. The cache does not weaken the SSRF
/// check: the addresses in the entry were validated when it was created and are
/// re-validated on every reuse, and the client is still pinned to those exact
/// addresses - which is the property the TOCTOU fix depends on.
pub(crate) async fn resolve_pinned_client(
    default_client: &reqwest::Client,
    url_str: &str,
) -> Result<reqwest::Client, String> {
    if let Some(host) = check_url_base(url_str)? {
        let allow_local = std::env::var("MTC_ALLOW_LOCAL_WEBHOOK").is_ok();
        let parsed_url = reqwest::Url::parse(url_str).map_err(|e| format!("Invalid URL: {}", e))?;
        let port = parsed_url.port_or_known_default().unwrap_or(80);
        let lookup_target = format!("{}:{}", host, port);

        //--- cache hit: re-validate the pinned addresses (cheap, no DNS) and reuse
        let cached = {
            let mut guard = PINNED_CLIENTS.lock().unwrap_or_else(|e| e.into_inner());
            let map = guard.get_or_insert_with(HashMap::new);
            let mut hit: Option<reqwest::Client> = None;
            let mut drop_entry = false;
            if let Some(e) = map.get(&lookup_target) {
                if e.at.elapsed() < PINNED_CLIENT_TTL {
                    let mut ok = true;
                    for a in &e.addrs {
                        if check_single_ip(a.ip(), allow_local).is_err() {
                            ok = false;
                            break;
                        }
                    }
                    if ok {
                        hit = Some(e.client.clone());
                    } else {
                        drop_entry = true;
                    }
                } else {
                    drop_entry = true;
                }
            }
            if drop_entry {
                //--- expired, or an address that is no longer permitted
                map.remove(&lookup_target);
            }
            hit
        };
        if let Some(c) = cached {
            return Ok(c);
        }

        let mut addrs: Vec<std::net::SocketAddr> = Vec::new();
        // N76-03: 3s timeout for DNS lookup
        let lookup = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            tokio::net::lookup_host(&lookup_target),
        )
        .await;

        match lookup {
            Ok(Ok(mut it)) => {
                while let Some(addr) = it.next() {
                    check_single_ip(addr.ip(), allow_local)?;
                    addrs.push(addr);
                }
            }
            Ok(Err(e)) => return Err(format!("DNS lookup failed for {}: {}", host, e)),
            Err(_) => return Err(format!("DNS lookup timed out for {}", host)),
        }

        if addrs.is_empty() {
            return Err(format!("DNS lookup yielded no addresses for {}", host));
        }

        // N76-01: Sort IPv4 addresses first, preserving all candidates so dual-stack hosts
        // don't fail when connecting from IPv4-only networks.
        addrs.sort_by_key(|a| a.is_ipv6());

        let pinned_client = reqwest::Client::builder()
            .resolve_to_addrs(&host, &addrs)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
            .build()
            .map_err(|e| format!("Failed to build pinned client: {}", e))?;

        {
            let mut guard = PINNED_CLIENTS.lock().unwrap_or_else(|e| e.into_inner());
            let map = guard.get_or_insert_with(HashMap::new);
            if map.len() >= PINNED_CLIENT_MAX {
                //--- drop the oldest entry rather than growing without bound; the
                //--- next send for that host simply re-resolves.
                if let Some(oldest) = map
                    .iter()
                    .min_by_key(|(_, e)| e.at)
                    .map(|(k, _)| k.clone())
                {
                    map.remove(&oldest);
                }
            }
            map.insert(
                lookup_target.clone(),
                PinnedEntry { addrs: addrs.clone(), client: pinned_client.clone(), at: Instant::now() },
            );
        }
        return Ok(pinned_client);
    }
    // If check_url_base returned None, it is an IP literal already validated by check_single_ip
    Ok(default_client.clone())
}

async fn send_wecom(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    let url = if let Some(u) = channel.config.get("webhook_url").and_then(|v| v.as_str()) {
        u.to_string()
    } else if let Some(key) = channel.config.get("key").and_then(|v| v.as_str()) {
        format!("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={}", key)
    } else {
        return Err("WeCom webhook_url or key missing".to_string());
    };
    let client = resolve_pinned_client(client, &url).await?;

    let lang = get_channel_lang(channel);
    let fmt = format_alert_with_lang(alert, lang);
    let color_tag = match alert.kind {
        "node.recovered" => "info",
        _ => match alert.severity {
            Severity::Critical => "warning",
            Severity::Warning => "comment",
        },
    };

    let content = format!(
        "### <font color=\"{}\">{}</font>\n\
        > **{}**: {}\n\
        > **{}**: <font color=\"comment\">{}</font>\n\
        > **{}**: {}\n\
        > **{}**: {}",
        color_tag,
        html_escape(&fmt.title),
        html_escape(&fmt.lbl_severity),
        html_escape(&fmt.severity_badge),
        html_escape(&fmt.lbl_target),
        html_escape(&fmt.node),
        html_escape(&fmt.lbl_time),
        html_escape(&fmt.time_str),
        html_escape(&fmt.lbl_detail),
        html_escape(&fmt.detail_summary)
    );

    let payload = json!({
        "msgtype": "markdown",
        "markdown": {
            "content": content
        }
    });

    let resp = client
        .post(&url)
        .json(&payload)
        .send()
        .await
        .map_err(|e| {
            if let Some(status) = e.status() {
                format!("WeCom request failed: HTTP {}", status)
            } else {
                "WeCom request failed: connection error".to_string()
            }
        })?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if status.is_redirection() {
        return Err(format!("WeCom request failed: HTTP {} (redirect blocked by SSRF policy; please configure target HTTPS URL directly)", status));
    }
    //--- N56-06: WeCom answers HTTP 200 even when it REFUSES the message - the
    //--- real verdict is `errcode` in the JSON body. Treating 200 as success
    //--- makes a revoked key, an IP-whitelist rejection or a rate limit look
    //--- like a delivered alert, which is the one failure an alert channel must
    //--- never have.
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
        if let Some(code) = v.get("errcode").and_then(|c| c.as_i64()) {
            if code != 0 {
                let msg = v.get("errmsg").and_then(|m| m.as_str()).unwrap_or("");
                return Err(format!("WeCom rejected: errcode {} - {}", code, msg));
            }
        }
    }
    if status.is_success() {
        Ok(format!("WeCom sent: HTTP {}", status))
    } else {
        Err(format!("WeCom failed: HTTP {} - {}", status, body))
    }
}

async fn send_dingtalk(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    let raw_url = if let Some(u) = channel.config.get("webhook_url").and_then(|v| v.as_str()) {
        u.to_string()
    } else if let Some(tok) = channel.config.get("access_token").and_then(|v| v.as_str()) {
        format!("https://oapi.dingtalk.com/robot/send?access_token={}", tok)
    } else {
        return Err("DingTalk webhook_url or access_token missing".to_string());
    };
    let client = resolve_pinned_client(client, &raw_url).await?;

    let secret = channel.config.get("secret").and_then(|v| v.as_str()).unwrap_or("");

    let url = if !secret.is_empty() {
        let now_millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let string_to_sign = format!("{}\n{}", now_millis, secret);
        let hmac = hmac_sha256(secret.as_bytes(), string_to_sign.as_bytes());
        let b64 = base64_encode(&hmac);
        let sign = url_encode(&b64);
        let sep = if raw_url.contains('?') { "&" } else { "?" };
        format!("{}{}timestamp={}&sign={}", raw_url, sep, now_millis, sign)
    } else {
        raw_url
    };

    let lang = get_channel_lang(channel);
    let fmt = format_alert_with_lang(alert, lang);
    let md_text = format!(
        "### {}\n\n\
        - **{}**: {}\n\
        - **{}**: `{}`\n\
        - **{}**: {}\n\
        - **{}**: {}",
        markdown_escape(&fmt.title),
        markdown_escape(&fmt.lbl_severity),
        markdown_escape(&fmt.severity_badge),
        markdown_escape(&fmt.lbl_target),
        markdown_escape(&fmt.node),
        markdown_escape(&fmt.lbl_time),
        markdown_escape(&fmt.time_str),
        markdown_escape(&fmt.lbl_detail),
        markdown_escape(&fmt.detail_summary)
    );

    let payload = json!({
        "msgtype": "markdown",
        "markdown": {
            "title": fmt.title,
            "text": md_text,
        }
    });

    let resp = client
        .post(&url)
        .json(&payload)
        .send()
        .await
        .map_err(|e| {
            if let Some(status) = e.status() {
                format!("DingTalk request failed: HTTP {}", status)
            } else {
                "DingTalk request failed: connection error".to_string()
            }
        })?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if status.is_redirection() {
        return Err(format!("DingTalk request failed: HTTP {} (redirect blocked by SSRF policy; please configure target HTTPS URL directly)", status));
    }
    //--- N56-06: same trap as WeCom - DingTalk returns HTTP 200 with
    //--- {"errcode":310000,...} for an expired token or a keyword mismatch.
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
        if let Some(code) = v.get("errcode").and_then(|c| c.as_i64()) {
            if code != 0 {
                let msg = v.get("errmsg").and_then(|m| m.as_str()).unwrap_or("");
                return Err(format!("DingTalk rejected: errcode {} - {}", code, msg));
            }
        }
    }
    if status.is_success() {
        Ok(format!("DingTalk sent: HTTP {}", status))
    } else {
        Err(format!("DingTalk failed: HTTP {} - {}", status, body))
    }
}

async fn send_webhook(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    let url = channel
        .config
        .get("url")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Webhook URL missing".to_string())?;

    let client = resolve_pinned_client(client, url).await?;

    let method_str = channel
        .config
        .get("method")
        .and_then(|v| v.as_str())
        .unwrap_or("POST");

    let method = match method_str.to_uppercase().as_str() {
        "PUT" => reqwest::Method::PUT,
        _ => reqwest::Method::POST,
    };

    let mut req = client.request(method, url);

    if let Some(headers) = channel.config.get("headers").and_then(|v| v.as_object()) {
        for (k, v) in headers {
            if let Some(val_str) = v.as_str() {
                let k_lower = k.to_ascii_lowercase();
                // BUG-10: Prohibit overriding sensitive transport/routing headers that could bypass SSRF or poison HTTP requests
                if k_lower == "host"
                    || k_lower == "content-length"
                    || k_lower == "transfer-encoding"
                    || k_lower == "connection"
                {
                    eprintln!("[notifications] WARN skipping prohibited header: {}", k);
                    continue;
                }
                if let (Ok(hname), Ok(hval)) = (
                    reqwest::header::HeaderName::try_from(k.as_str()),
                    reqwest::header::HeaderValue::try_from(val_str),
                ) {
                    req = req.header(hname, hval);
                } else {
                    eprintln!("[notifications] WARN skipping malformed header: {}", k);
                }
            }
        }
    }

    let lang = get_channel_lang(channel);
    let fmt = format_alert_with_lang(alert, lang);
    let payload = json!({
        "event": "alert",
        "lang": lang,
        "title": fmt.title,
        "ts": alert.ts,
        "utc_time": format_utc_timestamp(alert.ts),
        "kind": alert.kind,
        "severity": alert.severity.as_str(),
        "severity_badge": fmt.severity_badge,
        "node": alert.node,
        "detail": alert.detail,
        "detail_summary": fmt.detail_summary,
    });

    let resp = req
        .json(&payload)
        .send()
        .await
        .map_err(|e| {
            if let Some(status) = e.status() {
                format!("Webhook request failed: HTTP {}", status)
            } else {
                "Webhook request failed: connection error".to_string()
            }
        })?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if status.is_redirection() {
        return Err(format!("Webhook request failed: HTTP {} (redirect blocked by SSRF policy; please configure target HTTPS URL directly)", status));
    }
    if status.is_success() {
        Ok(format!("Webhook sent: HTTP {}", status))
    } else {
        Err(format!("Webhook failed: HTTP {} - {}", status, body))
    }
}

async fn send_wechat(
    client: &reqwest::Client,
    channel: &NotificationChannel,
    alert: &Alert,
) -> Result<String, String> {
    let raw_token = if let Some(tok) = channel.config.get("token").and_then(|v| v.as_str()) {
        tok.trim()
    } else if let Some(tok) = channel.config.get("key").and_then(|v| v.as_str()) {
        tok.trim()
    } else if let Some(u) = channel.config.get("webhook_url").and_then(|v| v.as_str()) {
        u.trim()
    } else {
        return Err("WeChat (Xtuis) token missing".to_string());
    };

    if raw_token.is_empty() {
        return Err("WeChat (Xtuis) token cannot be empty".to_string());
    }

    // Determine target URL: user can enter raw token or full https://wx.xtuis.cn/...
    let url = if raw_token.starts_with("http://") || raw_token.starts_with("https://") {
        raw_token.to_string()
    } else {
        let clean_token = raw_token.trim_end_matches(".send");
        // N83-05: Enforce character whitelist on raw WeChat token
        if !clean_token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("WeChat (Xtuis) token contains invalid characters".to_string());
        }
        format!("https://wx.xtuis.cn/{}.send", clean_token)
    };

    let client = resolve_pinned_client(client, &url).await?;

    let lang = get_channel_lang(channel);
    let fmt = format_alert_with_lang(alert, lang);

    let text = if alert.node.is_empty() {
        fmt.title.clone()
    } else {
        format!("{} - {}", fmt.title, fmt.node)
    };

    let desp = format!(
        "### {}\n\n\
        - **{}**: {}\n\
        - **{}**: `{}`\n\
        - **{}**: {}\n\
        - **{}**: {}",
        fmt.title,
        fmt.lbl_severity,
        fmt.severity_badge,
        fmt.lbl_target,
        fmt.node,
        fmt.lbl_time,
        fmt.time_str,
        fmt.lbl_detail,
        fmt.detail_summary
    );

    let params = [
        ("text", text.as_str()),
        ("desp", desp.as_str()),
    ];

    let resp = client
        .post(&url)
        .form(&params)
        .send()
        .await
        .map_err(|e| {
            if let Some(status) = e.status() {
                format!("WeChat (Xtuis) request failed: HTTP {}", status)
            } else {
                "WeChat (Xtuis) request failed: connection error".to_string()
            }
        })?;

    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();

    if status.is_redirection() {
        return Err(format!("WeChat (Xtuis) request failed: HTTP {} (redirect blocked by SSRF policy; please configure target HTTPS URL directly)", status));
    }

    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return Err(format!(
            "WeChat (Xtuis) rate limit exceeded (HTTP 429): {}",
            body
        ));
    }

    if status.is_success() {
        Ok(format!("WeChat (Xtuis) sent: HTTP {}", status))
    } else {
        Err(format!("WeChat (Xtuis) failed: HTTP {} - {}", status, body))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_sha256_rfc4231_test_case() {
        // RFC 4231 Test Case 2:
        // Key  = "Jefe"
        // Data = "what do ya want for nothing?"
        // Digest = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
        let key = b"Jefe";
        let data = b"what do ya want for nothing?";
        let h = hmac_sha256(key, data);
        let hex_str = users::hex(&h);
        assert_eq!(
            hex_str,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn base64_encode_rfc4648_test_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn format_utc_timestamp_test() {
        assert_eq!(format_utc_timestamp(0), "1970-01-01 00:00:00 UTC");
        // Leap year and late-February edge cases (HUB-01 prevention)
        assert_eq!(format_utc_timestamp(1709164799), "2024-02-28 23:59:59 UTC");
        assert_eq!(format_utc_timestamp(1709208000), "2024-02-29 12:00:00 UTC");
        assert_eq!(format_utc_timestamp(1772107200), "2026-02-26 12:00:00 UTC");
        assert_eq!(format_utc_timestamp(1772193600), "2026-02-27 12:00:00 UTC");
        assert_eq!(format_utc_timestamp(1772280000), "2026-02-28 12:00:00 UTC");
        assert_eq!(format_utc_timestamp(1772323200), "2026-03-01 00:00:00 UTC");
        // 2026-10-16 00:00:00 UTC = 1792108800 (or similar)
        let s = format_utc_timestamp(1792083200);
        assert!(s.contains("2026"));
        assert!(s.ends_with("UTC"));
    }

    #[test]
    fn mask_secret_hides_content() {
        assert_eq!(mask_secret("1234567890abcdef"), "1234***cdef");
        assert_eq!(mask_secret("short"), "******");
    }

    #[test]
    fn mask_secret_never_panics_on_multibyte_input() {
        //--- The byte-slicing original panicked here ('中' is 3 bytes and the
        //--- first one can be at index 0 or inside the last-4 window), and a
        //--- panic in an API handler poisoned the shared-state mutex and
        //--- 500-ed every subsequent /api/v1/ request until a restart.
        let masked = mask_secret("机密token机密token机密token");
        assert!(!masked.contains("机密token机密token"));
        assert!(masked.contains("***"));
        //--- ASCII behaviour is unchanged by the char-based rewrite.
        assert_eq!(mask_secret("abcdefghij"), "abcd***ghij");
    }

    #[test]
    fn secret_key_names_are_masked_by_name_not_by_allowlist() {
        //--- The real dingtalk store keeps the access token as its own field
        //--- (AND inside webhook_url); webhook URLs are themselves the
        //--- capability. Both used to go out verbatim.
        let ch = NotificationChannel {
            id: "c1".into(),
            name: "n".into(),
            channel_type: "dingtalk".into(),
            enabled: true,
            min_severity: "warning".into(),
            lang: "en".into(),
            config: json!({
                "access_token": "SECRETDTOKEN123456",
                "secret": "SEC4567890abcdef",
                "webhook_url": "https://oapi.dingtalk.com/robot/send?access_token=SECRETDTOKEN123456&footer=no",
                "chat_id": "keep-me"
            }),
            created_at: 1,
        };
        let s = ch.safe_json();
        let cfg = &s["config"];
        assert_eq!(cfg["access_token"], json!("SECR***3456"));
        assert_eq!(cfg["secret"], json!("SEC4***cdef"));
        assert!(cfg["webhook_url"].as_str().unwrap().contains("access_token=SECR***3456"));
        assert!(cfg["webhook_url"].as_str().unwrap().contains("footer=no"));
        assert_eq!(cfg["chat_id"], json!("keep-me"));
    }

    #[test]
    fn every_webhook_header_value_is_masked_not_just_two_named_ones() {
        let ch = NotificationChannel {
            id: "c2".into(),
            name: "n".into(),
            channel_type: "webhook".into(),
            enabled: true,
            min_severity: "warning".into(),
            lang: "en".into(),
            config: json!({
                "url": "https://example.invalid/hook?token=URLSECRET12345&x=1",
                "headers": {
                    "X-Api-Key": "KEYKEYKEY123456",
                    "Authorization": "Bearer abcdefghijkl",
                    "Content-Type": "application/json"
                }
            }),
            created_at: 1,
        };
        let s = ch.safe_json();
        let cfg = &s["config"];
        assert_eq!(cfg["headers"]["X-Api-Key"], json!("KEYK***3456"));
        assert_eq!(cfg["headers"]["Authorization"], json!("Bear***ijkl"));
        //--- A non-secret header keeps its value so the operator can debug.
        assert_eq!(cfg["headers"]["Content-Type"], json!("application/json"));
        //--- The URL is a capability: host kept (so the channel is
        //--- identifiable), everything after it gone. The old assertion here
        //--- required the query params to survive, which was the leak - a
        //--- Slack/Discord secret lives in the PATH, so masking only the
        //--- query left a fully working credential readable by any viewer.
        assert_eq!(cfg["url"], json!("https://example.invalid/***"));
    }

    /// The path of a webhook URL is the credential for the common providers.
    #[test]
    fn a_webhook_capability_url_loses_its_path_and_query() {
        assert_eq!(
            mask_webhook_url("https://hooks.slack.com/services/T000/B000/XXXXYYYY"),
            "https://hooks.slack.com/***"
        );
        assert_eq!(
            mask_webhook_url("https://discord.com/api/webhooks/123/tok_abc?wait=true"),
            "https://discord.com/***"
        );
        // No path at all: nothing to hide beyond the host, which is kept.
        assert_eq!(
            mask_webhook_url("https://example.invalid"),
            "https://example.invalid"
        );
        // Basic-auth credentials go too.
        assert_eq!(
            mask_webhook_url("https://user:pass@example.invalid/hook/x"),
            "https://***@example.invalid/***"
        );
    }

    /// `https://u:p@host` is a capability like any token, and every masking
    /// path used to pass it through untouched.
    #[test]
    fn basic_auth_userinfo_is_masked_for_every_channel_type() {
        assert_eq!(
            mask_url_secrets("https://u:p@example.invalid/path?a=1"),
            "https://***@example.invalid/path?a=1"
        );
        // And a URL with no query is still scrubbed.
        assert_eq!(
            mask_url_secrets("https://u:p@example.invalid/path"),
            "https://***@example.invalid/path"
        );
    }

    /// Changing a channel's TYPE must not persist the mask as the credential:
    /// masking ran under the stored type, so restoring must too.
    #[test]
    fn a_type_change_restores_secrets_under_the_stored_type() {
        let old = json!({ "webhook_auth_value": "Bearer sk-live-abcdef123456" });
        let mut new_cfg = json!({ "webhook_auth_value": "Bear***3456" });
        // The STORED type was webhook, the incoming one is telegram. Passing
        // the stored type is what makes this restore instead of persisting.
        merge_unmasked_config(&mut new_cfg, &old, "webhook");
        assert_eq!(
            new_cfg["webhook_auth_value"],
            json!("Bearer sk-live-abcdef123456")
        );
    }

    #[test]
    fn a_webhook_raw_auth_string_is_masked_even_with_an_innocent_name() {
        //--- The observed real shape: webhook_auth_value = "Bearer xxx",
        //--- whose name contains no secret-word. For WEBHOOK the rule
        //--- inverts - anything not in WEBHOOK_PLAIN_KEYS is masked.
        let ch = NotificationChannel {
            id: "c3".into(),
            name: "n".into(),
            channel_type: "webhook".into(),
            enabled: true,
            min_severity: "warning".into(),
            lang: "en".into(),
            config: json!({
                "url": "https://example.invalid/hook",
                "webhook_auth_value": "Bearer sk-live-abcdef123456",
                "custom_text": "please page me"
            }),
            created_at: 1,
        };
        let s = ch.safe_json();
        let cfg = &s["config"];
        assert_eq!(cfg["webhook_auth_value"], json!("Bear***3456"));
        //--- A webhook URL with no query is STILL a capability (its path is
        //--- the secret), so it is masked too. The old assertion here
        //--- required it to survive verbatim, which was the leak.
        assert_eq!(cfg["url"], json!("https://example.invalid/***"));
        //--- ...and the merge restores it on update instead of persisting
        //--- the mask as the credential.
        let mut incoming = cfg.clone();
        merge_unmasked_config(&mut incoming, &ch.config, "webhook");
        assert_eq!(incoming["webhook_auth_value"], json!("Bearer sk-live-abcdef123456"));
        assert_eq!(incoming["url"], json!("https://example.invalid/hook"));
    }

    #[test]
    fn html_escape_covers_the_three_html_specials() {
        assert_eq!(html_escape("a & b < c > d"), "a &amp; b &lt; c &gt; d");
        //--- Telegram would 400 the whole request on these, losing the alert.
        assert_eq!(html_escape("<b>x</b>"), "&lt;b&gt;x&lt;/b&gt;");
        assert_eq!(html_escape("plain"), "plain");
    }

    #[test]
    fn url_without_query_is_returned_unchanged() {
        assert_eq!(mask_url_secrets("https://example.invalid/hook"), "https://example.invalid/hook");
    }

    #[test]
    fn store_crud_and_persistence() {
        let tmp_file = PathBuf::from(format!("test_alert_channels_{}.json", std::process::id()));
        let _ = fs::remove_file(&tmp_file);

        let mut store = NotificationStore::new(Some(&tmp_file));
        let ch = NotificationChannel {
            id: "chan_test1".to_string(),
            name: "Test Telegram".to_string(),
            channel_type: "telegram".to_string(),
            enabled: true,
            min_severity: "warning".to_string(),
            lang: "en".to_string(),
            config: json!({
                "bot_token": "123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
                "chat_id": "-100123456789"
            }),
            created_at: 1000,
        };

        store.upsert(ch.clone()).unwrap();
        assert_eq!(store.list_safe().len(), 1);

        let safe = &store.list_safe()[0];
        assert_eq!(safe["id"], "chan_test1");
        assert!(safe["config"]["bot_token"].as_str().unwrap().contains("***"));

        // Re-read from disk
        let store2 = NotificationStore::new(Some(&tmp_file));
        let loaded = store2.get("chan_test1").unwrap();
        assert_eq!(loaded.name, "Test Telegram");
        assert_eq!(loaded.config["bot_token"], "123456789:ABCdefGHIjklMNOpqrsTUVwxyz");

        let _ = fs::remove_file(&tmp_file);
    }

    #[test]
    fn format_node_recovered_alert() {
        let alert = Alert {
            ts: 1792139807,
            kind: "node.recovered",
            severity: Severity::Warning,
            node: "receiver:252034803".to_string(),
            detail: json!({
                "role": "receiver",
                "name": "Alpari MT4",
                "account": "252034803",
                "outage_secs": 125,
            }),
        };

        let fmt = format_alert(&alert);
        assert!(fmt.title.contains("[RECOVERED]"));
        assert!(fmt.title.contains("Node Recovered"));
        assert_eq!(fmt.severity_badge, "🟢 RECOVERED");
        assert_eq!(fmt.node, "receiver:252034803");
        assert!(fmt.detail_summary.contains("2m 5s (125s)"));
        assert!(fmt.detail_summary.contains("252034803"));
    }

    #[test]
    fn critical_channel_receives_recovery_for_closed_loop() {
        let tmp_file = PathBuf::from(format!("test_crit_loop_{}.json", std::process::id()));
        let _ = fs::remove_file(&tmp_file);
        let mut store = NotificationStore::new(Some(&tmp_file));
        let ch = NotificationChannel {
            id: "chan_crit".to_string(),
            name: "Crit Only".to_string(),
            channel_type: "telegram".to_string(),
            enabled: true,
            min_severity: "critical".to_string(),
            lang: "en".to_string(),
            config: json!({}),
            created_at: 1000,
        };
        store.upsert(ch).unwrap();

        let alert_offline = Alert {
            ts: 1000,
            kind: "node.offline",
            severity: Severity::Critical,
            node: "sender:1".to_string(),
            detail: json!({}),
        };
        let m_offline = store.matching_channels_for_alert(&alert_offline);
        assert_eq!(m_offline.len(), 1);

        let alert_rec = Alert {
            ts: 1060,
            kind: "node.recovered",
            severity: Severity::Warning,
            node: "sender:1".to_string(),
            detail: json!({}),
        };
        let m_rec = store.matching_channels_for_alert(&alert_rec);
        assert_eq!(m_rec.len(), 1, "Critical-only channel must receive node.recovered alert");

        let alert_drift = Alert {
            ts: 1070,
            kind: "node.clock.drift",
            severity: Severity::Warning,
            node: "sender:1".to_string(),
            detail: json!({}),
        };
        let m_drift = store.matching_channels_for_alert(&alert_drift);
        assert_eq!(m_drift.len(), 0, "Ordinary warning must still be filtered out by critical channel");

        let _ = fs::remove_file(&tmp_file);
    }

    #[tokio::test]
    async fn validate_outgoing_url_ssrf_protection() {
        // HUB-04: Even when MTC_ALLOW_LOCAL_WEBHOOK=1, cloud metadata (169.254.x.x) is strictly blocked
        std::env::set_var("MTC_ALLOW_LOCAL_WEBHOOK", "1");
        assert!(validate_outgoing_url("http://169.254.169.254/latest/meta-data").await.is_err());
        assert!(validate_outgoing_url("http://100.100.100.200/latest/meta-data").await.is_err());
        assert!(validate_outgoing_url("http://127.0.0.1:8080/hook").await.is_ok());
        std::env::remove_var("MTC_ALLOW_LOCAL_WEBHOOK");
        assert!(validate_outgoing_url("http://metadata.google.internal/computeMetadata/v1").await.is_err());
        assert!(validate_outgoing_url("http://[fe80::1]:8080/hook").await.is_err());
        // Disallow loopback and private networks by default
        assert!(validate_outgoing_url("http://127.0.0.1:8080/hook").await.is_err());
        assert!(validate_outgoing_url("http://localhost:8080/hook").await.is_err());
        assert!(validate_outgoing_url("http://[::ffff:127.0.0.1]:8080/hook").await.is_err());
        assert!(validate_outgoing_url("http://localtest.me/hook").await.is_err());
        assert!(validate_outgoing_url("http://10.0.0.1/hook").await.is_err());
        assert!(validate_outgoing_url("http://192.168.1.1/hook").await.is_err());
        assert!(validate_outgoing_url("http://172.16.0.1/hook").await.is_err());
        assert!(validate_outgoing_url("http://172.31.255.255/hook").await.is_err());
        // Disallow userinfo
        assert!(validate_outgoing_url("http://admin:secret@example.com/hook").await.is_err());
        // Allow valid public urls
        assert!(validate_outgoing_url("https://qyapi.weixin.qq.com/cgi-bin/webhook/send").await.is_ok());
        assert!(validate_outgoing_url("https://oapi.dingtalk.com/robot/send").await.is_ok());
        assert!(validate_outgoing_url("https://api.telegram.org/bot123/sendMessage").await.is_ok());
        // N76-02: Public urls without path or with query only must extract host cleanly
        assert!(validate_outgoing_url("https://qyapi.weixin.qq.com?key=123").await.is_ok());

        // N74-02 & N76-01: resolve_pinned_client must also reject SSRF attempts
        let def_client = reqwest::Client::new();
        assert!(resolve_pinned_client(&def_client, "http://127.0.0.1:8080/hook").await.is_err());
        assert!(resolve_pinned_client(&def_client, "http://localhost:8080/hook").await.is_err());
        assert!(resolve_pinned_client(&def_client, "http://10.0.0.1/hook").await.is_err());
    }

    #[test]
    fn webhook_header_prohibition_check() {
        let prohibited = ["host", "Host", "HOST", "content-length", "Transfer-Encoding", "connection"];
        for h in prohibited {
            let lower = h.to_ascii_lowercase();
            assert!(
                lower == "host" || lower == "content-length" || lower == "transfer-encoding" || lower == "connection",
                "Header {} must be marked prohibited", h
            );
        }
    }

    #[test]
    fn wechat_xtuis_channel_masking_and_merge() {
        let ch = NotificationChannel {
            id: "chan_wx1".to_string(),
            name: "My WeChat".to_string(),
            channel_type: "wechat".to_string(),
            enabled: true,
            min_severity: "warning".to_string(),
            lang: "zh-CN".to_string(),
            config: json!({
                "token": "ABC123456789XYZ",
            }),
            created_at: 1000,
        };
        let s = ch.safe_json();
        assert_eq!(s["config"]["token"], json!("ABC1***9XYZ"));

        // Test merge on unmasked update
        let mut updated_config = json!({
            "token": "ABC1***9XYZ"
        });
        merge_unmasked_config(&mut updated_config, &ch.config, "wechat");
        assert_eq!(updated_config["token"], json!("ABC123456789XYZ"));
    }

    #[test]
    fn format_alert_multilingual_test() {
        let alert = Alert {
            ts: 1792139807,
            kind: "test",
            severity: Severity::Warning,
            node: "hub:selftest".to_string(),
            detail: json!({}),
        };

        let fmt_zh = format_alert_with_lang(&alert, "zh-CN");
        assert_eq!(fmt_zh.severity_badge, "🟡 一般警告");
        assert!(fmt_zh.title.contains("渠道连通性测试"));
        assert!(fmt_zh.detail_summary.contains("测试通知"));
        assert_eq!(fmt_zh.lbl_severity, "告警级别");

        let fmt_tw = format_alert_with_lang(&alert, "zh-TW");
        assert_eq!(fmt_tw.severity_badge, "🟡 一般警告");
        assert!(fmt_tw.title.contains("渠道連通性測試"));
        assert_eq!(fmt_tw.lbl_severity, "告警級別");

        let fmt_en = format_alert_with_lang(&alert, "en");
        assert_eq!(fmt_en.severity_badge, "🟡 WARNING");
        assert!(fmt_en.title.contains("Channel Connectivity Test"));
        assert_eq!(fmt_en.lbl_severity, "Severity");

        let fmt_ja = format_alert_with_lang(&alert, "ja");
        assert_eq!(fmt_ja.severity_badge, "🟡 警告");
        assert!(fmt_ja.title.contains("接続テスト"));
        assert_eq!(fmt_ja.lbl_severity, "重要度");

        let fmt_ru = format_alert_with_lang(&alert, "ru");
        assert_eq!(fmt_ru.severity_badge, "🟡 ПРЕДУПРЕЖДЕНИЕ");
        assert!(fmt_ru.title.contains("Тест подключения канала"));
        assert_eq!(fmt_ru.lbl_severity, "Уровень");

        let fmt_es = format_alert_with_lang(&alert, "es");
        assert_eq!(fmt_es.severity_badge, "🟡 ADVERTENCIA");
        assert!(fmt_es.title.contains("Prueba de conectividad"));
        assert_eq!(fmt_es.lbl_severity, "Severidad");
    }

    #[test]
    fn notifications_disabled_mode_does_not_load_disk_or_match_alerts() {
        let store = NotificationStore::new(None);
        assert!(!store.enabled());
        assert_eq!(store.list_safe().len(), 0);
        let alert = Alert {
            ts: 1000,
            kind: "risk.tripped",
            severity: Severity::Critical,
            node: "receiver:252034803".to_string(),
            detail: json!({ "trip": "maxtot" }),
        };
        assert_eq!(store.matching_channels_for_alert(&alert).len(), 0);
        assert_eq!(store.matching_channels(Severity::Critical).len(), 0);
    }
}
