//! Pure helpers for Nook Chat's own browser tools (`read_nook_browser` and `open_in_nook_browser`): HTTPS validation
//! and formatting the open page for the brain.

use crate::brain::retrieval::reference_line;
use crate::i18n::tr;

/// Only `https://` URLs with a host may be opened in Nook's browser from Nook Chat.
pub fn https_url(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    let parsed = url::Url::parse(trimmed).ok();
    let ok = parsed.as_ref().is_some_and(|u| u.scheme() == "https" && u.host_str().is_some_and(|h| !h.is_empty()));
    if !ok {
        return Err(tr("Alleen https-links mogen.", "Only https addresses can be opened.").into());
    }
    Ok(parsed.expect("validated above").to_string())
}

/// Formats the page open in Nook's browser with its title, URL, text, and a source reference line for citations.
pub fn format_page(title: &str, url: &str, text: &str) -> String {
    format!("## {title}\nURL: {url}\n\n{text}\n\n{}", reference_line(title, Some(url), "Nook browser"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_addresses_with_a_host_are_allowed() {
        assert_eq!(https_url("  https://nook.app/docs  ").unwrap(), "https://nook.app/docs");
        for bad in ["", "   ", "http://nook.app", "file:///etc/passwd", "javascript:alert(1)", "https://", "https:// /path"] {
            assert!(https_url(bad).is_err(), "{bad} must be rejected");
        }
    }

    #[test]
    fn formats_page_with_source_reference() {
        let out = format_page("Docs", "https://nook.app/docs", "Hello world");
        assert!(out.starts_with("## Docs\nURL: https://nook.app/docs\n\nHello world\n\n"));
        assert!(out.contains("https://nook.app/docs"));
        assert!(out.contains("Nook browser"));
    }
}
