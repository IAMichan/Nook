//! Korte geluiden als een agent op je wacht, iets klaar is of misging. Eigen geluiden gaan voor: zet `attention`,
//! `done` of `error` (.wav, .mp3, .ogg, .m4a) in de map `Sounds` (`NookSound` op de Mac).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::paths;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NookSound {
    Attention,
    /// An agent asks for permission (an approval is waiting), as the Mac's `NookSound.permission`.
    Permission,
    Done,
    Error,
}

pub const EXTENSIONS: [&str; 6] = ["wav", "mp3", "ogg", "oga", "m4a", "flac"];

impl NookSound {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::Attention => "attention",
            Self::Permission => "permission",
            Self::Done => "done",
            Self::Error => "error",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "attention" => Some(Self::Attention),
            "permission" => Some(Self::Permission),
            "done" => Some(Self::Done),
            "error" => Some(Self::Error),
            _ => None,
        }
    }

    /// Het eigen geluid voor dit geluid, als de gebruiker er een neerzette.
    pub fn custom_file(self) -> Option<PathBuf> {
        custom_in(&folder(), self)
    }
}

/// De map met eigen geluiden.
pub fn folder() -> PathBuf {
    paths::support_directory().join("Sounds")
}

pub fn custom_in(dir: &std::path::Path, sound: NookSound) -> Option<PathBuf> {
    EXTENSIONS.iter().map(|ext| dir.join(format!("{}.{ext}", sound.file_name()))).find(|p| p.is_file())
}

/// The system's own sounds, which a moment can play instead of Nook's tone (the Mac's picker of macOS sounds): the
/// `.wav` files in `%WINDIR%\Media` on Windows, the `.aiff` files in `/System/Library/Sounds` on a Mac.
pub fn system_folder() -> Option<PathBuf> {
    if cfg!(windows) {
        let root = std::env::var_os("WINDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
        Some(root.join("Media"))
    } else if cfg!(target_os = "macos") {
        Some(PathBuf::from("/System/Library/Sounds"))
    } else {
        None
    }
}

/// The names of the system's sounds, sorted, without their extension.
pub fn system_sounds() -> Vec<String> {
    system_folder().map(|dir| system_sounds_in(&dir)).unwrap_or_default()
}

pub fn system_sounds_in(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && matches!(p.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref(), Some("wav" | "aiff")))
        .filter_map(|p| p.file_stem().and_then(|s| s.to_str()).map(String::from))
        .collect();
    names.sort_by_key(|n| n.to_lowercase());
    names.dedup();
    names
}

/// The file of a system sound by its name; only a name from the list, so a stored choice never reaches another folder.
pub fn system_file_in(dir: &std::path::Path, name: &str) -> Option<PathBuf> {
    if !system_sounds_in(dir).iter().any(|n| n == name) {
        return None;
    }
    ["wav", "aiff"].iter().map(|ext| dir.join(format!("{name}.{ext}"))).find(|p| p.is_file())
}

/// MIME-type voor de interface, die het geluid afspeelt.
pub fn mime(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() {
        Some("mp3") => "audio/mpeg",
        Some("ogg") | Some("oga") => "audio/ogg",
        Some("m4a") => "audio/mp4",
        Some("flac") => "audio/flac",
        Some("aiff") => "audio/aiff",
        _ => "audio/wav",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_custom_sound() {
        let dir = std::env::temp_dir().join(format!("nook-sounds-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(custom_in(&dir, NookSound::Done).is_none());
        std::fs::write(dir.join("done.mp3"), b"x").unwrap();
        let found = custom_in(&dir, NookSound::Done).unwrap();
        assert_eq!(mime(&found), "audio/mpeg");
        assert_eq!(NookSound::parse("error"), Some(NookSound::Error));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn lists_system_sounds_and_only_opens_those() {
        let dir = std::env::temp_dir().join(format!("nook-system-sounds-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("Windows Ding.wav"), b"x").unwrap();
        std::fs::write(dir.join("Alarm01.wav"), b"x").unwrap();
        std::fs::write(dir.join("notes.txt"), b"x").unwrap();
        assert_eq!(system_sounds_in(&dir), vec!["Alarm01".to_string(), "Windows Ding".to_string()]);
        assert!(system_file_in(&dir, "Windows Ding").is_some());
        assert!(system_file_in(&dir, "../notes").is_none());
        assert!(system_file_in(&dir, "notes").is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
