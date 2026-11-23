//! Lyrics through lrclib.net (the Mac's `LyricsService`): only when you turned it on, and then only the title, artist,
//! album and length of the playing track are sent. Synced lyrics (LRC) become timed lines the Music page follows.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricLine {
    /// Seconds into the track; none for plain lyrics.
    pub at: Option<f64>,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Lyrics {
    pub lines: Vec<LyricLine>,
    pub synced: bool,
    pub instrumental: bool,
}

/// lrclib's answer (`/api/get`).
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct LrclibTrack {
    pub instrumental: bool,
    pub plain_lyrics: Option<String>,
    pub synced_lyrics: Option<String>,
}

/// The address to ask for one track; the length is rounded to whole seconds, as lrclib matches within two.
pub fn request_url(title: &str, artist: &str, album: &str, duration: Option<f64>) -> String {
    let enc = |t: &str| percent_encoding::utf8_percent_encode(t.trim(), percent_encoding::NON_ALPHANUMERIC).to_string();
    let mut url = format!("https://lrclib.net/api/get?track_name={}&artist_name={}", enc(title), enc(artist));
    if !album.trim().is_empty() {
        url.push_str(&format!("&album_name={}", enc(album)));
    }
    if let Some(d) = duration.filter(|d| *d > 0.0) {
        url.push_str(&format!("&duration={}", d.round() as u64));
    }
    url
}

/// LRC ("[01:02.34] words") to timed lines, in order; lines without a time tag are dropped.
pub fn parse_lrc(text: &str) -> Vec<LyricLine> {
    let mut out = vec![];
    for line in text.lines() {
        let mut rest = line.trim();
        let mut times = vec![];
        while let Some(stripped) = rest.strip_prefix('[') {
            let Some(end) = stripped.find(']') else { break };
            let tag = &stripped[..end];
            let Some((m, s)) = tag.split_once(':') else { break };
            let (Ok(m), Ok(s)) = (m.parse::<f64>(), s.parse::<f64>()) else { break };
            times.push(m * 60.0 + s);
            rest = stripped[end + 1..].trim_start();
        }
        for at in times {
            out.push(LyricLine { at: Some(at), text: rest.to_string() });
        }
    }
    out.sort_by(|a, b| a.at.partial_cmp(&b.at).unwrap_or(std::cmp::Ordering::Equal));
    out
}

pub fn from_lrclib(track: LrclibTrack) -> Lyrics {
    if let Some(lines) = track.synced_lyrics.as_deref().map(parse_lrc).filter(|l| !l.is_empty()) {
        return Lyrics { lines, synced: true, instrumental: track.instrumental };
    }
    let lines =
        track.plain_lyrics.unwrap_or_default().lines().map(|t| LyricLine { at: None, text: t.trim().to_string() }).collect::<Vec<_>>();
    Lyrics { lines, synced: false, instrumental: track.instrumental }
}

/// The line being sung at `position` seconds: the last one that started; none before the first.
pub fn current_line(lines: &[LyricLine], position: f64) -> Option<usize> {
    lines.iter().rposition(|l| l.at.is_some_and(|at| at <= position))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_synced_lyrics() {
        let lines = parse_lrc("[00:12.50] First\n[00:05.00][01:00.00] Chorus\nno time\n[ar:Band]");
        assert_eq!(lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), vec!["Chorus", "First", "Chorus"]);
        assert_eq!(current_line(&lines, 13.0), Some(1));
        assert_eq!(current_line(&lines, 1.0), None);
    }

    #[test]
    fn falls_back_to_plain_lyrics_and_asks_with_little() {
        let lyrics = from_lrclib(LrclibTrack { plain_lyrics: Some("a\nb".into()), ..Default::default() });
        assert!(!lyrics.synced && lyrics.lines.len() == 2);
        assert_eq!(
            request_url("Song A", "The Band", "", Some(201.6)),
            "https://lrclib.net/api/get?track_name=Song%20A&artist_name=The%20Band&duration=202"
        );
    }
}
