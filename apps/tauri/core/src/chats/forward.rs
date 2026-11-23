//! Forwarding a chat message to one or more target chats (`ChatForward.swift` on the Mac, CH-48).
//!
//! Pure core logic so forwarding rules (text trimming, captioned vs separate-text media kinds,
//! and capability filtering per target chat) are tested independently of any chat bridge.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::abilities::OutgoingKind;
use super::ChatMedia;

/// An attachment prepared for forwarding to a target chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForwardAttachment {
    pub file: PathBuf,
    pub kind: OutgoingKind,
    pub caption: String,
}

/// The payload produced for a target chat: an optional attachment (carrying the caption when
/// supported by its kind) and any follow-up text that must go separately.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForwardParts {
    pub attachment: Option<ForwardAttachment>,
    pub text: String,
}

/// A chat message on its way to another chat (`ChatForward` on the Mac): its file (when Nook
/// has it on disk) and its trimmed text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatForward {
    pub text: String,
    pub file: Option<PathBuf>,
    pub kind: Option<OutgoingKind>,
}

impl ChatForward {
    /// Builds a forwardable payload if there is text, a file, or both. Returns `None` when empty.
    pub fn new(text: &str, file: Option<PathBuf>, kind: Option<OutgoingKind>) -> Option<Self> {
        let trimmed = text.trim().to_string();
        if trimmed.is_empty() && file.is_none() {
            return None;
        }
        Some(Self { text: trimmed, file, kind })
    }

    /// Maps a [`ChatMedia`] variant to its corresponding [`OutgoingKind`], if sendable.
    pub fn outgoing_kind(media: &ChatMedia, file: Option<&PathBuf>) -> Option<OutgoingKind> {
        match media {
            ChatMedia::Image => Some(if is_gif(file) { OutgoingKind::Gif } else { OutgoingKind::Photo }),
            ChatMedia::Video => Some(OutgoingKind::Video),
            ChatMedia::Audio => Some(OutgoingKind::Audio),
            ChatMedia::Voice => Some(OutgoingKind::Voice),
            ChatMedia::Document { .. } => Some(OutgoingKind::File),
            ChatMedia::None | ChatMedia::Sticker | ChatMedia::Location | ChatMedia::Contact | ChatMedia::Other => None,
        }
    }

    /// Attachment kinds that carry a caption directly (their text goes as the caption rather than
    /// a second message after the file).
    pub fn is_captioned(kind: OutgoingKind) -> bool {
        matches!(kind, OutgoingKind::Photo | OutgoingKind::Video | OutgoingKind::Gif | OutgoingKind::File)
    }

    /// Infers an [`OutgoingKind`] from a file extension when `kind` was not provided explicitly.
    pub fn infer_kind(file: &Path) -> OutgoingKind {
        let ext = file.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).unwrap_or_default();
        match ext.as_str() {
            "gif" => OutgoingKind::Gif,
            "jpg" | "jpeg" | "png" | "webp" | "heic" | "bmp" => OutgoingKind::Photo,
            "mp4" | "mov" | "mkv" | "webm" | "avi" => OutgoingKind::Video,
            "ogg" | "oga" | "opus" => OutgoingKind::Voice,
            "mp3" | "m4a" | "wav" | "aac" | "flac" => OutgoingKind::Audio,
            _ => OutgoingKind::File,
        }
    }

    /// Computes what goes to a target chat accepting `sends` besides text.
    /// Returns `None` if this message carries a file that the target chat cannot accept.
    pub fn parts(&self, sends: &HashSet<OutgoingKind>) -> Option<ForwardParts> {
        let Some(file) = &self.file else {
            return Some(ForwardParts { attachment: None, text: self.text.clone() });
        };
        let kind = self.kind.unwrap_or_else(|| Self::infer_kind(file));
        if !sends.contains(&kind) {
            return None;
        }
        if Self::is_captioned(kind) && !self.text.is_empty() {
            Some(ForwardParts {
                attachment: Some(ForwardAttachment { file: file.clone(), kind, caption: self.text.clone() }),
                text: String::new(),
            })
        } else {
            Some(ForwardParts {
                attachment: Some(ForwardAttachment { file: file.clone(), kind, caption: String::new() }),
                text: self.text.clone(),
            })
        }
    }

    /// Whether a target chat accepting `sends` can receive this forwarded message.
    pub fn fits(&self, sends: &HashSet<OutgoingKind>) -> bool {
        self.parts(sends).is_some()
    }
}

fn is_gif(file: Option<&PathBuf>) -> bool {
    file.and_then(|p| p.extension()).and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("gif"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_message() {
        assert!(ChatForward::new("   \n\t ", None, None).is_none());
    }

    #[test]
    fn text_only_fits_every_writable_chat() {
        let fwd = ChatForward::new("  Hello world  ", None, None).unwrap();
        let none: HashSet<OutgoingKind> = HashSet::new();
        assert!(fwd.fits(&none));
        assert_eq!(fwd.parts(&none), Some(ForwardParts { attachment: None, text: "Hello world".into() }));
    }

    #[test]
    fn photo_takes_text_as_caption_while_voice_sends_text_separately() {
        let all: HashSet<OutgoingKind> = OutgoingKind::ALL.into_iter().collect();

        let photo = ChatForward::new("Look at this", Some(PathBuf::from("sunset.jpg")), None).unwrap();
        let parts = photo.parts(&all).unwrap();
        assert_eq!(parts.text, "");
        assert_eq!(parts.attachment.as_ref().unwrap().kind, OutgoingKind::Photo);
        assert_eq!(parts.attachment.as_ref().unwrap().caption, "Look at this");

        let voice = ChatForward::new("Transcript note", Some(PathBuf::from("note.ogg")), Some(OutgoingKind::Voice)).unwrap();
        let parts = voice.parts(&all).unwrap();
        assert_eq!(parts.text, "Transcript note");
        assert_eq!(parts.attachment.as_ref().unwrap().kind, OutgoingKind::Voice);
        assert_eq!(parts.attachment.as_ref().unwrap().caption, "");
    }

    #[test]
    fn rejects_target_that_cannot_take_attachment_kind() {
        let fwd = ChatForward::new("Video clip", Some(PathBuf::from("clip.mp4")), None).unwrap();
        let only_photos: HashSet<OutgoingKind> = [OutgoingKind::Photo].into_iter().collect();
        assert!(!fwd.fits(&only_photos));
        assert!(fwd.parts(&only_photos).is_none());
    }
}
