//! Zoeken op het web en webpagina's lezen, voor elk brein (ook Ollama en LM Studio). Claude via de API heeft daarnaast
//! zijn eigen zoektool.
//!
//! Veiligheid: `read_webpage` opent alleen adressen die al eerder voorkwamen (in je vraag, op je scherm, in zoekresultaten).
//! Zo kan tekst op een webpagina het brein niet verleiden gegevens naar een willekeurig adres te sturen.

use std::collections::{HashSet, VecDeque};
use std::sync::Mutex;

use super::network_guard;
use crate::{NookError, Result};

/// Adressen die het brein mag openen.
#[derive(Default)]
pub struct KnownUrls {
    inner: Mutex<(VecDeque<String>, HashSet<String>)>,
}

impl KnownUrls {
    pub fn normalize(raw: &str) -> String {
        let mut text = raw.trim().to_string();
        if let Some(hash) = text.find('#') {
            text.truncate(hash);
        }
        while text.ends_with('/') {
            text.pop();
        }
        if text.to_lowercase().starts_with("http://") {
            text = format!("https://{}", &text[7..]);
        }
        text.to_lowercase()
    }

    pub fn remember(&self, raw: &str) {
        let key = Self::normalize(raw);
        if key.is_empty() {
            return;
        }
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let (order, set) = &mut *guard;
        if !set.insert(key.clone()) {
            return;
        }
        order.push_back(key);
        if order.len() > 3_000 {
            for _ in 0..1_000 {
                if let Some(old) = order.pop_front() {
                    set.remove(&old);
                }
            }
        }
    }

    /// Onthoudt de adressen in deze tekst, zodat het brein ze mag openen.
    pub fn note(&self, text: &str) {
        for m in rx!(r#"(?i)\bhttps?://[^\s<>"'\)\]]+"#).find_iter(text).flatten() {
            self.remember(m.as_str().trim_end_matches(['.', ',', ';', ':', '!', '?']));
        }
    }

    pub fn is_known(&self, raw: &str) -> bool {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).1.contains(&Self::normalize(raw))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchResult {
    pub title: String,
    pub url: String,
    pub snippet: String,
}

pub async fn search(query: &str) -> Result<Vec<SearchResult>> {
    let mut url = url::Url::parse("https://html.duckduckgo.com/html/").expect("vast adres");
    url.query_pairs_mut().append_pair("q", query).append_pair("kl", "nl-nl");
    let response = network_guard::client()
        .get(url)
        .send()
        .await
        .map_err(|_| NookError::new("Zoeken op het web lukte niet. Probeer het zo opnieuw."))?;
    if response.status().as_u16() != 200 {
        return Err(NookError::new("Zoeken op het web lukte niet. Probeer het zo opnieuw."));
    }
    Ok(parse_results(&response.text().await.unwrap_or_default()))
}

/// De HTML-pagina van DuckDuckGo: elk resultaat heeft een link met class "result__a" en een stukje met "result__snippet".
pub fn parse_results(html: &str) -> Vec<SearchResult> {
    let links: Vec<(String, String)> = rx!(r#"(?s)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#)
        .captures_iter(html)
        .flatten()
        .map(|c| (c[1].to_string(), c[2].to_string()))
        .collect();
    let snippets: Vec<String> =
        rx!(r#"(?s)<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#).captures_iter(html).flatten().map(|c| c[1].to_string()).collect();
    let mut results = vec![];
    for (index, (href, title)) in links.into_iter().enumerate() {
        let mut target = decode_entities(&href);
        if target.starts_with("//") {
            target = format!("https:{target}");
        }
        // Een omleiding van DuckDuckGo: het echte adres staat in uddg.
        if let Ok(parsed) = url::Url::parse(&target) {
            if parsed.host_str().is_some_and(|h| h.contains("duckduckgo.com")) {
                if let Some((_, real)) = parsed.query_pairs().find(|(k, _)| k == "uddg") {
                    target = real.to_string();
                }
            }
        }
        if !target.starts_with("http") || target.contains("duckduckgo.com/y.js") {
            continue;
        }
        results.push(SearchResult {
            title: plain(&title),
            url: target,
            snippet: snippets.get(index).map(|s| plain(s)).unwrap_or_default(),
        });
    }
    results
}

/// Leest een openbare pagina. De host en elke omleiding worden gecontroleerd.
pub async fn read(raw: &str) -> Result<String> {
    let response = network_guard::fetch(raw).await?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(NookError(format!("De pagina gaf status {status}.")));
    }
    let kind = response.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_lowercase();
    let bytes = response.bytes().await?;
    if bytes.len() >= 4_000_000 {
        return Err(NookError::new("Die pagina is te groot om te lezen."));
    }
    let raw = String::from_utf8_lossy(&bytes).to_string();
    let text = if kind.contains("html") || raw.contains("<html") { readable(&raw) } else { raw };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(NookError::new("Geen leesbare tekst gevonden op die pagina."));
    }
    Ok(trimmed.chars().take(14_000).collect())
}

/// HTML naar leesbare tekst: zonder scripts, stijlen en navigatie; blokken op hun eigen regel.
pub fn readable(html: &str) -> String {
    let mut text = html.to_string();
    for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form"] {
        let re = fancy_regex::Regex::new(&format!(r"(?is)<{tag}[^>]*>.*?</{tag}>")).expect("geldig patroon");
        text = re.replace_all(&text, " ").to_string();
    }
    text = rx!(r"(?s)<!--.*?-->").replace_all(&text, " ").to_string();
    text = rx!(r"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>").replace_all(&text, "\n").to_string();
    text = rx!(r"(?i)<li[^>]*>").replace_all(&text, "\n- ").to_string();
    text = plain(&text);
    text = rx!(r"[ \t]+").replace_all(&text, " ").to_string();
    rx!(r"\n\s*\n+").replace_all(&text, "\n\n").to_string()
}

pub fn plain(html: &str) -> String {
    decode_entities(&rx!(r"<[^>]+>").replace_all(html, "")).trim().to_string()
}

pub fn decode_entities(text: &str) -> String {
    let mut result = text.to_string();
    for (entity, value) in
        [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&apos;", "'")]
    {
        result = result.replace(entity, value);
    }
    rx!(r"&#(\d{2,6});")
        .replace_all(&result, |c: &fancy_regex::Captures| {
            c[1].parse::<u32>().ok().and_then(char::from_u32).map(String::from).unwrap_or_default()
        })
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_duckduckgo() {
        let html = r#"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fweer&amp;rut=x">Weer <b>Utrecht</b></a>
<a class="result__snippet" href="x">Zonnig &amp; 18 &#176;C</a>
<a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Advertentie</a>"#;
        let results = parse_results(html);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].url, "https://example.com/weer");
        assert_eq!(results[0].title, "Weer Utrecht");
        assert_eq!(results[0].snippet, "Zonnig & 18 °C");
    }

    #[test]
    fn readable_text_without_scripts() {
        let html = "<html><head><style>x{}</style><script>alert(1)</script></head><body><nav>menu</nav><h1>Titel</h1><p>Een &amp; twee</p><ul><li>a</li><li>b</li></ul></body></html>";
        let text = readable(html);
        assert!(text.contains("Titel") && text.contains("Een & twee") && text.contains("- a"));
        assert!(!text.contains("alert") && !text.contains("menu"));
    }

    #[test]
    fn only_known_urls() {
        let known = KnownUrls::default();
        known.note("Kijk op https://nook.app/docs/ en http://example.com/a#b.");
        assert!(known.is_known("https://nook.app/docs"));
        assert!(known.is_known("https://example.com/a"));
        assert!(!known.is_known("https://evil.example/steal"));
    }
}
