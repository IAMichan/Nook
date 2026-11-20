//! What a link in a chat message shows (`ChatLinkPreview` on the Mac): a picture, a video or a sound the link points
//! at shows as itself; a page shows as a card with its picture, its site and its title. Nook fetches only public
//! addresses (never this computer or its network), without cookies, a little of each page, and nothing is kept on
//! disk.

use std::net::IpAddr;
use std::time::Duration;

use base64::Engine;
use serde::Serialize;

/// The most of a page Nook reads for its title and picture.
const PAGE_BYTES: usize = 512 * 1024;
/// The largest picture a card brings in.
const PICTURE_BYTES: usize = 3 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkKind {
    Image,
    Video,
    Audio,
    Page,
}

/// The first web address in a message's text, as the bubble shows its preview for it.
pub fn first_link(text: &str) -> Option<String> {
    text.split(|c: char| c.is_whitespace() || c == '<' || c == '>' || c == '"')
        .find(|w| w.starts_with("https://") || w.starts_with("http://"))
        .map(|w| w.trim_end_matches(['.', ',', ')', '!', '?', ';', ':', '\'']).to_string())
        .filter(|w| url::Url::parse(w).is_ok_and(|u| u.host_str().is_some_and(|h| h.contains('.'))))
}

/// What a link points at, by its file name (`ChatFormat.linkKind`).
pub fn link_kind(url: &str) -> LinkKind {
    let path = url::Url::parse(url).map(|u| u.path().to_lowercase()).unwrap_or_default();
    let ext = path.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    match ext {
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "heic" | "bmp" => LinkKind::Image,
        "mp4" | "mov" | "m4v" | "webm" => LinkKind::Video,
        "mp3" | "m4a" | "ogg" | "opus" | "wav" | "aac" => LinkKind::Audio,
        _ => LinkKind::Page,
    }
}

/// A page whose preview is a video (YouTube, Vimeo, TikTok, an Instagram reel): its card has a play mark.
pub fn is_video_page(url: &str) -> bool {
    let Ok(u) = url::Url::parse(url) else { return false };
    let host = u.host_str().unwrap_or("").to_lowercase();
    let path = u.path().to_lowercase();
    host.ends_with("youtube.com") || host == "youtu.be" || host.ends_with("vimeo.com") || host.ends_with("tiktok.com")
        || (host.ends_with("instagram.com") && path.starts_with("/reel"))
}

/// A page's title and picture from its head: Open Graph first, then Twitter's card, then `<title>`.
pub fn parse_meta(html: &str, base: &url::Url) -> (Option<String>, Option<String>) {
    let lower = html.to_lowercase();
    let head = &html[..lower.find("</head>").unwrap_or(html.len()).min(html.len())];
    let meta = |names: &[&str]| -> Option<String> {
        for tag in head.split('<').filter(|t| t.len() > 5 && t[..5].eq_ignore_ascii_case("meta ")) {
            let key = attr(tag, "property").or_else(|| attr(tag, "name")).unwrap_or_default().to_lowercase();
            if names.contains(&key.as_str()) {
                if let Some(content) = attr(tag, "content").filter(|c| !c.trim().is_empty()) {
                    return Some(unescape(content.trim()));
                }
            }
        }
        None
    };
    let title = meta(&["og:title", "twitter:title"]).or_else(|| {
        let start = lower.find("<title")?;
        let open = start + lower[start..].find('>')? + 1;
        let close = open + lower[open..].find("</title>")?;
        Some(unescape(html[open..close].trim())).filter(|t| !t.is_empty())
    });
    let image = meta(&["og:image", "og:image:url", "og:image:secure_url", "twitter:image"])
        .and_then(|i| base.join(&i).ok())
        .filter(|u| matches!(u.scheme(), "https" | "http"))
        .map(|u| u.to_string());
    (title.map(|t| t.chars().take(200).collect()), image)
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_lowercase();
    let mut from = 0;
    while let Some(i) = lower[from..].find(name) {
        let at = from + i;
        let before_ok = at == 0 || lower.as_bytes()[at - 1].is_ascii_whitespace();
        let rest = lower[at + name.len()..].trim_start();
        if before_ok && rest.starts_with('=') {
            let value_start = tag.len() - rest.len() + 1;
            let value = tag[value_start..].trim_start();
            let quote = value.chars().next()?;
            return Some(if quote == '"' || quote == '\'' {
                value[1..].split(quote).next().unwrap_or("").to_string()
            } else {
                value.split(|c: char| c.is_whitespace() || c == '>' || c == '/').next().unwrap_or("").to_string()
            });
        }
        from = at + name.len();
    }
    None
}

fn unescape(text: &str) -> String {
    text.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&#x27;", "'").replace("&lt;", "<").replace("&gt;", ">")
}

/// An address on the internet: not this computer, not its network, not a link-local or reserved one.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => !(v4.is_private() || v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() || v4.is_broadcast()
            || v4.is_documentation() || v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]) || v4.octets()[0] >= 224),
        IpAddr::V6(v6) => {
            let seg = v6.segments();
            !(v6.is_loopback() || v6.is_unspecified() || (seg[0] & 0xfe00) == 0xfc00 || (seg[0] & 0xffc0) == 0xfe80 || v6.is_multicast())
                && v6.to_ipv4_mapped().is_none_or(|m| is_public(IpAddr::V4(m)))
        }
    }
}

/// What a card shows.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preview {
    pub title: Option<String>,
    /// The picture as a data URL, ready for the bubble.
    pub image: Option<String>,
    pub video: bool,
}

async fn public(url: &url::Url) -> bool {
    let Some(host) = url.host_str() else { return false };
    let port = url.port_or_known_default().unwrap_or(443);
    match tokio::net::lookup_host((host, port)).await {
        Ok(addrs) => {
            let list: Vec<_> = addrs.collect();
            !list.is_empty() && list.iter().all(|a| is_public(a.ip()))
        }
        Err(_) => false,
    }
}

/// One address, redirects followed by hand so each address is checked before it is asked: its body (at most `limit`
/// bytes; a page is cut there, anything else larger is refused), its type and where it ended.
async fn get(client: &reqwest::Client, url: &url::Url, limit: usize) -> Option<(Vec<u8>, String, url::Url)> {
    let mut current = url.clone();
    for _ in 0..4 {
        if !matches!(current.scheme(), "https" | "http") || !public(&current).await {
            return None;
        }
        let mut response = client.get(current.clone()).send().await.ok()?;
        if response.status().is_redirection() {
            current = response.headers().get("location").and_then(|l| l.to_str().ok()).and_then(|l| current.join(l).ok())?;
            continue;
        }
        if !response.status().is_success() {
            return None;
        }
        let mime = response.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.ok()? {
            body.extend_from_slice(&chunk);
            if body.len() > limit {
                if mime.starts_with("text/html") {
                    body.truncate(limit);
                    break;
                }
                return None;
            }
        }
        return Some((body, mime, current));
    }
    None
}

/// Fetches a link's preview: a picture link as the picture, a page as its title and picture. `None` when it cannot.
pub async fn fetch(link: &str) -> Option<Preview> {
    let url = url::Url::parse(link).ok()?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .user_agent("Mozilla/5.0 (compatible; Nook link preview)")
        .build()
        .ok()?;
    let picture = |bytes: Vec<u8>, mime: String| {
        mime.starts_with("image/").then(|| format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
    };
    let limit = if link_kind(link) == LinkKind::Image { PICTURE_BYTES } else { PAGE_BYTES };
    let (body, mime, page) = get(&client, &url, limit).await?;
    if mime.starts_with("image/") {
        return Some(Preview { title: None, image: picture(body, mime), video: false });
    }
    let html = String::from_utf8_lossy(&body);
    let (title, image) = parse_meta(&html, &page);
    let image = match image.and_then(|i| url::Url::parse(&i).ok()) {
        Some(i) => get(&client, &i, PICTURE_BYTES).await.and_then(|(b, m, _)| picture(b, m)),
        None => None,
    };
    Some(Preview { title, image, video: is_video_page(link) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_link_of_a_message() {
        assert_eq!(first_link("look at https://example.com/a?b=1, nice").as_deref(), Some("https://example.com/a?b=1"));
        assert_eq!(first_link("(see http://nook.app/x.png)").as_deref(), Some("http://nook.app/x.png"));
        assert_eq!(first_link("no link, and https://localhost alone"), None);
        assert_eq!(link_kind("https://a.com/cat.JPG"), LinkKind::Image);
        assert_eq!(link_kind("https://a.com/page"), LinkKind::Page);
        assert!(is_video_page("https://www.youtube.com/watch?v=1"));
    }

    #[test]
    fn a_page_names_its_title_and_picture() {
        let base = url::Url::parse("https://shop.example/item/1").unwrap();
        let html = r#"<html><head><title>Fallback</title><meta property="og:title" content="Blue &amp; green chair">
            <meta content='/img/chair.jpg' property='og:image'></head><body><meta property="og:title" content="no"></body>"#;
        let (title, image) = parse_meta(html, &base);
        assert_eq!(title.as_deref(), Some("Blue & green chair"));
        assert_eq!(image.as_deref(), Some("https://shop.example/img/chair.jpg"));
        let (title, image) = parse_meta("<head><TITLE> Plain page </TITLE></head>", &base);
        assert_eq!((title.as_deref(), image), (Some("Plain page"), None));
    }

    #[test]
    fn only_the_internet_is_asked() {
        for private in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.1.1", "100.64.0.1", "::1", "fd00::1", "::ffff:192.168.0.1"] {
            assert!(!is_public(private.parse().unwrap()), "{private}");
        }
        assert!(is_public("93.184.216.34".parse().unwrap()));
        assert!(is_public("2606:4700::1".parse().unwrap()));
    }
}
