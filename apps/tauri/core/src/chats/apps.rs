//! The chat apps Nook knows and what sets each apart (`MessagingApp`, `MessagingApps.builtIn`, `NoticeLayout` on the
//! Mac). What an app does differently is said here once, not by its id across the code.

use serde::{Deserialize, Serialize};

/// Where a group's sender sits when a notice's subtitle does not say: in front of the text ("Anna: ...").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeakerInText {
    #[default]
    Never,
    /// Only in a channel, whose title starts with "#" (Slack).
    InChannels,
    Always,
}

/// How an app writes a chat message into its notification, where that differs from "the title is the chat, the
/// subtitle who wrote, the body the text".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoticeLayout {
    /// Slack calls a channel's message "New message in #general" and writes its markup into the text.
    pub slack_markup: bool,
    pub speaker_in_text: SpeakerInText,
    /// The app titles a group's message with who wrote it and puts the group in the subtitle, or writes it as
    /// "Anna @ Family" (the WhatsApp app; its website does not swap).
    pub sender_in_title: bool,
    /// The app titles a channel's or group's message "Anna (#general, Server)": who wrote it, then the chat in
    /// parentheses (Discord).
    #[serde(default)]
    pub chat_in_parentheses: bool,
}

/// A connection of its own that Nook links an app with, beyond notifications and its bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnLink {
    /// WhatsApp through a linked phone (the gateway).
    WhatsAppGateway,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagingApp {
    pub id: &'static str,
    pub name: &'static str,
    /// Its web versions: a browser's notification from one of these sites is its message.
    pub domains: &'static [&'static str],
    pub site: Option<&'static str>,
    pub notice_layout: NoticeLayout,
    /// Nook may notify about its chats until you choose. Only WhatsApp: the other apps show their own notifications.
    pub notifies_by_default: bool,
    /// Its own calls are FaceTime (Messages).
    pub calls_are_facetime: bool,
    pub own_link: Option<OwnLink>,
}

const PLAIN: NoticeLayout =
    NoticeLayout { slack_markup: false, speaker_in_text: SpeakerInText::Never, sender_in_title: false, chat_in_parentheses: false };

const fn app(id: &'static str, name: &'static str, domains: &'static [&'static str], site: Option<&'static str>) -> MessagingApp {
    MessagingApp { id, name, domains, site, notice_layout: PLAIN, notifies_by_default: false, calls_are_facetime: false, own_link: None }
}

/// The chat apps Nook knows by itself, in the Mac's order.
pub fn built_in() -> Vec<MessagingApp> {
    let mut whatsapp = app("whatsapp", "WhatsApp", &["web.whatsapp.com"], Some("whatsapp.com"));
    whatsapp.notice_layout = NoticeLayout { sender_in_title: true, ..PLAIN };
    whatsapp.notifies_by_default = true;
    whatsapp.own_link = Some(OwnLink::WhatsAppGateway);
    let mut messages = app("messages", "Messages", &[], None);
    messages.calls_are_facetime = true;
    let mut slack = app("slack", "Slack", &["app.slack.com"], Some("slack.com"));
    slack.notice_layout = NoticeLayout { slack_markup: true, speaker_in_text: SpeakerInText::InChannels, ..PLAIN };
    let mut teams = app("teams", "Teams", &["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"], Some("teams.microsoft.com"));
    teams.notice_layout = NoticeLayout { speaker_in_text: SpeakerInText::Always, ..PLAIN };
    let mut discord = app("discord", "Discord", &["discord.com"], Some("discord.com"));
    discord.notice_layout = NoticeLayout { chat_in_parentheses: true, ..PLAIN };
    vec![
        whatsapp,
        app("telegram", "Telegram", &["web.telegram.org"], Some("telegram.org")),
        app("instagram", "Instagram", &["instagram.com"], Some("instagram.com")),
        app("messenger", "Messenger", &["messenger.com"], Some("messenger.com")),
        app("signal", "Signal", &[], Some("signal.org")),
        messages,
        slack,
        discord,
        teams,
        app("googlechat", "Google Chat", &["chat.google.com"], Some("chat.google.com")),
        app("snapchat", "Snapchat", &["snapchat.com"], Some("snapchat.com")),
        app("viber", "Viber", &[], Some("viber.com")),
        app("wechat", "WeChat", &[], Some("wechat.com")),
        app("line", "LINE", &[], Some("line.me")),
        app("skype", "Skype", &[], Some("skype.com")),
        app("element", "Element", &["app.element.io"], Some("element.io")),
        app("threema", "Threema", &[], Some("threema.ch")),
        app("wire", "Wire", &[], Some("wire.com")),
        app("linkedin", "LinkedIn", &["linkedin.com"], Some("linkedin.com")),
        app("x", "X", &["x.com", "twitter.com"], Some("x.com")),
        app("mail", "Mail", &[], None),
        app("outlook", "Outlook", &["outlook.office.com", "outlook.live.com", "outlook.office365.com"], Some("outlook.com")),
        app("gmail", "Gmail", &["mail.google.com"], Some("mail.google.com")),
        app("spark", "Spark", &[], Some("sparkmailapp.com")),
        app("protonmail", "Proton Mail", &["mail.proton.me"], Some("proton.me")),
    ]
}

/// The built-in app with this id.
pub fn known(id: &str) -> Option<MessagingApp> {
    let id = id.to_lowercase();
    built_in().into_iter().find(|app| app.id == id)
}

/// A chat message as a notification says it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatNotice {
    pub app: String,
    pub chat: String,
    pub sender: String,
    pub text: String,
}

/// "New message in #general" as "#general" (Slack, in the five languages).
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
    let lower = title.to_lowercase();
    for prefix in PREFIXES {
        if lower.starts_with(&prefix.to_lowercase()) {
            let chat = title.chars().skip(prefix.chars().count()).collect::<String>();
            let chat = chat.trim();
            return if chat.is_empty() { title.to_string() } else { chat.to_string() };
        }
    }
    title.to_string()
}

/// "anna: see you" as ("anna", "see you"): a short name without a line break before the colon.
pub fn speaker(text: &str) -> Option<(String, String)> {
    let colon = text.find(':')?;
    let name = text[..colon].trim();
    let rest = text[colon + 1..].trim();
    if name.is_empty() || name.chars().count() > 40 || name.contains('\n') || name.contains("http") || rest.is_empty() {
        return None;
    }
    Some((name.to_string(), rest.to_string()))
}

/// Slack's markup in a notice's text: `<@U1>`/`<#C1|general>`/`<url|label>` as what a person reads, and the escaped
/// `&amp; &lt; &gt;` back.
pub fn clean_slack(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('<') {
        out.push_str(&rest[..open]);
        let Some(close) = rest[open..].find('>') else {
            out.push_str(&rest[open..]);
            rest = "";
            break;
        };
        let inner = &rest[open + 1..open + close];
        match inner.split_once('|') {
            Some((_, label)) if !label.is_empty() => out.push_str(label),
            _ => out.push_str(inner.trim_start_matches(['@', '#'])),
        }
        rest = &rest[open + close + 1..];
    }
    out.push_str(rest);
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

/// "Anna (#general, Server)" as ("Anna", "#general, Server"); `None` without a name before the parentheses.
fn in_parentheses(title: &str) -> Option<(String, String)> {
    let inner = title.strip_suffix(')')?;
    let open = inner.rfind(" (")?;
    let (sender, chat) = (inner[..open].trim(), inner[open + 2..].trim());
    (!sender.is_empty() && !chat.is_empty()).then(|| (sender.to_string(), chat.to_string()))
}

/// Reads a notification's title, subtitle and body by the app's layout into the chat, the sender and the text.
pub fn parse_notice(app: &str, title: &str, subtitle: &str, body: &str, from_browser: bool) -> ChatNotice {
    let layout = known(app).map(|app| app.notice_layout).unwrap_or_default();
    let (mut title, mut subtitle, mut text) = (title.trim().to_string(), subtitle.trim().to_string(), body.trim().to_string());
    if layout.slack_markup {
        title = slack_chat(&title);
        text = clean_slack(&text);
    }
    let speaker_first = match layout.speaker_in_text {
        SpeakerInText::Never => false,
        SpeakerInText::InChannels => title.starts_with('#'),
        SpeakerInText::Always => true,
    };
    if speaker_first && subtitle.is_empty() {
        if let Some((name, rest)) = speaker(&text) {
            if name.to_lowercase() != title.to_lowercase() {
                subtitle = name;
                text = rest;
            }
        }
    }
    if layout.sender_in_title && !from_browser && !subtitle.is_empty() {
        std::mem::swap(&mut title, &mut subtitle);
    }
    if subtitle.is_empty() && layout.sender_in_title {
        if let Some((sender, chat)) = title.clone().split_once(" @ ") {
            subtitle = sender.to_string();
            title = chat.to_string();
        }
    }
    if subtitle.is_empty() && layout.chat_in_parentheses {
        if let Some((sender, chat)) = in_parentheses(&title) {
            subtitle = sender;
            title = chat;
        }
    }
    if subtitle.to_lowercase() == title.to_lowercase() {
        subtitle.clear();
    }
    ChatNotice { app: app.to_string(), chat: title, sender: subtitle, text }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_apps_say_what_sets_them_apart() {
        assert_eq!(
            known("slack").unwrap().notice_layout,
            NoticeLayout { slack_markup: true, speaker_in_text: SpeakerInText::InChannels, ..PLAIN }
        );
        assert_eq!(known("teams").unwrap().notice_layout.speaker_in_text, SpeakerInText::Always);
        assert!(known("whatsapp").unwrap().notice_layout.sender_in_title);
        assert_eq!(known("telegram").unwrap().notice_layout, NoticeLayout::default());
        let all = built_in();
        let default_on: Vec<_> = all.iter().filter(|app| app.notifies_by_default).map(|app| app.id).collect();
        assert_eq!(default_on, ["whatsapp"]);
        let facetime: Vec<_> = all.iter().filter(|app| app.calls_are_facetime).map(|app| app.id).collect();
        assert_eq!(facetime, ["messages"]);
        let linked: Vec<_> = all.iter().filter(|app| app.own_link.is_some()).map(|app| app.id).collect();
        assert_eq!(linked, ["whatsapp"]);
    }

    #[test]
    fn slack_channel_notice_gets_chat_and_speaker() {
        let notice = parse_notice("slack", "New message in #general", "", "GitHub: <https://x.io|build> passed &amp; done", false);
        assert_eq!(notice.chat, "#general");
        assert_eq!(notice.sender, "GitHub");
        assert_eq!(notice.text, "build passed & done");
    }

    #[test]
    fn whatsapp_swaps_title_and_subtitle_for_the_app_but_not_the_website() {
        let app = parse_notice("whatsapp", "Anna", "Family", "hi", false);
        assert_eq!((app.chat.as_str(), app.sender.as_str()), ("Family", "Anna"));
        let web = parse_notice("whatsapp", "Anna", "Family", "hi", true);
        assert_eq!((web.chat.as_str(), web.sender.as_str()), ("Anna", "Family"));
        let at = parse_notice("whatsapp", "Anna @ Family", "", "hi", false);
        assert_eq!((at.chat.as_str(), at.sender.as_str()), ("Family", "Anna"));
    }

    #[test]
    fn discord_names_the_channel_in_parentheses_and_a_direct_message_by_the_person() {
        let channel = parse_notice("discord", "Anna (#general, Nook)", "", "hi", false);
        assert_eq!((channel.chat.as_str(), channel.sender.as_str()), ("#general, Nook", "Anna"));
        let direct = parse_notice("discord", "Anna", "", "hi", false);
        assert_eq!((direct.chat.as_str(), direct.sender.as_str()), ("Anna", ""));
        let plain = parse_notice("telegram", "Anna (work)", "", "hi", false);
        assert_eq!(plain.chat, "Anna (work)");
    }

    #[test]
    fn teams_speaker_moves_out_of_the_text_and_plain_apps_stay() {
        let teams = parse_notice("teams", "Project", "", "Bo: ready?", false);
        assert_eq!((teams.sender.as_str(), teams.text.as_str()), ("Bo", "ready?"));
        let plain = parse_notice("telegram", "Project", "", "Bo: ready?", false);
        assert_eq!((plain.sender.as_str(), plain.text.as_str()), ("", "Bo: ready?"));
    }
}
