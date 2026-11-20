//! The file preview window (the Mac's `FilePreviewWindow`): a photo, PDF, video or sound file shown over Nook's window
//! (`components/FilePreview.svelte`), with "Open in app". Only files in your home folder, never hidden folders or app
//! data (`attachments::is_allowed`), and at most `LIMIT` bytes, as the interface gets them inline.

use base64::Engine;
use serde::Serialize;
use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;

use nook_core::i18n::tr;

/// The largest file shown inline (a longer video opens in its app).
pub const LIMIT: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PreviewKind {
    Image,
    Pdf,
    Video,
    Audio,
    Other,
}

/// What a file is, by its extension, and the media type the page needs.
pub fn kind_of(name: &str) -> (PreviewKind, &'static str) {
    let ext = name.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "png" => (PreviewKind::Image, "image/png"),
        "jpg" | "jpeg" => (PreviewKind::Image, "image/jpeg"),
        "gif" => (PreviewKind::Image, "image/gif"),
        "webp" => (PreviewKind::Image, "image/webp"),
        "bmp" => (PreviewKind::Image, "image/bmp"),
        "svg" => (PreviewKind::Image, "image/svg+xml"),
        "pdf" => (PreviewKind::Pdf, "application/pdf"),
        "mp4" | "m4v" => (PreviewKind::Video, "video/mp4"),
        "webm" => (PreviewKind::Video, "video/webm"),
        "mov" => (PreviewKind::Video, "video/quicktime"),
        "mp3" => (PreviewKind::Audio, "audio/mpeg"),
        "m4a" => (PreviewKind::Audio, "audio/mp4"),
        "wav" => (PreviewKind::Audio, "audio/wav"),
        "ogg" | "opus" => (PreviewKind::Audio, "audio/ogg"),
        _ => (PreviewKind::Other, "application/octet-stream"),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FilePreview {
    pub path: String,
    pub name: String,
    pub kind: PreviewKind,
    pub media_type: String,
    pub size: u64,
    /// The file itself, unless it is too large or not something the page can show.
    pub base64: Option<String>,
}

fn resolve(path: &str) -> Result<std::path::PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "No home folder".to_string())?;
    let raw = path.trim().trim_start_matches("file://");
    let path = match raw.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => std::path::PathBuf::from(raw),
    };
    if !path.is_file() {
        return Err(tr("Dit bestand bestaat niet meer.", "This file no longer exists.").into());
    }
    if !nook_core::attachments::is_allowed(&path, &home) {
        return Err(tr(
            "Nook leest alleen bestanden in je eigen map (niet in verborgen mappen of app-gegevens).",
            "Nook only reads files in your home folder (not in hidden folders or app data).",
        )
        .into());
    }
    Ok(path)
}

#[tauri::command]
pub async fn file_preview(path: String) -> Result<FilePreview, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let file = resolve(&path)?;
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        let (kind, media) = kind_of(&name);
        let base64 = if kind != PreviewKind::Other && size <= LIMIT {
            Some(base64::engine::general_purpose::STANDARD.encode(std::fs::read(&file).map_err(|e| e.to_string())?))
        } else {
            None
        };
        Ok(FilePreview { path: file.to_string_lossy().into_owned(), name, kind, media_type: media.into(), size, base64 })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// "Open in app": the file in the app Windows (or Linux) opens it with.
#[tauri::command]
pub fn file_open_in_app(app: AppHandle, path: String) -> Result<(), String> {
    let file = resolve(&path)?;
    app.opener().open_path(file.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_what_a_file_is() {
        assert_eq!(kind_of("Photo.JPG"), (PreviewKind::Image, "image/jpeg"));
        assert_eq!(kind_of("report.pdf").0, PreviewKind::Pdf);
        assert_eq!(kind_of("clip.mov").0, PreviewKind::Video);
        assert_eq!(kind_of("voice.opus").0, PreviewKind::Audio);
        assert_eq!(kind_of("notes").0, PreviewKind::Other);
    }
}
