//! Chat messages from other apps' notifications (`ChatCapture`, `ChatNotice`, `CapturedNotification` on the Mac): for
//! the apps Nook has no bridge for (Discord, Google Chat, Viber, LINE…), and for the others while their bridge is not
//! linked. The system part (Windows' notification database, the Linux notification bus) lives in
//! `src-tauri/src/platform/*/notifications.rs`; it only hands over [`CapturedNotification`]s.

use chrono::{DateTime, Utc};
use serde::Serialize;

use super::apps::{self, MessagingApp, SpeakerInText};

/// One notification as the system kept it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapturedNotification {
    /// The system's own number for it, so none is read twice.
    pub record: i64,
    /// The program that sent it: a Windows AppUserModelID or a Linux app name.
    pub system_id: String,
    pub title: String,
    pub subtitle: String,
    pub body: String,
    pub date: DateTime<Utc>,
}

/// What a chat app's notification says: the chat, who wrote in it and what.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatNotice {
    pub app: String,
    pub chat: String,
    pub sender: String,
    pub text: String,
    pub date: DateTime<Utc>,
}

/// The mail apps: their notifications are mail, the chat is the person and the message its subject over its start.
const MAIL_APPS: [&str; 6] = ["mail", "outlook", "gmail", "spark", "protonmail", "custom.mail"];

/// The chat message in a notification, or `None` when it is from none of `apps` or holds no message. `web_app_name`
/// gives the name of a website installed as an app of its own, which says which chat app it is.
pub fn notice(n: &CapturedNotification, apps: &[MessagingApp], web_app_name: impl Fn(&str) -> Option<String>) -> Option<ChatNotice> {
    let from_browser = apps::is_browser(&n.system_id);
    let app = if let Some(own) = apps::by_system_id(&n.system_id, apps) {
        own
    } else if from_browser {
        apps::mentioned_in(&[&n.subtitle, &n.title, &n.body], apps)
            .or_else(|| web_app_name(&n.system_id).and_then(|name| apps::by_web_app_name(&name, apps)))?
    } else {
        return None;
    };
    if MAIL_APPS.contains(&app.id.as_str()) {
        return mail_notice(n, app, from_browser);
    }
    let mut title = unmarked(&n.title);
    // A browser puts the site in a field of its own; it says which app, not who.
    let mut subtitle = if from_browser && looks_like_site(&n.subtitle) { String::new() } else { unmarked(&n.subtitle) };
    let mut text = n.body.clone();
    if from_browser {
        title = without_app_suffix(&title, &app.name);
    }
    if is_blank(&text) {
        return None;
    }
    // The app's name as the title: the text starts with who wrote ("anna: see you").
    if title.is_empty() || title.eq_ignore_ascii_case(&app.name) {
        let (name, rest) = speaker(&text)?;
        title = name;
        text = rest;
    }
    // How this app writes its notifications; an app you added has the plain layout.
    let layout = apps::known(&app.id).map(|a| a.notice_layout).unwrap_or(app.notice_layout);
    if layout.slack_markup {
        title = slack_chat(&title);
        text = slack_clean(&text);
    }
    let speaker_first = match layout.speaker_in_text {
        SpeakerInText::Never => false,
        SpeakerInText::InChannels => title.starts_with('#'),
        SpeakerInText::Always => true,
    };
    if speaker_first && subtitle.is_empty() {
        if let Some((name, rest)) = speaker(&text).filter(|(name, _)| !name.eq_ignore_ascii_case(&title)) {
            subtitle = name;
            text = rest;
        }
    }
    // The WhatsApp app titles a group's message with who wrote it and puts the group in the subtitle.
    if layout.sender_in_title && !from_browser && !subtitle.is_empty() {
        std::mem::swap(&mut title, &mut subtitle);
    }
    // WhatsApp writes a group's message as "Anna @ Family".
    if subtitle.is_empty() && layout.sender_in_title {
        if let Some((who, group)) = title.split_once(" @ ") {
            subtitle = who.to_string();
            title = group.to_string();
        }
    }
    if subtitle.to_lowercase() == title.to_lowercase() {
        subtitle.clear();
    }
    Some(ChatNotice { app: app.id.clone(), chat: title, sender: subtitle, text, date: n.date })
}

fn without_app_suffix(title: &str, app: &str) -> String {
    let suffix = format!(" - {}", app.to_lowercase());
    if title.to_lowercase().ends_with(&suffix) {
        title[..title.len() - suffix.len()].to_string()
    } else {
        title.to_string()
    }
}

/// A mail app's notification: the title is who wrote, the subtitle (or the text's first line, in a browser) the
/// subject. The chat is the person, and the message its subject over the start of the text.
fn mail_notice(n: &CapturedNotification, app: &MessagingApp, from_browser: bool) -> Option<ChatNotice> {
    let mut title = unmarked(&n.title);
    if from_browser {
        title = without_app_suffix(&title, &app.name);
    }
    let mut subject = if from_browser && looks_like_site(&n.subtitle) { String::new() } else { unmarked(&n.subtitle) };
    let mut body = n.body.clone();
    if subject.is_empty() && from_browser {
        if let Some((first, rest)) = n.body.split_once('\n') {
            subject = first.to_string();
            body = rest.to_string();
        }
    }
    let text = mail_text(&subject, &body);
    if title.is_empty() || title.eq_ignore_ascii_case(&app.name) || is_blank(&text) {
        return None;
    }
    Some(ChatNotice { app: app.id.clone(), chat: title, sender: String::new(), text, date: n.date })
}

/// A mail as a chat message (`MailChatData.text`): the subject in bold over the start of the text, without what it
/// quotes.
pub fn mail_text(subject: &str, body: &str) -> String {
    let subject = subject.trim();
    let mut kept: Vec<&str> = vec![];
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('>') || is_quote_header(trimmed) {
            break;
        }
        if trimmed.is_empty() && kept.last().is_none_or(|l| l.is_empty()) {
            continue;
        }
        kept.push(trimmed);
    }
    while kept.last().is_some_and(|l| l.is_empty()) {
        kept.pop();
    }
    let start = kept.join("\n");
    match (subject.is_empty(), start.is_empty()) {
        (true, _) => start,
        (false, true) => format!("*{subject}*"),
        (false, false) => format!("*{subject}*\n{start}"),
    }
}

fn is_quote_header(line: &str) -> bool {
    let lower = line.to_lowercase();
    let headers = ["from: ", "van: ", "von: ", "de : ", "de: ", "-----original message", "-----oorspronkelijk bericht"];
    if headers.iter().any(|h| lower.starts_with(h)) {
        return true;
    }
    lower.ends_with(':') && [" wrote", " schreef", " schrieb", " a écrit", " escribió"].iter().any(|w| lower.contains(w))
}

/// The chat in a Slack notification's title: "#general" for "New message in #general", in the languages Slack writes.
pub fn slack_chat(title: &str) -> String {
    const PREFIXES: [&str; 10] = [
        "New message in ",
        "New message from ",
        "Nieuw bericht in ",
        "Nieuw bericht van ",
        "Neue Nachricht in ",
        "Neue Nachricht von ",
        "Nouveau message dans ",
        "Nouveau message de ",
        "Nuevo mensaje en ",
        "Nuevo mensaje de ",
    ];
    for prefix in PREFIXES {
        if title.to_lowercase().starts_with(&prefix.to_lowercase()) {
            let chat = title[prefix.len()..].trim();
            return if chat.is_empty() { title.to_string() } else { chat.to_string() };
        }
    }
    title.to_string()
}

/// Slack's markup as plain text (`SlackData.clean`): `<@U1|anna>` → "@anna", `<#C1|general>` → "#general",
/// `<!here>` → "@here", `<https://x|label>` → "label".
pub fn slack_clean(text: &str) -> String {
    let mut result = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('<') {
        let Some(close) = rest[open..].find('>').map(|c| open + c) else { break };
        result.push_str(&rest[..open]);
        let inner = &rest[open + 1..close];
        let (target, label) = match inner.split_once('|') {
            Some((t, l)) => (t, Some(l)),
            None => (inner, None),
        };
        if let Some(id) = target.strip_prefix('@') {
            result.push('@');
            result.push_str(label.unwrap_or(id));
        } else if let Some(channel) = target.strip_prefix('#') {
            result.push('#');
            result.push_str(label.unwrap_or(channel));
        } else if let Some(special) = target.strip_prefix('!') {
            match label {
                Some(l) => result.push_str(l),
                None => {
                    result.push('@');
                    result.push_str(special);
                }
            }
        } else {
            result.push_str(label.unwrap_or(target));
        }
        rest = &rest[close + 1..];
    }
    result.push_str(rest);
    result.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").trim().to_string()
}

/// "anna: see you" as ("anna", "see you"): a short name without a line break before the colon.
pub fn speaker(text: &str) -> Option<(String, String)> {
    let (name, rest) = text.split_once(':')?;
    let name = name.trim();
    let rest = rest.trim();
    (!name.is_empty() && name.chars().count() <= 40 && !name.contains('\n') && !name.contains("http") && !rest.is_empty())
        .then(|| (name.to_string(), rest.to_string()))
}

/// Invisible format marks (the bidirectional marks WhatsApp puts around names); the zero-width joiner of emoji stays.
fn is_format_mark(c: char) -> bool {
    matches!(c, '\u{200B}'..='\u{200C}' | '\u{200E}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}'
        | '\u{2066}'..='\u{206F}' | '\u{FEFF}' | '\u{00AD}' | '\u{061C}')
}

/// A name without the invisible marks an app puts around it: the same chat by any app's spelling of it.
pub fn unmarked(text: &str) -> String {
    if !text.chars().any(is_format_mark) {
        return text.to_string();
    }
    text.chars().filter(|c| !is_format_mark(*c)).collect::<String>().trim().to_string()
}

/// Only white space and invisible marks: nothing to show.
pub fn is_blank(text: &str) -> bool {
    text.chars().all(|c| c.is_whitespace() || c.is_control() || is_format_mark(c) || matches!(c, '\u{FE00}'..='\u{FE0F}'))
}

fn is_emoji(c: char) -> bool {
    let v = c as u32;
    (0x1F000..=0x1FAFF).contains(&v) || (0x2600..=0x27BF).contains(&v) || (0x2B00..=0x2BFF).contains(&v) || v == 0x2764
}

/// Someone's emoji on a message, as a notification says it ("Reacted 👍 to: “See you”", "Reageerde met 👍🏼 op Komt
/// goed"): the emoji, and the message's text when it quotes it (`None` for "your message").
pub fn reaction(text: &str) -> Option<(String, Option<String>)> {
    let plain = unmarked(text);
    let lower = plain.to_lowercase();
    let starts = ["reacted", "reageerde", "heeft gereageerd", "gereageerd", "a réagi", "reaccionó", "reacciono", "reagierte"]
        .iter()
        .any(|p| lower.starts_with(p))
        || (lower.starts_with("hat ") && lower.contains("reagiert"));
    if plain.chars().count() > 400 || !starts {
        return None;
    }
    let (index, first) = plain.char_indices().find(|(_, c)| is_emoji(*c))?;
    // The emoji with its skin tone and joined parts.
    let mut end = index + first.len_utf8();
    for c in plain[end..].chars() {
        let v = c as u32;
        if (0x1F3FB..=0x1F3FF).contains(&v) || c == '\u{200D}' || c == '\u{FE0F}' || (c == '\u{200D}' || is_emoji(c)) && plain[index..end].ends_with('\u{200D}') {
            end += c.len_utf8();
        } else {
            break;
        }
    }
    let emoji = plain[index..end].to_string();
    let mut rest = plain[end..].trim().to_string();
    for word in ["to", "op", "auf", "à", "a"] {
        let lower = rest.to_lowercase();
        if lower.starts_with(&format!("{word} ")) {
            rest = rest[word.len() + 1..].to_string();
            break;
        }
        if lower.starts_with(&format!("{word}:")) {
            rest = rest[word.len() + 1..].to_string();
            break;
        }
    }
    if rest.to_lowercase().ends_with(" reagiert") {
        rest.truncate(rest.len() - " reagiert".len());
    }
    let target = rest.trim_matches(|c: char| " :\"'“”„«»‘’‚".contains(c)).to_string();
    let generic = [
        "your message",
        "a message",
        "je bericht",
        "jouw bericht",
        "een bericht",
        "deine nachricht",
        "votre message",
        "ton message",
        "tu mensaje",
        "your story",
        "je verhaal",
    ];
    let quoted = (!target.is_empty() && !generic.contains(&target.to_lowercase().as_str())).then_some(target);
    Some((emoji, quoted))
}

/// A vote on a poll, as a notification says it: no message of its own, so it never moves its chat up. Only with the
/// poll named, so a message that talks about voting stays a message.
pub fn is_poll_vote(text: &str) -> bool {
    let plain = unmarked(text).to_lowercase();
    if plain.chars().count() > 400 {
        return false;
    }
    let voted = ["voted", "gestemd", "stemde", "abgestimmt", "a voté", "votó", "voto"].iter().any(|w| plain.contains(w));
    let poll = plain.starts_with('📊')
        || plain.contains(": 📊")
        || ["poll", "peiling", "umfrage", "sondage", "encuesta"].iter().any(|w| plain.contains(w));
    voted && poll
}

fn looks_like_site(text: &str) -> bool {
    !text.is_empty() && !text.contains(' ') && text.contains('.')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chats::apps::built_in;

    fn n(system_id: &str, title: &str, subtitle: &str, body: &str) -> CapturedNotification {
        CapturedNotification {
            record: 1,
            system_id: system_id.into(),
            title: title.into(),
            subtitle: subtitle.into(),
            body: body.into(),
            date: DateTime::<Utc>::from_timestamp(1_800_000_000, 0).unwrap(),
        }
    }

    fn get(n: &CapturedNotification) -> Option<(String, String, String, String)> {
        notice(n, &built_in(), |_| None).map(|c| (c.app, c.chat, c.sender, c.text))
    }

    fn t(app: &str, chat: &str, sender: &str, text: &str) -> Option<(String, String, String, String)> {
        Some((app.into(), chat.into(), sender.into(), text.into()))
    }

    #[test]
    fn each_app_by_its_own_layout() {
        let wa = "5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App";
        assert_eq!(get(&n(wa, "\u{200E}Anna", "", "Hoi")), t("whatsapp", "Anna", "", "Hoi"));
        assert_eq!(get(&n(wa, "Piet", "Familie", "Eten?")), t("whatsapp", "Familie", "Piet", "Eten?"), "sender in the title");
        assert_eq!(get(&n(wa, "Piet @ Familie", "", "Eten?")), t("whatsapp", "Familie", "Piet", "Eten?"));
        let slack = "com.squirrel.slack.slack";
        assert_eq!(
            get(&n(slack, "New message in #general", "", "GitHub: <https://x.y|PR 12> by <@U1|anna> &amp; co")),
            t("slack", "#general", "GitHub", "PR 12 by @anna & co")
        );
        assert_eq!(get(&n(slack, "New message from Anna", "", "lunch?")), t("slack", "Anna", "", "lunch?"));
        assert_eq!(get(&n("MSTeams_8wekyb3d8bbwe!MSTeams", "Project X", "", "Bo: done")), t("teams", "Project X", "Bo", "done"));
        assert_eq!(get(&n("com.squirrel.Discord.Discord", "Discord", "", "kai: gg")), t("discord", "kai", "", "gg"));
        assert_eq!(get(&n("Spotify", "Song", "", "Artist")), None, "not a chat app");
        assert_eq!(get(&n(wa, "Anna", "", "\u{200E} ")), None, "nothing to show");
    }

    #[test]
    fn browsers_say_which_app_by_its_site() {
        assert_eq!(get(&n("Chrome", "Anna - Instagram", "www.instagram.com", "hey")), t("instagram", "Anna", "", "hey"));
        assert_eq!(get(&n("MSEdge", "Kai", "chat.google.com", "ok")), t("googlechat", "Kai", "", "ok"));
        let web_app = notice(&n("Chrome._crx_abc", "Ann", "", "yo"), &built_in(), |_| Some("LinkedIn Messaging".into()));
        assert_eq!(web_app.map(|c| c.app), Some("linkedin".into()));
        assert_eq!(get(&n("Chrome", "Weather", "weather.com", "Rain")), None);
    }

    #[test]
    fn mail_is_its_subject_over_its_start() {
        assert_eq!(
            get(&n("Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows", "Anna Bel", "Lunch", "Friday?\n\nOn Mon Bo wrote:\n> old")),
            t("outlook", "Anna Bel", "", "*Lunch*\nFriday?")
        );
        assert_eq!(get(&n("Chrome", "Bo - Gmail", "mail.google.com", "Plans\nSee you")), t("gmail", "Bo", "", "*Plans*\nSee you"));
    }

    #[test]
    fn reactions_and_poll_votes() {
        assert_eq!(reaction("Reacted 👍 to: “See you”"), Some(("👍".into(), Some("See you".into()))));
        assert_eq!(reaction("Reageerde met 👍🏼 op je bericht"), Some(("👍🏼".into(), None)));
        assert_eq!(reaction("Hat mit ❤️ auf „Bis dann“ reagiert"), Some(("❤️".into(), Some("Bis dann".into()))));
        assert_eq!(reaction("I reacted badly 👍"), None);
        assert!(is_poll_vote("📊 Jan voted in the poll: Friday?"));
        assert!(is_poll_vote("Heeft gestemd in de peiling Etentje"));
        assert!(!is_poll_vote("Did you vote yet?"));
    }


    #[test]
    fn windows_toasts_and_their_database() {
        let xml = r#"<toast launch="x"><visual><binding template="ToastGeneric"><text>Anna &amp; Bo</text><text>Hoi</text><text>daar</text><text placement="attribution">web.whatsapp.com</text></binding></visual></toast>"#;
        assert_eq!(
            windows_db::toast(xml),
            Some(("Anna & Bo".into(), "web.whatsapp.com".into(), "Hoi\ndaar".into()))
        );
        assert_eq!(windows_db::toast("<toast/>"), None);
        let date = DateTime::<Utc>::from_timestamp(1_800_000_000, 0).unwrap();
        assert_eq!(windows_db::date(windows_db::filetime(date)), Some(date));
        // A database in the shape Windows keeps.
        let dir = std::env::temp_dir().join(format!("nook-wpn-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("wpndatabase.db");
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch(
            "CREATE TABLE NotificationHandler (RecordId INTEGER PRIMARY KEY, PrimaryId TEXT);
             CREATE TABLE Notification (Id INTEGER PRIMARY KEY, HandlerId INTEGER, Type TEXT, Payload BLOB, ArrivalTime INTEGER);
             INSERT INTO NotificationHandler VALUES (1, 'com.squirrel.Discord.Discord'), (2, 'Microsoft.Windows.Explorer');",
        )
        .unwrap();
        let toast = |t: &str, b: &str| format!("<toast><visual><binding><text>{t}</text><text>{b}</text></binding></visual></toast>");
        db.execute("INSERT INTO Notification VALUES (5, 1, 'toast', ?1, ?2)", rusqlite::params![toast("Kai", "gg").into_bytes(), windows_db::filetime(date)]).unwrap();
        db.execute("INSERT INTO Notification VALUES (6, 2, 'tile', ?1, ?2)", rusqlite::params![toast("x", "y").into_bytes(), windows_db::filetime(date)]).unwrap();
        db.execute("INSERT INTO Notification VALUES (7, 1, 'toast', ?1, ?2)", rusqlite::params![toast("Old", "z").into_bytes(), windows_db::filetime(date - chrono::Duration::days(30))]).unwrap();
        drop(db);
        let read = windows_db::read(&path, 0, date - chrono::Duration::days(14), 100).unwrap();
        assert_eq!(read.len(), 1);
        assert_eq!((read[0].record, read[0].system_id.as_str(), read[0].title.as_str()), (5, "com.squirrel.Discord.Discord", "Kai"));
        assert!(windows_db::read(&path, 5, date - chrono::Duration::days(14), 100).unwrap().is_empty());
        assert_eq!(windows_db::newest(&path).unwrap(), 7);
        let notice = notice(&read[0], &built_in(), |_| None).unwrap();
        assert_eq!((notice.app.as_str(), notice.chat.as_str(), notice.text.as_str()), ("discord", "Kai", "gg"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn linux_notify_calls_from_dbus_monitor() {
        let output = r#"signal time=1 sender=org.freedesktop.DBus -> destination=:1.1 serial=2 path=/org/freedesktop/DBus; interface=org.freedesktop.DBus; member=NameAcquired
   string ":1.1"
method call time=2 sender=:1.50 -> destination=:1.20 serial=7 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=Notify
   string "Telegram Desktop"
   uint32 0
   string ""
   string "Anna"
   string "see you
at 8"
   array [
   ]
   int32 -1
method call time=3 sender=:1.51 -> destination=:1.20 serial=8 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=GetServerInformation"#;
        let mut monitor = dbus::Monitor::default();
        let calls: Vec<_> = output.lines().filter_map(|l| monitor.line(l)).collect();
        assert_eq!(calls, vec![("Telegram Desktop".into(), "Anna".into(), "see you\nat 8".into())]);
    }

    #[test]
    fn small_parts() {
        assert_eq!(speaker("anna: see you"), Some(("anna".into(), "see you".into())));
        assert_eq!(speaker("see https://x.y: now"), None);
        assert_eq!(unmarked("\u{202A}Anna\u{202C}"), "Anna");
        assert_eq!(unmarked("👨‍👩‍👧"), "👨‍👩‍👧", "the joiner of an emoji stays");
        assert_eq!(slack_clean("<!here> hi <#C1>"), "@here hi #C1");
        assert_eq!(slack_chat("Nieuw bericht van Anna"), "Anna");
    }
}

/// Windows keeps the notifications it showed in `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db`, a
/// SQLite database the user can read: each toast's XML, the program that sent it (its AppUserModelID) and when it came.
pub mod windows_db {
    use std::path::{Path, PathBuf};

    use chrono::{DateTime, TimeZone, Utc};
    use rusqlite::{Connection, OpenFlags};

    use super::CapturedNotification;

    /// Where Windows keeps them, under the user's local app data.
    pub fn path(local_app_data: &Path) -> PathBuf {
        local_app_data.join("Microsoft").join("Windows").join("Notifications").join("wpndatabase.db")
    }

    pub const QUERY: &str = "SELECT n.Id, h.PrimaryId, n.Payload, n.ArrivalTime FROM Notification n \
        JOIN NotificationHandler h ON n.HandlerId = h.RecordId \
        WHERE n.Type = 'toast' AND n.Id > ?1 AND n.ArrivalTime >= ?2 ORDER BY n.Id LIMIT ?3";

    /// A Windows FILETIME (100 ns since 1601) as a date.
    pub fn date(filetime: i64) -> Option<DateTime<Utc>> {
        let unix_100ns = filetime.checked_sub(116_444_736_000_000_000)?;
        Utc.timestamp_opt(unix_100ns / 10_000_000, ((unix_100ns % 10_000_000) * 100) as u32).single()
    }

    pub fn filetime(date: DateTime<Utc>) -> i64 {
        date.timestamp() * 10_000_000 + i64::from(date.timestamp_subsec_nanos() / 100) + 116_444_736_000_000_000
    }

    /// A toast's texts as title, subtitle and body: the first text is the title, the others the body; a browser
    /// writes the site as the attribution text, which becomes the subtitle (where the Mac's browsers put it).
    pub fn toast(xml: &str) -> Option<(String, String, String)> {
        use quick_xml::events::Event;
        let mut reader = quick_xml::Reader::from_str(xml);
        let mut texts: Vec<String> = vec![];
        let mut attribution = String::new();
        let mut current: Option<(bool, String)> = None;
        loop {
            match reader.read_event() {
                Ok(Event::Start(e)) if e.name().as_ref() == "text" => {
                    let is_attribution = e.attributes().flatten().any(|a| {
                        a.key.as_ref() == "placement" && a.normalized_value(quick_xml::XmlVersion::Implicit1_0).is_ok_and(|v| v == "attribution")
                    });
                    current = Some((is_attribution, String::new()));
                }
                Ok(Event::Text(t)) => {
                    if let Some((_, text)) = current.as_mut() {
                        text.push_str(&t.xml10_content());
                    }
                }
                Ok(Event::GeneralRef(r)) => {
                    if let Some((_, text)) = current.as_mut() {
                        if let Ok(Some(c)) = r.resolve_char_ref() {
                            text.push(c);
                            continue;
                        }
                        text.push_str(match r.xml10_content().as_ref() {
                            "amp" => "&",
                            "lt" => "<",
                            "gt" => ">",
                            "quot" => "\"",
                            "apos" => "'",
                            _ => "",
                        });
                    }
                }
                Ok(Event::End(e)) if e.name().as_ref() == "text" => {
                    if let Some((is_attribution, text)) = current.take() {
                        if is_attribution {
                            attribution = text.trim().to_string();
                        } else {
                            texts.push(text.trim().to_string());
                        }
                    }
                }
                Ok(Event::Eof) => break,
                Err(_) => return None,
                _ => {}
            }
        }
        let mut texts = texts.into_iter().filter(|t| !t.is_empty());
        let title = texts.next()?;
        let body = texts.collect::<Vec<_>>().join("\n");
        Some((title, attribution, body))
    }

    /// The toasts after record `after`, no older than `since`, at most `limit`, oldest first. The database is opened
    /// read-only: Windows owns it.
    pub fn read(path: &Path, after: i64, since: DateTime<Utc>, limit: usize) -> rusqlite::Result<Vec<CapturedNotification>> {
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        db.busy_timeout(std::time::Duration::from_millis(500))?;
        let mut statement = db.prepare(QUERY)?;
        let rows = statement.query_map(rusqlite::params![after, filetime(since), limit as i64], |row| {
            let payload: Vec<u8> = match row.get_ref(2)? {
                rusqlite::types::ValueRef::Blob(b) => b.to_vec(),
                rusqlite::types::ValueRef::Text(t) => t.to_vec(),
                _ => vec![],
            };
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, payload, row.get::<_, i64>(3)?))
        })?;
        Ok(rows
            .flatten()
            .filter_map(|(record, system_id, payload, arrival)| {
                let (title, subtitle, body) = toast(&String::from_utf8_lossy(&payload))?;
                Some(CapturedNotification { record, system_id, title, subtitle, body, date: date(arrival)? })
            })
            .collect())
    }

    /// The newest record there is, to start from on a later look.
    pub fn newest(path: &Path) -> rusqlite::Result<i64> {
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        db.query_row("SELECT coalesce(max(Id), 0) FROM Notification", [], |r| r.get(0))
    }
}

/// The Linux notification bus: `dbus-monitor` prints every `Notify` call, and this reads them. Linux keeps no history,
/// so only what comes while Nook runs is read.
pub mod dbus {
    /// What `dbus-monitor` is asked to print.
    pub const MATCH: &str = "interface='org.freedesktop.Notifications',member='Notify'";

    /// Reads `dbus-monitor` output line by line: a `Notify` call's app name, summary and body.
    #[derive(Default)]
    pub struct Monitor {
        in_call: bool,
        values: Vec<String>,
        open: Option<String>,
    }

    impl Monitor {
        /// One line of output; a whole call once its body is read: (app name, summary, body).
        pub fn line(&mut self, line: &str) -> Option<(String, String, String)> {
            if let Some(open) = self.open.as_mut() {
                // A string that runs over several lines ends with its closing quote.
                if let Some(end) = line.strip_suffix('"') {
                    open.push('\n');
                    open.push_str(end);
                    let value = self.open.take().unwrap_or_default();
                    return self.push(value);
                }
                open.push('\n');
                open.push_str(line);
                return None;
            }
            if line.starts_with("method call") {
                self.in_call = line.contains("member=Notify");
                self.values.clear();
                return None;
            }
            if !self.in_call {
                return None;
            }
            let trimmed = line.trim_start();
            if let Some(rest) = trimmed.strip_prefix("string \"") {
                return match rest.strip_suffix('"') {
                    Some(value) => self.push(value.to_string()),
                    None => {
                        self.open = Some(rest.to_string());
                        None
                    }
                };
            }
            if trimmed.starts_with("uint32 ") && self.values.len() == 1 {
                // replaces_id: kept in its place so the strings after it count right.
                self.values.push(String::new());
            }
            None
        }

        fn push(&mut self, value: String) -> Option<(String, String, String)> {
            self.values.push(value);
            // app_name, replaces_id, app_icon, summary, body
            if self.values.len() == 5 {
                self.in_call = false;
                let v = std::mem::take(&mut self.values);
                return Some((v[0].clone(), v[3].clone(), v[4].clone()));
            }
            None
        }
    }
}
