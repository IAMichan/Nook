//! What the brain's chat tools (`chat_inbox`, `chat_send`; `ChatInboxConnector` on the Mac) read from the shared inbox,
//! the same for every chat app: an overview of the recent chats, one chat's messages as a transcript, the messages of
//! every chat that hold some words, and which chat a name means. Messages are other people's words: the tools hand
//! them on as data, never as instructions.

use chrono::{DateTime, Local, Utc};

use super::{ChatInbox, ChatMedia, InboxMessage, InboxThread};
use crate::brain::text::fold;

/// How many messages of one chat `chat_inbox` reads by default, and at most.
pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 50;

/// A chat app's name as people say it.
pub fn app_name(app: &str) -> String {
    match app {
        "whatsapp" => "WhatsApp".into(),
        "telegram" => "Telegram".into(),
        "signal" => "Signal".into(),
        "messenger" => "Messenger".into(),
        "instagram" => "Instagram".into(),
        "x" | "twitter" => "X".into(),
        "linkedin" => "LinkedIn".into(),
        "slack" => "Slack".into(),
        "teams" => "Teams".into(),
        "discord" => "Discord".into(),
        "messages" | "imessage" => "Messages".into(),
        other => {
            let mut c = other.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

/// The app id a name means ("WhatsApp", "insta", "imessage"); the name itself, folded, when it is none Nook knows.
pub fn app_id(name: &str) -> String {
    match fold(name.trim()).as_str() {
        "insta" | "ig" => "instagram".into(),
        "imessage" | "sms" | "imessages" => "messages".into(),
        "twitter" => "x".into(),
        "fb" | "facebook" => "messenger".into(),
        "wa" => "whatsapp".into(),
        other => other.to_string(),
    }
}

/// The limit a call asks for, clamped to 1…[`MAX_LIMIT`]; [`DEFAULT_LIMIT`] when none or not a number.
pub fn clamp_limit(value: Option<f64>) -> usize {
    match value {
        Some(v) if v.is_finite() => (v.round().clamp(1.0, MAX_LIMIT as f64)) as usize,
        _ => DEFAULT_LIMIT,
    }
}

/// A message's words, or what it holds when it has none ("[photo]").
pub fn message_text(m: &InboxMessage) -> String {
    if m.deleted {
        return "[deleted]".into();
    }
    let text = m.text.trim();
    let media = match &m.media {
        ChatMedia::None => "",
        ChatMedia::Image => "[photo]",
        ChatMedia::Video => "[video]",
        ChatMedia::Audio => "[audio]",
        ChatMedia::Voice => "[voice message]",
        ChatMedia::Document { .. } => "[document]",
        ChatMedia::Sticker => "[sticker]",
        ChatMedia::Location => "[location]",
        ChatMedia::Contact => "[contact]",
        #[allow(unreachable_patterns)]
        _ => "[attachment]",
    };
    match (text.is_empty(), media.is_empty()) {
        (true, _) => media.to_string(),
        (false, true) => text.to_string(),
        (false, false) => format!("{media} {text}"),
    }
}

fn who(thread: &InboxThread, m: &InboxMessage) -> String {
    if m.from_me {
        "You".into()
    } else if m.sender.trim().is_empty() {
        thread.name.clone()
    } else {
        m.sender.clone()
    }
}

fn when(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%Y-%m-%d %H:%M").to_string()
}

/// One line per chat: app, name, unread count and its newest message.
pub fn overview(threads: &[&InboxThread], limit: usize) -> String {
    threads
        .iter()
        .take(limit)
        .map(|t| {
            let unread = if t.unread > 0 { format!(" · {} unread", t.unread) } else { String::new() };
            let last = t.messages.last().map(|m| format!(" · {} {}: {}", when(m.date), who(t, m), clip(&message_text(m), 120))).unwrap_or_default();
            let trust = t.trust();
            let warning = if trust.is_suspicious() { format!(" · {}", trust.marker()) } else { String::new() };
            format!("- {} · {}{unread}{last}{warning}", app_name(&t.app), t.name)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The newest `limit` messages of a chat, oldest first, "date Who: text".
pub fn transcript(thread: &InboxThread, limit: usize) -> String {
    let start = thread.messages.len().saturating_sub(limit);
    let lines: Vec<String> = thread.messages[start..].iter().map(|m| format!("{} {}: {}", when(m.date), who(thread, m), message_text(m))).collect();
    if lines.is_empty() {
        "(Nook has no messages of this chat yet.)".into()
    } else {
        lines.join("\n")
    }
}

/// What a chat is: its app, kind, members and unread count.
pub fn details(thread: &InboxThread) -> String {
    let mut parts = vec![];
    let trust = thread.trust();
    if trust.is_suspicious() {
        parts.push(trust.marker());
    }
    if let Some(members) = thread.members.as_ref().filter(|m| !m.is_empty()) {
        parts.push(format!("Group with {}", members.join(", ")));
    }
    if thread.unread > 0 {
        parts.push(format!("{} unread", thread.unread));
    }
    parts.join(" · ")
}

/// The messages of every chat that hold every word of the query, newest first, at most 30.
pub fn search(threads: &[&InboxThread], query: &str) -> String {
    let words: Vec<String> = fold(query).split_whitespace().map(str::to_string).collect();
    if words.is_empty() {
        return String::new();
    }
    let mut found: Vec<(DateTime<Utc>, String)> = vec![];
    for t in threads {
        for m in &t.messages {
            let text = fold(&message_text(m));
            if words.iter().all(|w| text.contains(w.as_str())) {
                found.push((m.date, format!("- {} · {} · {} {}: {}", app_name(&t.app), t.name, when(m.date), who(t, m), clip(&message_text(m), 300))));
            }
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().take(30).map(|(_, l)| l).collect::<Vec<_>>().join("\n")
}

fn clip(text: &str, n: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > n {
        format!("{}…", flat.chars().take(n - 1).collect::<String>())
    } else {
        flat
    }
}

/// Which chat a name means.
#[derive(Debug)]
pub enum Pick<'a> {
    One(&'a InboxThread),
    Several(Vec<&'a InboxThread>),
    None,
}

/// The chat `name` means among `threads` (its name exactly, then the chats whose name holds it; or its key), in `app`
/// when given. Two chats that fit are never guessed between.
pub fn pick<'a>(threads: &[&'a InboxThread], name: &str, app: Option<&str>) -> Pick<'a> {
    let wanted = fold(name.trim());
    if wanted.is_empty() {
        return Pick::None;
    }
    let pool: Vec<&InboxThread> = threads.iter().copied().filter(|t| app.is_none_or(|a| t.app == a)).collect();
    if let Some(t) = pool.iter().find(|t| t.id == name.trim() || t.chat_id.as_deref() == Some(name.trim())) {
        return Pick::One(t);
    }
    let exact: Vec<&InboxThread> = pool.iter().copied().filter(|t| fold(&t.name) == wanted || t.handle.as_deref().is_some_and(|h| fold(h) == wanted)).collect();
    let list = if exact.is_empty() { pool.iter().copied().filter(|t| fold(&t.name).contains(&wanted)).collect() } else { exact };
    match list.len() {
        0 => Pick::None,
        1 => Pick::One(list[0]),
        _ => Pick::Several(list),
    }
}

/// The question back when a name fits several chats.
pub fn which(name: &str, threads: &[&InboxThread]) -> String {
    let list = threads.iter().take(8).map(|t| format!("- {} · {} (id {})", app_name(&t.app), t.name, t.id)).collect::<Vec<_>>().join("\n");
    format!("\"{name}\" fits several chats. Name the app or give the id:\n{list}")
}

/// The chats a call may see, newest first: not those of an app kept on this device for this caller (`withheld`).
pub fn shown<'a>(inbox: &'a ChatInbox, withheld: &[String]) -> Vec<&'a InboxThread> {
    let now = Utc::now();
    inbox
        .sorted()
        .into_iter()
        .filter(|t| !withheld.contains(&t.app) && (!t.messages.is_empty() || ChatInbox::is_listed(t, now)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, app: &str, name: &str, messages: &[(&str, &str, bool)]) -> InboxThread {
        let mut t = InboxThread::new(id, app, name);
        t.messages = messages.iter().enumerate().map(|(i, (sender, text, mine))| {
            let mut m = InboxMessage::new(format!("{id}-{i}"), *text, Utc::now() - chrono::Duration::minutes(10 - i as i64), *mine);
            m.sender = (*sender).into();
            m
        }).collect();
        t
    }

    #[test]
    fn picks_a_chat_by_name_and_never_guesses() {
        let a = thread("telegram#1", "telegram", "Anna de Vries", &[("Anna", "See you Friday", false)]);
        let b = thread("whatsapp#2", "whatsapp", "Anna Bakker", &[("", "Thanks!", false)]);
        let c = thread("slack#3", "slack", "Team", &[("Tom", "Release on Friday?", false), ("", "Yes", true)]);
        let all = vec![&a, &b, &c];
        assert!(matches!(pick(&all, "anna de vries", None), Pick::One(t) if t.id == "telegram#1"));
        assert!(matches!(pick(&all, "anna", None), Pick::Several(list) if list.len() == 2));
        assert!(matches!(pick(&all, "anna", Some("whatsapp")), Pick::One(t) if t.id == "whatsapp#2"));
        assert!(matches!(pick(&all, "slack#3", None), Pick::One(_)));
        assert!(matches!(pick(&all, "nobody", None), Pick::None));
        assert!(which("anna", &[&a, &b]).contains("Telegram · Anna de Vries"));
    }

    #[test]
    fn reads_and_searches_every_app_alike() {
        let a = thread("telegram#1", "telegram", "Anna", &[("Anna", "See you Friday", false), ("", "Great", true)]);
        let c = thread("slack#3", "slack", "Team", &[("Tom", "Release on friday?", false)]);
        let found = search(&[&a, &c], "FRIDAY");
        assert_eq!(found.lines().count(), 2);
        assert!(found.contains("Slack · Team") && found.contains("Tom: Release on friday?"));
        let t = transcript(&a, 1);
        assert!(t.ends_with("You: Great") && !t.contains("See you"));
        assert!(overview(&[&a], 5).starts_with("- Telegram · Anna"));
        assert_eq!(clamp_limit(Some(500.0)), MAX_LIMIT);
        assert_eq!(clamp_limit(Some(f64::NAN)), DEFAULT_LIMIT);
        assert_eq!(clamp_limit(Some(0.0)), 1);
        assert_eq!(app_id("Insta"), "instagram");
    }
}
