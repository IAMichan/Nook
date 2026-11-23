//! GIFs to send from a chat without a file of your own (`Giphy` on the Mac): GIPHY's trending ones when the panel opens,
//! and a search. Nook ships with its own GIPHY API key; one of your own (developers.giphy.com), kept in the keychain,
//! takes its place. Only the search words and the key go to api.giphy.com, and files are only fetched from GIPHY itself.

use serde::Serialize;
use serde_json::Value;

/// The keychain account of your own GIPHY API key.
pub const KEY_ACCOUNT: &str = "chats.giphy.key";
/// Nook's own GIPHY API key (the Mac's; public in this repository, limited per hour for everyone together).
pub const BUILT_IN_KEY: &str = "xyhdXQHlDecswVxeKnPnt7Rlvh67lWSD";
pub const HOST: &str = "api.giphy.com";
/// How many GIFs one page holds.
pub const PAGE_SIZE: usize = 30;
/// The largest GIF file Nook fetches to send.
pub const MAX_BYTES: usize = 16 * 1024 * 1024;

/// One GIF: a small moving preview for the grid, and the file that is sent (an MP4 when GIPHY has one, as WhatsApp sends
/// a GIF, else the GIF itself).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Gif {
    pub id: String,
    pub title: String,
    pub preview: String,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub file: String,
}

/// Your own key when you added one, else Nook's.
pub fn key(own: Option<&str>) -> Option<String> {
    own.map(str::trim).filter(|k| !k.is_empty()).map(str::to_string).or_else(|| (!BUILT_IN_KEY.is_empty()).then(|| BUILT_IN_KEY.into()))
}

/// Trending GIFs when `query` is empty, else a search; `language` is a two-letter code for the search.
pub fn request(query: &str, key: &str, language: &str, offset: usize) -> String {
    let words: String = query.trim().chars().take(50).collect();
    let path = if words.is_empty() { "/v1/gifs/trending" } else { "/v1/gifs/search" };
    let mut items = vec![
        ("api_key", key.to_string()),
        ("limit", PAGE_SIZE.to_string()),
        ("offset", offset.to_string()),
        ("rating", "pg-13".to_string()),
    ];
    if !words.is_empty() {
        items.push(("q", words));
        items.push(("lang", language.to_string()));
    }
    crate::connectors::with_query(&format!("https://{HOST}{path}"), &items)
}

/// A file's address, only when it is GIPHY's own over HTTPS: an answer can never send Nook to fetch from elsewhere.
pub fn media(value: &Value) -> Option<String> {
    let url = url::Url::parse(value.as_str()?).ok()?;
    let host = url.host_str()?.to_lowercase();
    (url.scheme() == "https" && (host == "giphy.com" || host.ends_with(".giphy.com"))).then(|| url.to_string())
}

fn number(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))
}

/// The GIFs in an answer, in GIPHY's order; one without a usable preview or file is left out.
pub fn gifs(data: &[u8]) -> Vec<Gif> {
    let Ok(v) = serde_json::from_slice::<Value>(data) else { return vec![] };
    crate::connectors::list(&v["data"])
        .iter()
        .filter_map(|item| {
            let id = item["id"].as_str().filter(|i| !i.is_empty())?;
            let images = &item["images"];
            let small = if images["fixed_width_small"].is_object() { &images["fixed_width_small"] } else { &images["fixed_width"] };
            let preview = media(&small["url"])?;
            let mp4 = ["original", "fixed_height", "downsized_small"].iter().find_map(|r| media(&images[*r]["mp4"]));
            let file = mp4.or_else(|| media(&images["original"]["url"]))?;
            let (width, height) = (number(&small["width"]).filter(|w| *w > 0.0), number(&small["height"]).filter(|h| *h > 0.0));
            Some(Gif { id: id.into(), title: item["title"].as_str().unwrap_or("").into(), preview, width, height, file })
        })
        .collect()
}

/// Why GIPHY refused (a wrong key, too many requests), in its own words.
pub fn problem(data: &[u8]) -> Option<String> {
    let v: Value = serde_json::from_slice(data).ok()?;
    let text = v["meta"]["msg"].as_str().or(v["message"].as_str())?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// The name a GIF's file goes under, with its own extension.
pub fn file_name(file: &str) -> String {
    let ext = file.rsplit('/').next().and_then(|n| n.split('?').next()).and_then(|n| n.rsplit_once('.')).map(|(_, e)| e.to_lowercase());
    format!("GIF.{}", ext.filter(|e| e == "mp4" || e == "gif").unwrap_or_else(|| "mp4".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trending_or_search_with_the_key() {
        let trending = request("  ", "k", "nl", 0);
        assert!(trending.starts_with("https://api.giphy.com/v1/gifs/trending?") && !trending.contains("q="));
        let search = request("happy cat", "k", "nl", 30);
        assert!(search.contains("/v1/gifs/search") && search.contains("q=happy") && search.contains("lang=nl") && search.contains("offset=30"));
        assert_eq!(key(Some("  ")), Some(BUILT_IN_KEY.to_string()));
        assert_eq!(key(Some("mine")), Some("mine".to_string()));
    }

    #[test]
    fn only_giphys_own_files_are_kept() {
        let answer = br#"{"data":[
          {"id":"a","title":"Cat","images":{"fixed_width_small":{"url":"https://media2.giphy.com/a/100w.gif","width":"100","height":"80"},
            "original":{"url":"https://media2.giphy.com/a/giphy.gif","mp4":"https://media2.giphy.com/a/giphy.mp4"}}},
          {"id":"b","images":{"fixed_width":{"url":"https://evil.example/b.gif"},"original":{"url":"https://media.giphy.com/b.gif"}}},
          {"id":"c","images":{"fixed_width":{"url":"https://i.giphy.com/c.gif"},"original":{"url":"http://media.giphy.com/c.gif"}}}]}"#;
        let found = gifs(answer);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].file, "https://media2.giphy.com/a/giphy.mp4");
        assert_eq!((found[0].width, found[0].height), (Some(100.0), Some(80.0)));
        assert_eq!(file_name(&found[0].file), "GIF.mp4");
        assert_eq!(file_name("https://i.giphy.com/x/giphy.gif?cid=1"), "GIF.gif");
        assert_eq!(problem(br#"{"meta":{"msg":"Invalid authentication credentials"}}"#).as_deref(), Some("Invalid authentication credentials"));
    }
}
