//! GIFs for the chat's "+" (`ChatGIFShelf`, `Giphy` on the Mac) and your own GIPHY key in Settings › Chat options. The
//! grid shows GIPHY's previews straight from GIPHY; the GIF you pick is fetched here (GIPHY's own files only, never
//! larger than [`giphy::MAX_BYTES`]) and handed to the page to go out like any file, for every chat app that takes one.

use base64::Engine;
use nook_core::chats::giphy;
use nook_core::i18n::tr;
use serde::Serialize;
use tauri::State;

use crate::connectors::Connectors;

type Res<T> = Result<T, String>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GifPage {
    gifs: Vec<giphy::Gif>,
    /// Why GIPHY gave nothing (a wrong key, its limit, no connection); `None` while it answers.
    problem: Option<String>,
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("Nook")
        // A redirect may only stay with GIPHY.
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let host = attempt.url().host_str().unwrap_or("").to_lowercase();
            if attempt.url().scheme() == "https" && (host == "giphy.com" || host.ends_with(".giphy.com")) && attempt.previous().len() < 5 {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .unwrap_or_default()
}

/// GIPHY's trending GIFs while nothing is typed, else the ones matching the words.
#[tauri::command]
pub async fn chat_gifs(c: State<'_, Connectors>, query: String, offset: Option<usize>) -> Res<GifPage> {
    let own = c.env.secrets.read(giphy::KEY_ACCOUNT);
    let Some(key) = giphy::key(own.as_deref()) else {
        return Ok(GifPage {
            gifs: vec![],
            problem: Some(tr("Voeg een GIPHY-sleutel toe om GIF's te zoeken.", "Add a GIPHY key to search GIFs.").into()),
        });
    };
    let url = giphy::request(&query, &key, nook_core::i18n::language(), offset.unwrap_or(0));
    let response = match client().get(&url).send().await {
        Ok(r) => r,
        Err(_) => return Ok(GifPage { gifs: vec![], problem: Some(tr("Geen verbinding met GIPHY.", "No connection to GIPHY.").into()) }),
    };
    let status = response.status().as_u16();
    let data = response.bytes().await.map_err(|e| e.to_string())?;
    if status != 200 {
        let why = giphy::problem(&data).unwrap_or_else(|| format!("HTTP {status}"));
        return Ok(GifPage {
            gifs: vec![],
            problem: Some(nook_core::i18n::trf("GIPHY gaf geen GIF's: {why}", "GIPHY gave no GIFs: {why}", &[("why", &why)])),
        });
    }
    let gifs = giphy::gifs(&data);
    let problem = gifs.is_empty().then(|| tr("Geen GIF's gevonden.", "No GIFs found.").to_string());
    Ok(GifPage { gifs, problem })
}

/// The file of the GIF you picked, to send.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GifFile {
    name: String,
    mime: String,
    base64: String,
}

#[tauri::command]
pub async fn chat_gif_file(file: String) -> Res<GifFile> {
    let not_sent = || tr("De GIF kon niet worden opgehaald.", "The GIF could not be fetched.").to_string();
    let url = giphy::media(&serde_json::Value::String(file.clone())).ok_or_else(not_sent)?;
    let response = client().get(&url).send().await.map_err(|_| not_sent())?;
    if !response.status().is_success() || response.content_length().is_some_and(|n| n as usize > giphy::MAX_BYTES) {
        return Err(not_sent());
    }
    let bytes = response.bytes().await.map_err(|_| not_sent())?;
    if bytes.len() > giphy::MAX_BYTES || bytes.is_empty() {
        return Err(not_sent());
    }
    let name = giphy::file_name(&url);
    let mime = if name.ends_with(".gif") { "image/gif" } else { "video/mp4" };
    Ok(GifFile { name, mime: mime.into(), base64: base64::engine::general_purpose::STANDARD.encode(&bytes) })
}

/// Whether you added a GIPHY key of your own.
#[tauri::command]
pub fn chat_giphy_key_set(c: State<'_, Connectors>) -> bool {
    c.env.secrets.read(giphy::KEY_ACCOUNT).is_some_and(|k| !k.trim().is_empty())
}

#[tauri::command]
pub fn chat_giphy_key_save(c: State<'_, Connectors>, key: String) -> Res<()> {
    let key = nook_core::secrets::clean_secret(&key);
    if key.is_empty() {
        return Err(tr("De GIPHY-sleutel kon niet bewaard worden", "The GIPHY key could not be saved").into());
    }
    c.env
        .secrets
        .write(giphy::KEY_ACCOUNT, &key)
        .map_err(|_| tr("De GIPHY-sleutel kon niet bewaard worden", "The GIPHY key could not be saved").to_string())
}

#[tauri::command]
pub fn chat_giphy_key_remove(c: State<'_, Connectors>) -> Res<()> {
    c.env.secrets.remove(giphy::KEY_ACCOUNT)
}
