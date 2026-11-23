//! Lyrics for the Music page from lrclib.net (`nook_core::services::lyrics`), only after you turned it on there or in
//! Privacy; answers are kept for this run, so a track asks once.

use std::collections::HashMap;
use std::sync::Mutex;

use nook_core::services::lyrics::{from_lrclib, request_url, LrclibTrack, Lyrics};
use tauri::{AppHandle, Manager};

use super::Services;

static CACHE: Mutex<Option<HashMap<String, Option<Lyrics>>>> = Mutex::new(None);

#[tauri::command]
pub async fn music_lyrics(
    app: AppHandle,
    title: String,
    artist: String,
    album: String,
    duration: Option<f64>,
) -> Result<Option<Lyrics>, String> {
    if !app.state::<Services>().prefs().online_lyrics || title.trim().is_empty() {
        return Ok(None);
    }
    let url = request_url(&title, &artist, &album, duration);
    if let Some(hit) = CACHE.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).get(&url) {
        return Ok(hit.clone());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .user_agent("Nook (https://github.com/IAMichan/Nook)")
        .build()
        .map_err(|e| e.to_string())?;
    let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
    let found = if response.status() == reqwest::StatusCode::NOT_FOUND {
        None
    } else {
        let track: LrclibTrack = response.error_for_status().map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
        Some(from_lrclib(track)).filter(|l| !l.lines.is_empty() || l.instrumental)
    };
    CACHE.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).insert(url, found.clone());
    Ok(found)
}
