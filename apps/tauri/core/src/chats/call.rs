//! Calling someone from the Chats tab, the same for every chat app (`ChatCalls`, `ChatCallTracker` on the Mac): a voice or
//! video button in the chat's header. No chat app lets another app hold a call for it, so Nook asks the app itself:
//! straight into the call where its link does that (Teams, Skype), else into the chat in its app, where you press call.
//! While the call goes on, Nook follows it by the app holding the microphone and shows how long it lasts.
//!
//! Windows has no FaceTime and no Messages app, so those two ways of the Mac are left out here.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Voice only, or with video.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CallKind {
    Voice,
    Video,
}

/// How a chat's app takes a call from Nook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Launch {
    /// A link the app opens straight into the call.
    Direct(String),
    /// A link that opens this chat in its app, where you press call.
    Chat(String),
    /// The app opens (no link to the chat Nook can make), and you press call in the chat there.
    App,
}

impl Launch {
    pub fn url(&self) -> Option<&str> {
        match self {
            Self::Direct(u) | Self::Chat(u) => Some(u),
            Self::App => None,
        }
    }

    pub fn is_direct(&self) -> bool {
        matches!(self, Self::Direct(_))
    }
}

/// Who a call goes to, as far as their chat's app said.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Person {
    /// The app's source id ("whatsapp").
    pub app: String,
    pub name: String,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub username: Option<String>,
    pub is_group: bool,
}

/// The apps that hold calls at all, by source id. A mail app, LinkedIn and an app you added yourself have none.
pub const CALLING_APPS: &[&str] = &[
    "whatsapp",
    "telegram",
    "instagram",
    "messenger",
    "signal",
    "slack",
    "discord",
    "teams",
    "googlechat",
    "snapchat",
    "viber",
    "wechat",
    "line",
    "skype",
    "element",
    "threema",
    "wire",
    "x",
];

/// The apps that also call a group, in the group's chat in the app.
pub const GROUP_CALLING_APPS: &[&str] = &[
    "whatsapp",
    "telegram",
    "messenger",
    "signal",
    "slack",
    "discord",
    "teams",
    "googlechat",
    "element",
    "wire",
    "line",
    "wechat",
    "viber",
    "skype",
];

/// Whether `app` holds calls Nook can start (for a person or for a group).
pub fn can_call(app: &str, is_group: bool) -> bool {
    if is_group {
        GROUP_CALLING_APPS.contains(&app)
    } else {
        CALLING_APPS.contains(&app)
    }
}

/// How `person`'s app takes this call; `None` when the app has no calls (or none for a group).
pub fn launch(kind: CallKind, person: &Person) -> Option<Launch> {
    if person.is_group {
        return GROUP_CALLING_APPS.contains(&person.app.as_str()).then_some(Launch::App);
    }
    if !CALLING_APPS.contains(&person.app.as_str()) {
        return None;
    }
    let phone = person.phone.as_deref().and_then(phone_digits);
    let username = person.username.as_deref().and_then(clean_username);
    let email = person.email.as_deref().and_then(clean_email);
    let video = kind == CallKind::Video;
    Some(match person.app.as_str() {
        // Teams' call link: learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/deep-link-teams
        "teams" => match email {
            Some(e) => Launch::Direct(link("msteams:/l/call/0/0", &[("users", &e), ("withVideo", if video { "true" } else { "false" })])),
            None => Launch::App,
        },
        "skype" => match username {
            Some(u) => Launch::Direct(format!("skype:{u}?call{}", if video { "&video=true" } else { "" })),
            None => Launch::App,
        },
        "whatsapp" => match phone {
            Some(p) => Launch::Chat(link("whatsapp://send", &[("phone", &p[1..])])),
            None => Launch::App,
        },
        "telegram" => match (username, phone) {
            (Some(u), _) => Launch::Chat(link("tg://resolve", &[("domain", &u)])),
            (None, Some(p)) => Launch::Chat(link("tg://resolve", &[("phone", &p[1..])])),
            _ => Launch::App,
        },
        "signal" => match phone {
            Some(p) => Launch::Chat(format!("sgnl://signal.me/#p/{p}")),
            None => Launch::App,
        },
        "viber" => match phone {
            Some(p) => Launch::Chat(link("viber://chat", &[("number", &p)])),
            None => Launch::App,
        },
        _ => Launch::App,
    })
}

/// The website of a chat app, opened when no desktop link or app opens it (matching macOS `MessagingApps.builtIn`).
pub fn web_url(app: &str) -> Option<&'static str> {
    Some(match app {
        "whatsapp" => "https://web.whatsapp.com",
        "telegram" => "https://web.telegram.org",
        "instagram" => "https://instagram.com",
        "messenger" => "https://messenger.com",
        "signal" => "https://signal.org",
        "slack" => "https://app.slack.com",
        "discord" => "https://discord.com",
        "teams" => "https://teams.microsoft.com",
        "googlechat" => "https://chat.google.com",
        "snapchat" => "https://snapchat.com",
        "viber" => "https://viber.com",
        "wechat" => "https://wechat.com",
        "line" => "https://line.me",
        "skype" => "https://skype.com",
        "element" => "https://app.element.io",
        "threema" => "https://threema.ch",
        "wire" => "https://wire.com",
        "x" => "https://x.com",
        "linkedin" => "https://linkedin.com",
        _ => return None,
    })
}

/// Human-readable display name of a known chat app (`MessagingApps` on the Mac).
pub fn display_name(app: &str) -> &str {
    match app {
        "whatsapp" => "WhatsApp",
        "telegram" => "Telegram",
        "instagram" => "Instagram",
        "messenger" => "Messenger",
        "signal" => "Signal",
        "slack" => "Slack",
        "discord" => "Discord",
        "teams" => "Teams",
        "googlechat" => "Google Chat",
        "snapchat" => "Snapchat",
        "viber" => "Viber",
        "wechat" => "WeChat",
        "line" => "LINE",
        "skype" => "Skype",
        "element" => "Element",
        "threema" => "Threema",
        "wire" => "Wire",
        "x" => "X",
        "linkedin" => "LinkedIn",
        other => other,
    }
}

/// "+31 6 1234 5678" → "+31612345678"; `None` for what is no phone number (6 to 15 digits, `ChatHandle.e164`).
/// Also reads WhatsApp number JIDs (`31612345678@s.whatsapp.net`, `31612345678:3@s.whatsapp.net`, `31612345678@c.us`,
/// and multi-account keys `nook-abc123~31612345678@s.whatsapp.net`).
pub fn phone_digits(text: &str) -> Option<String> {
    let mut raw = text.trim();
    if raw.is_empty() {
        return None;
    }
    if let Some((before_at, host)) = raw.split_once('@') {
        let host = host.to_ascii_lowercase();
        if !host.ends_with("whatsapp.net") && host != "c.us" {
            return None;
        }
        // Multi-account WhatsApp key (`nook-abc123~31612345678@s.whatsapp.net`) and device suffix (`:3`).
        let user = before_at.rsplit_once('~').map_or(before_at, |(_, jid)| jid);
        raw = user.split_once(':').map_or(user, |(num, _)| num);
    }
    if !raw.chars().all(|c| c.is_ascii_digit() || "+-() .".contains(c)) {
        return None;
    }
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    let digits = if raw.starts_with("00") { digits.strip_prefix("00").map(str::to_string).unwrap_or(digits) } else { digits };
    (6..=15).contains(&digits.len()).then(|| format!("+{digits}"))
}

fn clean_username(text: &str) -> Option<String> {
    let name = text.trim().trim_matches('@');
    (!name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || "._-".contains(c))).then(|| name.to_string())
}

fn clean_email(text: &str) -> Option<String> {
    let mail = text.trim();
    (mail.contains('@') && !mail.contains(' ')).then(|| mail.to_string())
}

fn link(base: &str, query: &[(&str, &str)]) -> String {
    let mut sorted = query.to_vec();
    sorted.sort_by_key(|(k, _)| *k);
    // A "+" in a query means a space to many apps: every value is percent-encoded.
    let encoded: Vec<String> = sorted
        .iter()
        .map(|(k, v)| format!("{k}={}", percent_encoding::utf8_percent_encode(v, percent_encoding::NON_ALPHANUMERIC)))
        .collect();
    format!("{base}?{}", encoded.join("&"))
}

/// The programs (Windows: program names or Store packages, any case) that hold a call of `app`'s desktop app.
pub fn programs(app: &str) -> &'static [&'static str] {
    match app {
        "whatsapp" => &["whatsapp"],
        "telegram" => &["telegram"],
        "signal" => &["signal"],
        "discord" => &["discord"],
        "slack" => &["slack"],
        "teams" => &["teams", "msteams"],
        "skype" => &["skype"],
        "viber" => &["viber"],
        "messenger" => &["messenger"],
        "line" => &["line"],
        "wechat" => &["wechat", "weixin"],
        "element" => &["element"],
        "threema" => &["threema"],
        "wire" => &["wire"],
        _ => &[],
    }
}

/// The browsers whose microphone means a call on an app's website.
pub const BROWSERS: &[&str] = &["chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc", "zen", "safari"];

/// Whether one of `programs` has the microphone open: a program or Store package name that holds one of them.
pub fn holds_microphone(programs: &[&str], microphone_apps: &[String]) -> bool {
    microphone_apps.iter().any(|app| {
        let app = app.to_lowercase();
        // A Store package ("5319275A.WhatsAppDesktop_cv1…") or a program ("WhatsApp", "ms-teams").
        programs.iter().any(|p| app == *p || app.contains(p))
    })
}

/// Where a call stands.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "phase")]
pub enum Phase {
    Calling,
    Live { since: DateTime<Utc> },
    Ended { seconds: i64, at: DateTime<Utc> },
}

/// Where a call stands, by whether its app holds the microphone: calling until it does, then live, then ended once it let
/// go for a few seconds. A call that never got the microphone ends on its own after a while, as does the line that said
/// it ended.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tracker {
    pub started: DateTime<Utc>,
    pub phase: Phase,
    #[serde(skip)]
    last_heard: Option<DateTime<Utc>>,
}

impl Tracker {
    /// How long a call may ring (or wait for you to press call in its app) before Nook stops following it.
    pub const CONNECT_WAIT: i64 = 180;
    /// How long the microphone may be let go during a call (an app switching devices) before the call counts as ended.
    pub const DROP_GRACE: i64 = 6;
    /// How long "Call ended" stays.
    pub const ENDED_SHOWN: i64 = 5;

    pub fn new(started: DateTime<Utc>) -> Self {
        Self { started, phase: Phase::Calling, last_heard: None }
    }

    /// Takes a reading; returns false once the call is over and nothing more shows.
    pub fn observe(&mut self, in_call: bool, now: DateTime<Utc>) -> bool {
        match self.phase {
            Phase::Calling => {
                if in_call {
                    self.phase = Phase::Live { since: now };
                    self.last_heard = Some(now);
                } else if (now - self.started).num_seconds() > Self::CONNECT_WAIT {
                    return false;
                }
            }
            Phase::Live { since } => {
                if in_call {
                    self.last_heard = Some(now);
                } else if let Some(heard) = self.last_heard.filter(|h| (now - *h).num_seconds() > Self::DROP_GRACE) {
                    self.phase = Phase::Ended { seconds: (heard - since).num_seconds().max(0), at: now };
                }
            }
            Phase::Ended { at, .. } => return (now - at).num_seconds() <= Self::ENDED_SHOWN,
        }
        true
    }
}

/// "4:07", "1:02:33".
pub fn clock(seconds: i64) -> String {
    let total = seconds.max(0);
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{rest:02}")
    } else {
        format!("{minutes}:{rest:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn person(app: &str) -> Person {
        Person { app: app.into(), name: "Anna".into(), ..Default::default() }
    }

    #[test]
    fn every_calling_app_has_a_launch_and_non_calling_apps_do_not() {
        for app in CALLING_APPS {
            assert!(can_call(app, false), "{app} should allow 1-to-1 calls");
            assert!(launch(CallKind::Voice, &person(app)).is_some(), "{app} should have a launch");
            assert!(web_url(app).is_some(), "{app} should have a fallback website");
        }
        for app in ["mail", "gmail", "outlook", "linkedin", "messages", "custom"] {
            assert!(!can_call(app, false), "{app} should not allow calls on Windows");
            assert_eq!(launch(CallKind::Voice, &person(app)), None, "{app}");
        }
    }

    #[test]
    fn each_app_takes_the_call_its_own_way() {
        let mut p = person("whatsapp");
        p.phone = Some("+31 6 1234 5678".into());
        assert_eq!(launch(CallKind::Voice, &p), Some(Launch::Chat("whatsapp://send?phone=31612345678".into())));
        // WhatsApp JID as phone works too.
        p.phone = Some("31612345678@s.whatsapp.net".into());
        assert_eq!(launch(CallKind::Video, &p), Some(Launch::Chat("whatsapp://send?phone=31612345678".into())));
        p.app = "signal".into();
        assert_eq!(launch(CallKind::Voice, &p), Some(Launch::Chat("sgnl://signal.me/#p/+31612345678".into())));
        p.app = "viber".into();
        assert_eq!(launch(CallKind::Voice, &p).unwrap().url(), Some("viber://chat?number=%2B31612345678"));
        let mut t = person("telegram");
        t.username = Some("@anna_b".into());
        assert_eq!(launch(CallKind::Video, &t), Some(Launch::Chat("tg://resolve?domain=anna%5Fb".into())));
        // Telegram falls back to phone when username is absent.
        t.username = None;
        t.phone = Some("+31 6 1234 5678".into());
        assert_eq!(launch(CallKind::Voice, &t), Some(Launch::Chat("tg://resolve?phone=31612345678".into())));
        let mut teams = person("teams");
        teams.email = Some("anna@example.com".into());
        let call = launch(CallKind::Video, &teams).unwrap();
        assert!(call.is_direct());
        assert_eq!(call.url(), Some("msteams:/l/call/0/0?users=anna%40example%2Ecom&withVideo=true"));
        assert_eq!(launch(CallKind::Voice, &teams).unwrap().url(), Some("msteams:/l/call/0/0?users=anna%40example%2Ecom&withVideo=false"));
        let mut skype = person("skype");
        skype.username = Some("anna.b".into());
        assert_eq!(launch(CallKind::Video, &skype), Some(Launch::Direct("skype:anna.b?call&video=true".into())));
        assert_eq!(launch(CallKind::Voice, &skype), Some(Launch::Direct("skype:anna.b?call".into())));
        // Known only by name: the app opens and you press call there.
        assert_eq!(launch(CallKind::Voice, &person("discord")), Some(Launch::App));
        assert_eq!(launch(CallKind::Voice, &person("whatsapp")), Some(Launch::App));
        assert_eq!(launch(CallKind::Voice, &person("teams")), Some(Launch::App));
        // No calls at all.
        assert_eq!(launch(CallKind::Voice, &person("linkedin")), None);
        assert_eq!(launch(CallKind::Voice, &person("mail")), None);
    }

    #[test]
    fn groups_call_only_where_the_app_calls_groups() {
        for app in GROUP_CALLING_APPS {
            assert!(CALLING_APPS.contains(app), "group app {app} must also be in CALLING_APPS");
            assert!(can_call(app, true));
            let mut g = person(app);
            g.is_group = true;
            g.phone = Some("+31612345678".into());
            assert_eq!(launch(CallKind::Video, &g), Some(Launch::App));
        }
        for app in ["instagram", "snapchat", "threema", "x", "linkedin"] {
            assert!(!can_call(app, true));
            let mut g = person(app);
            g.is_group = true;
            assert_eq!(launch(CallKind::Voice, &g), None);
        }
    }

    #[test]
    fn a_number_is_a_number() {
        assert_eq!(phone_digits("+31 6 1234 5678").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("0031 6 12345678").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("0031-6-12345678").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("31612345678@s.whatsapp.net").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("31612345678:3@s.whatsapp.net").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("nook-abc123~31612345678@s.whatsapp.net").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("31612345678@c.us").as_deref(), Some("+31612345678"));
        assert_eq!(phone_digits("1234567890@g.us"), None);
        assert_eq!(phone_digits("1234567890@lid"), None);
        assert_eq!(phone_digits("anna@example.com"), None);
        assert_eq!(phone_digits("@anna"), None);
        assert_eq!(phone_digits("123"), None);
        assert_eq!(phone_digits("12"), None);
        assert_eq!(phone_digits("1234567890123456"), None);
    }

    #[test]
    fn the_app_holding_the_microphone_is_the_call() {
        let apps = vec!["5319275A.WhatsAppDesktop_cv1g1gvanyjgm".to_string(), "chrome".to_string()];
        assert!(holds_microphone(programs("whatsapp"), &apps));
        assert!(!holds_microphone(programs("signal"), &apps));
        assert!(holds_microphone(BROWSERS, &apps));
    }

    #[test]
    fn a_call_rings_goes_live_and_ends() {
        let t0 = Utc::now();
        let mut tracker = Tracker::new(t0);
        assert!(tracker.observe(false, t0 + Duration::seconds(10)));
        assert_eq!(tracker.phase, Phase::Calling);
        assert!(tracker.observe(true, t0 + Duration::seconds(20)));
        assert_eq!(tracker.phase, Phase::Live { since: t0 + Duration::seconds(20) });
        // A short drop (switching devices) is still the call.
        assert!(tracker.observe(false, t0 + Duration::seconds(24)));
        assert_eq!(tracker.phase, Phase::Live { since: t0 + Duration::seconds(20) });
        assert!(tracker.observe(true, t0 + Duration::seconds(80)));
        // Exactly at DROP_GRACE is still live; past DROP_GRACE ends.
        assert!(tracker.observe(false, t0 + Duration::seconds(86)));
        assert_eq!(tracker.phase, Phase::Live { since: t0 + Duration::seconds(20) });
        assert!(tracker.observe(false, t0 + Duration::seconds(90)));
        assert_eq!(tracker.phase, Phase::Ended { seconds: 60, at: t0 + Duration::seconds(90) });
        assert!(tracker.observe(false, t0 + Duration::seconds(95)));
        assert!(!tracker.observe(false, t0 + Duration::seconds(96)));
        // Never picked up: Nook stops following after three minutes.
        let mut quiet = Tracker::new(t0);
        assert!(quiet.observe(false, t0 + Duration::seconds(Tracker::CONNECT_WAIT)));
        assert!(!quiet.observe(false, t0 + Duration::seconds(Tracker::CONNECT_WAIT + 1)));
    }

    #[test]
    fn the_clock_reads_like_a_phone() {
        assert_eq!(clock(0), "0:00");
        assert_eq!(clock(247), "4:07");
        assert_eq!(clock(3753), "1:02:33");
        assert_eq!(clock(-3), "0:00");
    }
}
