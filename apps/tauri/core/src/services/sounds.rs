//! Korte geluiden als een agent op je wacht, iets klaar is of misging. Eigen geluiden gaan voor: zet `attention`,
//! `done` of `error` (.wav, .mp3, .ogg, .m4a) in de map `Sounds` (`NookSound` op de Mac).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::paths;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NookSound {
    Attention,
    Done,
    Error,
}

pub const EXTENSIONS: [&str; 6] = ["wav", "mp3", "ogg", "oga", "m4a", "flac"];

impl NookSound {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::Attention => "attention",
            Self::Done => "done",
            Self::Error => "error",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "attention" => Some(Self::Attention),
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

/// MIME-type voor de interface, die het geluid afspeelt.
pub fn mime(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() {
        Some("mp3") => "audio/mpeg",
        Some("ogg") | Some("oga") => "audio/ogg",
        Some("m4a") => "audio/mp4",
        Some("flac") => "audio/flac",
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
}
