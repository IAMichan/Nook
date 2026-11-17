//! The chat apps Nook knows (`MessagingApp`, `NoticeLayout`, `MessagingApps`, `ChatSources` in
//! `apps/macos/Services/Messages/ChatInbox.swift`): which programs and websites are which app, how each writes a chat
//! message into its notification, and which apps feed the inbox (Settings › Connections).
//!
//! On the Mac an app is known by its bundle id. Here it is known by its id on this system: a Windows AppUserModelID
//! (`5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App`) or a Linux notification's app name (`Telegram Desktop`), matched by
//! a fragment in any case (`system_ids`). The fragments still need a check on a real Windows PC (FD-01).

use serde::{Deserialize, Serialize};

/// Where a group's sender sits when the notification's subtitle does not say.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoticeLayout {
    /// Slack calls a channel's message "New message in #general" and writes its markup into the text.
    pub slack_markup: bool,
    pub speaker_in_text: SpeakerInText,
    /// The app titles a group's message with who wrote it and puts the group in the subtitle, or writes it as
    /// "Anna @ Family" (the WhatsApp app; its website does not swap).
    pub sender_in_title: bool,
}

/// A connection of its own Nook links an app with, beyond its notifications and its bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnLink {
    /// WhatsApp through a linked phone (the gateway).
    WhatsAppGateway,
}

/// One chat app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagingApp {
    /// The source id ("telegram").
    pub id: String,
    pub name: String,
    /// Its programs on this system, by a fragment of their id: their notifications are its messages.
    #[serde(default)]
    pub system_ids: Vec<String>,
    /// Its web versions: a browser's notification from one of these sites is its message.
    #[serde(default)]
    pub domains: Vec<String>,
    /// The website whose icon stands for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub site: Option<String>,
    // What sets the app apart, said here once instead of by its id across the app. Not stored: an app you added has
    // none of it.
    #[serde(skip)]
    pub notice_layout: NoticeLayout,
    /// Nook may notify about its chats until you choose. Only WhatsApp: the other apps show their own notifications.
    #[serde(skip)]
    pub notifies_by_default: bool,
    /// Its own calls are FaceTime (Messages).
    #[serde(skip)]
    pub calls_are_face_time: bool,
    #[serde(skip)]
    pub own_link: Option<OwnLink>,
}

impl MessagingApp {
    fn new(id: &str, name: &str, system_ids: &[&str], domains: &[&str], site: Option<&str>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            system_ids: system_ids.iter().map(|s| s.to_string()).collect(),
            domains: domains.iter().map(|s| s.to_string()).collect(),
            site: site.map(str::to_string),
            notice_layout: NoticeLayout::default(),
            notifies_by_default: false,
            calls_are_face_time: false,
            own_link: None,
        }
    }

    fn layout(mut self, layout: NoticeLayout) -> Self {
        self.notice_layout = layout;
        self
    }
}

/// The chat apps Nook knows by itself, in the Mac's order.
pub fn built_in() -> Vec<MessagingApp> {
    let app = MessagingApp::new;
    let mut whatsapp = app(
        "whatsapp",
        "WhatsApp",
        &["whatsappdesktop", "whatsapp"],
        &["web.whatsapp.com"],
        Some("whatsapp.com"),
    )
    .layout(NoticeLayout { sender_in_title: true, ..Default::default() });
    whatsapp.notifies_by_default = true;
    whatsapp.own_link = Some(OwnLink::WhatsAppGateway);
    let mut messages = app("messages", "Messages", &["com.apple.mobilesms"], &[], None);
    messages.calls_are_face_time = true;
    vec![
        whatsapp,
        app("telegram", "Telegram", &["telegramdesktop", "telegram desktop", "org.telegram"], &["web.telegram.org"], Some("telegram.org")),
        app("instagram", "Instagram", &["instagram"], &["instagram.com"], Some("instagram.com")),
        app("messenger", "Messenger", &["facebook.317180b0bb486", "messenger"], &["messenger.com"], Some("messenger.com")),
        app("signal", "Signal", &["signal-desktop", "signal"], &[], Some("signal.org")),
        messages,
        app("slack", "Slack", &["com.squirrel.slack", "slack"], &["app.slack.com"], Some("slack.com"))
            .layout(NoticeLayout { slack_markup: true, speaker_in_text: SpeakerInText::InChannels, ..Default::default() }),
        app("discord", "Discord", &["com.squirrel.discord", "discord"], &["discord.com"], Some("discord.com")),
        app(
            "teams",
            "Teams",
            &["msteams", "teams"],
            &["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"],
            Some("teams.microsoft.com"),
        )
        .layout(NoticeLayout { speaker_in_text: SpeakerInText::Always, ..Default::default() }),
        app("googlechat", "Google Chat", &[], &["chat.google.com"], Some("chat.google.com")),
        app("snapchat", "Snapchat", &[], &["snapchat.com"], Some("snapchat.com")),
        app("viber", "Viber", &["viber"], &[], Some("viber.com")),
        app("wechat", "WeChat", &["wechat", "tencent.weixin"], &[], Some("wechat.com")),
        app("line", "LINE", &["naver.line", "line"], &[], Some("line.me")),
        app("skype", "Skype", &["skype"], &[], Some("skype.com")),
        app("element", "Element", &["im.riot", "element"], &["app.element.io"], Some("element.io")),
        app("threema", "Threema", &["threema"], &[], Some("threema.ch")),
        app("wire", "Wire", &["wire"], &[], Some("wire.com")),
        // Mostly in the browser, where their notifications name the site.
        app("linkedin", "LinkedIn", &["linkedin"], &["linkedin.com"], Some("linkedin.com")),
        app("x", "X", &[], &["x.com", "twitter.com"], Some("x.com")),
        // Mail: the mail apps and websites whose notifications are all Nook gets of them.
        app("mail", "Mail", &["microsoft.windowscommunicationsapps", "thunderbird", "evolution"], &[], None),
        app(
            "outlook",
            "Outlook",
            &["microsoft.outlookforwindows", "microsoft.office.outlook", "outlook"],
            &["outlook.office.com", "outlook.live.com", "outlook.office365.com"],
            Some("outlook.com"),
        ),
        app("gmail", "Gmail", &[], &["mail.google.com"], Some("mail.google.com")),
        app("spark", "Spark", &["readdle.spark", "spark"], &[], Some("sparkmailapp.com")),
        app("protonmail", "Proton Mail", &["proton mail", "protonmail", "proton.mail"], &["mail.proton.me"], Some("proton.me")),
    ]
}

/// A chat app Nook knows by itself, by its id, without reading your settings.
pub fn known(id: &str) -> Option<MessagingApp> {
    built_in().into_iter().find(|a| a.id == id)
}

/// The app whose program sent a notification, by a fragment of the program's id on this system (any case). The
/// longest fragment wins, so "Signal" does not take a program that only shares a word with it.
pub fn by_system_id<'a>(system_id: &str, apps: &'a [MessagingApp]) -> Option<&'a MessagingApp> {
    let wanted = system_id.to_lowercase();
    if wanted.is_empty() || is_browser(&wanted) {
        return None;
    }
    let words = words(&wanted);
    apps.iter()
        .filter_map(|app| {
            let best = app.system_ids.iter().filter(|f| holds_words(&words, f)).map(String::len).max()?;
            Some((best, app))
        })
        .max_by_key(|(len, _)| *len)
        .map(|(_, app)| app)
}

fn words(text: &str) -> Vec<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_string).collect()
}

/// The fragment's words, one after another, among the id's words: "signal-desktop" in
/// "org.whispersystems.signal-desktop", but "line" not in "online".
fn holds_words(words: &[String], fragment: &str) -> bool {
    let wanted = self::words(fragment);
    !wanted.is_empty() && words.windows(wanted.len()).any(|w| w == wanted.as_slice())
}

/// Browsers, whose notifications come from a website: the site says which app.
pub fn is_browser(system_id: &str) -> bool {
    let id = system_id.to_lowercase();
    ["chrome", "msedge", "microsoft.microsoftedge", "firefox", "308046b0af4a39cb", "brave", "opera", "vivaldi", "zen", "chromium"]
        .iter()
        .any(|b| id.contains(b))
}

/// "instagram.com" in "www.instagram.com" or "https://instagram.com/direct", not in "notinstagram.com".
pub fn mentions(text: &str, domain: &str) -> bool {
    if domain.is_empty() {
        return false;
    }
    let mut start = 0;
    while let Some(found) = text[start..].find(domain) {
        let at = start + found;
        let end = at + domain.len();
        let before = text[..at].chars().next_back();
        let after = text[end..].chars().next();
        let boundary_before = before.is_none_or(|c| matches!(c, '.' | '/' | ' ' | '('));
        let boundary_after = match after {
            None => true,
            Some('.') => text[end + 1..].chars().next().is_none_or(|c| !c.is_alphabetic()),
            Some(c) => !(c.is_alphanumeric() || c == '-'),
        };
        if boundary_before && boundary_after {
            return true;
        }
        start = end;
    }
    false
}

/// The chat app a browser's notification is from: a site of it in one of its fields (where the browser names the
/// site), or the app's own name as the title ("Instagram").
pub fn mentioned_in<'a>(fields: &[&str], apps: &'a [MessagingApp]) -> Option<&'a MessagingApp> {
    for field in fields {
        let text = field.to_lowercase();
        if text.is_empty() {
            continue;
        }
        if let Some(app) = apps.iter().find(|a| a.domains.iter().any(|d| mentions(&text, d))) {
            return Some(app);
        }
    }
    let title = fields.iter().find(|f| !f.is_empty()).map(|f| f.to_lowercase()).unwrap_or_default();
    apps.iter().find(|a| !a.domains.is_empty() && a.name.to_lowercase() == title)
}

/// The chat app a website installed as an app of its own is (a Chrome or Edge app), by the name it was given
/// ("Instagram", "LinkedIn Messaging"): an app with a website whose name is one of its words.
pub fn by_web_app_name<'a>(name: &str, apps: &'a [MessagingApp]) -> Option<&'a MessagingApp> {
    let words = |text: &str| -> Vec<String> {
        text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_string).collect()
    };
    let given = words(name);
    if given.is_empty() {
        return None;
    }
    apps.iter().find(|app| {
        if app.domains.is_empty() {
            return false;
        }
        let own = words(&app.name);
        match own.len() {
            0 => false,
            1 => given.contains(&own[0]),
            _ => name.to_lowercase().contains(&app.name.to_lowercase()),
        }
    })
}

/// The app a word names: its id or its name, any case.
pub fn named<'a>(word: &str, apps: &'a [MessagingApp]) -> Option<&'a MessagingApp> {
    let wanted = word.trim().to_lowercase();
    if wanted.is_empty() {
        return None;
    }
    apps.iter().find(|a| a.id == wanted || a.name.to_lowercase() == wanted)
}

/// Which chat apps feed the inbox: every app Nook knows unless you switched it off, and the apps you added yourself.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatSources {
    /// The ids of the apps you switched off.
    pub off: Vec<String>,
    /// The apps you added, in the order you added them.
    pub custom: Vec<MessagingApp>,
}

/// What adding something did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "app")]
pub enum Added {
    /// A new app of your own.
    Added(MessagingApp),
    /// An app Nook already knows (or you already added): switched on.
    Known(MessagingApp),
    /// Neither a website, nor a program, nor the name of a known app.
    Invalid,
}

impl ChatSources {
    pub fn apps(&self) -> Vec<MessagingApp> {
        let mut all = built_in();
        all.extend(self.custom.iter().cloned());
        all
    }

    pub fn active(&self) -> Vec<MessagingApp> {
        self.apps().into_iter().filter(|a| self.is_on(&a.id)).collect()
    }

    pub fn is_on(&self, id: &str) -> bool {
        !self.off.iter().any(|o| o == id)
    }

    pub fn set(&mut self, id: &str, on: bool) {
        self.off.retain(|o| o != id);
        if !on {
            self.off.push(id.to_string());
        }
    }

    /// Adds what was typed: a known app's name ("LinkedIn"), else a website ("linkedin.com/messaging"). A website Nook
    /// already knows switches that app on instead of adding it twice.
    pub fn add(&mut self, typed: &str, name: &str) -> Added {
        let apps = self.apps();
        if let Some(known) = named(typed, &apps) {
            return self.turn_on(known.clone());
        }
        let Some(host) = host(typed) else { return Added::Invalid };
        if let Some(known) = apps
            .iter()
            .find(|a| a.domains.iter().any(|d| mentions(&host, d) || mentions(d, &host)) || a.site.as_deref() == Some(host.as_str()))
        {
            return self.turn_on(known.clone());
        }
        let title = if name.trim().is_empty() { title_for(&host) } else { name.trim().to_string() };
        let app = MessagingApp::new(
            &format!("custom.{host}"),
            &title,
            &[],
            &[&host],
            Some(&host),
        );
        self.custom.push(app.clone());
        self.off.retain(|o| o != &app.id);
        Added::Added(app)
    }

    /// Adds a program by its id on this system (as the program picker gives it), or switches it on when it is here.
    pub fn add_program(&mut self, system_id: &str, name: &str) -> Added {
        let id = system_id.trim();
        if id.is_empty() || is_browser(id) {
            return Added::Invalid;
        }
        let apps = self.apps();
        if let Some(known) = by_system_id(id, &apps) {
            return self.turn_on(known.clone());
        }
        let title = name.trim();
        let app = MessagingApp::new(&format!("custom.{}", id.to_lowercase()), if title.is_empty() { id } else { title }, &[id], &[], None);
        self.custom.push(app.clone());
        self.off.retain(|o| o != &app.id);
        Added::Added(app)
    }

    /// Forgets an app you added; the ones Nook knows can only be switched off.
    pub fn remove(&mut self, id: &str) {
        self.custom.retain(|a| a.id != id);
        self.off.retain(|o| o != id);
    }

    fn turn_on(&mut self, app: MessagingApp) -> Added {
        self.off.retain(|o| o != &app.id);
        Added::Known(app)
    }
}

/// The website in what was typed, without "https://", "www." or a path: "linkedin.com/messaging" → "linkedin.com".
/// `None` for anything that is no host name with a dot.
pub fn host(text: &str) -> Option<String> {
    let mut rest = text.trim().to_lowercase();
    if let Some(at) = rest.find("://") {
        rest = rest[at + 3..].to_string();
    }
    if let Some(end) = rest.find(['/', '?', '#']) {
        rest.truncate(end);
    }
    if let Some(stripped) = rest.strip_prefix("www.") {
        rest = stripped.to_string();
    }
    let labels: Vec<&str> = rest.split('.').collect();
    let valid = labels.len() >= 2
        && labels.iter().all(|l| !l.is_empty() && l.chars().all(|c| c.is_alphanumeric() || c == '-'))
        && labels.last().is_some_and(|t| t.chars().count() >= 2 && t.chars().all(char::is_alphabetic));
    valid.then_some(rest)
}

/// "linkedin.com" → "Linkedin", "app.example.org" → "Example": the name before the top-level domain.
pub fn title_for(host: &str) -> String {
    let labels: Vec<&str> = host.split('.').collect();
    let main = if labels.len() >= 2 { labels[labels.len() - 2] } else { host };
    let mut chars = main.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_sets_each_app_apart_is_said_once() {
        let apps = built_in();
        assert_eq!(apps.len(), 25);
        let wa = known("whatsapp").unwrap();
        assert!(wa.notice_layout.sender_in_title && wa.notifies_by_default && wa.own_link == Some(OwnLink::WhatsAppGateway));
        assert!(apps.iter().filter(|a| a.notifies_by_default).count() == 1, "only WhatsApp notifies by default");
        let slack = known("slack").unwrap();
        assert!(slack.notice_layout.slack_markup && slack.notice_layout.speaker_in_text == SpeakerInText::InChannels);
        assert_eq!(known("teams").unwrap().notice_layout.speaker_in_text, SpeakerInText::Always);
        assert!(known("messages").unwrap().calls_are_face_time);
        let ids: std::collections::HashSet<&str> = apps.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids.len(), apps.len(), "ids are unique");
    }

    #[test]
    fn programs_by_their_id_on_this_system() {
        let apps = built_in();
        let by = |id: &str| by_system_id(id, &apps).map(|a| a.id.as_str());
        assert_eq!(by("5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App"), Some("whatsapp"));
        assert_eq!(by("TelegramDesktop.TelegramDesktop"), Some("telegram"));
        assert_eq!(by("Telegram Desktop"), Some("telegram"));
        assert_eq!(by("com.squirrel.slack.slack"), Some("slack"));
        assert_eq!(by("com.squirrel.Discord.Discord"), Some("discord"));
        assert_eq!(by("MSTeams_8wekyb3d8bbwe!MSTeams"), Some("teams"));
        assert_eq!(by("org.whispersystems.signal-desktop"), Some("signal"));
        assert_eq!(by("Chrome"), None, "a browser is no chat app");
        assert_eq!(by("MSEdge"), None);
        assert_eq!(by("Spotify"), None);
        assert_eq!(by("Contoso.Online_1!App"), None, "a word of an app's name inside another word is no match");
    }

    #[test]
    fn websites_in_browser_notifications() {
        let apps = built_in();
        assert!(mentions("www.instagram.com", "instagram.com"));
        assert!(mentions("https://instagram.com/direct", "instagram.com"));
        assert!(!mentions("notinstagram.com", "instagram.com"));
        assert!(!mentions("instagram.community", "instagram.com"));
        assert_eq!(mentioned_in(&["Anna", "web.whatsapp.com", "hoi"], &apps).map(|a| a.id.as_str()), Some("whatsapp"));
        assert_eq!(mentioned_in(&["Instagram", "", "Anna liked"], &apps).map(|a| a.id.as_str()), Some("instagram"));
        assert_eq!(mentioned_in(&["Messages", "", ""], &apps), None, "an app without a website is no website");
        assert_eq!(by_web_app_name("LinkedIn Messaging", &apps).map(|a| a.id.as_str()), Some("linkedin"));
        assert_eq!(by_web_app_name("Feed | LinkedIn", &apps).map(|a| a.id.as_str()), Some("linkedin"));
        assert_eq!(by_web_app_name("Google Messages", &apps), None);
        assert_eq!(named("linkedin", &apps).map(|a| a.id.as_str()), Some("linkedin"));
    }

    #[test]
    fn sources_switch_add_and_remove() {
        let mut sources = ChatSources::default();
        assert!(sources.is_on("telegram"));
        sources.set("telegram", false);
        assert!(!sources.active().iter().any(|a| a.id == "telegram"));
        assert_eq!(sources.add("Telegram", ""), Added::Known(known("telegram").unwrap()));
        assert!(sources.is_on("telegram"));
        assert!(matches!(sources.add("https://www.linkedin.com/messaging", ""), Added::Known(a) if a.id == "linkedin"));
        let Added::Added(app) = sources.add("chat.example.org/inbox", "") else { panic!("added") };
        assert_eq!((app.id.as_str(), app.name.as_str()), ("custom.chat.example.org", "Example"));
        assert_eq!(sources.add("not a site", ""), Added::Invalid);
        assert_eq!(sources.add_program("Chrome", "Chrome"), Added::Invalid);
        assert!(matches!(sources.add_program("Acme.Chat_123!App", "Acme Chat"), Added::Added(a) if a.name == "Acme Chat"));
        assert_eq!(by_system_id("Acme.Chat_123!App", &sources.apps()).map(|a| a.name.as_str()), Some("Acme Chat"));
        sources.remove("custom.chat.example.org");
        assert_eq!(sources.custom.len(), 1);
        let json = serde_json::to_string(&sources).unwrap();
        let back: ChatSources = serde_json::from_str(&json).unwrap();
        assert_eq!(back, sources);
        assert_eq!(host("WWW.Example.COM/x?y"), Some("example.com".into()));
        assert_eq!(host("example.c0m"), None);
        assert_eq!(title_for("app.example.org"), "Example");
    }
}
