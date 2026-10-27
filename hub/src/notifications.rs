//! notifications.rs - External Alert Dispatcher (Telegram, WeCom, DingTalk, Webhook).
//!
//! Sends real-time notifications when the hub's alert engine fires.
//! Runs asynchronously over Tokio without blocking the main ZeroMQ router thread.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::alerts::{Alert, Severity};
use crate::users;

const DEFAULT_STORE_PATH: &str = "alert_channels.json";
pub const HTTP_TIMEOUT_SECS: u64 = 8;
const B64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct NotificationChannel {
    pub id: String,
    pub name: String,
    /// Channel kind: "telegram", "wecom", "dingtalk", "webhook"
    pub channel_type: String,
    pub enabled: bool,
    /// Minimum severity to trigger: "warning" (all) or "critical" (only critical)
    pub min_severity: String,
    /// Type-specific configuration
    pub config: Value,
    pub created_at: u64,
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
                            *v = Value::String(if self.channel_type == "webhook" {
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
}

impl NotificationStore {
    pub fn new(path: Option<&Path>) -> Self {
        let p = path
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from(DEFAULT_STORE_PATH));
        let mut store = NotificationStore {
            path: p,
            channels: HashMap::new(),
        };
        //--- A store that fails to load used to be swallowed here
        //--- (`let _ = store.load()`), so a corrupt JSON or a permission
        //--- error looked identical to "no channels configured" - and the
        //--- operator's channels silently stopped existing for that run.
        //--- Configuration that fails to load is a fact about THIS run, and
        //--- an alert channel that silently isn't there is worse than one
        //--- that never existed: when it matters, nothing gets paged.
        //--- Say it loudly, at start, where the log is being read anyway.
        if let Err(e) = store.load() {
            eprintln!(
                "[hub] notification store {} failed to load ({}): starting with ZERO channels",
                store.path.display(),
                e
            );
        }
        store
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&mut self) -> io::Result<()> {
        if !self.path.exists() {
            return Ok(());
        }
        let data = fs::read_to_string(&self.path)?;
        if data.trim().is_empty() {
            return Ok(());
        }
        let list: Vec<NotificationChannel> = serde_json::from_str(&data)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.channels.clear();
        for ch in list {
            self.channels.insert(ch.id.clone(), ch);
        }
        Ok(())
    }

    pub fn save(&self) -> io::Result<()> {
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
        fs::rename(&tmp_path, &self.path)?;
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
        if channel.created_at == 0 {
            channel.created_at = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
        }
        self.channels.insert(channel.id.clone(), channel.clone());
        self.save()?;
        Ok(channel)
    }

    pub fn remove(&mut self, id: &str) -> io::Result<bool> {
        if self.channels.remove(id).is_some() {
            self.save()?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    #[allow(dead_code)]
    pub fn matching_channels(&self, severity: Severity) -> Vec<NotificationChannel> {
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
    let is_masked = |s: &str| s.contains("***") || s.is_empty();

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
    let yoe = (doe - doe / 1020 + doe / 1461 - doe / 146096) / 365;
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
}

pub fn format_alert(alert: &Alert) -> AlertFormatted {
    let time_str = format_utc_timestamp(alert.ts);
    let (sev_str, badge) = match (alert.kind, alert.severity) {
        ("node.recovered", _) => ("[RECOVERED]", "🟢 RECOVERED"),
        (_, Severity::Critical) => ("[CRITICAL ALERT]", "🔴 CRITICAL"),
        (_, Severity::Warning) => ("[WARNING]", "🟡 WARNING"),
    };

    let title_prefix = match alert.kind {
        "node.offline" => "Node Offline",
        "node.recovered" => "Node Recovered",
        "node.clock.drift" => "Clock Drift Exceeded",
        "risk.blocked" => "Risk Gate Blocked",
        "risk.tripped" => "Risk Gate Tripped",
        "command.unknown" => "Command Retries Exhausted",
        "test" => "Channel Connectivity Test",
        _ => alert.kind,
    };

    let title = format!("{} {}", sev_str, title_prefix);
    let node_display = if alert.node.is_empty() {
        "hub (global)".to_string()
    } else {
        alert.node.clone()
    };

    let detail_summary = match alert.kind {
        "node.offline" => {
            let role = alert.detail.get("role").and_then(|v| v.as_str()).unwrap_or("node");
            let acc = alert.detail.get("account").and_then(|v| v.as_str()).unwrap_or("-");
            let quiet = alert.detail.get("quiet_secs").and_then(|v| v.as_u64());
            if let Some(q) = quiet {
                format!("Role: {}, Account: {}, heartbeat timeout exceeded (silent for {}s)", role, acc, q)
            } else {
                format!("Role: {}, Account: {}, heartbeat timeout exceeded", role, acc)
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
                format!("Role: {}, Account: {}, connection & heartbeat restored (outage: {})", role, acc, dur_str)
            } else {
                format!("Role: {}, Account: {}, connection & heartbeat restored", role, acc)
            }
        }
        "node.clock.drift" => {
            let drift = alert.detail.get("drift_secs").or_else(|| alert.detail.get("drift")).and_then(|v| v.as_i64()).unwrap_or(0);
            format!("Node clock offset vs Hub reached {}s (threshold: 300s)", drift)
        }
        "risk.blocked" => {
            let cnt = alert.detail.get("blocked_entries").or_else(|| alert.detail.get("blocked")).and_then(|v| v.as_i64()).unwrap_or(0);
            format!("Receiver risk gate active, blocked orders: {}", cnt)
        }
        "risk.tripped" => {
            let r = alert.detail.get("trip").or_else(|| alert.detail.get("risk")).and_then(|v| v.as_str()).unwrap_or("tripped");
            format!("Receiver reported risk trip: {}", r)
        }
        "command.unknown" => {
            let op = alert.detail.get("op").and_then(|v| v.as_str()).unwrap_or("command");
            format!("Command [{}] retry backoff exhausted, no ACK confirmation received", op)
        }
        "test" => {
            "This is a test notification from MT-Copier Hub. The channel is configured and working properly.".to_string()
        }
        _ => alert.detail.to_string(),
    };

    AlertFormatted {
        title,
        severity_badge: badge.to_string(),
        time_str,
        node: node_display,
        detail_summary,
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

    let fmt = format_alert(alert);
    //--- Everything interpolated is HTML-escaped. node names come from REG
    //--- (operator-supplied) and risk names from the node itself; a "&" or
    //--- "<" in either makes Telegram reject the whole request with 400, so
    //--- the alert is lost. See html_escape.
    let text = format!(
        "<b>{}</b>\n\n\
        <b>Severity</b>: {}\n\
        <b>Target</b>: <code>{}</code>\n\
        <b>Time</b>: {}\n\
        <b>Detail</b>: {}",
        html_escape(&fmt.title),
        html_escape(&fmt.severity_badge),
        html_escape(&fmt.node),
        html_escape(&fmt.time_str),
        html_escape(&fmt.detail_summary)
    );

    let url = format!("https://api.telegram.org/bot{}/sendMessage", token);
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

pub(crate) fn validate_outgoing_url(url: &str) -> Result<(), String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("URL must begin with http:// or https://".to_string());
    }

    let authority = url.split("://").nth(1).unwrap_or("").split('/').next().unwrap_or("");
    if authority.contains('@') {
        return Err("URL cannot contain userinfo credentials".to_string());
    }

    // Handle IPv6 bracket format [fe80::...]:port or standard host:port
    let host = if authority.starts_with('[') {
        authority.split(']').next().unwrap_or("").trim_start_matches('[')
    } else {
        authority.split(':').next().unwrap_or("")
    };

    let host_lower = host.to_ascii_lowercase();
    if host_lower.starts_with("169.254.")
        || host_lower == "metadata.google.internal"
        || host_lower == "fd00:ec2::254"
        || host_lower == "100.100.100.200"
        || host_lower.starts_with("fe80:")
        || host_lower.starts_with("fe80::")
    {
        return Err("URL points to prohibited cloud metadata or link-local service".to_string());
    }

    // R48-04 & N49-06: Enforce comprehensive SSRF protection against loopback, IPv4-mapped, and RFC 1918 private networks
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

        let check_single_ip = |ip: std::net::IpAddr| -> Result<(), String> {
            if ip.is_loopback() || ip.is_unspecified() {
                return Err("URL points to prohibited loopback or unspecified IP".to_string());
            }
            match ip {
                std::net::IpAddr::V4(v4) => {
                    if v4.is_loopback() || v4.is_private() || v4.is_link_local() || v4.is_unspecified() {
                        return Err("URL points to prohibited private or link-local IPv4".to_string());
                    }
                }
                std::net::IpAddr::V6(v6) => {
                    let segs = v6.segments();
                    if (segs[0] & 0xfe00) == 0xfc00 || (segs[0] & 0xffc0) == 0xfe80 {
                        return Err("URL points to prohibited private or link-local IPv6".to_string());
                    }
                    if segs[0..5] == [0, 0, 0, 0, 0] && segs[5] == 0xffff {
                        let v4 = std::net::Ipv4Addr::new(
                            (segs[6] >> 8) as u8,
                            (segs[6] & 0xff) as u8,
                            (segs[7] >> 8) as u8,
                            (segs[7] & 0xff) as u8,
                        );
                        if v4.is_loopback() || v4.is_private() || v4.is_link_local() || v4.is_unspecified() {
                            return Err("URL points to prohibited IPv4-mapped private or loopback".to_string());
                        }
                    }
                }
            }
            Ok(())
        };

        if let Ok(ip) = host.parse::<std::net::IpAddr>() {
            check_single_ip(ip)?;
        }

        use std::net::ToSocketAddrs;
        if let Ok(addrs) = format!("{}:80", host).to_socket_addrs() {
            for addr in addrs {
                check_single_ip(addr.ip())?;
            }
        }
    }

    Ok(())
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
    validate_outgoing_url(&url)?;

    let fmt = format_alert(alert);
    let color_tag = match alert.kind {
        "node.recovered" => "info",
        _ => match alert.severity {
            Severity::Critical => "warning",
            Severity::Warning => "comment",
        },
    };

    let content = format!(
        "### <font color=\"{}\">{}</font>\n\
        > **Severity**: {}\n\
        > **Target**: <font color=\"comment\">{}</font>\n\
        > **Time**: {}\n\
        > **Detail**: {}",
        color_tag,
        html_escape(&fmt.title),
        html_escape(&fmt.severity_badge),
        html_escape(&fmt.node),
        html_escape(&fmt.time_str),
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
    validate_outgoing_url(&raw_url)?;

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

    let fmt = format_alert(alert);
    let md_text = format!(
        "### {}\n\n\
        - **Severity**: {}\n\
        - **Target**: `{}`\n\
        - **Time**: {}\n\
        - **Detail**: {}",
        markdown_escape(&fmt.title),
        markdown_escape(&fmt.severity_badge),
        markdown_escape(&fmt.node),
        markdown_escape(&fmt.time_str),
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

    validate_outgoing_url(url)?;

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

    let payload = json!({
        "event": "alert",
        "ts": alert.ts,
        "utc_time": format_utc_timestamp(alert.ts),
        "kind": alert.kind,
        "severity": alert.severity.as_str(),
        "node": alert.node,
        "detail": alert.detail,
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
    if status.is_success() {
        Ok(format!("Webhook sent: HTTP {}", status))
    } else {
        Err(format!("Webhook failed: HTTP {} - {}", status, body))
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

    #[test]
    fn validate_outgoing_url_ssrf_protection() {
        // Disallow metadata and link-local
        assert!(validate_outgoing_url("http://169.254.169.254/latest/meta-data").is_err());
        assert!(validate_outgoing_url("http://metadata.google.internal/computeMetadata/v1").is_err());
        assert!(validate_outgoing_url("http://[fe80::1]:8080/hook").is_err());
        // Disallow loopback and private networks by default
        assert!(validate_outgoing_url("http://127.0.0.1:8080/hook").is_err());
        assert!(validate_outgoing_url("http://localhost:8080/hook").is_err());
        assert!(validate_outgoing_url("http://[::ffff:127.0.0.1]:8080/hook").is_err());
        assert!(validate_outgoing_url("http://localtest.me/hook").is_err());
        assert!(validate_outgoing_url("http://10.0.0.1/hook").is_err());
        assert!(validate_outgoing_url("http://192.168.1.1/hook").is_err());
        assert!(validate_outgoing_url("http://172.16.0.1/hook").is_err());
        assert!(validate_outgoing_url("http://172.31.255.255/hook").is_err());
        // Disallow userinfo
        assert!(validate_outgoing_url("http://admin:secret@example.com/hook").is_err());
        // Allow valid public urls
        assert!(validate_outgoing_url("https://qyapi.weixin.qq.com/cgi-bin/webhook/send").is_ok());
        assert!(validate_outgoing_url("https://oapi.dingtalk.com/robot/send").is_ok());
        assert!(validate_outgoing_url("https://api.telegram.org/bot123/sendMessage").is_ok());
    }
}
