//! Reading local images that an answer places on a line of its own (`AnswerImages` on the Mac).
//! Web images (`https://` / `http://localhost`) are loaded by the webview directly; local paths (`file://`,
//! `/…`, `~/…`, or relative to a session folder) are verified to be real images up to `BYTE_LIMIT` and returned
//! as `data:` URIs so the webview never needs broad filesystem access.

use std::path::{Path, PathBuf};

use base64::Engine as _;

/// Larger than this an answer image is not loaded (`AnswerImages.byteLimit` on the Mac).
pub const BYTE_LIMIT: usize = 20 * 1024 * 1024;

/// Resolves a local image `source` (optional `base` folder for relative paths), reads it if it is an
/// image within `BYTE_LIMIT`, and returns a `data:<mime>;base64,…` URI.
pub fn load_local(source: &str, base: Option<&str>) -> Option<String> {
    let path = resolve_path(source, base)?;
    let meta = std::fs::metadata(&path).ok()?;
    if !meta.is_file() || meta.len() as usize > BYTE_LIMIT {
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    if bytes.len() > BYTE_LIMIT {
        return None;
    }
    let mime = image_mime(&bytes, &path)?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Some(format!("data:{mime};base64,{encoded}"))
}

/// Resolves a local image reference (`file://`, `~/…`, absolute path, or relative to `base`).
/// Web URLs (`http://`, `https://`, `data:`, `blob:`) return `None`.
pub fn resolve_path(source: &str, base: Option<&str>) -> Option<PathBuf> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("data:") || lower.starts_with("blob:") {
        return None;
    }
    if lower.starts_with("file://") {
        let parsed = url::Url::parse(trimmed).ok()?;
        // Windows cannot turn a drive-less `file:///tmp/a.png` into a path; keep it rooted like on the Mac.
        return parsed.to_file_path().ok().or_else(|| {
            let decoded = percent_encoding::percent_decode_str(parsed.path()).decode_utf8().ok()?;
            Some(PathBuf::from(decoded.as_ref()))
        });
    }
    let decoded = percent_encoding::percent_decode_str(trimmed).decode_utf8().ok()?;
    let raw = decoded.as_ref();
    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        return Some(dirs::home_dir()?.join(rest));
    }
    let path = Path::new(raw);
    // A rooted path (`/tmp/a.png`, `\tmp\a.png`) is absolute even on Windows, where it lacks a drive letter.
    if path.is_absolute() || raw.starts_with('/') || raw.starts_with('\\') {
        return Some(path.to_path_buf());
    }
    // Windows drive-letter path (`C:\…` or `C:/…`) even when parsed generically.
    if raw.len() >= 3
        && raw.as_bytes()[0].is_ascii_alphabetic()
        && raw.as_bytes()[1] == b':'
        && (raw.as_bytes()[2] == b'\\' || raw.as_bytes()[2] == b'/')
    {
        return Some(PathBuf::from(raw));
    }
    let base = base?.trim();
    if base.is_empty() {
        return None;
    }
    Some(Path::new(base).join(path))
}

/// Identifies the image MIME type from magic bytes (or SVG markup for `.svg`).
pub fn image_mime(bytes: &[u8], path: &Path) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some("image/png");
    }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if bytes.starts_with(b"BM") && bytes.len() >= 26 {
        return Some("image/bmp");
    }
    if bytes.starts_with(&[0x00, 0x00, 0x01, 0x00]) {
        return Some("image/x-icon");
    }
    if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        return Some("image/tiff");
    }
    if path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("svg")) {
        let head = std::str::from_utf8(&bytes[..bytes.len().min(512)]).ok()?;
        let lower = head.to_ascii_lowercase();
        if lower.contains("<svg") {
            return Some("image/svg+xml");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_relative_absolute_tilde_and_file_urls() {
        assert_eq!(resolve_path("https://example.com/a.png", Some("/repo")), None);
        assert_eq!(resolve_path("shot.png", None), None);
        assert_eq!(resolve_path("./shot%201.png", Some("/repo")), Some(PathBuf::from("/repo/./shot 1.png")));
        assert_eq!(resolve_path("/tmp/a.png", None), Some(PathBuf::from("/tmp/a.png")));
        assert!(resolve_path("~/Desktop/a.png", None).is_some_and(|p| p.ends_with("Desktop/a.png")));
        assert_eq!(resolve_path("file:///tmp/a.png", None), Some(PathBuf::from("/tmp/a.png")));
    }

    #[test]
    fn loads_real_images_and_rejects_non_images() {
        let dir = std::env::temp_dir().join(format!("nook-answer-images-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = dir.join("ok.png");
        std::fs::write(&png, [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).unwrap();
        let text = dir.join("secret.txt");
        std::fs::write(&text, b"not an image").unwrap();

        let uri = load_local("ok.png", dir.to_str()).expect("png loads");
        assert!(uri.starts_with("data:image/png;base64,"));
        assert_eq!(load_local("secret.txt", dir.to_str()), None);
        assert_eq!(load_local("missing.png", dir.to_str()), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
