//! What Nook's own file viewer shows and writes for a file (`FileViewing` on the Mac, AG-101): the text of a file with
//! `\n` breaks and how to write it back the way it was (encoding, byte order mark, Windows line breaks), so saving one
//! changed line leaves the rest of the file alone. A file that is not text, or too large, is shown by its app instead.

use std::path::Path;
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};

/// Larger files are not read as lines: thousands of colored rows would make the panel slow.
pub const LARGEST_TEXT: u64 = 2 * 1024 * 1024;

/// Files an app shows better than their bytes, whatever they contain.
const PREVIEW_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns", "pdf", "mov", "mp4", "m4v", "mp3", "m4a",
    "wav", "aiff", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "zip", "gz", "tar", "dmg",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum FileEncoding {
    #[default]
    Utf8,
    Utf16Le,
    Utf16Be,
    Latin1,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FileEditText {
    pub text: String,
    pub encoding: FileEncoding,
    pub byte_order_mark: bool,
    pub windows_breaks: bool,
    /// When the file was last written (ms since the epoch), to notice a change on disk before saving over it.
    pub modified: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileViewKind {
    Text,
    /// Not text (a picture, a PDF, an archive …) or too large to read as lines.
    Preview,
    Folder,
    Missing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileView {
    pub kind: FileViewKind,
    pub size: u64,
    pub file: Option<FileEditText>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "camelCase")]
pub enum FileSaveResult {
    /// Written; the file's new modification time.
    Saved {
        modified: Option<u64>,
    },
    /// Someone else wrote the file after it was opened: saving would overwrite that.
    ChangedOnDisk,
    Failed {
        reason: String,
    },
}

/// The text of a file that holds text, or `None` for bytes that are not text.
pub fn decode(data: &[u8], modified: Option<u64>) -> Option<FileEditText> {
    let mut file = FileEditText { modified, ..Default::default() };
    let text = if data.starts_with(&[0xFF, 0xFE]) || data.starts_with(&[0xFE, 0xFF]) {
        let little = data[0] == 0xFF;
        let units: Vec<u16> =
            data[2..].as_chunks::<2>().0.iter().map(|&c| if little { u16::from_le_bytes(c) } else { u16::from_be_bytes(c) }).collect();
        file.encoding = if little { FileEncoding::Utf16Le } else { FileEncoding::Utf16Be };
        file.byte_order_mark = true;
        String::from_utf16(&units).ok()?
    } else {
        // A zero byte in the first part never occurs in text: it is a binary file.
        if data.iter().take(8192).any(|b| *b == 0) {
            return None;
        }
        match std::str::from_utf8(data) {
            Ok(text) => {
                file.byte_order_mark = data.starts_with(&[0xEF, 0xBB, 0xBF]);
                text.strip_prefix('\u{FEFF}').unwrap_or(text).to_string()
            }
            Err(_) => {
                file.encoding = FileEncoding::Latin1;
                data.iter().map(|b| *b as char).collect()
            }
        }
    };
    file.windows_breaks = text.contains("\r\n");
    file.text = text.replace("\r\n", "\n");
    Some(file)
}

/// The bytes of `text` written the way `file` was. Text that no longer fits a Latin-1 file is written as UTF-8
/// rather than lost.
pub fn encode(text: &str, file: &FileEditText) -> Vec<u8> {
    let mut out = text.replace("\r\n", "\n");
    if file.windows_breaks {
        out = out.replace('\n', "\r\n");
    }
    match file.encoding {
        FileEncoding::Utf8 => {
            let mut bytes = if file.byte_order_mark { vec![0xEF, 0xBB, 0xBF] } else { vec![] };
            bytes.extend_from_slice(out.as_bytes());
            bytes
        }
        FileEncoding::Utf16Le | FileEncoding::Utf16Be => {
            let little = file.encoding == FileEncoding::Utf16Le;
            let mut bytes = vec![if little { 0xFF } else { 0xFE }, if little { 0xFE } else { 0xFF }];
            for unit in out.encode_utf16() {
                bytes.extend_from_slice(&if little { unit.to_le_bytes() } else { unit.to_be_bytes() });
            }
            bytes
        }
        FileEncoding::Latin1 => {
            if out.chars().all(|c| (c as u32) < 256) {
                out.chars().map(|c| c as u32 as u8).collect()
            } else {
                out.into_bytes()
            }
        }
    }
}

fn modified_ms(path: &Path) -> Option<u64> {
    let t = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(t.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64)
}

/// What the viewer shows for `path`.
pub fn read(path: &str) -> FileView {
    let p = Path::new(path);
    let Ok(meta) = std::fs::metadata(p) else { return FileView { kind: FileViewKind::Missing, size: 0, file: None } };
    if meta.is_dir() {
        return FileView { kind: FileViewKind::Folder, size: 0, file: None };
    }
    let size = meta.len();
    let preview = FileView { kind: FileViewKind::Preview, size, file: None };
    let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if PREVIEW_EXTENSIONS.contains(&ext.as_str()) || size > LARGEST_TEXT {
        return preview;
    }
    match std::fs::read(p).ok().and_then(|data| decode(&data, modified_ms(p))) {
        Some(file) => FileView { kind: FileViewKind::Text, size, file: Some(file) },
        None => preview,
    }
}

/// Writes the edited text over the file. In place, not through a temporary file, so the file keeps its permissions
/// and links. Unless `overwrite`, a file written by someone else since it was opened is left alone.
pub fn save(path: &str, text: &str, file: &FileEditText, overwrite: bool) -> FileSaveResult {
    let p = Path::new(path);
    if !overwrite {
        if let (Some(opened), Some(now)) = (file.modified, modified_ms(p)) {
            if now != opened {
                return FileSaveResult::ChangedOnDisk;
            }
        }
    }
    match std::fs::write(p, encode(text, file)) {
        Ok(()) => FileSaveResult::Saved { modified: modified_ms(p) },
        Err(e) => FileSaveResult::Failed { reason: e.to_string() },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_with_mark_and_windows_breaks_round_trips() {
        let data = b"\xEF\xBB\xBFone\r\ntwo\r\n";
        let f = decode(data, None).unwrap();
        assert!(f.byte_order_mark && f.windows_breaks);
        assert_eq!(f.text, "one\ntwo\n");
        assert_eq!(encode(&f.text, &f), data.to_vec());
    }

    #[test]
    fn utf16_both_orders_round_trip() {
        for little in [true, false] {
            let mut data = vec![if little { 0xFF } else { 0xFE }, if little { 0xFE } else { 0xFF }];
            for u in "héllo\n".encode_utf16() {
                data.extend_from_slice(&if little { u.to_le_bytes() } else { u.to_be_bytes() });
            }
            let f = decode(&data, None).unwrap();
            assert_eq!(f.text, "héllo\n");
            assert_eq!(encode(&f.text, &f), data);
        }
    }

    #[test]
    fn latin1_is_kept_and_widened_to_utf8_when_needed() {
        let f = decode(&[b'c', b'a', b'f', 0xE9], None).unwrap();
        assert_eq!(f.encoding, FileEncoding::Latin1);
        assert_eq!(f.text, "café");
        assert_eq!(encode("café", &f), vec![b'c', b'a', b'f', 0xE9]);
        assert_eq!(encode("日本", &f), "日本".as_bytes().to_vec());
    }

    #[test]
    fn binary_is_not_text() {
        assert!(decode(&[1, 2, 0, 3], None).is_none());
    }

    #[test]
    fn read_and_save_a_file_and_notice_a_change_on_disk() {
        let dir = std::env::temp_dir().join(format!("nook-fv-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.txt").to_string_lossy().into_owned();
        std::fs::write(&path, "x\r\ny\r\n").unwrap();
        let view = read(&path);
        assert_eq!(view.kind, FileViewKind::Text);
        let mut file = view.file.unwrap();
        assert_eq!(file.text, "x\ny\n");
        let saved = save(&path, "x\ny2\n", &file, false);
        assert!(matches!(saved, FileSaveResult::Saved { .. }));
        assert_eq!(std::fs::read(&path).unwrap(), b"x\r\ny2\r\n");
        // Someone else wrote it after we opened it.
        file.modified = Some(1);
        assert_eq!(save(&path, "z\n", &file, false), FileSaveResult::ChangedOnDisk);
        assert!(matches!(save(&path, "z\n", &file, true), FileSaveResult::Saved { .. }));
        assert_eq!(read(&dir.to_string_lossy()).kind, FileViewKind::Folder);
        assert_eq!(read(&format!("{path}.missing")).kind, FileViewKind::Missing);
        std::fs::write(dir.join("p.png"), b"x").unwrap();
        assert_eq!(read(&dir.join("p.png").to_string_lossy()).kind, FileViewKind::Preview);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
