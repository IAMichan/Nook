//! Mail and calendar on Windows and Linux (the Mac reads Mail.app and EventKit; neither exists here): your Microsoft
//! (Outlook, Microsoft 365) and Google (Gmail) accounts, read and changed through Microsoft Graph and the Gmail and
//! Google Calendar APIs. The brain gets the Mac's tools on them (`mail_unread`, `inbox_mail`, `search_mail`, `read_mail`,
//! `trash_mail`, `mark_mail`, `create_event`), the calendars join `list_events`, `check_availability` and `find_time`,
//! and a mail written with `compose_mail` goes out through the account after your Send.
//!
//! Nothing of a mail is written to disk or a log; tokens live in the keychain only.

pub mod auth;
pub mod gmail;
pub mod graph;
pub mod service;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::connectors::dates;

/// Who holds the account.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    /// Outlook.com, Hotmail, Microsoft 365 (Microsoft Graph).
    Microsoft,
    /// Gmail and Google Workspace (Gmail API, Google Calendar).
    Google,
}

impl Provider {
    pub fn name(self) -> &'static str {
        match self {
            Self::Microsoft => "Microsoft",
            Self::Google => "Google",
        }
    }
}

/// One linked account (kept in `connectors.json`; its refresh token in the keychain under [`MailAccount::token_key`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailAccount {
    pub id: String,
    pub provider: Provider,
    /// The address it signed in as.
    pub address: String,
    #[serde(default)]
    pub name: String,
    /// Read and write its calendar too.
    #[serde(default = "yes")]
    pub calendar: bool,
}

fn yes() -> bool {
    true
}

impl MailAccount {
    pub fn token_key(&self) -> String {
        format!("mail.{}.refresh", self.id)
    }

    /// "Werk (Microsoft)", else the address.
    pub fn label(&self) -> String {
        if self.name.is_empty() {
            self.address.clone()
        } else {
            format!("{} ({})", self.name, self.provider.name())
        }
    }
}

/// One mail as the tools show it. `id` is "<account>:<the provider's id>", so a tool's answer names the account too.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Mail {
    pub id: String,
    pub account: String,
    pub from_name: String,
    pub from_address: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub subject: String,
    pub date: Option<DateTime<Utc>>,
    pub unread: bool,
    pub flagged: bool,
    /// Whether you answered it, where the provider says so.
    pub replied: Option<bool>,
    pub snippet: String,
    /// The whole text, once read.
    pub body: Option<String>,
    pub thread: Option<String>,
    /// The `Message-ID` header, for threading a reply.
    pub message_id: Option<String>,
}

impl Mail {
    pub fn sender(&self) -> String {
        match (self.from_name.is_empty(), self.from_address.is_empty()) {
            (false, false) => format!("{} <{}>", self.from_name, self.from_address),
            (true, false) => self.from_address.clone(),
            _ => self.from_name.clone(),
        }
    }

    fn trust(&self) -> String {
        crate::brain::message_trust::assess(&self.sender(), &self.subject, self.body.as_deref().unwrap_or(&self.snippet), false).marker()
    }
}

/// The provider's own id of a tool's mail id ("acct:AAMk…" → ("acct", "AAMk…")).
pub fn split_id(id: &str) -> Option<(&str, &str)> {
    id.trim().trim_start_matches("id:").trim().split_once(':').filter(|(a, m)| !a.is_empty() && !m.is_empty())
}

/// What `mark_mail` and `trash_mail` change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    Read,
    Unread,
    Flagged,
    Unflagged,
    Trash,
}

impl Change {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text.trim().to_lowercase().as_str() {
            "read" => Self::Read,
            "unread" => Self::Unread,
            "flagged" => Self::Flagged,
            "unflagged" => Self::Unflagged,
            "trash" => Self::Trash,
            _ => return None,
        })
    }
}

/// Which mail a change is for: ids from `search_mail`, or a filter (`MailActions.selection` on the Mac).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Selection {
    pub ids: Vec<String>,
    pub from: String,
    pub subject: String,
    pub unread_only: bool,
    pub days: Option<i64>,
}

/// At most this many messages per change.
pub const MAX_CHANGE: usize = 200;

impl Selection {
    pub fn from_input(input: &Value) -> Self {
        Self {
            ids: input["ids"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect(),
            from: crate::connectors::text(input, "from").trim().to_string(),
            subject: crate::connectors::text(input, "subject").trim().to_string(),
            unread_only: input["unread_only"].as_bool().unwrap_or(false),
            days: crate::connectors::int(&input["days"]).filter(|d| *d > 0),
        }
    }

    /// Why this selection is not enough to act on (never "everything"): empty when it is.
    pub fn problems(&self) -> Vec<String> {
        if self.ids.is_empty() && self.from.is_empty() && self.subject.is_empty() && !(self.unread_only && self.days.is_some()) {
            return vec!["Choose the mail: ids from search_mail, or a filter (from, subject, or unread_only with days).".into()];
        }
        if self.ids.len() > MAX_CHANGE {
            return vec![format!("At most {MAX_CHANGE} messages per action.")];
        }
        vec![]
    }

    /// Whether `mail` falls under the filter part (ids are matched by the caller).
    pub fn matches(&self, mail: &Mail, now: DateTime<Utc>) -> bool {
        let fold = |s: &str| s.to_lowercase();
        (self.from.is_empty() || fold(&mail.sender()).contains(&fold(&self.from)))
            && (self.subject.is_empty() || fold(&mail.subject).contains(&fold(&self.subject)))
            && (!self.unread_only || mail.unread)
            && self.days.is_none_or(|d| mail.date.is_some_and(|t| t >= now - chrono::Duration::days(d)))
    }

    /// "Mark mail from linkedin as read" for the plan card.
    pub fn summary(&self, change: Change) -> String {
        let what = match change {
            Change::Read => "Mark as read",
            Change::Unread => "Mark as unread",
            Change::Flagged => "Flag",
            Change::Unflagged => "Unflag",
            Change::Trash => "Move to Trash",
        };
        let mut parts = vec![];
        if !self.ids.is_empty() {
            parts.push(format!("{} message{}", self.ids.len(), if self.ids.len() == 1 { "" } else { "s" }));
        }
        if !self.from.is_empty() {
            parts.push(format!("from {}", self.from));
        }
        if !self.subject.is_empty() {
            parts.push(format!("about \"{}\"", self.subject));
        }
        if self.unread_only {
            parts.push("unread".into());
        }
        if let Some(d) = self.days {
            parts.push(format!("last {d} days"));
        }
        format!("{what}: {}", parts.join(", "))
    }
}

/// A mail to send after your click (`compose_mail`'s draft).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Outgoing {
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body: String,
    /// A tool mail id this answers: the reply goes in its thread.
    pub reply_to: Option<String>,
    pub attachments: Vec<Attachment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    pub name: String,
    pub mime: String,
    pub bytes: Vec<u8>,
}

/// One calendar event from an account.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub id: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub all_day: bool,
    pub busy: bool,
    pub location: String,
}

/// A new event (`create_event`).
#[derive(Debug, Clone, PartialEq)]
pub struct NewEvent {
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub location: String,
    pub notes: String,
}

impl NewEvent {
    /// `create_event`'s input: title and start needed, end an hour later by default.
    pub fn from_input(input: &Value) -> Result<Self, String> {
        let title = crate::connectors::text(input, "title").trim().to_string();
        if title.is_empty() {
            return Err("The event needs a title.".into());
        }
        let start = dates::parse(crate::connectors::text(input, "start")).ok_or("start must be an ISO 8601 time.")?;
        let end = dates::parse(crate::connectors::text(input, "end")).filter(|e| *e > start).unwrap_or(start + chrono::Duration::hours(1));
        Ok(Self {
            title,
            start,
            end,
            location: crate::connectors::text(input, "location").trim().to_string(),
            notes: crate::connectors::text(input, "notes").trim().to_string(),
        })
    }
}

// What the tools answer

fn when(date: Option<DateTime<Utc>>) -> String {
    date.map(dates::iso).unwrap_or_else(|| "?".into())
}

fn shorten(text: &str, max: usize) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        one_line
    } else {
        format!("{}…", one_line.chars().take(max).collect::<String>())
    }
}

/// `inbox_mail`'s and `search_mail`'s lines, newest first, each with its id and the start of its text.
pub fn lines(mails: &[Mail], labels: &dyn Fn(&str) -> String) -> String {
    mails
        .iter()
        .map(|m| {
            let mut state = vec![if m.unread { "unread" } else { "read" }.to_string()];
            if m.replied == Some(true) {
                state.push("replied".into());
            }
            if m.flagged {
                state.push("flagged".into());
            }
            let trust = m.trust();
            let warn = if trust.is_empty() { String::new() } else { format!("\n  {trust}") };
            format!(
                "- {} | from {} | {} | {} | {} | id:{}\n  {}{warn}",
                if m.subject.is_empty() { "(no subject)" } else { &m.subject },
                m.sender(),
                when(m.date),
                state.join(", "),
                labels(&m.account),
                m.id,
                shorten(&m.snippet, 240)
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `read_mail`'s answer: the whole message.
pub fn full(mail: &Mail) -> String {
    let mut out = vec![format!("Subject: {}", mail.subject), format!("From: {}", mail.sender()), format!("To: {}", mail.to.join(", "))];
    if !mail.cc.is_empty() {
        out.push(format!("Cc: {}", mail.cc.join(", ")));
    }
    out.push(format!("Date: {}", when(mail.date)));
    out.push(format!("id:{}", mail.id));
    let trust = mail.trust();
    if !trust.is_empty() {
        out.push(trust);
    }
    out.push(String::new());
    let body = mail.body.clone().unwrap_or_else(|| mail.snippet.clone());
    out.push(body.chars().take(20_000).collect());
    out.join("\n")
}

/// `mail_unread`'s answer: total, per account, per day received (the last 14 days) and the senders with the most.
pub fn unread_summary(per_account: &[(String, usize)], recent: &[Mail], now: DateTime<Utc>) -> String {
    let total: usize = per_account.iter().map(|(_, n)| n).sum();
    let mut out = vec![format!("Unread mail in the inbox: {total}.")];
    if per_account.len() > 1 {
        out.push(format!("Per account: {}.", per_account.iter().map(|(a, n)| format!("{a}: {n}")).collect::<Vec<_>>().join(", ")));
    }
    let mut days: std::collections::BTreeMap<String, usize> = Default::default();
    let mut senders: std::collections::HashMap<String, usize> = Default::default();
    for m in recent.iter().filter(|m| m.unread) {
        if let Some(d) = m.date.filter(|d| *d >= now - chrono::Duration::days(14)) {
            *days.entry(d.format("%Y-%m-%d").to_string()).or_default() += 1;
        }
        let who = if m.from_name.is_empty() { m.from_address.clone() } else { m.from_name.clone() };
        *senders.entry(who).or_default() += 1;
    }
    if !days.is_empty() {
        out.push(format!(
            "Per day received (last 14 days): {}.",
            days.iter().map(|(d, n)| format!("{d}: {n}")).collect::<Vec<_>>().join(", ")
        ));
    }
    let mut top: Vec<(String, usize)> = senders.into_iter().collect();
    top.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    if !top.is_empty() {
        out.push(format!("Most unread from: {}.", top.iter().take(8).map(|(s, n)| format!("{s} ({n})")).collect::<Vec<_>>().join(", ")));
    }
    out.join("\n")
}

/// Plain text from HTML, for a mail that has no text part: tags out, entities read, paragraphs kept.
pub fn html_to_text(html: &str) -> String {
    static TAGS: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"(?is)<(script|style)[^>]*>.*?</(script|style)>|<[^>]+>").expect("valid"));
    static BREAKS: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"(?i)<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>").expect("valid"));
    let text = BREAKS.replace_all(html, "\n");
    let text = TAGS.replace_all(&text, "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    let mut out = vec![];
    for line in text.lines().map(str::trim) {
        if line.is_empty() && out.last().is_some_and(|l: &String| l.is_empty()) {
            continue;
        }
        out.push(line.to_string());
    }
    out.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mail(id: &str, from: &str, subject: &str, unread: bool) -> Mail {
        Mail {
            id: format!("a:{id}"),
            account: "a".into(),
            from_name: from.into(),
            from_address: format!("{}@example.com", from.to_lowercase()),
            subject: subject.into(),
            unread,
            date: Some(Utc::now()),
            snippet: "Hello there".into(),
            ..Default::default()
        }
    }

    #[test]
    fn a_selection_never_means_everything() {
        assert!(!Selection::default().problems().is_empty());
        assert!(Selection { from: "linkedin".into(), ..Default::default() }.problems().is_empty());
        assert!(Selection { unread_only: true, days: Some(7), ..Default::default() }.problems().is_empty());
        assert!(!Selection { unread_only: true, ..Default::default() }.problems().is_empty());
        let s = Selection { from: "LinkedIn".into(), unread_only: true, ..Default::default() };
        assert!(s.matches(&mail("1", "Linkedin", "Jobs", true), Utc::now()));
        assert!(!s.matches(&mail("2", "Linkedin", "Jobs", false), Utc::now()));
        assert_eq!(s.summary(Change::Read), "Mark as read: from LinkedIn, unread");
    }

    #[test]
    fn ids_name_their_account() {
        assert_eq!(split_id("id:work:AAMkAD=="), Some(("work", "AAMkAD==")));
        assert_eq!(split_id("nothing"), None);
    }

    #[test]
    fn the_tools_show_mail_with_its_id_and_a_warning_for_a_fake() {
        let mut fake = mail("2", "PayPal", "Verify your account now", true);
        fake.from_address = "service@paypa1-secure.example".into();
        fake.snippet = "Your account is suspended. Log in within 24 hours to verify your identity.".into();
        let text = lines(&[mail("1", "Anna", "Lunch?", true), fake], &|_| "Work".into());
        assert!(text.contains("Lunch? | from Anna <anna@example.com>"));
        assert!(text.contains("id:a:1"));
        assert!(text.contains("WARNING"));
        let summary = unread_summary(&[("Work".into(), 3), ("Home".into(), 2)], &[mail("1", "Anna", "x", true)], Utc::now());
        assert!(summary.starts_with("Unread mail in the inbox: 5."));
        assert!(summary.contains("Work: 3, Home: 2"));
        assert!(summary.contains("Anna (1)"));
    }

    #[test]
    fn html_becomes_readable_text() {
        let text = html_to_text("<html><style>p{}</style><p>Hi&nbsp;Anna,</p><p>See you <b>tomorrow</b>.</p><br>Bye</html>");
        assert_eq!(text, "Hi Anna,\nSee you tomorrow.\n\nBye");
    }

    #[test]
    fn an_event_needs_a_title_and_a_start() {
        let e = NewEvent::from_input(&serde_json::json!({"title": "Lunch", "start": "2026-11-23T12:00:00Z"})).unwrap();
        assert_eq!((e.end - e.start).num_minutes(), 60);
        assert!(NewEvent::from_input(&serde_json::json!({"start": "2026-11-23T12:00:00Z"})).is_err());
    }
}
