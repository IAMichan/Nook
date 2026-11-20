//! A voice note as the chat apps take one (`OggOpus` on the Mac): Opus in an Ogg file. The window records Opus in WebM
//! (what WebView2's `MediaRecorder` makes); this moves the same Opus packets into Ogg pages, without decoding them.

/// The Opus packets of a WebM recording and its `OpusHead` (CodecPrivate), when it has one.
pub struct WebmOpus {
    pub head: Option<Vec<u8>>,
    pub packets: Vec<Vec<u8>>,
}

const SEGMENT: u64 = 0x1853_8067;
const CLUSTER: u64 = 0x1F43_B675;
const TRACKS: u64 = 0x1654_AE6B;
const TRACK_ENTRY: u64 = 0xAE;
const BLOCK_GROUP: u64 = 0xA0;
const SIMPLE_BLOCK: u64 = 0xA3;
const BLOCK: u64 = 0xA1;
const CODEC_PRIVATE: u64 = 0x63A2;

/// An EBML variable-length number at `at`: its value (with the marker bit kept for ids, dropped for sizes), its
/// length, and whether it is the "unknown size" of a live recording.
fn vint(data: &[u8], at: usize, keep_marker: bool) -> Option<(u64, usize, bool)> {
    let first = *data.get(at)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 8 || at + len > data.len() {
        return None;
    }
    let mut value = if keep_marker { first as u64 } else { (first as u64) & ((1u64 << (8 - len)) - 1) };
    for b in &data[at + 1..at + len] {
        value = (value << 8) | *b as u64;
    }
    let unknown = !keep_marker && value == (1u64 << (7 * len)) - 1;
    Some((value, len, unknown))
}

/// Reads the Opus packets out of a WebM file (one audio track, no lacing, as `MediaRecorder` writes it).
pub fn read_webm(data: &[u8]) -> Option<WebmOpus> {
    let mut out = WebmOpus { head: None, packets: vec![] };
    walk(data, 0, data.len(), &mut out);
    (!out.packets.is_empty()).then_some(out)
}

fn walk(data: &[u8], mut at: usize, end: usize, out: &mut WebmOpus) {
    while at < end {
        let Some((id, id_len, _)) = vint(data, at, true) else { return };
        let Some((size, size_len, unknown)) = vint(data, at + id_len, false) else { return };
        let body = at + id_len + size_len;
        let stop = if unknown { end } else { (body as u64 + size).min(end as u64) as usize };
        match id {
            SEGMENT | CLUSTER | TRACKS | TRACK_ENTRY | BLOCK_GROUP => {
                if unknown {
                    // A live recording's cluster runs until the next one: go on reading at this level.
                    at = body;
                    continue;
                }
                walk(data, body, stop, out);
            }
            CODEC_PRIVATE => out.head = Some(data[body..stop].to_vec()),
            SIMPLE_BLOCK | BLOCK => {
                // Track number, a 16-bit timecode, flags, then the frame.
                if let Some((_, track_len, _)) = vint(data, body, false) {
                    let frame = body + track_len + 3;
                    if frame < stop {
                        out.packets.push(data[frame..stop].to_vec());
                    }
                }
            }
            _ => {}
        }
        at = stop;
    }
}

/// The samples (at 48 kHz) one Opus packet holds, from its TOC byte (RFC 6716, 3.1).
pub fn packet_samples(packet: &[u8]) -> u64 {
    let Some(&toc) = packet.first() else { return 0 };
    let config = toc >> 3;
    let frame: u64 = match config {
        0..=11 => [480, 960, 1920, 2880][(config % 4) as usize],
        12..=15 => [480, 960][(config % 2) as usize],
        _ => [120, 240, 480, 960][(config % 4) as usize],
    };
    let frames = match toc & 3 {
        0 => 1,
        1 | 2 => 2,
        _ => packet.get(1).map_or(1, |b| (b & 0x3F) as u64),
    };
    frame * frames
}

/// The Ogg CRC-32 (polynomial 0x04C11DB7, not reflected).
fn crc(data: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &b in data {
        crc ^= (b as u32) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 { (crc << 1) ^ 0x04C1_1DB7 } else { crc << 1 };
        }
    }
    crc
}

fn page(out: &mut Vec<u8>, flags: u8, granule: u64, serial: u32, sequence: u32, packet: &[u8]) {
    let mut lacing: Vec<u8> = vec![255; packet.len() / 255];
    lacing.push((packet.len() % 255) as u8);
    let start = out.len();
    out.extend_from_slice(b"OggS");
    out.push(0);
    out.push(flags);
    out.extend_from_slice(&granule.to_le_bytes());
    out.extend_from_slice(&serial.to_le_bytes());
    out.extend_from_slice(&sequence.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.push(lacing.len() as u8);
    out.extend_from_slice(&lacing);
    out.extend_from_slice(packet);
    let sum = crc(&out[start..]);
    out[start + 22..start + 26].copy_from_slice(&sum.to_le_bytes());
}

/// The packets as an Ogg Opus file: `OpusHead`, `OpusTags`, then one packet per page. Packets over 64 kB do not occur in
/// a voice note and are left out.
pub fn ogg_opus(head: Option<&[u8]>, packets: &[Vec<u8>]) -> Vec<u8> {
    let serial = 0x4E6F_6F6B; // "Nook"
    let default_head: Vec<u8> = {
        let mut h = b"OpusHead".to_vec();
        h.extend_from_slice(&[1, 1]);
        h.extend_from_slice(&312u16.to_le_bytes());
        h.extend_from_slice(&48_000u32.to_le_bytes());
        h.extend_from_slice(&[0, 0, 0]);
        h
    };
    let head = head.filter(|h| h.starts_with(b"OpusHead")).map(<[u8]>::to_vec).unwrap_or(default_head);
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&4u32.to_le_bytes());
    tags.extend_from_slice(b"Nook");
    tags.extend_from_slice(&0u32.to_le_bytes());
    let mut out = vec![];
    page(&mut out, 0x02, 0, serial, 0, &head);
    page(&mut out, 0x00, 0, serial, 1, &tags);
    let mut granule = 0u64;
    let packets: Vec<&Vec<u8>> = packets.iter().filter(|p| !p.is_empty() && p.len() < 255 * 255).collect();
    for (i, p) in packets.iter().enumerate() {
        granule += packet_samples(p);
        let last = i + 1 == packets.len();
        page(&mut out, if last { 0x04 } else { 0 }, granule, serial, 2 + i as u32, p);
    }
    out
}

/// A WebM Opus recording as an Ogg Opus voice note; `None` when it holds no Opus.
pub fn webm_to_ogg(data: &[u8]) -> Option<Vec<u8>> {
    let webm = read_webm(data)?;
    Some(ogg_opus(webm.head.as_deref(), &webm.packets))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn element(id: &[u8], body: &[u8]) -> Vec<u8> {
        let mut out = id.to_vec();
        out.push(0x80 | body.len() as u8);
        out.extend_from_slice(body);
        out
    }

    #[test]
    fn packets_move_from_webm_into_ogg_pages() {
        let head = {
            let mut h = b"OpusHead".to_vec();
            h.extend_from_slice(&[1, 1, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]);
            h
        };
        let codec = element(&[0x63, 0xA2], &head);
        let tracks = element(&[0x16, 0x54, 0xAE, 0x6B], &element(&[0xAE], &codec));
        // Two 20 ms CELT packets (config 31, one frame) in simple blocks of track 1.
        let block = |frame: &[u8]| {
            let mut b = vec![0x81, 0, 0, 0x80];
            b.extend_from_slice(frame);
            element(&[0xA3], &b)
        };
        let mut cluster_body = element(&[0xE7], &[0]);
        cluster_body.extend(block(&[0xF8, 1, 2, 3]));
        cluster_body.extend(block(&[0xF8, 4, 5]));
        // A live recording: the segment and the cluster of unknown size.
        let mut data = vec![0x1A, 0x45, 0xDF, 0xA3, 0x80];
        data.extend_from_slice(&[0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        data.extend(tracks);
        data.extend_from_slice(&[0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        data.extend(cluster_body);
        let webm = read_webm(&data).unwrap();
        assert_eq!(webm.head.as_deref(), Some(head.as_slice()));
        assert_eq!(webm.packets, vec![vec![0xF8, 1, 2, 3], vec![0xF8, 4, 5]]);
        let ogg = webm_to_ogg(&data).unwrap();
        assert!(ogg.starts_with(b"OggS"));
        assert_eq!(ogg.windows(8).filter(|w| *w == b"OpusHead").count(), 1);
        assert_eq!(ogg.windows(4).filter(|w| *w == b"OggS").count(), 4);
        // The last page ends the stream at 2 × 960 samples.
        let last = ogg.windows(4).rposition(|w| w == b"OggS").unwrap();
        assert_eq!(ogg[last + 5], 0x04);
        assert_eq!(u64::from_le_bytes(ogg[last + 6..last + 14].try_into().unwrap()), 1920);
    }

    #[test]
    fn samples_follow_the_toc() {
        assert_eq!(packet_samples(&[0xF8]), 960); // CELT 20 ms
        assert_eq!(packet_samples(&[0x19]), 2880 * 2); // SILK 60 ms, two frames
        assert_eq!(packet_samples(&[0xFB, 0x03]), 960 * 3);
        // The CRC of the Ogg spec's empty case.
        assert_eq!(crc(b""), 0);
    }
}
