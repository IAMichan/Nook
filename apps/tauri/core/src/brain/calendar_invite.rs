//! A real calendar invitation (iCalendar, RFC 5545, `METHOD:REQUEST`) that goes with a mail draft as `invite.ics`.
//! Mail clients (Outlook, Thunderbird, Gmail, Apple Mail) show an attached `.ics` request as an invitation with
//! Accept and Decline. `compose_mail`'s `invite` builds it.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::dates;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarInviteEvent {
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub notes: String,
    /// The user's own address; left out when unknown.
    #[serde(default)]
    pub organizer: String,
    #[serde(default)]
    pub attendees: Vec<String>,
    pub uid: String,
    pub stamp: DateTime<Utc>,
}

impl CalendarInviteEvent {
    pub fn new(title: impl Into<String>, start: DateTime<Utc>, end: DateTime<Utc>) -> Self {
        Self {
            title: title.into(),
            start,
            end,
            location: String::new(),
            notes: String::new(),
            organizer: String::new(),
            attendees: Vec::new(),
            uid: format!("{}@nook", uuid::Uuid::new_v4()),
            stamp: Utc::now(),
        }
    }
}

/// The whole file, CRLF line endings and lines folded at 75 octets as the standard asks.
pub fn ics(event: &CalendarInviteEvent) -> String {
    let mut lines = vec![
        "BEGIN:VCALENDAR".to_string(),
        "VERSION:2.0".to_string(),
        "PRODID:-//Nook//Nook//EN".to_string(),
        "CALSCALE:GREGORIAN".to_string(),
        "METHOD:REQUEST".to_string(),
        "BEGIN:VEVENT".to_string(),
        format!("UID:{}", event.uid),
        format!("DTSTAMP:{}", utc(event.stamp)),
        format!("DTSTART:{}", utc(event.start)),
        format!("DTEND:{}", utc(event.end.max(event.start + Duration::seconds(60)))),
        format!("SUMMARY:{}", escape(&event.title)),
    ];
    if !event.location.is_empty() {
        lines.push(format!("LOCATION:{}", escape(&event.location)));
    }
    if !event.notes.is_empty() {
        lines.push(format!("DESCRIPTION:{}", escape(&event.notes)));
    }
    let organizer = event.organizer.trim().to_lowercase();
    if is_address(&organizer) {
        lines.push(format!("ORGANIZER:mailto:{organizer}"));
    }
    let mut seen: HashSet<String> = HashSet::from([organizer]);
    for raw in &event.attendees {
        let address = raw.trim().to_lowercase();
        if is_address(&address) && seen.insert(address.clone()) {
            lines.push(format!("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:{address}"));
        }
    }
    lines.extend([
        "SEQUENCE:0".to_string(),
        "STATUS:CONFIRMED".to_string(),
        "TRANSP:OPAQUE".to_string(),
        "END:VEVENT".to_string(),
        "END:VCALENDAR".to_string(),
    ]);
    let mut out = lines.into_iter().map(|line| fold(&line)).collect::<Vec<_>>().join("\r\n");
    out.push_str("\r\n");
    out
}

/// Writes the invitation as `invite.ics` in a folder of its own under `folder` (one per draft, so two drafts never
/// share a file) and returns its path.
pub fn write(event: &CalendarInviteEvent, folder: &Path) -> std::io::Result<PathBuf> {
    let dir = folder.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&dir)?;
    let file = dir.join("invite.ics");
    std::fs::write(&file, ics(event).as_bytes())?;
    Ok(file)
}

/// The fields of `compose_mail`'s `invite`, `None` when it has no title or no start time it can read.
pub fn event_from_input(input: &Value, attendees: Vec<String>, organizer: &str) -> Option<CalendarInviteEvent> {
    let text = |key: &str| input[key].as_str().unwrap_or("").trim().to_string();
    let title = text("title");
    if title.is_empty() {
        return None;
    }
    let start = dates::parse(&text("start"))?.with_timezone(&Utc);
    let end =
        dates::parse(&text("end")).map(|d| d.with_timezone(&Utc)).filter(|e| *e > start).unwrap_or_else(|| start + Duration::seconds(3600));
    Some(CalendarInviteEvent {
        title,
        start,
        end,
        location: text("location"),
        notes: text("notes"),
        organizer: organizer.to_string(),
        attendees,
        uid: format!("{}@nook", uuid::Uuid::new_v4()),
        stamp: Utc::now(),
    })
}

pub fn utc(date: DateTime<Utc>) -> String {
    date.format("%Y%m%dT%H%M%SZ").to_string()
}

/// TEXT values: backslash, semicolon, comma and line breaks escaped.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => out.push_str("\\\\"),
            ';' => out.push_str("\\;"),
            ',' => out.push_str("\\,"),
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push_str("\\n");
            }
            '\n' => out.push_str("\\n"),
            _ => out.push(ch),
        }
    }
    out
}

/// A content line longer than 75 octets continues on the next line after a space, never inside a UTF-8 character.
pub fn fold(line: &str) -> String {
    if line.len() <= 75 {
        return line.to_string();
    }
    let mut parts = Vec::new();
    let mut current = String::new();
    for ch in line.chars() {
        let limit = if parts.is_empty() { 75 } else { 74 };
        if current.len() + ch.len_utf8() > limit {
            parts.push(std::mem::take(&mut current));
        }
        current.push(ch);
    }
    parts.push(current);
    parts.join("\r\n ")
}

/// Parses email addresses from `"lisa@x.nl, Bram <bram@y.nl>; …"`.
pub fn addresses(text: &str) -> Vec<String> {
    text.split([',', ';', '\n'])
        .filter_map(|part| {
            let trimmed = part.trim();
            let address = match (trimmed.find('<'), trimmed.rfind('>')) {
                (Some(open), Some(close)) if open < close => trimmed[open + 1..close].trim(),
                _ => trimmed,
            };
            (!address.is_empty()).then(|| address.to_string())
        })
        .collect()
}

pub fn is_address(text: &str) -> bool {
    let mut parts = text.split('@');
    match (parts.next(), parts.next(), parts.next()) {
        (Some(local), Some(domain), None) => {
            !local.is_empty() && domain.contains('.') && !text.contains(char::is_whitespace) && !text.contains(':')
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn start() -> DateTime<Utc> {
        DateTime::from_timestamp(1_795_000_000, 0).unwrap()
    }

    fn sample_event() -> CalendarInviteEvent {
        let start = start();
        CalendarInviteEvent {
            title: "Lunch, with Jan; and Sara".into(),
            start,
            end: start + Duration::seconds(3600),
            location: "Café de Jaren".into(),
            notes: "Line one\nLine two".into(),
            organizer: "Me@Example.com".into(),
            attendees: vec![
                "jan@example.com".into(),
                "JAN@example.com".into(),
                "not an address".into(),
                "me@example.com".into(),
                "sara@example.nl".into(),
            ],
            uid: "abc@nook".into(),
            stamp: start,
        }
    }

    #[test]
    fn request_with_every_attendee_once() {
        let text = ics(&sample_event());
        assert!(text.starts_with("BEGIN:VCALENDAR\r\n"));
        assert!(text.contains("METHOD:REQUEST\r\n"));
        assert!(text.contains("UID:abc@nook\r\n"));
        assert!(text.contains(&format!("DTSTART:{}\r\n", utc(start()))));
        assert!(text.contains("ORGANIZER:mailto:me@example.com\r\n"));
        let attendees: Vec<&str> = text.split("\r\n").filter(|line| line.starts_with("ATTENDEE")).collect();
        assert_eq!(attendees.len(), 2, "duplicates, the organizer and a non-address are left out");
        assert!(attendees.iter().all(|line| line.contains("RSVP=TRUE")));
        assert!(text.ends_with("END:VCALENDAR\r\n"));
    }

    #[test]
    fn text_is_escaped() {
        let text = ics(&sample_event());
        assert!(text.contains("SUMMARY:Lunch\\, with Jan\\; and Sara\r\n"));
        assert!(text.contains("DESCRIPTION:Line one\\nLine two\r\n"));
    }

    #[test]
    fn utc_stamp() {
        assert_eq!(utc(DateTime::from_timestamp(0, 0).unwrap()), "19700101T000000Z");
    }

    #[test]
    fn long_lines_fold_without_splitting_characters() {
        let line = format!("DESCRIPTION:{}", "é".repeat(80));
        let folded = fold(&line);
        let parts: Vec<&str> = folded.split("\r\n").collect();
        assert!(parts.len() > 1);
        assert!(parts.iter().all(|part| part.len() <= 75));
        assert!(parts[1..].iter().all(|part| part.starts_with(' ')));
        let unfolded: String = parts.iter().enumerate().map(|(i, part)| if i == 0 { *part } else { &part[1..] }).collect();
        assert_eq!(unfolded, line);
    }

    #[test]
    fn event_from_tool_input() {
        let input = json!({
            "title": "Call",
            "start": "2026-11-18T10:00:00+01:00",
            "end": "2026-11-18T09:00:00+01:00"
        });
        let made = event_from_input(&input, vec!["a@b.nl".into()], "").unwrap();
        assert_eq!((made.end - made.start).num_seconds(), 3600, "an end before the start falls back to an hour");
        assert!(event_from_input(&json!({"title": "Call"}), vec![], "").is_none());
    }

    #[test]
    fn writes_a_file_of_its_own() {
        let folder = std::env::temp_dir().join(format!("nook-invite-tests-{}", uuid::Uuid::new_v4()));
        let event = sample_event();
        let one = write(&event, &folder).unwrap();
        let two = write(&event, &folder).unwrap();
        assert_ne!(one, two);
        assert!(one.ends_with("invite.ics"));
        assert_eq!(std::fs::read_to_string(&one).unwrap(), ics(&event));
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[test]
    fn parses_addresses_with_display_names() {
        assert_eq!(addresses("lisa@x.nl, Bram <bram@y.nl>; \n  Sara <sara@z.nl>"), vec!["lisa@x.nl", "bram@y.nl", "sara@z.nl"]);
    }
}
