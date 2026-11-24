//! Spotify Web API with OAuth 2.0 PKCE (`SpotifyWebAPI.swift` on the Mac, `SV-30..SV-38`, `BR-28`):
//! sign-in with PKCE (S256 challenge, loopback callback or code paste, automatic token refresh), catalog search
//! (tracks, albums, playlists), queue inspection and queueing, playlists CRUD, top tracks and artists, recent plays
//! import, and Spotify Connect output switching.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::music::{self, Failure, LoadState, MusicOutput, MusicPlayerStats, MusicPlaylist, MusicSearchResult, MusicTrack, OutputKind};
use super::music_history::MusicPlay;
use crate::brain::LoopTool;

pub const REDIRECT_URI: &str = "http://127.0.0.1:43821/spotify/callback";
pub const AUTHORIZE_URL: &str = "https://accounts.spotify.com/authorize";
pub const TOKEN_URL: &str = "https://accounts.spotify.com/api/token";
pub const API_BASE: &str = "https://api.spotify.com/v1";

pub const SCOPES: &str = "user-read-playback-state user-modify-playback-state user-read-currently-playing \
user-read-recently-played user-top-read playlist-read-private playlist-read-collaborative \
playlist-modify-private playlist-modify-public";

/// An album returned by Spotify catalog search (`SV-32`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MusicAlbum {
    pub id: String,
    pub name: String,
    pub artist: String,
    pub artwork_url: Option<String>,
    pub release_year: String,
    pub total_tracks: u32,
}

/// Full catalog search result across tracks, albums, and playlists (`SV-32`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SpotifySearchCatalog {
    pub query: String,
    pub state: LoadState,
    pub tracks: Vec<MusicTrack>,
    pub albums: Vec<MusicAlbum>,
    pub playlists: Vec<MusicPlaylist>,
}

/// Active Spotify OAuth PKCE session (`SV-31`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SpotifySession {
    pub client_id: String,
    pub access_token: String,
    pub refresh_token: String,
    /// Unix timestamp (seconds) when `access_token` expires.
    pub expires_at: i64,
    pub scope: String,
    pub user_id: Option<String>,
    pub display_name: Option<String>,
}

impl SpotifySession {
    pub fn is_expired(&self, now_epoch: i64) -> bool {
        self.access_token.trim().is_empty() || now_epoch + 60 >= self.expires_at
    }

    pub fn has_scope(&self, required: &str) -> bool {
        let granted: std::collections::HashSet<&str> = self.scope.split_whitespace().collect();
        required.split_whitespace().all(|s| granted.contains(s))
    }
}

/// In-flight PKCE authorization state waiting for the browser callback (`SV-31`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SpotifyPendingAuth {
    pub client_id: String,
    pub redirect_uri: String,
    pub verifier: String,
    pub state: String,
    pub authorize_url: String,
}

/// Persisted Spotify configuration and PKCE credentials (`spotify-auth.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SpotifyConfig {
    pub client_id: String,
    pub redirect_uri: String,
    pub session: Option<SpotifySession>,
    pub pending: Option<SpotifyPendingAuth>,
}

impl SpotifyConfig {
    pub fn file() -> std::path::PathBuf {
        crate::paths::support_directory().join("spotify-auth.json")
    }

    pub fn load() -> Self {
        let mut cfg: Self = std::fs::read(Self::file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        if cfg.redirect_uri.trim().is_empty() {
            cfg.redirect_uri = REDIRECT_URI.to_string();
        }
        cfg
    }

    pub fn save(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        crate::paths::write_atomic(&Self::file(), &bytes)
    }

    pub fn connected(&self) -> bool {
        self.session.as_ref().is_some_and(|s| !s.access_token.is_empty() || !s.refresh_token.is_empty())
    }
}

// ── PKCE Cryptography & URL Builders (SV-31) ──

/// Generates a 64-character RFC 7636 PKCE code verifier.
pub fn generate_code_verifier() -> String {
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(64);
    for _ in 0..64 {
        let idx = (rand::random::<u8>() as usize) % CHARSET.len();
        out.push(CHARSET[idx] as char);
    }
    out
}

/// Computes the RFC 7636 S256 code challenge (`BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`).
pub fn code_challenge_s256(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(digest)
}

/// Builds the Spotify OAuth 2.0 PKCE authorization URL.
pub fn authorization_url(client_id: &str, redirect_uri: &str, challenge: &str, state: &str) -> String {
    let mut url = url::Url::parse(AUTHORIZE_URL).expect("valid authorize url");
    url.query_pairs_mut()
        .append_pair("client_id", client_id.trim())
        .append_pair("response_type", "code")
        .append_pair("redirect_uri", redirect_uri.trim())
        .append_pair("code_challenge_method", "S256")
        .append_pair("code_challenge", challenge.trim())
        .append_pair("state", state.trim())
        .append_pair("scope", SCOPES);
    url.to_string()
}

/// Extracts the authorization `code` from either a full callback URL (`http://127.0.0.1:43821/spotify/callback?code=...`)
/// or a raw pasted authorization code, verifying `expected_state` when the input is a URL.
pub fn parse_callback_code(input: &str, expected_state: Option<&str>) -> Result<String, Failure> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(Failure::Failed("Empty authorization code.".into()));
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") || trimmed.contains("code=") {
        let parsed = url::Url::parse(trimmed)
            .or_else(|_| {
                let query = trimmed.trim_start_matches('?');
                url::Url::parse(&format!("{REDIRECT_URI}?{query}"))
            })
            .map_err(|e| Failure::Failed(format!("Invalid callback URL: {e}")))?;

        let mut code = None;
        let mut state = None;
        let mut err = None;
        for (k, v) in parsed.query_pairs() {
            match k.as_ref() {
                "code" => code = Some(v.to_string()),
                "state" => state = Some(v.to_string()),
                "error" => err = Some(v.to_string()),
                _ => {}
            }
        }
        if let Some(e) = err {
            return Err(Failure::Failed(format!("Spotify authorization denied: {e}")));
        }
        if let (Some(exp), Some(got)) = (expected_state.filter(|s| !s.is_empty()), state.as_deref()) {
            if exp != got {
                return Err(Failure::Failed("Spotify OAuth state mismatch.".into()));
            }
        }
        return code.filter(|c| !c.is_empty()).ok_or_else(|| Failure::Failed("No code parameter in callback URL.".into()));
    }
    Ok(trimmed.to_string())
}

/// Parses a token endpoint JSON payload into a [`SpotifySession`].
pub fn parse_token_response(
    json: &Value,
    client_id: &str,
    fallback_refresh: Option<&str>,
    now_epoch: i64,
) -> Result<SpotifySession, Failure> {
    if let Some(err) = json.get("error").and_then(Value::as_str) {
        let desc = json.get("error_description").and_then(Value::as_str).unwrap_or(err);
        return Err(Failure::Failed(format!("Spotify token error: {desc}")));
    }
    let access_token = json.get("access_token").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or(Failure::NotSignedIn)?.to_string();
    let refresh_token = json.get("refresh_token").and_then(Value::as_str).or(fallback_refresh).unwrap_or("").to_string();
    let expires_in = json.get("expires_in").and_then(Value::as_i64).unwrap_or(3600);
    let scope = json.get("scope").and_then(Value::as_str).unwrap_or(SCOPES).to_string();
    Ok(SpotifySession {
        client_id: client_id.to_string(),
        access_token,
        refresh_token,
        expires_at: now_epoch + expires_in,
        scope,
        user_id: None,
        display_name: None,
    })
}

/// Starts a new PKCE sign-in flow for `client_id` and persists the pending verifier/state.
pub fn begin_pkce(client_id: &str, redirect_uri: Option<&str>) -> Result<SpotifyPendingAuth, Failure> {
    let cid = client_id.trim();
    if cid.is_empty() {
        return Err(Failure::Failed("Enter a Spotify Client ID first.".into()));
    }
    let redirect = redirect_uri.map(str::trim).filter(|s| !s.is_empty()).unwrap_or(REDIRECT_URI);
    let verifier = generate_code_verifier();
    let challenge = code_challenge_s256(&verifier);
    let state = uuid::Uuid::new_v4().simple().to_string();
    let authorize_url = authorization_url(cid, redirect, &challenge, &state);
    let pending = SpotifyPendingAuth { client_id: cid.to_string(), redirect_uri: redirect.to_string(), verifier, state, authorize_url };
    let mut cfg = SpotifyConfig::load();
    cfg.client_id = cid.to_string();
    cfg.redirect_uri = redirect.to_string();
    cfg.pending = Some(pending.clone());
    let _ = cfg.save();
    Ok(pending)
}

/// Waits on the local loopback redirect (`127.0.0.1:43821`) for the browser callback, returning the raw request path/query.
pub async fn await_loopback_callback(expected_state: String, timeout: std::time::Duration) -> Option<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:43821").await.ok()?;
    let accept_fut = async {
        let (mut socket, _) = listener.accept().await.ok()?;
        let mut buf = [0u8; 4096];
        let n = socket.read(&mut buf).await.ok()?;
        let req = String::from_utf8_lossy(&buf[..n]);
        let first_line = req.lines().next()?;
        let path = first_line.split_whitespace().nth(1)?;
        let full_url = format!("http://127.0.0.1:43821{path}");
        let code = parse_callback_code(&full_url, Some(&expected_state)).ok();
        let body = if code.is_some() {
            "<html><body style='font-family:system-ui;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><div style='text-align:center'><h2>Spotify connected to Nook</h2><p>You can close this browser tab and return to Nook.</p></div></body></html>"
        } else {
            "<html><body style='font-family:system-ui;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><div style='text-align:center'><h2>Spotify sign-in failed</h2><p>Return to Nook and try again.</p></div></body></html>"
        };
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = socket.write_all(resp.as_bytes()).await;
        code
    };
    tokio::time::timeout(timeout, accept_fut).await.ok().flatten()
}

/// Exchanges an authorization code (or callback URL) for a Spotify access & refresh token using PKCE.
pub async fn complete_pkce(callback_or_code: &str) -> Result<SpotifySession, Failure> {
    let mut cfg = SpotifyConfig::load();
    let pending = cfg.pending.clone().ok_or_else(|| Failure::Failed("No pending Spotify PKCE authorization found.".into()))?;
    let code = parse_callback_code(callback_or_code, Some(&pending.state))?;
    let form = [
        ("client_id", pending.client_id.as_str()),
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("redirect_uri", pending.redirect_uri.as_str()),
        ("code_verifier", pending.verifier.as_str()),
    ];
    let client = reqwest::Client::new();
    let resp = client
        .post(TOKEN_URL)
        .form(&form)
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| Failure::Failed(e.to_string()))?;
    let json: Value = resp.json().await.unwrap_or(Value::Null);
    let mut session = parse_token_response(&json, &pending.client_id, None, Utc::now().timestamp())?;
    if let Ok(me) = api_get_with_token(&session.access_token, "/me").await {
        session.user_id = music::user_id(&me);
        session.display_name = me.get("display_name").and_then(Value::as_str).map(str::to_string);
    }
    cfg.session = Some(session.clone());
    cfg.pending = None;
    let _ = cfg.save();
    Ok(session)
}

/// Refreshes an expired [`SpotifySession`] using its `refresh_token`.
pub async fn refresh_token(session: &SpotifySession) -> Result<SpotifySession, Failure> {
    if session.refresh_token.trim().is_empty() || session.client_id.trim().is_empty() {
        return Err(Failure::NotSignedIn);
    }
    let form =
        [("client_id", session.client_id.as_str()), ("grant_type", "refresh_token"), ("refresh_token", session.refresh_token.as_str())];
    let resp = reqwest::Client::new()
        .post(TOKEN_URL)
        .form(&form)
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| Failure::Failed(e.to_string()))?;
    let json: Value = resp.json().await.unwrap_or(Value::Null);
    let mut next = parse_token_response(&json, &session.client_id, Some(&session.refresh_token), Utc::now().timestamp())?;
    next.user_id = session.user_id.clone();
    next.display_name = session.display_name.clone();
    Ok(next)
}

/// Returns a valid, non-expired [`SpotifySession`], automatically refreshing and saving if needed.
pub async fn active_session() -> Result<SpotifySession, Failure> {
    let mut cfg = SpotifyConfig::load();
    let session = cfg.session.clone().ok_or(Failure::NotSignedIn)?;
    if !session.is_expired(Utc::now().timestamp()) {
        return Ok(session);
    }
    let refreshed = refresh_token(&session).await?;
    cfg.session = Some(refreshed.clone());
    let _ = cfg.save();
    Ok(refreshed)
}

/// Disconnects Spotify and removes stored tokens (`SV-31`).
pub fn disconnect() {
    let mut cfg = SpotifyConfig::load();
    cfg.session = None;
    cfg.pending = None;
    let _ = cfg.save();
}

// ── Low-Level HTTP Helpers ──

async fn api_get_with_token(token: &str, path_and_query: &str) -> Result<Value, Failure> {
    let url = if path_and_query.starts_with("http") { path_and_query.to_string() } else { format!("{API_BASE}{path_and_query}") };
    let resp = reqwest::Client::new()
        .get(&url)
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| Failure::Failed(e.to_string()))?;
    let status = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    if let Some(fail) = music::failure(status, &body) {
        return Err(fail);
    }
    Ok(serde_json::from_str(&body).unwrap_or(Value::Null))
}

async fn api_request(method: reqwest::Method, path_and_query: &str, body: Option<Value>) -> Result<Value, Failure> {
    let session = active_session().await?;
    let url = if path_and_query.starts_with("http") { path_and_query.to_string() } else { format!("{API_BASE}{path_and_query}") };
    let mut req =
        reqwest::Client::new().request(method, &url).bearer_auth(&session.access_token).timeout(std::time::Duration::from_secs(15));
    if let Some(json_body) = body {
        req = req.json(&json_body);
    }
    let resp = req.send().await.map_err(|e| Failure::Failed(e.to_string()))?;
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    if let Some(fail) = music::failure(status, &text) {
        return Err(fail);
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
}

// ── Pure JSON Parsers for Albums & Recent Plays ──

/// Parses albums from `GET /v1/search?type=track,album,playlist` (`SV-32`).
pub fn search_albums(v: &Value) -> Vec<MusicAlbum> {
    v.get("albums")
        .and_then(|a| a.get("items"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let uri = item.get("uri").and_then(Value::as_str)?;
                    let name = item.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
                    let artists: Vec<&str> = item
                        .get("artists")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|x| x.get("name").and_then(Value::as_str)).collect())
                        .unwrap_or_default();
                    let artwork_url = item
                        .get("images")
                        .and_then(Value::as_array)
                        .and_then(|imgs| imgs.first())
                        .and_then(|i| i.get("url").and_then(Value::as_str))
                        .map(str::to_string);
                    let release_year =
                        item.get("release_date").and_then(Value::as_str).and_then(|d| d.split('-').next()).unwrap_or("").to_string();
                    let total_tracks = item.get("total_tracks").and_then(Value::as_u64).unwrap_or(0) as u32;
                    Some(MusicAlbum {
                        id: uri.to_string(),
                        name: name.to_string(),
                        artist: artists.join(", "),
                        artwork_url,
                        release_year,
                        total_tracks,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Parses playlists from `GET /v1/search?type=track,album,playlist` (`SV-32`).
pub fn search_playlists(v: &Value, user_id: Option<&str>) -> Vec<MusicPlaylist> {
    v.get("playlists").map(|p| music::playlists(p, user_id)).unwrap_or_default()
}

/// Parses recent play items from `GET /v1/me/player/recently-played` into [`MusicPlay`] records (`SV-36`).
pub fn parse_recent_plays(v: &Value) -> Vec<MusicPlay> {
    v.get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|entry| {
                    let track_obj = entry.get("track")?;
                    let t = music::track(track_obj)?;
                    let played_str = entry.get("played_at").and_then(Value::as_str)?;
                    let played_at = DateTime::parse_from_rfc3339(played_str).ok()?.with_timezone(&Utc);
                    Some(MusicPlay {
                        id: t.id,
                        title: t.title,
                        artist: t.artist,
                        album: t.album,
                        app: "Spotify".into(),
                        artwork_url: t.artwork_url,
                        duration: t.duration,
                        listened: t.duration.max(30),
                        played_at,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

// ── High-Level Spotify Web API Operations (SV-32..SV-38) ──

/// Searches Spotify's catalog for tracks, albums, and playlists (`SV-32`).
pub async fn search_catalog(query: &str, limit: u32) -> SpotifySearchCatalog {
    let clean = query.trim();
    if clean.is_empty() {
        return SpotifySearchCatalog::default();
    }
    let session = match active_session().await {
        Ok(s) => s,
        Err(f) => return SpotifySearchCatalog { query: clean.to_string(), state: LoadState::from_failure(&f), ..Default::default() },
    };
    let encoded: String = url::form_urlencoded::byte_serialize(clean.as_bytes()).collect();
    let lim = limit.clamp(1, 50);
    let path = format!("/search?type=track,album,playlist&limit={lim}&q={encoded}");
    match api_get_with_token(&session.access_token, &path).await {
        Ok(v) => SpotifySearchCatalog {
            query: clean.to_string(),
            state: LoadState::Done,
            tracks: music::search_tracks(&v),
            albums: search_albums(&v),
            playlists: search_playlists(&v, session.user_id.as_deref()),
        },
        Err(f) => SpotifySearchCatalog { query: clean.to_string(), state: LoadState::from_failure(&f), ..Default::default() },
    }
}

/// Converts a catalog search into `MusicSearchResult` for track-focused callers.
pub fn to_track_search_result(catalog: &SpotifySearchCatalog) -> MusicSearchResult {
    MusicSearchResult { query: catalog.query.clone(), state: catalog.state.clone(), tracks: catalog.tracks.clone() }
}

/// Reads Spotify's live player queue (`GET /v1/me/player/queue`, `SV-33`).
pub async fn player_queue() -> Result<Vec<MusicTrack>, Failure> {
    let v = api_request(reqwest::Method::GET, "/me/player/queue", None).await?;
    Ok(music::queue_tracks(&v))
}

/// Adds a track or episode URI to Spotify's live player queue (`POST /v1/me/player/queue`, `SV-33`).
pub async fn add_to_player_queue(uri: &str) -> Result<(), Failure> {
    let encoded: String = url::form_urlencoded::byte_serialize(uri.trim().as_bytes()).collect();
    let _ = api_request(reqwest::Method::POST, &format!("/me/player/queue?uri={encoded}"), None).await?;
    Ok(())
}

/// Starts playback of a track/episode URI or an album/playlist context URI (`PUT /v1/me/player/play`, `SV-32..SV-34`).
pub async fn play_uri(uri: &str, context_uri: Option<&str>, device_id: Option<&str>) -> Result<(), Failure> {
    let target = uri.trim();
    if target.is_empty() && context_uri.is_none() {
        return Err(Failure::Failed("Nothing to play.".into()));
    }
    let query = device_id
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(|d| {
            let enc: String = url::form_urlencoded::byte_serialize(d.as_bytes()).collect();
            format!("?device_id={enc}")
        })
        .unwrap_or_default();

    let payload = if let Some(ctx) = context_uri.map(str::trim).filter(|c| !c.is_empty()) {
        if music::is_spotify_uri(target) {
            json!({ "context_uri": ctx, "offset": { "uri": target } })
        } else {
            json!({ "context_uri": ctx })
        }
    } else if music::is_spotify_uri(target) {
        json!({ "uris": [target] })
    } else {
        json!({ "context_uri": target })
    };

    let _ = api_request(reqwest::Method::PUT, &format!("/me/player/play{query}"), Some(payload)).await?;
    Ok(())
}

/// Lists the user's playlists (`GET /v1/me/playlists`, `SV-34`).
pub async fn user_playlists() -> Result<Vec<MusicPlaylist>, Failure> {
    let session = active_session().await?;
    let v = api_get_with_token(&session.access_token, "/me/playlists?limit=50").await?;
    Ok(music::playlists(&v, session.user_id.as_deref()))
}

fn normalize_playlist_id(uri_or_id: &str) -> Result<String, Failure> {
    let trimmed = uri_or_id.trim();
    if let Some(id) = music::playlist_id(trimmed) {
        return Ok(id.to_string());
    }
    if !trimmed.is_empty() && trimmed.len() <= 64 && trimmed.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Ok(trimmed.to_string());
    }
    Err(Failure::Failed("Invalid Spotify playlist ID.".into()))
}

/// Lists the tracks inside a playlist (`GET /v1/playlists/{id}/tracks`, `SV-34`).
pub async fn playlist_tracks(playlist_uri_or_id: &str) -> Result<Vec<MusicTrack>, Failure> {
    let id = normalize_playlist_id(playlist_uri_or_id)?;
    let v = api_request(reqwest::Method::GET, &format!("/playlists/{id}/tracks?limit=100"), None).await?;
    Ok(music::playlist_tracks(&v))
}

/// Creates a new Spotify playlist in the user's library (`POST /v1/me/playlists`, `SV-34`).
pub async fn create_playlist(name: &str, description: Option<&str>, public: bool) -> Result<MusicPlaylist, Failure> {
    let clean = name.trim();
    if clean.is_empty() {
        return Err(Failure::Failed("Playlist name cannot be empty.".into()));
    }
    let session = active_session().await?;
    let payload = json!({
        "name": clean,
        "description": description.unwrap_or(""),
        "public": public,
    });
    let v = api_request(reqwest::Method::POST, "/me/playlists", Some(payload)).await?;
    music::playlist(&v, session.user_id.as_deref()).ok_or_else(|| Failure::Failed("Could not parse created playlist.".into()))
}

/// Renames a Spotify playlist (`PUT /v1/playlists/{id}`, `SV-34`).
pub async fn rename_playlist(playlist_uri_or_id: &str, new_name: &str) -> Result<(), Failure> {
    let id = normalize_playlist_id(playlist_uri_or_id)?;
    let clean = new_name.trim();
    if clean.is_empty() {
        return Err(Failure::Failed("Playlist name cannot be empty.".into()));
    }
    let _ = api_request(reqwest::Method::PUT, &format!("/playlists/{id}"), Some(json!({ "name": clean }))).await?;
    Ok(())
}

/// Deletes / unfollows a Spotify playlist (`DELETE /v1/playlists/{id}/followers`, `SV-34`).
pub async fn delete_playlist(playlist_uri_or_id: &str) -> Result<(), Failure> {
    let id = normalize_playlist_id(playlist_uri_or_id)?;
    let _ = api_request(reqwest::Method::DELETE, &format!("/playlists/{id}/followers"), None).await?;
    Ok(())
}

/// Adds tracks to a Spotify playlist (`POST /v1/playlists/{id}/tracks`, `SV-34`).
pub async fn add_tracks_to_playlist(playlist_uri_or_id: &str, track_uris: &[String]) -> Result<(), Failure> {
    let id = normalize_playlist_id(playlist_uri_or_id)?;
    let uris: Vec<&str> = track_uris.iter().map(String::as_str).filter(|u| music::is_spotify_uri(u)).collect();
    if uris.is_empty() {
        return Err(Failure::Failed("No valid Spotify track URIs to add.".into()));
    }
    let _ = api_request(reqwest::Method::POST, &format!("/playlists/{id}/tracks"), Some(json!({ "uris": uris }))).await?;
    Ok(())
}

/// Removes tracks from a Spotify playlist (`DELETE /v1/playlists/{id}/tracks`, `SV-34`).
pub async fn remove_tracks_from_playlist(playlist_uri_or_id: &str, track_uris: &[String]) -> Result<(), Failure> {
    let id = normalize_playlist_id(playlist_uri_or_id)?;
    let tracks: Vec<Value> =
        track_uris.iter().map(String::as_str).filter(|u| music::is_spotify_uri(u)).map(|u| json!({ "uri": u })).collect();
    if tracks.is_empty() {
        return Err(Failure::Failed("No valid Spotify track URIs to remove.".into()));
    }
    let _ = api_request(reqwest::Method::DELETE, &format!("/playlists/{id}/tracks"), Some(json!({ "tracks": tracks }))).await?;
    Ok(())
}

/// Fetches the user's top tracks and top artists (`GET /v1/me/top/tracks` & `artists`, `SV-35`).
pub async fn top_stats(time_range: Option<&str>) -> Result<MusicPlayerStats, Failure> {
    let range = match time_range {
        Some("short_term" | "medium_term" | "long_term") => time_range.unwrap(),
        _ => "medium_term",
    };
    let tracks_val = api_request(reqwest::Method::GET, &format!("/me/top/tracks?time_range={range}&limit=20"), None).await?;
    let artists_val = api_request(reqwest::Method::GET, &format!("/me/top/artists?time_range={range}&limit=20"), None).await?;
    Ok(MusicPlayerStats { app: "Spotify".into(), tracks: music::top_tracks(&tracks_val), artists: music::top_artists(&artists_val) })
}

/// Fetches the user's recently played tracks from Spotify (`GET /v1/me/player/recently-played`, `SV-36`).
pub async fn recent_plays() -> Result<Vec<MusicPlay>, Failure> {
    let v = api_request(reqwest::Method::GET, "/me/player/recently-played?limit=50", None).await?;
    Ok(parse_recent_plays(&v))
}

/// Lists available Spotify Connect devices (`GET /v1/me/player/devices`, `SV-38`).
pub async fn connect_devices() -> Result<Vec<MusicOutput>, Failure> {
    let v = api_request(reqwest::Method::GET, "/me/player/devices", None).await?;
    let mut devices = music::spotify_devices(&v);
    music::sort_outputs(&mut devices);
    Ok(devices)
}

/// Transfers Spotify playback to `device_id` (`PUT /v1/me/player`, `SV-38`).
pub async fn select_connect_device(device_id: &str, play: bool) -> Result<(), Failure> {
    let clean = device_id.trim();
    if clean.is_empty() {
        return Err(Failure::Failed("No device ID specified.".into()));
    }
    let _ = api_request(reqwest::Method::PUT, "/me/player", Some(json!({ "device_ids": [clean], "play": play }))).await?;
    Ok(())
}

/// Merges local system audio outputs with Spotify Connect devices (`SV-38`), sorting active outputs first.
pub fn merge_outputs(local_endpoints: Vec<MusicOutput>, connect_devices: Vec<MusicOutput>) -> Vec<MusicOutput> {
    let mut combined = Vec::new();
    let any_connect_active = connect_devices.iter().any(|d| d.active);
    for mut local in local_endpoints {
        if any_connect_active {
            local.active = false;
        }
        combined.push(local);
    }
    for dev in connect_devices {
        if !combined.iter().any(|c| c.id == dev.id) {
            combined.push(dev);
        }
    }
    music::sort_outputs(&mut combined);
    combined
}

/// Default local audio output entry for the current computer when platform audio enumeration is combined with Spotify Connect.
pub fn local_computer_output(system_volume: Option<u8>) -> MusicOutput {
    let host = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "This Computer".into());
    MusicOutput { id: "local:default".into(), name: host, kind: OutputKind::Computer, active: true, volume: system_volume }
}

// ── BR-28: Brain Tools (`search_music` & `play_music`) ──

/// Brain tool definitions for `search_music` and `play_music` (`BR-28`).
pub fn brain_tools() -> Vec<LoopTool> {
    vec![
        LoopTool::read(
            "search_music",
            "Search Spotify and the user's music library/history for tracks, albums, and playlists.",
            json!({
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Song title, artist, album, or playlist to search for."
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of results to return (default 8)."
                    }
                },
                "required": ["query"]
            }),
            |args| async move {
                match execute_brain_tool("search_music", &args).await {
                    Some(Ok(text)) => Ok(text),
                    Some(Err(err)) => Err(crate::NookError::new(err)),
                    None => Ok(String::new()),
                }
            },
        )
        .in_source("music"),
        LoopTool::action(
            "play_music",
            "Play a track, album, or playlist on Spotify by URI or by searching for a query, or add a track to the queue.",
            json!({
                "type": "object",
                "properties": {
                    "uri": {
                        "type": "string",
                        "description": "Optional Spotify URI (spotify:track:..., spotify:album:..., spotify:playlist:...)."
                    },
                    "query": {
                        "type": "string",
                        "description": "Optional search query if no URI is known; Nook searches Spotify and plays the best match."
                    },
                    "queue": {
                        "type": "boolean",
                        "description": "If true, adds the track to Up Next instead of interrupting current playback."
                    },
                    "device_id": {
                        "type": "string",
                        "description": "Optional Spotify Connect device ID to play on."
                    }
                }
            }),
        )
        .in_source("music"),
    ]
}

/// Executes the `search_music` or `play_music` brain tool (`BR-28`).
pub async fn execute_brain_tool(name: &str, args: &Value) -> Option<Result<String, String>> {
    match name {
        "search_music" => {
            let query = args.get("query").and_then(Value::as_str).unwrap_or("").trim();
            if query.is_empty() {
                return Some(Err("Missing 'query' parameter for search_music.".into()));
            }
            let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(8) as u32;
            let catalog = search_catalog(query, limit).await;
            let mut lines = Vec::new();
            for t in catalog.tracks.iter().take(limit as usize) {
                lines.push(format!("Track: {} — {} ({}) [{}]", t.title, t.artist, t.album, t.id));
            }
            for a in catalog.albums.iter().take(4) {
                lines.push(format!("Album: {} — {} ({}) [{}]", a.name, a.artist, a.release_year, a.id));
            }
            for p in catalog.playlists.iter().take(4) {
                lines.push(format!("Playlist: {} ({} tracks) [{}]", p.name, p.track_count, p.id));
            }
            if lines.is_empty() {
                let history = super::music_history::MusicHistory::load();
                let lower = query.to_lowercase();
                for t in history
                    .recent
                    .tracks
                    .iter()
                    .filter(|t| t.title.to_lowercase().contains(&lower) || t.artist.to_lowercase().contains(&lower))
                    .take(limit as usize)
                {
                    lines.push(format!("Recent Track: {} — {} [{}]", t.title, t.artist, t.id));
                }
            }
            if lines.is_empty() {
                Some(Ok(format!("No tracks found for '{query}'. ({:?})", catalog.state)))
            } else {
                Some(Ok(lines.join("\n")))
            }
        }
        "play_music" => {
            let uri_arg = args.get("uri").and_then(Value::as_str).unwrap_or("").trim();
            let query_arg = args.get("query").and_then(Value::as_str).unwrap_or("").trim();
            let enqueue = args.get("queue").and_then(Value::as_bool).unwrap_or(false);
            let device_id = args.get("device_id").and_then(Value::as_str);

            let (resolved_uri, label) = if !uri_arg.is_empty() {
                (uri_arg.to_string(), uri_arg.to_string())
            } else if !query_arg.is_empty() {
                let catalog = search_catalog(query_arg, 5).await;
                if let Some(first) = catalog.tracks.first() {
                    (first.id.clone(), format!("{} — {}", first.title, first.artist))
                } else if let Some(pl) = catalog.playlists.first() {
                    (pl.id.clone(), pl.name.clone())
                } else if let Some(al) = catalog.albums.first() {
                    (al.id.clone(), format!("{} — {}", al.name, al.artist))
                } else {
                    return Some(Err(format!("Could not find '{query_arg}' on Spotify.")));
                }
            } else {
                return Some(Err("Provide either 'uri' or 'query' to play_music.".into()));
            };

            let res = if enqueue && music::is_spotify_uri(&resolved_uri) {
                add_to_player_queue(&resolved_uri).await.map(|()| format!("Queued {label}"))
            } else {
                play_uri(&resolved_uri, None, device_id).await.map(|()| format!("Playing {label}"))
            };
            Some(res.map_err(|e| e.to_string()))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc7636_test_vector() {
        // RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(code_challenge_s256(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        let generated = generate_code_verifier();
        assert_eq!(generated.len(), 64);
    }

    #[test]
    fn builds_authorize_url_and_parses_callback_code() {
        let url = authorization_url("client123", REDIRECT_URI, "chal_xyz", "state_abc");
        assert!(url.starts_with("https://accounts.spotify.com/authorize?"));
        assert!(url.contains("client_id=client123"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("code_challenge=chal_xyz"));
        assert!(url.contains("state=state_abc"));

        let cb = "http://127.0.0.1:43821/spotify/callback?code=AQB_test_code&state=state_abc";
        assert_eq!(parse_callback_code(cb, Some("state_abc")).unwrap(), "AQB_test_code");
        assert!(parse_callback_code(cb, Some("wrong_state")).is_err());
        assert_eq!(parse_callback_code("raw_code_123", Some("state_abc")).unwrap(), "raw_code_123");
    }

    #[test]
    fn parses_tokens_and_tracks_expiry() {
        let payload = json!({
            "access_token": "acc_1",
            "refresh_token": "ref_1",
            "expires_in": 3600,
            "scope": SCOPES
        });
        let session = parse_token_response(&payload, "cid", None, 1_000).unwrap();
        assert_eq!(session.access_token, "acc_1");
        assert_eq!(session.refresh_token, "ref_1");
        assert_eq!(session.expires_at, 4_600);
        assert!(!session.is_expired(2_000));
        assert!(session.is_expired(4_550));
        assert!(session.has_scope("user-read-playback-state playlist-modify-private"));
    }

    #[test]
    fn parses_albums_recent_plays_and_merges_outputs() {
        let search_json = json!({
            "albums": {
                "items": [{
                    "uri": "spotify:album:al1",
                    "name": "Random Access Memories",
                    "release_date": "2013-05-17",
                    "total_tracks": 13,
                    "artists": [{"name": "Daft Punk"}],
                    "images": [{"url": "https://img/ram.jpg", "width": 300}]
                }]
            }
        });
        let albums = search_albums(&search_json);
        assert_eq!(albums.len(), 1);
        assert_eq!(
            (albums[0].name.as_str(), albums[0].artist.as_str(), albums[0].release_year.as_str()),
            ("Random Access Memories", "Daft Punk", "2013")
        );

        let recent_json = json!({
            "items": [{
                "played_at": "2026-11-22T18:30:00Z",
                "track": {
                    "uri": "spotify:track:1111111111111111111111",
                    "name": "Veridis Quo",
                    "duration_ms": 345000,
                    "artists": [{"name": "Daft Punk"}],
                    "album": {"name": "Discovery"}
                }
            }]
        });
        let plays = parse_recent_plays(&recent_json);
        assert_eq!(plays.len(), 1);
        assert_eq!((plays[0].title.as_str(), plays[0].duration), ("Veridis Quo", 345));

        let local = vec![local_computer_output(Some(70))];
        let connect = vec![MusicOutput {
            id: "sp1".into(),
            name: "Living Room Sonos".into(),
            kind: OutputKind::Speaker,
            active: true,
            volume: Some(45),
        }];
        let merged = merge_outputs(local, connect);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].name, "Living Room Sonos");
        assert!(merged[0].active);
        assert!(!merged[1].active);
    }

    #[test]
    fn brain_tools_expose_search_and_play_music() {
        let tools = brain_tools();
        let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, vec!["search_music", "play_music"]);
    }
}
