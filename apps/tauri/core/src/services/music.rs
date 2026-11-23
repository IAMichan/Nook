//! The data of the Music page, as on the Mac (`MusicLibrary.swift`, `MusicOutputs.swift`): tracks, playlists, Nook's own
//! queue, outputs, and the readers of what Spotify's Web API answers. Plain data and pure functions, so everything is
//! tested without a player or the network; the requests live in `spotify`, the listening log in `music_history`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A track in Up Next, a playlist, a search or Recent. `id` is what the player plays it by: a Spotify URI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicTrack {
    pub id: String,
    pub title: String,
    pub artist: String,
    /// Seconds.
    pub duration: u32,
    pub artwork_url: Option<String>,
    pub album: String,
}

/// A playlist on Spotify (`id` a `spotify:playlist:…` URI).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicPlaylist {
    pub id: String,
    pub name: String,
    pub track_count: u32,
    pub artwork_url: Option<String>,
    /// The user may add and remove tracks: their own playlist or a collaborative one.
    pub editable: bool,
    /// Who made it, when that is not the user.
    pub owner: String,
}

/// An artist in the user's top list, or among the plays.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicArtist {
    pub name: String,
    pub plays: Option<u32>,
    pub artwork_url: Option<String>,
}

/// What the user played most lately, as Spotify keeps it (the last six months or so).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicPlayerStats {
    pub app: String,
    pub tracks: Vec<MusicTrack>,
    pub artists: Vec<MusicArtist>,
}

/// Why a Spotify request did not work; the Music page words each one differently.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "message")]
pub enum Failure {
    /// No sign-in, or the token was refused.
    NotSignedIn,
    /// Spotify answered 403: the account has no Premium.
    PremiumRequired,
    /// Spotify answered 404: no device is playing.
    NoActiveDevice,
    /// 403 because the sign-in lacks a permission (it was made before Nook asked for it).
    MissingScope,
    Failed(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotSignedIn => write!(f, "Spotify is not connected."),
            Self::PremiumRequired => write!(f, "Spotify Premium is needed for this."),
            Self::NoActiveDevice => write!(f, "No Spotify device is playing. Open Spotify somewhere and start a track."),
            Self::MissingScope => write!(f, "Spotify needs a new sign-in for this permission."),
            Self::Failed(m) => write!(f, "{m}"),
        }
    }
}

/// How far loading something for the Music page got.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", tag = "kind", content = "message")]
pub enum LoadState {
    #[default]
    Idle,
    Done,
    ConnectSpotify,
    ReconnectSpotify,
    Failed(String),
}

impl LoadState {
    pub fn from_failure(failure: &Failure) -> Self {
        match failure {
            Failure::NotSignedIn => Self::ConnectSpotify,
            Failure::MissingScope => Self::ReconnectSpotify,
            other => Self::Failed(other.to_string()),
        }
    }
}

/// What the page's search shows: the tracks found for `query`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicSearchResult {
    pub query: String,
    pub state: LoadState,
    pub tracks: Vec<MusicTrack>,
}

// Readers of Spotify's answers

/// The bare id in `spotify:playlist:<id>`, or none for anything else.
pub fn playlist_id(uri: &str) -> Option<&str> {
    let mut parts = uri.split(':');
    let (a, b, c, rest) = (parts.next()?, parts.next()?, parts.next()?, parts.next());
    (a == "spotify" && b == "playlist" && rest.is_none() && !c.is_empty() && c.len() <= 64 && c.chars().all(|ch| ch.is_ascii_alphanumeric())).then_some(c)
}

/// `spotify:track:…` or `spotify:episode:…`: what Spotify can play and queue.
pub fn is_spotify_uri(id: &str) -> bool {
    let mut parts = id.split(':');
    matches!((parts.next(), parts.next(), parts.next(), parts.next()), (Some("spotify"), Some("track" | "episode"), Some(x), None) if !x.is_empty())
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

/// The smallest image that is still sharp on a cover (Spotify lists them largest first).
fn image(images: Option<&Value>, min_width: u64) -> Option<String> {
    let list = images?.as_array()?;
    list.iter()
        .rev()
        .find(|i| i.get("width").and_then(Value::as_u64).unwrap_or(0) >= min_width)
        .or_else(|| list.first())
        .and_then(|i| str_of(i, "url"))
        .map(str::to_string)
}

/// One track or episode object.
pub fn track(item: &Value) -> Option<MusicTrack> {
    let uri = str_of(item, "uri")?;
    let name = str_of(item, "name").filter(|n| !n.is_empty())?;
    let artists: Vec<&str> = item.get("artists").and_then(Value::as_array).map(|a| a.iter().filter_map(|x| str_of(x, "name")).collect()).unwrap_or_default();
    let show = item.get("show").and_then(|s| str_of(s, "name"));
    let album = item.get("album");
    let images = album.and_then(|a| a.get("images")).or_else(|| item.get("images"));
    Some(MusicTrack {
        id: uri.to_string(),
        title: name.to_string(),
        artist: if artists.is_empty() { show.unwrap_or("").to_string() } else { artists.join(", ") },
        duration: (item.get("duration_ms").and_then(Value::as_u64).unwrap_or(0) / 1000) as u32,
        artwork_url: image(images, 200),
        album: album.and_then(|a| str_of(a, "name")).or(show).unwrap_or("").to_string(),
    })
}

fn items(v: &Value) -> &[Value] {
    v.get("items").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

/// The tracks in `GET /me/player/queue`, in the order Spotify plays them.
pub fn queue_tracks(v: &Value) -> Vec<MusicTrack> {
    v.get("queue").and_then(Value::as_array).map(|q| q.iter().filter_map(track).collect()).unwrap_or_default()
}

/// The tracks `GET /search?type=track` found, best match first; `null` entries are skipped.
pub fn search_tracks(v: &Value) -> Vec<MusicTrack> {
    v.get("tracks").map(|t| items(t).iter().filter_map(track).collect()).unwrap_or_default()
}

pub fn user_id(v: &Value) -> Option<String> {
    str_of(v, "id").map(str::to_string)
}

/// The `next` page of a paged answer.
pub fn next_page(v: &Value) -> Option<String> {
    str_of(v, "next").filter(|n| !n.is_empty()).map(str::to_string)
}

/// One playlist object. Spotify renamed the `tracks` count to `items` in 2026; both are read.
pub fn playlist(item: &Value, user: Option<&str>) -> Option<MusicPlaylist> {
    let uri = str_of(item, "uri")?;
    playlist_id(uri)?;
    let name = str_of(item, "name")?;
    let count = item.get("items").or_else(|| item.get("tracks")).and_then(|t| t.get("total")).and_then(Value::as_u64).unwrap_or(0) as u32;
    let owner = item.get("owner");
    let owner_id = owner.and_then(|o| str_of(o, "id"));
    let mine = user.is_some() && owner_id == user;
    Some(MusicPlaylist {
        id: uri.to_string(),
        name: name.to_string(),
        track_count: count,
        artwork_url: image(item.get("images"), 200),
        editable: mine || item.get("collaborative").and_then(Value::as_bool).unwrap_or(false),
        owner: if mine { String::new() } else { owner.and_then(|o| str_of(o, "display_name")).or(owner_id).unwrap_or("").to_string() },
    })
}

pub fn playlists(v: &Value, user: Option<&str>) -> Vec<MusicPlaylist> {
    items(v).iter().filter_map(|p| playlist(p, user)).collect()
}

/// The tracks in a page of a playlist's items: each entry holds its track under `item` (since 2026) or `track`; local
/// files and tracks Spotify cannot show are skipped.
pub fn playlist_tracks(v: &Value) -> Vec<MusicTrack> {
    items(v)
        .iter()
        .filter_map(|entry| {
            let object = entry.get("item").or_else(|| entry.get("track")).filter(|o| o.is_object())?;
            if object.get("is_local").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            track(object)
        })
        .collect()
}

pub fn top_tracks(v: &Value) -> Vec<MusicTrack> {
    items(v).iter().filter_map(track).collect()
}

pub fn top_artists(v: &Value) -> Vec<MusicArtist> {
    items(v)
        .iter()
        .filter_map(|a| {
            let name = str_of(a, "name").filter(|n| !n.is_empty())?;
            Some(MusicArtist { name: name.to_string(), plays: None, artwork_url: image(a.get("images"), 160) })
        })
        .collect()
}

/// Classifies a Spotify answer: none when it worked.
pub fn failure(status: u16, body: &str) -> Option<Failure> {
    let message = || serde_json::from_str::<Value>(body).ok().and_then(|v| v.get("error")?.get("message")?.as_str().map(str::to_string));
    match status {
        200..=299 => None,
        401 => Some(Failure::NotSignedIn),
        403 => Some(if message().is_some_and(|m| m.to_lowercase().contains("scope")) { Failure::MissingScope } else { Failure::PremiumRequired }),
        404 => Some(Failure::NoActiveDevice),
        _ => Some(Failure::Failed(message().unwrap_or_else(|| format!("HTTP {status}")))),
    }
}

// Nook's own queue and Recent

/// The tracks played last, the playing one first, each once.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RecentTracks {
    pub tracks: Vec<MusicTrack>,
}

impl RecentTracks {
    pub const LIMIT: usize = 30;

    pub fn add(&mut self, track: MusicTrack) {
        self.tracks.retain(|t| !((!track.id.is_empty() && t.id == track.id) || (t.title == track.title && t.artist == track.artist)));
        self.tracks.insert(0, track);
        self.tracks.truncate(Self::LIMIT);
    }
}

/// One queued track; the same track may be queued twice, so each entry has its own id.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueEntry {
    pub id: String,
    pub track: MusicTrack,
}

/// Tracks the user queued in Nook, in the order they play. Spotify's own queue takes tracks only with Premium and a device
/// playing; otherwise Nook keeps the track here and starts it a moment before the playing track ends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PlayQueue {
    pub entries: Vec<QueueEntry>,
    #[serde(skip)]
    counter: u64,
}

impl PlayQueue {
    pub const LIMIT: usize = 100;

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Adds a track at the end; false when the queue is full or the track has nothing to play it by.
    pub fn append(&mut self, track: MusicTrack) -> bool {
        if track.id.is_empty() || self.entries.len() >= Self::LIMIT {
            return false;
        }
        self.counter += 1;
        self.entries.push(QueueEntry { id: format!("q{}", self.counter), track });
        true
    }

    pub fn remove(&mut self, id: &str) {
        self.entries.retain(|e| e.id != id);
    }

    /// Takes out the entry with `id`, or the first one without.
    pub fn take(&mut self, id: Option<&str>) -> Option<MusicTrack> {
        let index = match id {
            Some(id) => self.entries.iter().position(|e| e.id == id)?,
            None if self.entries.is_empty() => return None,
            None => 0,
        };
        Some(self.entries.remove(index).track)
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// The player moved on by itself while tracks were queued: did the previous track end (so the queue takes over), or did
    /// the user pick something else? One that got within a few seconds of its end ended.
    pub fn ended(position: f64, duration: u32) -> bool {
        duration > 0 && position >= f64::from(duration) - 3.0
    }
}

// Outputs

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutputKind {
    Speaker,
    Headphones,
    Bluetooth,
    Display,
    Phone,
    Computer,
    Tv,
    Car,
    Other,
}

/// Where the music sounds: a Spotify Connect device (a phone, a speaker, a TV, this computer's Spotify app).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicOutput {
    pub id: String,
    pub name: String,
    pub kind: OutputKind,
    /// The sound goes here now.
    pub active: bool,
    pub volume: Option<u8>,
}

/// Spotify's device `type`.
pub fn spotify_kind(kind: &str) -> OutputKind {
    match kind.to_lowercase().as_str() {
        "computer" => OutputKind::Computer,
        "smartphone" | "tablet" => OutputKind::Phone,
        "speaker" | "avr" | "audiodongle" | "castaudio" => OutputKind::Speaker,
        "tv" | "stb" | "castvideo" | "gameconsole" => OutputKind::Tv,
        "automobile" => OutputKind::Car,
        _ => OutputKind::Other,
    }
}

/// The devices in `GET /me/player/devices`; a restricted device cannot be controlled by another app, so it is left out.
pub fn spotify_devices(v: &Value) -> Vec<MusicOutput> {
    v.get("devices")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|d| {
                    let id = str_of(d, "id").filter(|i| !i.is_empty())?;
                    let name = str_of(d, "name").filter(|n| !n.is_empty())?;
                    if d.get("is_restricted").and_then(Value::as_bool) == Some(true) {
                        return None;
                    }
                    Some(MusicOutput {
                        id: id.to_string(),
                        name: name.to_string(),
                        kind: spotify_kind(str_of(d, "type").unwrap_or("")),
                        active: d.get("is_active").and_then(Value::as_bool).unwrap_or(false),
                        volume: d.get("volume_percent").and_then(Value::as_u64).map(|v| v.min(100) as u8),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The device in use first, then computers and speakers, then phones, then the rest by name.
pub fn sort_outputs(outputs: &mut [MusicOutput]) {
    fn rank(o: &MusicOutput) -> u8 {
        if o.active {
            return 0;
        }
        match o.kind {
            OutputKind::Computer | OutputKind::Speaker | OutputKind::Headphones => 1,
            OutputKind::Bluetooth | OutputKind::Phone => 2,
            _ => 3,
        }
    }
    outputs.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
}

/// What a Windows audio endpoint is, from its name (the name tells headphones from a speaker).
pub fn endpoint_kind(name: &str) -> OutputKind {
    let lower = name.to_lowercase();
    if ["headphone", "airpods", "buds", "beats", "koptelefoon", "kopfhörer", "casque", "auriculares", "headset"].iter().any(|s| lower.contains(s)) {
        OutputKind::Headphones
    } else if lower.contains("bluetooth") {
        OutputKind::Bluetooth
    } else if ["hdmi", "displayport", "monitor", "display"].iter().any(|s| lower.contains(s)) {
        OutputKind::Display
    } else {
        OutputKind::Speaker
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_tracks_with_artist_and_cover() {
        let v = json!({"tracks": {"items": [null, {"uri": "spotify:track:a", "name": "Song", "duration_ms": 201500,
            "artists": [{"name": "A"}, {"name": "B"}],
            "album": {"name": "Album", "images": [{"url": "big", "width": 640}, {"url": "mid", "width": 300}, {"url": "tiny", "width": 64}]}}]}});
        let tracks = search_tracks(&v);
        assert_eq!(tracks.len(), 1);
        assert_eq!((tracks[0].artist.as_str(), tracks[0].duration, tracks[0].artwork_url.as_deref(), tracks[0].album.as_str()), ("A, B", 201, Some("mid"), "Album"));
    }

    #[test]
    fn episodes_use_the_show() {
        let t = track(&json!({"uri": "spotify:episode:e", "name": "Ep", "show": {"name": "The Show"}, "images": [{"url": "u", "width": 300}]})).unwrap();
        assert_eq!((t.artist.as_str(), t.album.as_str(), t.artwork_url.as_deref()), ("The Show", "The Show", Some("u")));
    }

    #[test]
    fn playlists_know_what_the_user_may_edit() {
        let v = json!({"items": [
            {"uri": "spotify:playlist:p1", "name": "Mine", "owner": {"id": "me"}, "items": {"total": 4}},
            {"uri": "spotify:playlist:p2", "name": "Theirs", "owner": {"id": "x", "display_name": "Xavier"}, "tracks": {"total": 9}},
            {"uri": "spotify:playlist:p3", "name": "Shared", "collaborative": true, "owner": {"id": "y"}},
            {"uri": "spotify:album:nope", "name": "Not a playlist"}]});
        let list = playlists(&v, Some("me"));
        assert_eq!(list.len(), 3);
        assert!(list[0].editable && list[0].owner.is_empty() && list[0].track_count == 4);
        assert!(!list[1].editable && list[1].owner == "Xavier" && list[1].track_count == 9);
        assert!(list[2].editable);
        assert_eq!(playlist_id("spotify:playlist:p1"), Some("p1"));
        assert_eq!(playlist_id("spotify:playlist:p1:x"), None);
        assert_eq!(playlist_id("spotify:playlist:a/b"), None);
    }

    #[test]
    fn playlist_items_skip_local_files_and_read_both_shapes() {
        let v = json!({"items": [
            {"item": {"uri": "spotify:track:a", "name": "New shape"}},
            {"track": {"uri": "spotify:track:b", "name": "Old shape"}},
            {"track": {"uri": "spotify:track:c", "name": "Local", "is_local": true}},
            {"track": null}]});
        assert_eq!(playlist_tracks(&v).iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["New shape", "Old shape"]);
    }

    #[test]
    fn failures_are_told_apart() {
        assert_eq!(failure(200, ""), None);
        assert_eq!(failure(401, ""), Some(Failure::NotSignedIn));
        assert_eq!(failure(403, r#"{"error":{"message":"Insufficient client scope"}}"#), Some(Failure::MissingScope));
        assert_eq!(failure(403, r#"{"error":{"message":"Player command failed: Premium required"}}"#), Some(Failure::PremiumRequired));
        assert_eq!(failure(404, ""), Some(Failure::NoActiveDevice));
        assert_eq!(failure(500, r#"{"error":{"message":"boom"}}"#), Some(Failure::Failed("boom".into())));
        assert_eq!(failure(502, ""), Some(Failure::Failed("HTTP 502".into())));
    }

    #[test]
    fn recent_keeps_each_track_once_newest_first() {
        let mut recent = RecentTracks::default();
        let t = |id: &str, title: &str| MusicTrack { id: id.into(), title: title.into(), artist: "A".into(), ..Default::default() };
        recent.add(t("1", "One"));
        recent.add(t("2", "Two"));
        recent.add(t("", "One"));
        assert_eq!(recent.tracks.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["One", "Two"]);
        for i in 0..40 {
            recent.add(t(&format!("x{i}"), &format!("T{i}")));
        }
        assert_eq!(recent.tracks.len(), RecentTracks::LIMIT);
    }

    #[test]
    fn nooks_queue_keeps_order_and_duplicates() {
        let mut q = PlayQueue::default();
        let t = |id: &str| MusicTrack { id: id.into(), title: id.into(), ..Default::default() };
        assert!(!q.append(t("")));
        assert!(q.append(t("a")) && q.append(t("b")) && q.append(t("a")));
        let second = q.entries[1].id.clone();
        assert_ne!(q.entries[0].id, q.entries[2].id);
        assert_eq!(q.take(Some(&second)).map(|t| t.id), Some("b".into()));
        assert_eq!(q.take(None).map(|t| t.id), Some("a".into()));
        let last = q.entries[0].id.clone();
        q.remove(&last);
        assert!(q.is_empty());
        assert!(PlayQueue::ended(198.0, 200) && !PlayQueue::ended(50.0, 200) && !PlayQueue::ended(5.0, 0));
        for _ in 0..PlayQueue::LIMIT + 5 {
            q.append(t("z"));
        }
        assert_eq!(q.entries.len(), PlayQueue::LIMIT);
    }

    #[test]
    fn outputs_come_from_connect_devices() {
        let v = json!({"devices": [
            {"id": "d1", "name": "Kitchen", "type": "Speaker", "is_active": false, "volume_percent": 30},
            {"id": "d2", "name": "Laptop", "type": "Computer", "is_active": true},
            {"id": "d3", "name": "Locked", "type": "TV", "is_restricted": true},
            {"id": "d4", "name": "Phone", "type": "Smartphone"}]});
        let mut list = spotify_devices(&v);
        sort_outputs(&mut list);
        assert_eq!(list.iter().map(|o| o.name.as_str()).collect::<Vec<_>>(), vec!["Laptop", "Kitchen", "Phone"]);
        assert_eq!(list[1].volume, Some(30));
        assert_eq!(endpoint_kind("Speakers (Realtek)"), OutputKind::Speaker);
        assert_eq!(endpoint_kind("Headphones (WH-1000XM5)"), OutputKind::Headphones);
        assert_eq!(endpoint_kind("DELL U2720Q (HDMI)"), OutputKind::Display);
        assert!(is_spotify_uri("spotify:track:abc") && !is_spotify_uri("spotify:playlist:abc") && !is_spotify_uri("abc"));
    }
}
