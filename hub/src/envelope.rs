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

use std::io::Read;

/// Bytes as text for display. The wire is ASCII by construction, but a hostile
/// peer is not, and a log line must never panic the hub.
pub fn latin1(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.to_string(),
        Err(_) => b.iter().map(|c| *c as char).collect(),
    }
}

const MAX_DECOMPRESSED_LEN: u64 = 4 * 1024 * 1024; // 4 MiB protection against Zip bombs

/// Decompress a field payload with adaptive "0:" (raw) or "1:" (Z85-encoded Zlib/Deflate/PKZIP).
pub fn decompress_field(field_bytes: &[u8]) -> String {
    if field_bytes.starts_with(b"1:") {
        let rest = &field_bytes[2..];
        // R47-27: Resolve z85 pad prefix ambiguity.
        // If rest is already a multiple of 5, it cannot have a 2-byte prefix.
        let (pad, z85_slice) = {
            let s_raw = std::str::from_utf8(rest).map(|s| s.trim()).unwrap_or("");
            if s_raw.len() % 5 == 0 {
                (0, rest)
            } else if rest.len() >= 2 && rest[1] == b':' && rest[0] >= b'0' && rest[0] <= b'3' {
                let s_prefixed = std::str::from_utf8(&rest[2..]).map(|s| s.trim()).unwrap_or("");
                if s_prefixed.len() % 5 == 0 {
                    ((rest[0] - b'0') as usize, &rest[2..])
                } else {
                    (0, rest)
                }
            } else {
                (0, rest)
            }
        };
        if let Ok(z85_str) = std::str::from_utf8(z85_slice) {
            if let Ok(mut raw_bytes) = zmq::z85_decode(z85_str.trim()) {
                if pad > 0 && pad <= 3 && raw_bytes.len() >= pad {
                    if raw_bytes[raw_bytes.len() - pad..].iter().all(|&b| b == 0) {
                        raw_bytes.truncate(raw_bytes.len() - pad);
                    }
                }
                // Check if this is a PKZIP container (MQL CryptEncode CRYPT_ARCH_ZIP output)
                if raw_bytes.starts_with(b"PK\x03\x04") && raw_bytes.len() >= 30 {
                    let comp_size = u32::from_le_bytes(raw_bytes[18..22].try_into().unwrap_or([0; 4])) as usize;
                    let name_len = u16::from_le_bytes(raw_bytes[26..28].try_into().unwrap_or([0; 2])) as usize;
                    let extra_len = u16::from_le_bytes(raw_bytes[28..30].try_into().unwrap_or([0; 2])) as usize;
                    let data_start = 30 + name_len + extra_len;
                    if data_start <= raw_bytes.len() {
                        let data_end = if comp_size > 0 && data_start + comp_size <= raw_bytes.len() {
                            data_start + comp_size
                        } else {
                            let mut end = raw_bytes.len();
                            for sig in [b"PK\x01\x02", b"PK\x07\x08", b"PK\x05\x06"] {
                                if let Some(pos) = raw_bytes[data_start..end].windows(4).position(|w| w == sig) {
                                    end = data_start + pos;
                                }
                            }
                            end
                        };
                        let compressed_slice = &raw_bytes[data_start..data_end];
                        let mut buf = Vec::new();
                        let mut d = flate2::read::DeflateDecoder::new(compressed_slice).take(MAX_DECOMPRESSED_LEN + 1);
                        if d.read_to_end(&mut buf).is_ok() && (buf.len() as u64) <= MAX_DECOMPRESSED_LEN {
                            if let Ok(s) = String::from_utf8(buf.clone()) {
                                return s;
                            }
                        }
                    }
                }
                // Try zlib first
                let mut buf = Vec::new();
                let mut z = flate2::read::ZlibDecoder::new(&raw_bytes[..]).take(MAX_DECOMPRESSED_LEN + 1);
                if z.read_to_end(&mut buf).is_ok() && (buf.len() as u64) <= MAX_DECOMPRESSED_LEN {
                    return String::from_utf8(buf).unwrap_or_else(|e| latin1(e.as_bytes()));
                }
                buf.clear();
                // Fallback to deflate
                let mut d = flate2::read::DeflateDecoder::new(&raw_bytes[..]).take(MAX_DECOMPRESSED_LEN + 1);
                if d.read_to_end(&mut buf).is_ok() && (buf.len() as u64) <= MAX_DECOMPRESSED_LEN {
                    return String::from_utf8(buf).unwrap_or_else(|e| latin1(e.as_bytes()));
                }
            }
        }
    } else if field_bytes.starts_with(b"0:") {
        return latin1(&field_bytes[2..]);
    }
    latin1(field_bytes)
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

    #[test]
    fn decompress_field_uncompressed_and_raw() {
        assert_eq!(decompress_field(b"0:hello world"), "hello world");
        assert_eq!(decompress_field(b"raw fallback"), "raw fallback");
        assert_eq!(decompress_field(b""), "");
    }

    #[test]
    fn decompress_field_compressed_zlib_roundtrip() {
        use flate2::write::ZlibEncoder;
        use flate2::Compression;
        use std::io::Write;

        let src = b"UID12345,EURUSD,0.1,1.08500";
        let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
        enc.write_all(src).unwrap();
        let mut comp = enc.finish().unwrap();

        let pad = (4 - (comp.len() % 4)) % 4;
        comp.resize(comp.len() + pad, 0);

        let z85 = zmq::z85_encode(&comp).unwrap();
        let wire = format!("1:{}:{}", pad, z85);
        assert_eq!(decompress_field(wire.as_bytes()), "UID12345,EURUSD,0.1,1.08500");
    }

    #[test]
    fn decompress_field_corrupted_graceful() {
        assert_eq!(decompress_field(b"1:0:not_valid_z85!!!"), "1:0:not_valid_z85!!!");
        assert_eq!(decompress_field(b"1:"), "1:");
    }

    #[test]
    fn decompress_field_pkzip_container() {
        use flate2::write::DeflateEncoder;
        use flate2::Compression;
        use std::io::Write;

        let src = b"UID99999,GBPUSD,0.5,1.25000";
        let mut enc = DeflateEncoder::new(Vec::new(), Compression::default());
        enc.write_all(src).unwrap();
        let comp_data = enc.finish().unwrap();

        let mut pkzip = Vec::new();
        pkzip.extend_from_slice(b"PK\x03\x04");
        pkzip.extend_from_slice(&[20, 0]); // version needed
        pkzip.extend_from_slice(&[0, 0]);  // flags
        pkzip.extend_from_slice(&[8, 0]);  // compression method (deflate)
        pkzip.extend_from_slice(&[0, 0, 0, 0]); // mtime/mdate
        pkzip.extend_from_slice(&[0, 0, 0, 0]); // crc32
        pkzip.extend_from_slice(&(comp_data.len() as u32).to_le_bytes()); // comp_size
        pkzip.extend_from_slice(&(src.len() as u32).to_le_bytes()); // uncomp_size
        let fname = b"data.txt";
        pkzip.extend_from_slice(&(fname.len() as u16).to_le_bytes()); // name_len
        pkzip.extend_from_slice(&[0, 0]); // extra_len
        pkzip.extend_from_slice(fname);
        pkzip.extend_from_slice(&comp_data);
        // Append simulated Central Directory header to test trimming
        pkzip.extend_from_slice(b"PK\x01\x02");
        pkzip.extend_from_slice(&[0; 42]);

        let pad = (4 - (pkzip.len() % 4)) % 4;
        pkzip.resize(pkzip.len() + pad, 0);

        let z85 = zmq::z85_encode(&pkzip).unwrap();
        let wire = format!("1:{}:{}", pad, z85);
        assert_eq!(decompress_field(wire.as_bytes()), "UID99999,GBPUSD,0.5,1.25000");
    }
}
