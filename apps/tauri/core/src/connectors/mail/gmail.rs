//! The Gmail API and Google Calendar for a Google account: the inbox, search, one message, the Trash, read and star
//! marks, sending (a reply in its thread, with attachments as MIME), and the primary calendar. Field names from
//! developers.google.com/gmail/api/reference/rest and developers.google.com/calendar/api/v3/reference/events.

use base64::Engine;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::{Change, Event, Mail, NewEvent, Outgoing};
use crate::connectors::{list, with_query, CResult, ConnectorError, Http};

pub const GMAIL: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
pub const CALENDAR: &str = "https://www.googleapis.com/calendar/v3/calendars/primary";
const SERVICE: &str = "Google";

fn auth(token: &str) -> [(&'static str, String); 1] {
    [("Authorization", format!("Bearer {token}"))]
}

fn header<'a>(payload: &'a Value, name: &str) -> &'a str {
    list(&payload["headers"])
        .iter()
        .find(|h| h["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)))
        .and_then(|h| h["value"].as_str())
        .unwrap_or("")
}

/// "Anna <anna@x.nl>" → ("Anna", "anna@x.nl"); a bare address has no name.
pub fn person(text: &str) -> (String, String) {
    let text = text.trim();
    match (text.rfind('<'), text.rfind('>')) {
        (Some(a), Some(b)) if a < b => (text[..a].trim().trim_matches('"').to_string(), text[a + 1..b].trim().to_string()),
        _ => (String::new(), text.to_string()),
    }
}

fn split_people(text: &str) -> Vec<String> {
    // Commas inside a quoted name do not split.
    let mut out = vec![];
    let (mut current, mut quoted) = (String::new(), false);
    for c in text.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                current.push(c);
            }
            ',' if !quoted => {
                out.push(std::mem::take(&mut current));
            }
            _ => current.push(c),
        }
    }
    out.push(current);
    out.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

fn decode(data: &str) -> Option<String> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(data.trim_end_matches('=')).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// The text of a message: its first text/plain part, else its HTML as text.
pub fn body_text(payload: &Value) -> Option<String> {
    fn find(part: &Value, mime: &str) -> Option<String> {
        if part["mimeType"].as_str() == Some(mime) {
            if let Some(text) = part["body"]["data"].as_str().and_then(decode) {
                return Some(text);
            }
        }
        list(&part["parts"]).iter().find_map(|p| find(p, mime))
    }
    find(payload, "text/plain").map(|t| t.trim().to_string()).or_else(|| find(payload, "text/html").map(|h| super::html_to_text(&h)))
}

/// One message of `messages.get` (format metadata or full).
pub fn message(v: &Value, account: &str) -> Option<Mail> {
    let id = v["id"].as_str()?;
    let payload = &v["payload"];
    let (from_name, from_address) = person(header(payload, "From"));
    let labels: Vec<&str> = list(&v["labelIds"]).iter().filter_map(Value::as_str).collect();
    let date = v["internalDate"]
        .as_str()
        .and_then(|ms| ms.parse::<i64>().ok())
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .or_else(|| DateTime::parse_from_rfc2822(header(payload, "Date")).ok().map(|d| d.with_timezone(&Utc)));
    Some(Mail {
        id: format!("{account}:{id}"),
        account: account.into(),
        from_name,
        from_address,
        to: split_people(header(payload, "To")),
        cc: split_people(header(payload, "Cc")),
        subject: header(payload, "Subject").into(),
        date,
        unread: labels.contains(&"UNREAD"),
        flagged: labels.contains(&"STARRED"),
        replied: None,
        snippet: v["snippet"].as_str().map(super::html_to_text).unwrap_or_default(),
        body: body_text(payload),
        thread: v["threadId"].as_str().map(str::to_string),
        message_id: Some(header(payload, "Message-ID").to_string()).filter(|s| !s.is_empty()),
    })
}

const METADATA: [(&str, &str); 6] = [
    ("metadataHeaders", "From"),
    ("metadataHeaders", "To"),
    ("metadataHeaders", "Cc"),
    ("metadataHeaders", "Subject"),
    ("metadataHeaders", "Date"),
    ("metadataHeaders", "Message-ID"),
];

/// Mail that fits a Gmail search ("in:inbox newer_than:7d is:unread"), newest first, with its headers.
pub async fn query(http: &Http, base: &str, token: &str, account: &str, q: &str, limit: usize) -> CResult<Vec<Mail>> {
    let url = with_query(&format!("{base}/messages"), &[("q", q.to_string()), ("maxResults", limit.to_string())]);
    let found = http.get(&url, &auth(token), SERVICE).await?;
    let mut out = vec![];
    for id in list(&found["messages"]).iter().filter_map(|m| m["id"].as_str()).take(limit) {
        let mut query: Vec<(&str, String)> = vec![("format", "metadata".into())];
        query.extend(METADATA.iter().map(|(k, v)| (*k, v.to_string())));
        let url = with_query(&format!("{base}/messages/{id}"), &query);
        if let Some(m) = message(&http.get(&url, &auth(token), SERVICE).await?, account) {
            out.push(m);
        }
    }
    Ok(out)
}

/// The search for the inbox since `days` back.
pub fn inbox_query(days: i64, unread_only: bool) -> String {
    format!("in:inbox newer_than:{days}d{}", if unread_only { " is:unread" } else { "" })
}

/// Keywords in the inbox or Sent.
pub fn search_query(words: &str, sent: bool) -> String {
    format!("in:{} {}", if sent { "sent" } else { "inbox" }, words.trim())
}

pub async fn unread_count(http: &Http, base: &str, token: &str) -> CResult<usize> {
    let v = http.get(&format!("{base}/labels/INBOX"), &auth(token), SERVICE).await?;
    Ok(v["messagesUnread"].as_u64().unwrap_or(0) as usize)
}

pub async fn read(http: &Http, base: &str, token: &str, account: &str, id: &str) -> CResult<Mail> {
    let v = http.get(&format!("{base}/messages/{id}?format=full"), &auth(token), SERVICE).await?;
    message(&v, account).ok_or_else(|| ConnectorError::new("This message is gone."))
}

pub async fn change(http: &Http, base: &str, token: &str, id: &str, change: Change) -> CResult<()> {
    let (url, body) = match change {
        Change::Trash => (format!("{base}/messages/{id}/trash"), Value::Null),
        Change::Read => (format!("{base}/messages/{id}/modify"), json!({"removeLabelIds": ["UNREAD"]})),
        Change::Unread => (format!("{base}/messages/{id}/modify"), json!({"addLabelIds": ["UNREAD"]})),
        Change::Flagged => (format!("{base}/messages/{id}/modify"), json!({"addLabelIds": ["STARRED"]})),
        Change::Unflagged => (format!("{base}/messages/{id}/modify"), json!({"removeLabelIds": ["STARRED"]})),
    };
    http.json("POST", &url, &auth(token), (!body.is_null()).then_some(&body), SERVICE).await.map(|_| ())
}

/// A header value as RFC 2047 when it is not plain ASCII.
fn header_text(text: &str) -> String {
    if text.is_ascii() {
        text.to_string()
    } else {
        format!("=?UTF-8?B?{}?=", base64::engine::general_purpose::STANDARD.encode(text))
    }
}

fn wrapped(bytes: &[u8]) -> String {
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
    encoded.as_bytes().chunks(76).map(|c| String::from_utf8_lossy(c).into_owned()).collect::<Vec<_>>().join("\r\n")
}

/// The whole mail as MIME (RFC 2822): text in UTF-8, each attachment as a base64 part; a reply names the original in
/// `In-Reply-To` and `References`.
pub fn mime(mail: &Outgoing, from: &str, in_reply_to: Option<&str>, boundary: &str) -> String {
    let mut head = vec![format!("From: {from}"), format!("To: {}", mail.to.join(", "))];
    if !mail.cc.is_empty() {
        head.push(format!("Cc: {}", mail.cc.join(", ")));
    }
    if !mail.bcc.is_empty() {
        head.push(format!("Bcc: {}", mail.bcc.join(", ")));
    }
    head.push(format!("Subject: {}", header_text(&mail.subject)));
    if let Some(id) = in_reply_to {
        head.push(format!("In-Reply-To: {id}"));
        head.push(format!("References: {id}"));
    }
    head.push("MIME-Version: 1.0".into());
    let text = format!("Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{}", wrapped(mail.body.as_bytes()));
    if mail.attachments.is_empty() {
        return format!("{}\r\n{text}\r\n", head.join("\r\n"));
    }
    head.push(format!("Content-Type: multipart/mixed; boundary=\"{boundary}\""));
    let mut out = format!("{}\r\n\r\n--{boundary}\r\n{text}\r\n", head.join("\r\n"));
    for a in &mail.attachments {
        let name = a.name.replace('"', "");
        out.push_str(&format!(
            "--{boundary}\r\nContent-Type: {}; name=\"{name}\"\r\nContent-Disposition: attachment; filename=\"{name}\"\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",
            a.mime,
            wrapped(&a.bytes)
        ));
    }
    out.push_str(&format!("--{boundary}--\r\n"));
    out
}

/// Sends through the account; `reply` is the original (its thread and `Message-ID`).
pub async fn send(http: &Http, base: &str, token: &str, from: &str, mail: &Outgoing, reply: Option<&Mail>) -> CResult<()> {
    let boundary = format!("nook-{}", uuid::Uuid::new_v4().simple());
    let raw = mime(mail, from, reply.and_then(|r| r.message_id.as_deref()), &boundary);
    let mut body = json!({"raw": base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw)});
    if let Some(thread) = reply.and_then(|r| r.thread.clone()) {
        body["threadId"] = json!(thread);
    }
    http.json("POST", &format!("{base}/messages/send"), &auth(token), Some(&body), SERVICE).await.map(|_| ())
}

fn when(v: &Value) -> Option<(DateTime<Utc>, bool)> {
    if let Some(t) = v["dateTime"].as_str() {
        return crate::connectors::dates::parse(t).map(|d| (d, false));
    }
    let day = chrono::NaiveDate::parse_from_str(v["date"].as_str()?, "%Y-%m-%d").ok()?;
    Some((day.and_hms_opt(0, 0, 0)?.and_utc(), true))
}

pub fn parse_events(v: &Value) -> Vec<Event> {
    list(&v["items"])
        .iter()
        .filter(|e| e["status"].as_str() != Some("cancelled"))
        .filter_map(|e| {
            let (start, all_day) = when(&e["start"])?;
            let (end, _) = when(&e["end"])?;
            Some(Event {
                id: e["id"].as_str()?.into(),
                title: e["summary"].as_str().unwrap_or("").into(),
                start,
                end,
                all_day,
                busy: e["transparency"].as_str() != Some("transparent"),
                location: e["location"].as_str().unwrap_or("").into(),
            })
        })
        .collect()
}

pub async fn events(http: &Http, base: &str, token: &str, from: DateTime<Utc>, to: DateTime<Utc>) -> CResult<Vec<Event>> {
    let url = with_query(
        &format!("{base}/events"),
        &[
            ("timeMin", from.to_rfc3339()),
            ("timeMax", to.to_rfc3339()),
            ("singleEvents", "true".into()),
            ("orderBy", "startTime".into()),
            ("maxResults", "250".into()),
        ],
    );
    Ok(parse_events(&http.get(&url, &auth(token), SERVICE).await?))
}

pub fn event_body(event: &NewEvent) -> Value {
    json!({
        "summary": event.title,
        "start": {"dateTime": event.start.to_rfc3339()},
        "end": {"dateTime": event.end.to_rfc3339()},
        "location": event.location,
        "description": event.notes,
    })
}

pub async fn create_event(http: &Http, base: &str, token: &str, event: &NewEvent) -> CResult<String> {
    let v = http.json("POST", &format!("{base}/events"), &auth(token), Some(&event_body(event)), SERVICE).await?;
    Ok(v["id"].as_str().unwrap_or("").to_string())
}

/// The account's own address, after signing in.
pub async fn me(http: &Http, base: &str, token: &str) -> CResult<String> {
    let v = http.get(&format!("{base}/profile"), &auth(token), SERVICE).await?;
    Ok(v["emailAddress"].as_str().unwrap_or("").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;

    fn b64(text: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(text)
    }

    #[test]
    fn a_message_with_its_headers_labels_and_text() {
        let v = json!({
            "id": "18c1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD", "STARRED"], "snippet": "Shall we &amp; eat?",
            "internalDate": "1795165200000",
            "payload": {"mimeType": "multipart/alternative", "headers": [
                {"name": "From", "value": "\"Anna B\" <anna@example.com>"},
                {"name": "To", "value": "me@example.com, \"Doe, John\" <john@example.com>"},
                {"name": "Subject", "value": "Lunch?"}, {"name": "Message-ID", "value": "<m1@mail.gmail.com>"}],
              "parts": [{"mimeType": "text/html", "body": {"data": b64("<p>HTML</p>")}},
                        {"mimeType": "text/plain", "body": {"data": b64("Plain text\n")}}]}
        });
        let m = message(&v, "home").unwrap();
        assert_eq!((m.id.as_str(), m.from_name.as_str(), m.from_address.as_str()), ("home:18c1", "Anna B", "anna@example.com"));
        assert_eq!(m.to, vec!["me@example.com", "\"Doe, John\" <john@example.com>"]);
        assert!(m.unread && m.flagged);
        assert_eq!(m.body.as_deref(), Some("Plain text"));
        assert_eq!(m.snippet, "Shall we & eat?");
        assert_eq!(m.message_id.as_deref(), Some("<m1@mail.gmail.com>"));
        assert_eq!(m.date.unwrap().timestamp(), 1795165200);
    }

    #[test]
    fn a_reply_is_threaded_and_attachments_ride_along() {
        let mail = Outgoing {
            to: vec!["anna@example.com".into()],
            subject: "Re: Lunch – morgen".into(),
            body: "Ja!".into(),
            attachments: vec![super::super::Attachment { name: "invite.ics".into(), mime: "text/calendar".into(), bytes: b"BEGIN:VCALENDAR".to_vec() }],
            ..Default::default()
        };
        let raw = mime(&mail, "me@example.com", Some("<m1@x>"), "B");
        assert!(raw.contains("In-Reply-To: <m1@x>\r\nReferences: <m1@x>"));
        assert!(raw.contains("Subject: =?UTF-8?B?"));
        assert!(raw.contains("multipart/mixed; boundary=\"B\""));
        assert!(raw.contains("filename=\"invite.ics\""));
        assert!(raw.contains(&base64::engine::general_purpose::STANDARD.encode("BEGIN:VCALENDAR")));
        assert!(raw.ends_with("--B--\r\n"));
    }

    #[tokio::test]
    async fn the_inbox_is_listed_then_each_mail_fetched() {
        let one = json!({"id": "m1", "labelIds": ["UNREAD"], "payload": {"headers": [{"name": "From", "value": "x@y.z"}, {"name": "Subject", "value": "Hi"}]}});
        let server = TestServer::start(vec![
            ("/messages", 200, r#"{"messages":[{"id":"m1"}]}"#.into()),
            ("/messages/m1", 200, one.to_string()),
            ("POST /messages/m1/modify", 200, "{}".into()),
            ("POST /messages/send", 200, "{}".into()),
        ])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let http = Http::new();
        let mails = query(&http, &base, "tok", "home", &inbox_query(7, true), 5).await.unwrap();
        assert_eq!(mails[0].subject, "Hi");
        change(&http, &base, "tok", "m1", Change::Read).await.unwrap();
        let reply = Mail { thread: Some("t1".into()), message_id: Some("<m1@x>".into()), ..Default::default() };
        send(&http, &base, "tok", "me@x.nl", &Outgoing { to: vec!["x@y.z".into()], body: "Ok".into(), ..Default::default() }, Some(&reply))
            .await
            .unwrap();
        let got = server.received.lock().unwrap().clone();
        assert!(got[0].path.contains("is%3Aunread") || got[0].path.contains("is:unread"));
        assert!(got[2].body.contains("UNREAD"));
        let sent: Value = serde_json::from_str(&got[3].body).unwrap();
        assert_eq!(sent["threadId"], "t1");
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(sent["raw"].as_str().unwrap()).unwrap();
        assert!(String::from_utf8(raw).unwrap().contains("In-Reply-To: <m1@x>"));
    }

    #[test]
    fn calendar_events_and_all_day_ones() {
        let v = json!({"items": [
            {"id": "e1", "summary": "Standup", "start": {"dateTime": "2026-11-23T09:30:00+01:00"}, "end": {"dateTime": "2026-11-23T09:45:00+01:00"}},
            {"id": "e2", "summary": "Holiday", "start": {"date": "2026-11-24"}, "end": {"date": "2026-11-25"}, "transparency": "transparent"},
            {"id": "e3", "status": "cancelled", "start": {"date": "2026-11-24"}, "end": {"date": "2026-11-25"}}]});
        let events = parse_events(&v);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].start.to_rfc3339(), "2026-11-23T08:30:00+00:00");
        assert!(events[1].all_day && !events[1].busy);
    }
}
