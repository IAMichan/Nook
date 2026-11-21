//! Notice priority for incoming chat messages (`ChatNoticePriority` on the Mac, CH-64).
//!
//! Conservative on purpose:
//! - A direct question in a private chat (someone asks you something),
//! - A direct mention of you in a group that is otherwise quiet, or
//! - A direct reply to one of your messages in a group
//! raises priority so it can come through the pacer sooner and show a priority badge on the bar card.
//!
//! Priority NEVER bypasses user rules: a muted or hidden chat, an app switched off, quiet mode,
//! quiet hours, and "don't show" all still hold.

use serde::{Deserialize, Serialize};

use super::{ChatKind, InboxMessage, InboxThread};

/// Per-chat notification mode, matching macOS `ChatMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatNoticeMode {
    #[default]
    Automatic,
    Loud,
    Muted,
}

/// Priority tier of an incoming chat notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoticePriorityLevel {
    /// Normal message or ordinary group chatter.
    #[default]
    Normal,
    /// Worth surfacing sooner: private question, quiet-group mention, or reply-to-me.
    Elevated,
    /// Strong combination (e.g. direct mention + question, or urgent private question).
    Urgent,
}

impl NoticePriorityLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Elevated => "elevated",
            Self::Urgent => "urgent",
        }
    }
}

/// Why an incoming message earned priority.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PriorityReason {
    DirectMention,
    ReplyToMe,
    Question,
    UrgentCue,
}

impl PriorityReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DirectMention => "mention",
            Self::ReplyToMe => "replyToMe",
            Self::Question => "question",
            Self::UrgentCue => "urgent",
        }
    }
}

/// Scored notice priority for an incoming chat message.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoticeScore {
    /// 0..=100 relative importance score (higher = more urgent to surface first).
    pub score: u8,
    pub level: NoticePriorityLevel,
    /// Whether this notice raises above burst pacing (never bypasses mute / quiet hours / rules).
    pub raises: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasons: Vec<PriorityReason>,
}

impl NoticeScore {
    /// Primary reason to surface on a compact badge, highest signal first.
    pub fn primary_reason(&self) -> Option<PriorityReason> {
        for wanted in [
            PriorityReason::UrgentCue,
            PriorityReason::DirectMention,
            PriorityReason::ReplyToMe,
            PriorityReason::Question,
        ] {
            if self.reasons.contains(&wanted) {
                return Some(wanted);
            }
        }
        None
    }
}

/// Whether a message text asks a question (`TextKit.asksQuestion` on the Mac):
/// contains `?`, Spanish opening `¿`, or full-width `？` outside a URL query string.
pub fn asks_question(text: &str) -> bool {
    if text.contains(['¿', '？']) {
        return true;
    }
    if !text.contains('?') {
        return false;
    }
    text.split_whitespace().any(|token| {
        let trimmed = token.trim_matches(|c: char| matches!(c, '(' | ')' | '[' | ']' | '<' | '>' | '"' | '\''));
        let lower = trimmed.to_ascii_lowercase();
        let is_url = lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("www.");
        if is_url {
            // A trailing '?' after a URL (e.g. "https://example.com?") still asks a question; a query string does not.
            trimmed.ends_with('?') && !trimmed[..trimmed.len() - 1].contains('?')
        } else {
            token.contains('?')
        }
    })
}

/// Explicit urgency keywords across EN / NL / DE / FR / ES (whole-word match).
const URGENT_WORDS: &[&str] = &[
    "urgent",
    "asap",
    "emergency",
    "dringend",
    "spoed",
    "noodgeval",
    "notfall",
    "sofort",
    "urgente",
    "emergencia",
];

/// Whether a message carries an explicit urgency cue as a whole word.
pub fn has_urgent_cue(text: &str) -> bool {
    text.split(|c: char| !c.is_alphanumeric())
        .any(|word| !word.is_empty() && URGENT_WORDS.iter().any(|kw| word.eq_ignore_ascii_case(kw)))
}

/// Exact macOS `ChatNoticePriority.raises(kind:mentionsMe:asksQuestion:quietByKind:mode:)` rule:
/// - Muted chat never raises priority.
/// - Private (`Person`) chat raises on a question.
/// - Group (`Group`) chat raises on a direct mention when the group is otherwise quiet (`quiet_by_kind`).
/// - Status and Channel chats never raise priority.
pub fn raises(kind: ChatKind, mentions_me: bool, asks_question: bool, quiet_by_kind: bool, mode: ChatNoticeMode) -> bool {
    if mode == ChatNoticeMode::Muted {
        return false;
    }
    match kind {
        ChatKind::Person => asks_question,
        ChatKind::Group => mentions_me && quiet_by_kind,
        ChatKind::Status | ChatKind::Channel => false,
    }
}

/// Whether `message` directly replies to one of your own messages in `thread`.
pub fn is_reply_to_me(thread: &InboxThread, message: &InboxMessage) -> bool {
    let Some(reply_id) = message.reply_to.as_deref() else {
        return false;
    };
    thread.messages.iter().any(|m| m.id == reply_id && m.from_me)
}

/// Scores an incoming chat message across direct mention, reply-to-me, question, and urgency cues
/// while keeping normal group chatter low and strictly respecting mute / channel / status silence.
pub fn score_message(
    kind: ChatKind,
    text: &str,
    mentions_me: bool,
    replies_to_me: bool,
    quiet_by_kind: bool,
    mode: ChatNoticeMode,
) -> NoticeScore {
    if mode == ChatNoticeMode::Muted || matches!(kind, ChatKind::Status | ChatKind::Channel) {
        return NoticeScore::default();
    }

    let question = asks_question(text);
    let urgent_cue = has_urgent_cue(text);
    let mac_raises = raises(kind, mentions_me, question, quiet_by_kind, mode);

    let mut reasons = Vec::new();
    let mut score: u16 = match kind {
        ChatKind::Person => 10,
        ChatKind::Group => 0,
        ChatKind::Status | ChatKind::Channel => 0,
    };

    if mentions_me {
        reasons.push(PriorityReason::DirectMention);
        score += 50;
    }
    if replies_to_me {
        reasons.push(PriorityReason::ReplyToMe);
        score += 40;
    }
    if question {
        reasons.push(PriorityReason::Question);
        score += match kind {
            ChatKind::Person => 35,
            ChatKind::Group => 15,
            _ => 0,
        };
    }
    if urgent_cue {
        reasons.push(PriorityReason::UrgentCue);
        score += match kind {
            ChatKind::Person => 35,
            ChatKind::Group => 20,
            _ => 0,
        };
    }

    let capped = score.min(100) as u8;

    // Group chatter stays Normal unless you are directly addressed (quiet-group mention or direct reply-to-me).
    let elevated = mac_raises
        || (kind == ChatKind::Group && replies_to_me)
        || (kind == ChatKind::Person && (replies_to_me || urgent_cue));

    let level = if !elevated {
        NoticePriorityLevel::Normal
    } else if capped >= 65 {
        NoticePriorityLevel::Urgent
    } else {
        NoticePriorityLevel::Elevated
    };

    NoticeScore { score: capped, level, raises: elevated, reasons }
}

/// Evaluates notice priority for a specific message inside an [`InboxThread`].
/// Outgoing and deleted messages always score as `Normal` (0).
pub fn evaluate(thread: &InboxThread, message: &InboxMessage, quiet_by_kind: bool, mode: ChatNoticeMode) -> NoticeScore {
    if message.from_me || message.deleted {
        return NoticeScore::default();
    }
    let effective_mode = if thread.muted_in_app == Some(true) {
        ChatNoticeMode::Muted
    } else {
        mode
    };
    let reply_to_me = is_reply_to_me(thread, message);
    score_message(
        thread.notice_kind(),
        &message.text,
        message.mentions_me,
        reply_to_me,
        quiet_by_kind,
        effective_mode,
    )
}

/// Evaluates notice priority for the newest non-deleted incoming message in `thread`.
pub fn evaluate_latest(thread: &InboxThread, quiet_by_kind: bool, mode: ChatNoticeMode) -> NoticeScore {
    let Some(newest) = thread.messages.iter().rev().find(|m| m.is_incoming() && !m.deleted) else {
        return NoticeScore::default();
    };
    evaluate(thread, newest, quiet_by_kind, mode)
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    fn thread(kind: ChatKind) -> InboxThread {
        let mut t = InboxThread::new("slack#1", "slack", "Team");
        t.kind = Some(kind);
        t
    }

    #[test]
    fn macos_raises_parity_table() {
        // Private chat raises on questions, not on plain statements.
        assert!(raises(ChatKind::Person, false, true, false, ChatNoticeMode::Automatic));
        assert!(!raises(ChatKind::Person, false, false, false, ChatNoticeMode::Automatic));

        // Quiet group raises on direct mention, not on generic questions or loud groups.
        assert!(raises(ChatKind::Group, true, false, true, ChatNoticeMode::Automatic));
        assert!(!raises(ChatKind::Group, true, true, false, ChatNoticeMode::Automatic));
        assert!(!raises(ChatKind::Group, false, true, true, ChatNoticeMode::Automatic));

        // Muted chats, channels, and status updates never raise priority.
        assert!(!raises(ChatKind::Person, true, true, false, ChatNoticeMode::Muted));
        assert!(!raises(ChatKind::Group, true, true, true, ChatNoticeMode::Muted));
        assert!(!raises(ChatKind::Channel, true, true, true, ChatNoticeMode::Loud));
        assert!(!raises(ChatKind::Status, true, true, true, ChatNoticeMode::Loud));
    }

    #[test]
    fn asks_question_handles_unicode_and_urls() {
        assert!(asks_question("Kom je morgen?"));
        assert!(asks_question("¿Vienes mañana"));
        assert!(asks_question("明天来吗？"));
        assert!(!asks_question("See you tomorrow."));
        // Query strings in URLs should not falsely trigger question detection.
        assert!(!asks_question("Check https://example.com/search?q=nook&tab=1 please"));
        // A real question alongside a URL still counts.
        assert!(asks_question("Did you see https://example.com/search?q=nook ?"));
        assert!(asks_question("Is this it https://example.com?"));
    }

    #[test]
    fn scores_direct_mention_reply_to_me_question_and_urgent_vs_chatter() {
        let normal_group = score_message(ChatKind::Group, "Haha sounds good!", false, false, true, ChatNoticeMode::Automatic);
        assert_eq!(normal_group.level, NoticePriorityLevel::Normal);
        assert!(!normal_group.raises);
        assert_eq!(normal_group.score, 0);

        let group_general_q = score_message(ChatKind::Group, "Anyone grabbing coffee?", false, false, true, ChatNoticeMode::Automatic);
        assert_eq!(group_general_q.level, NoticePriorityLevel::Normal);
        assert!(!group_general_q.raises);
        assert!(group_general_q.reasons.contains(&PriorityReason::Question));

        let group_mention = score_message(ChatKind::Group, "@michan can you check this", true, false, true, ChatNoticeMode::Automatic);
        assert_eq!(group_mention.level, NoticePriorityLevel::Elevated);
        assert!(group_mention.raises);
        assert!(group_mention.score > group_general_q.score);
        assert_eq!(group_mention.primary_reason(), Some(PriorityReason::DirectMention));

        let group_mention_question = score_message(ChatKind::Group, "@michan can you deploy now?", true, false, true, ChatNoticeMode::Automatic);
        assert_eq!(group_mention_question.level, NoticePriorityLevel::Urgent);
        assert!(group_mention_question.raises);
        assert!(group_mention_question.score >= 65);

        let group_reply = score_message(ChatKind::Group, "Yes, I merged it.", false, true, true, ChatNoticeMode::Automatic);
        assert_eq!(group_reply.level, NoticePriorityLevel::Elevated);
        assert!(group_reply.raises);
        assert_eq!(group_reply.primary_reason(), Some(PriorityReason::ReplyToMe));

        let dm_plain = score_message(ChatKind::Person, "On my way", false, false, false, ChatNoticeMode::Automatic);
        assert_eq!(dm_plain.level, NoticePriorityLevel::Normal);
        assert!(!dm_plain.raises);

        let dm_question = score_message(ChatKind::Person, "Are you free at 3?", false, false, false, ChatNoticeMode::Automatic);
        assert_eq!(dm_question.level, NoticePriorityLevel::Elevated);
        assert!(dm_question.raises);
        assert_eq!(dm_question.primary_reason(), Some(PriorityReason::Question));

        let dm_urgent_q = score_message(ChatKind::Person, "Urgent: can you call me?", false, false, false, ChatNoticeMode::Automatic);
        assert_eq!(dm_urgent_q.level, NoticePriorityLevel::Urgent);
        assert!(dm_urgent_q.raises);
        assert_eq!(dm_urgent_q.primary_reason(), Some(PriorityReason::UrgentCue));
    }

    #[test]
    fn evaluate_detects_reply_to_my_message_and_respects_mute_and_outgoing() {
        let now = Utc::now();
        let mut t = thread(ChatKind::Group);
        t.messages.push(InboxMessage::new("mine-1", "Should we ship today?", now, true));
        let mut incoming = InboxMessage::new("theirs-1", "Yes, looks good to me", now, false);
        incoming.reply_to = Some("mine-1".into());
        t.messages.push(incoming.clone());

        let score = evaluate(&t, &incoming, true, ChatNoticeMode::Automatic);
        assert!(score.raises);
        assert_eq!(score.level, NoticePriorityLevel::Elevated);
        assert!(score.reasons.contains(&PriorityReason::ReplyToMe));

        // Muted thread suppresses priority completely.
        t.muted_in_app = Some(true);
        let muted = evaluate(&t, &incoming, true, ChatNoticeMode::Automatic);
        assert!(!muted.raises);
        assert_eq!(muted.score, 0);
        assert_eq!(muted.level, NoticePriorityLevel::Normal);

        // Outgoing messages never score as incoming priority.
        t.muted_in_app = Some(false);
        let mine = evaluate(&t, &t.messages[0], true, ChatNoticeMode::Automatic);
        assert!(!mine.raises);
        assert_eq!(mine.score, 0);
    }

    #[test]
    fn urgent_cue_requires_whole_word() {
        assert!(has_urgent_cue("This is URGENT!"));
        assert!(has_urgent_cue("Kun je dit met spoed bekijken"));
        assert!(has_urgent_cue("Need this ASAP"));
        assert!(!has_urgent_cue("The detergent is in the closet"));
    }

    #[test]
    fn evaluate_latest_scores_newest_non_deleted_incoming_message() {
        let now = Utc::now();
        let mut t = thread(ChatKind::Person);
        t.messages.push(InboxMessage::new("1", "Can we meet at 4?", now, false));
        let mut deleted = InboxMessage::new("2", "Ignored", now, false);
        deleted.deleted = true;
        t.messages.push(deleted);
        t.messages.push(InboxMessage::new("3", "Sure", now, true));

        let score = evaluate_latest(&t, false, ChatNoticeMode::Automatic);
        assert!(score.raises);
        assert_eq!(score.level, NoticePriorityLevel::Elevated);
        assert_eq!(score.primary_reason(), Some(PriorityReason::Question));
    }
}
