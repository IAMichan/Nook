//! Muziek op Windows: de mediabediening van het systeem (GSMTC), dezelfde die de volumeknoppen en het vergrendelscherm
//! gebruiken. Werkt met Spotify, de Media Player, browsers en elke app die zich aanmeldt. Volume via de standaard
//! geluidsuitgang (Core Audio).

use base64::Engine as _;
use nook_core::platform::{MediaCommand, MediaControl, NowPlaying};
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session, GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::DataReader;
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_ALL};
use windows::Win32::System::SystemInformation::GetSystemTimeAsFileTime;

use super::screen::com;

pub struct WindowsMedia;

impl WindowsMedia {
    pub fn new() -> Self {
        Self
    }
}

fn session() -> windows::core::Result<Session> {
    Manager::RequestAsync()?.join()?.GetCurrentSession()
}

fn fail(e: windows::core::Error) -> String {
    format!("De mediabediening van Windows weigerde: {}", e.message())
}

/// "Spotify.exe" of "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify" → "Spotify".
fn app_name(id: &str) -> String {
    let last = id.rsplit('!').next().unwrap_or(id);
    let stem = last.trim_end_matches(".exe").trim_end_matches(".EXE");
    let stem = stem.rsplit('.').next().unwrap_or(stem);
    match stem.to_lowercase().as_str() {
        "msedge" => "Microsoft Edge".into(),
        "chrome" => "Google Chrome".into(),
        "firefox" => "Firefox".into(),
        "zunemusic" | "microsoft.zunemusic" => "Media Player".into(),
        _ => stem.to_string(),
    }
}

fn artwork(session: &Session) -> Option<String> {
    let props = session.TryGetMediaPropertiesAsync().ok()?.join().ok()?;
    let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.join().ok()?;
    let size = stream.Size().ok()? as u32;
    if size == 0 || size > 4_000_000 {
        return None;
    }
    let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0).ok()?).ok()?;
    reader.LoadAsync(size).ok()?.join().ok()?;
    let mut bytes = vec![0u8; size as usize];
    reader.ReadBytes(&mut bytes).ok()?;
    let mime = stream.ContentType().map(|c| c.to_string()).unwrap_or_else(|_| "image/png".into());
    Some(format!(
        "data:{};base64,{}",
        if mime.is_empty() { "image/png" } else { &mime },
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

/// Nu in 100-nanoseconde-eenheden sinds 1601, zoals `DateTime.UniversalTime`.
fn now_ticks() -> i64 {
    let ft = unsafe { GetSystemTimeAsFileTime() };
    ((ft.dwHighDateTime as i64) << 32) | ft.dwLowDateTime as i64
}

fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
    com();
    unsafe {
        let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole)?;
        device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
    }
}

impl MediaControl for WindowsMedia {
    fn now_playing(&self) -> Option<NowPlaying> {
        let session = session().ok()?;
        let props = session.TryGetMediaPropertiesAsync().ok()?.join().ok()?;
        let title = props.Title().map(|t| t.to_string()).unwrap_or_default();
        let artist = props.Artist().map(|t| t.to_string()).unwrap_or_default();
        if title.is_empty() && artist.is_empty() {
            return None;
        }
        let info = session.GetPlaybackInfo().ok()?;
        let playing = info.PlaybackStatus().ok() == Some(Status::Playing);
        let shuffle = info.IsShuffleActive().ok().and_then(|r| r.Value().ok());
        let repeat = info.AutoRepeatMode().ok().and_then(|r| r.Value().ok()).map(|m| m != MediaPlaybackAutoRepeatMode::None);
        let seekable = info.Controls().and_then(|c| c.IsPlaybackPositionEnabled()).unwrap_or(false);
        let timeline = session.GetTimelineProperties().ok();
        let (mut position, duration) = match &timeline {
            Some(t) => (
                t.Position().ok().map(|p| p.Duration as f64 / 10_000_000.0),
                t.EndTime().ok().map(|e| e.Duration as f64 / 10_000_000.0).filter(|d| *d > 0.0),
            ),
            None => (None, None),
        };
        // De positie wordt alleen bij een wijziging bijgewerkt: tel de tijd sindsdien erbij op.
        if playing {
            if let (Some(p), Some(updated)) = (position, timeline.as_ref().and_then(|t| t.LastUpdatedTime().ok())) {
                let since = (now_ticks() - updated.UniversalTime) as f64 / 10_000_000.0;
                if (0.0..86_400.0).contains(&since) {
                    position = Some(duration.map(|d| (p + since).min(d)).unwrap_or(p + since));
                }
            }
        }
        Some(NowPlaying {
            app: app_name(&session.SourceAppUserModelId().map(|s| s.to_string()).unwrap_or_default()),
            title,
            artist,
            album: props.AlbumTitle().map(|t| t.to_string()).unwrap_or_default(),
            playing,
            artwork: artwork(&session),
            position,
            duration,
            shuffle,
            repeat,
            volume: self.volume(),
            can_seek: seekable && duration.is_some(),
        })
    }

    fn send(&self, command: MediaCommand) -> Result<(), String> {
        let session = session().map_err(|_| "Er speelt nu niets.".to_string())?;
        let op = match command {
            MediaCommand::PlayPause => session.TryTogglePlayPauseAsync(),
            MediaCommand::Next => session.TrySkipNextAsync(),
            MediaCommand::Previous => session.TrySkipPreviousAsync(),
        };
        op.and_then(|o| o.join()).map_err(fail)?;
        Ok(())
    }

    fn set_volume(&self, percent: u8) -> Result<(), String> {
        let endpoint = endpoint().map_err(|e| format!("Geen geluidsuitgang: {}", e.message()))?;
        unsafe { endpoint.SetMasterVolumeLevelScalar(percent.min(100) as f32 / 100.0, std::ptr::null()) }.map_err(fail)
    }

    fn volume(&self) -> Option<u8> {
        let endpoint = endpoint().ok()?;
        let level = unsafe { endpoint.GetMasterVolumeLevelScalar() }.ok()?;
        Some((level * 100.0).round().clamp(0.0, 100.0) as u8)
    }

    fn seek(&self, seconds: f64) -> Result<(), String> {
        let session = session().map_err(|_| "Er speelt nu niets.".to_string())?;
        session.TryChangePlaybackPositionAsync((seconds.max(0.0) * 10_000_000.0) as i64).and_then(|o| o.join()).map_err(fail)?;
        Ok(())
    }

    fn set_shuffle(&self, on: bool) -> Result<(), String> {
        let session = session().map_err(|_| "Er speelt nu niets.".to_string())?;
        session.TryChangeShuffleActiveAsync(on).and_then(|o| o.join()).map_err(fail)?;
        Ok(())
    }

    fn set_repeat(&self, on: bool) -> Result<(), String> {
        let session = session().map_err(|_| "Er speelt nu niets.".to_string())?;
        let mode = if on { MediaPlaybackAutoRepeatMode::List } else { MediaPlaybackAutoRepeatMode::None };
        session.TryChangeAutoRepeatModeAsync(mode).and_then(|o| o.join()).map_err(fail)?;
        Ok(())
    }
}
