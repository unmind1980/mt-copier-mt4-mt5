//! The two tiny parsers the hub uses - and deliberately nothing else.
//!
//! The hub NEVER decodes an envelope. It reads `T=` for a log line, and the
//! `P=` section for the one message it originates (a PONG). Everything else is
//! forwarded as opaque bytes.
//!
//! That restraint is the point. A hub that understood the protocol could
//! corrupt it; a hub that only moves bytes cannot. It is also why the receiver
//! needed no change to its convergence logic when the central channel was
//! added - frame 1 arrives byte-for-byte identical to a direct connection.
//!
//! These mirror `tools/hub_proto.py` exactly, including the fact that they
//! find the FIRST match rather than parsing properly. Where they are wrong,
//! they are wrong in the same way on both sides, which is what makes the
//! Python hub a valid reference for the Rust one.

/// The `T=` field of a v1 envelope, or `""` when it is not shaped as expected.
pub fn envelope_type(payload: &[u8]) -> String {
    let i = match find(payload, b"|T=") {
        Some(i) => i,
        None => return String::new(),
    };
    let start = i + 3;
    let j = match find(&payload[start..], b"|") {
        Some(j) => start + j,
        None => return String::new(),
    };
    latin1(&payload[start..j])
}

/// First `key=value` in the HEADER section - everything before `|P=`.
///
/// The mirror of `envelope_kv`, and it exists for the same reason: `SID` is a
/// header field, and reading it out of the payload section is not the same
/// question. `SNAP` is the case that forced it - a receiver's `STAT` carries
/// `SID=receiver` in the header and `SID=<sender>` in the payload, and the
/// position view needs to know which SENDER a snapshot came from regardless of
/// which topic carried it (a targeted repair arrives on the RECEIVER's nid).
pub fn envelope_hdr(payload: &[u8], key: &str) -> String {
    let end = match find(payload, b"|P=") {
        Some(p) => p,
        None => payload.len(),
    };
    let want = format!("{}=", key);
    let want = want.as_bytes();
    for item in payload[..end].split(|b| *b == b'|') {
        if item.starts_with(want) {
            return latin1(&item[want.len()..]);
        }
    }
    String::new()
}

/// The `P=` section: the payload bytes, without the header or the `P=` itself.
///
/// Callers that parse a payload must start here rather than at the envelope.
/// The distinction is not cosmetic - a payload field is preceded by `;`, while
/// the FIRST one is preceded by `|P=`. A scanner that requires `;` or
/// start-of-input therefore finds `R=`, `H=` and every later field but silently
/// misses `N=`, which is the one that comes first. That is exactly how the
/// position view first reported "declared 0, carried 3" on every snapshot.
pub fn envelope_payload(payload: &[u8]) -> &[u8] {
    match find(payload, b"|P=") {
        Some(p) => &payload[p + 3..],
        None => &[],
    }
}

/// First `key=value` in the payload section as Option. Returns Some(value) if
/// the key exists (even if empty, like "KEY=" -> Some("")), or None if absent.
pub fn envelope_kv_opt(payload: &[u8], key: &str) -> Option<String> {
    let p = find(payload, b"|P=")?;
    let want = format!("{}=", key);
    let want = want.as_bytes();
    for item in payload[p + 3..].split(|b| *b == b';') {
        if item.starts_with(want) {
            return Some(latin1(&item[want.len()..]));
        }
    }
    None
}

/// First `key=value` in the payload section. Logging and PONG only.
pub fn envelope_kv(payload: &[u8], key: &str) -> String {
    envelope_kv_opt(payload, key).unwrap_or_default()
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Bytes as text for display. The wire is ASCII by construction, but a hostile
/// peer is not, and a log line must never panic the hub.
fn latin1(b: &[u8]) -> String {
    b.iter().map(|c| *c as char).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn type_is_read_from_the_envelope() {
        assert_eq!(envelope_type(b"V=1|SID=1|T=SNAP|P=N=1"), "SNAP");
        assert_eq!(envelope_type(b"V=1|SID=1|T=OPEN|P=x"), "OPEN");
    }

    #[test]
    fn a_payload_without_a_type_reads_as_empty() {
        assert_eq!(envelope_type(b"V=1|SID=1|P=N=1"), "");
        assert_eq!(envelope_type(b"garbage"), "");
        // T= with no closing '|' is not a complete field either
        assert_eq!(envelope_type(b"V=1|T=SNAP"), "");
    }

    #[test]
    fn kv_finds_the_first_key_in_the_payload_section_only() {
        assert_eq!(envelope_kv(b"V=1|T=PING|P=MS=12345;FROM=444444", "MS"), "12345");
        assert_eq!(envelope_kv(b"V=1|T=PING|P=MS=12345;FROM=444444", "FROM"), "444444");
    }

    #[test]
    fn kv_does_not_read_the_envelope_header() {
        // T=PING must not satisfy a lookup for "P" or leak across sections
        assert_eq!(envelope_kv(b"V=1|SID=9|T=PING", "SID"), "");
    }

    #[test]
    fn kv_missing_key_is_empty_not_a_panic() {
        assert_eq!(envelope_kv(b"V=1|T=PING|P=MS=1", "NOPE"), "");
        assert_eq!(envelope_kv(b"no payload here", "MS"), "");
    }

    #[test]
    fn non_ascii_does_not_panic() {
        let junk = [0xffu8, 0xfe, b'|', b'T', b'=', b'X', b'|'];
        assert_eq!(envelope_type(&junk), "X");
    }

    #[test]
    fn hdr_reads_the_header_and_not_the_payload() {
        let p = b"V=1|SID=252033316|SEQ=9|T=STAT|P=LOGIN=1;SID=receiver;H=abc";
        // the header's SID, which is what the position view needs
        assert_eq!(envelope_hdr(p, "SID"), "252033316");
        // ...and the payload's, which is a DIFFERENT value in the same message
        assert_eq!(envelope_kv(p, "SID"), "receiver");
    }

    #[test]
    fn hdr_on_a_payload_with_no_p_section_reads_the_whole_thing() {
        assert_eq!(envelope_hdr(b"V=1|SID=42|T=SNAP", "SID"), "42");
        assert_eq!(envelope_hdr(b"V=1|T=SNAP", "SID"), "");
    }

    #[test]
    fn hdr_does_not_match_a_key_that_merely_ends_in_it() {
        // SSID must not satisfy a lookup for SID - the same trap that once made
        // OTS match inside LOTS.
        assert_eq!(envelope_hdr(b"V=1|SSID=zzz|T=SNAP|P=N=0", "SID"), "");
    }

    #[test]
    fn hdr_on_garbage_is_empty_not_a_panic() {
        assert_eq!(envelope_hdr(b"", "SID"), "");
        assert_eq!(envelope_hdr(b"garbage", "SID"), "");
        assert_eq!(envelope_hdr(&[0xff, 0xfe], "SID"), "");
    }

    #[test]
    fn payload_starts_at_the_first_field_not_after_a_separator() {
        // The whole point: a payload scanner that only accepts ';' or the start
        // of input finds R= and H= but MISSES N=, because N= is preceded by
        // '|P='. Handing it the envelope is how that bug gets written.
        let e = b"V=1|SID=9|T=SNAP|P=N=3;R=a~b~c;H=ff";
        assert_eq!(envelope_payload(e), b"N=3;R=a~b~c;H=ff");
        assert_eq!(envelope_payload(b"V=1|SID=9|T=SNAP"), b"");
        assert_eq!(envelope_payload(b"garbage"), b"");
    }
}
