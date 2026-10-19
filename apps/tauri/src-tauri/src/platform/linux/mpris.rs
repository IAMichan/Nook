//! Muziek op Linux via MPRIS (D-Bus): elke speler die meedoet (Spotify, Rhythmbox, VLC, Firefox, Chromium, mpv met
//! mpris-plugin…). De speler die speelt gaat voor; anders de laatst gepauzeerde.

use std::collections::HashMap;

use nook_core::platform::{MediaCommand, NowPlaying};
use zbus::blocking::Connection;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const PATH: &str = "/org/mpris/MediaPlayer2";
const PLAYER: &str = "org.mpris.MediaPlayer2.Player";
const ROOT: &str = "org.mpris.MediaPlayer2";

pub struct Mpris {
    bus: Connection,
}

struct Player {
    name: String,
    status: String,
}

impl Mpris {
    pub fn connect() -> Option<Self> {
        Some(Self { bus: Connection::session().ok()? })
    }

    fn players(&self) -> Vec<Player> {
        let names: Vec<String> = self
            .bus
            .call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"), "ListNames", &())
            .ok()
            .and_then(|r| r.body().deserialize().ok())
            .unwrap_or_default();
        let mut players: Vec<Player> = names
            .into_iter()
            .filter(|n| n.starts_with("org.mpris.MediaPlayer2."))
            .map(|name| {
                let status = self.get(&name, PLAYER, "PlaybackStatus").and_then(|v| String::try_from(v).ok()).unwrap_or_default();
                Player { name, status }
            })
            .collect();
        players.sort_by_key(|p| match p.status.as_str() {
            "Playing" => 0,
            "Paused" => 1,
            _ => 2,
        });
        players
    }

    fn active(&self) -> Option<Player> {
        self.players().into_iter().find(|p| p.status == "Playing" || p.status == "Paused")
    }

    fn get(&self, name: &str, iface: &str, prop: &str) -> Option<OwnedValue> {
        self.bus
            .call_method(Some(name), PATH, Some("org.freedesktop.DBus.Properties"), "Get", &(iface, prop))
            .ok()?
            .body()
            .deserialize::<OwnedValue>()
            .ok()
    }

    fn set(&self, prop: &str, value: Value<'_>) -> Result<(), String> {
        let player = self.active().ok_or("Er speelt nu niets.")?;
        self.bus
            .call_method(Some(player.name.as_str()), PATH, Some("org.freedesktop.DBus.Properties"), "Set", &(PLAYER, prop, value))
            .map(|_| ())
            .map_err(|e| format!("De speler weigerde: {e}"))
    }

    fn call(&self, method: &str) -> Result<(), String> {
        let player = self.active().or_else(|| self.players().into_iter().next()).ok_or("Er is geen muziekspeler open.")?;
        self.bus.call_method(Some(player.name.as_str()), PATH, Some(PLAYER), method, &()).map(|_| ()).map_err(|e| format!("De speler weigerde: {e}"))
    }

    pub fn now_playing(&self) -> Option<NowPlaying> {
        let player = self.active()?;
        let metadata: HashMap<String, OwnedValue> = self.get(&player.name, PLAYER, "Metadata").and_then(|v| v.try_into().ok()).unwrap_or_default();
        let text = |key: &str| metadata.get(key).and_then(|v| String::try_from(v.clone()).ok()).unwrap_or_default();
        let artist = metadata
            .get("xesam:artist")
            .and_then(|v| Vec::<String>::try_from(v.clone()).ok())
            .map(|a| a.join(", "))
            .unwrap_or_else(|| text("xesam:artist"));
        let length = metadata
            .get("mpris:length")
            .and_then(|v| i64::try_from(v.clone()).ok().or_else(|| u64::try_from(v.clone()).ok().map(|u| u as i64)))
            .map(|us| us as f64 / 1_000_000.0);
        let position = self.get(&player.name, PLAYER, "Position").and_then(|v| i64::try_from(v).ok()).map(|us| us as f64 / 1_000_000.0);
        let identity = self.get(&player.name, ROOT, "Identity").and_then(|v| String::try_from(v).ok());
        let boolean = |prop: &str| self.get(&player.name, PLAYER, prop).and_then(|v| bool::try_from(v).ok());
        let loop_status = self.get(&player.name, PLAYER, "LoopStatus").and_then(|v| String::try_from(v).ok());
        let volume = self.get(&player.name, PLAYER, "Volume").and_then(|v| f64::try_from(v).ok()).map(|v| (v * 100.0).round().clamp(0.0, 100.0) as u8);
        let title = text("xesam:title");
        if title.is_empty() && artist.is_empty() {
            return None;
        }
        Some(NowPlaying {
            app: identity.unwrap_or_else(|| player.name.trim_start_matches("org.mpris.MediaPlayer2.").split('.').next().unwrap_or("").to_string()),
            title,
            artist,
            album: text("xesam:album"),
            playing: player.status == "Playing",
            artwork: artwork(&text("mpris:artUrl")),
            position,
            duration: length.filter(|l| *l > 0.0),
            shuffle: boolean("Shuffle"),
            repeat: loop_status.map(|s| s != "None"),
            volume,
            can_seek: boolean("CanSeek").unwrap_or(false) && length.is_some(),
        })
    }

    pub fn send(&self, command: MediaCommand) -> Result<(), String> {
        self.call(match command {
            MediaCommand::PlayPause => "PlayPause",
            MediaCommand::Next => "Next",
            MediaCommand::Previous => "Previous",
        })
    }

    pub fn seek(&self, seconds: f64) -> Result<(), String> {
        let player = self.active().ok_or("Er speelt nu niets.")?;
        let metadata: HashMap<String, OwnedValue> = self.get(&player.name, PLAYER, "Metadata").and_then(|v| v.try_into().ok()).unwrap_or_default();
        let track = metadata
            .get("mpris:trackid")
            .and_then(|v| zbus::zvariant::OwnedObjectPath::try_from(v.clone()).ok())
            .ok_or("Deze speler zegt niet welk nummer speelt.")?;
        let micros = (seconds.max(0.0) * 1_000_000.0) as i64;
        self.bus
            .call_method(Some(player.name.as_str()), PATH, Some(PLAYER), "SetPosition", &(ObjectPath::from(&track), micros))
            .map(|_| ())
            .map_err(|e| format!("Doorspoelen mislukte: {e}"))
    }

    pub fn set_shuffle(&self, on: bool) -> Result<(), String> {
        self.set("Shuffle", Value::from(on))
    }

    pub fn set_repeat(&self, on: bool) -> Result<(), String> {
        self.set("LoopStatus", Value::from(if on { "Playlist" } else { "None" }))
    }

    pub fn set_volume(&self, percent: u8) -> Result<(), String> {
        self.set("Volume", Value::from(percent.min(100) as f64 / 100.0))
    }
}

/// De hoes: een bestand wordt een data-URL (de interface mag geen lokale bestanden laden), een webadres blijft.
fn artwork(url: &str) -> Option<String> {
    if url.starts_with("https://") || url.starts_with("http://") {
        return Some(url.into());
    }
    let path = url.strip_prefix("file://")?;
    let path = percent_encoding::percent_decode_str(path).decode_utf8_lossy().to_string();
    let bytes = std::fs::read(&path).ok().filter(|b| b.len() < 4_000_000)?;
    let mime = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) { "image/png" } else { "image/jpeg" };
    use base64::Engine as _;
    Some(format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
}
