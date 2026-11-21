//! Microsoft Graph for an Outlook or Microsoft 365 account: the inbox, search, one message, moving to Deleted Items,
//! read and flag marks, sending (a reply in its thread), and the calendar. Field names from
//! learn.microsoft.com/graph/api/resources/message and …/event.

use base64::Engine;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::{Attachment, Change, Event, Mail, NewEvent, Outgoing};
use crate::connectors::{list, with_query, CResult, ConnectorError, Http};

pub const BASE: &str = "https://graph.microsoft.com/v1.0";
const SERVICE: &str = "Microsoft";
const FIELDS: &str = "id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,flag,bodyPreview,conversationId,internetMessageId";

fn auth(token: &str) -> [(&'static str, String); 2] {
    [("Authorization", format!("Bearer {token}")), ("Prefer", "outlook.body-content-type=\"text\"".into())]
}

fn address(v: &Value) -> (String, String) {
    let e = &v["emailAddress"];
    (e["name"].as_str().unwrap_or("").to_string(), e["address"].as_str().unwrap_or("").to_string())
}

fn people(v: &Value) -> Vec<String> {
    list(v)
        .iter()
        .map(address)
        .map(|(n, a)| if n.is_empty() || n == a { a } else { format!("{n} <{a}>") })
        .filter(|s| !s.is_empty())
        .collect()
}

/// One message of a Graph answer.
pub fn message(v: &Value, account: &str) -> Option<Mail> {
    let id = v["id"].as_str()?;
    let (from_name, from_address) = address(&v["from"]);
    let body = v["body"]["content"].as_str().map(|b| {
        if v["body"]["contentType"].as_str() == Some("html") {
            super::html_to_text(b)
        } else {
            b.trim().to_string()
        }
    });
    Some(Mail {
        id: format!("{account}:{id}"),
        account: account.into(),
        from_name,
        from_address,
        to: people(&v["toRecipients"]),
        cc: people(&v["ccRecipients"]),
        subject: v["subject"].as_str().unwrap_or("").into(),
        date: crate::connectors::date(&v["receivedDateTime"]),
        unread: v["isRead"].as_bool() == Some(false),
        flagged: v["flag"]["flagStatus"].as_str() == Some("flagged"),
        replied: None,
        snippet: v["bodyPreview"].as_str().unwrap_or("").into(),
        body,
        thread: v["conversationId"].as_str().map(str::to_string),
        message_id: v["internetMessageId"].as_str().map(str::to_string),
    })
}

pub fn messages(v: &Value, account: &str) -> Vec<Mail> {
    list(&v["value"]).iter().filter_map(|m| message(m, account)).collect()
}

/// The inbox's newest mail since `since`, unread only when asked.
pub async fn inbox(http: &Http, base: &str, token: &str, account: &str, since: DateTime<Utc>, unread_only: bool, limit: usize) -> CResult<Vec<Mail>> {
    let mut filter = format!("receivedDateTime ge {}", since.format("%Y-%m-%dT%H:%M:%SZ"));
    if unread_only {
        filter.push_str(" and isRead eq false");
    }
    let url = with_query(
        &format!("{base}/me/mailFolders/inbox/messages"),
        &[("$select", FIELDS.into()), ("$top", limit.to_string()), ("$orderby", "receivedDateTime desc".into()), ("$filter", filter)],
    );
    Ok(messages(&http.get(&url, &auth(token), SERVICE).await?, account))
}

/// How many unread messages the inbox holds.
pub async fn unread_count(http: &Http, base: &str, token: &str) -> CResult<usize> {
    let v = http.get(&format!("{base}/me/mailFolders/inbox?$select=unreadItemCount"), &auth(token), SERVICE).await?;
    Ok(v["unreadItemCount"].as_u64().unwrap_or(0) as usize)
}

/// Keywords in the inbox (or in Sent Items).
pub async fn search(http: &Http, base: &str, token: &str, account: &str, query: &str, sent: bool, limit: usize) -> CResult<Vec<Mail>> {
    let folder = if sent { "sentitems" } else { "inbox" };
    let quoted = format!("\"{}\"", query.replace('"', " "));
    let url = with_query(
        &format!("{base}/me/mailFolders/{folder}/messages"),
        &[("$select", FIELDS.into()), ("$top", limit.to_string()), ("$search", quoted)],
    );
    Ok(messages(&http.get(&url, &auth(token), SERVICE).await?, account))
}

/// One whole message, its text as text.
pub async fn read(http: &Http, base: &str, token: &str, account: &str, id: &str) -> CResult<Mail> {
    let url = format!("{base}/me/messages/{}?$select={FIELDS},body", encode(id));
    message(&http.get(&url, &auth(token), SERVICE).await?, account).ok_or_else(|| ConnectorError::new("This message is gone."))
}

/// A change on one message: read marks and flags in place, the Trash as a move to Deleted Items (recoverable there).
pub async fn change(http: &Http, base: &str, token: &str, id: &str, change: Change) -> CResult<()> {
    let id = encode(id);
    let (method, url, body) = match change {
        Change::Trash => ("POST", format!("{base}/me/messages/{id}/move"), json!({"destinationId": "deleteditems"})),
        Change::Read | Change::Unread => ("PATCH", format!("{base}/me/messages/{id}"), json!({"isRead": change == Change::Read})),
        Change::Flagged | Change::Unflagged => (
            "PATCH",
            format!("{base}/me/messages/{id}"),
            json!({"flag": {"flagStatus": if change == Change::Flagged { "flagged" } else { "notFlagged" }}}),
        ),
    };
    http.json(method, &url, &auth(token), Some(&body), SERVICE).await.map(|_| ())
}

fn recipients(list: &[String]) -> Value {
    Value::Array(list.iter().map(|a| json!({"emailAddress": {"address": bare(a)}})).collect())
}

/// "Anna <anna@x.nl>" → "anna@x.nl".
pub fn bare(address: &str) -> String {
    match (address.rfind('<'), address.rfind('>')) {
        (Some(a), Some(b)) if a < b => address[a + 1..b].trim().to_string(),
        _ => address.trim().to_string(),
    }
}

fn attachments(list: &[Attachment]) -> Value {
    Value::Array(
        list.iter()
            .map(|a| {
                json!({
                    "@odata.type": "#microsoft.graph.fileAttachment",
                    "name": a.name,
                    "contentType": a.mime,
                    "contentBytes": base64::engine::general_purpose::STANDARD.encode(&a.bytes),
                })
            })
            .collect(),
    )
}

/// The body of `sendMail` (a new mail) or of `reply` (an answer in the original's thread, `reply_id` its Graph id).
pub fn send_body(mail: &Outgoing, reply: bool) -> Value {
    let mut message = json!({
        "toRecipients": recipients(&mail.to),
        "ccRecipients": recipients(&mail.cc),
        "bccRecipients": recipients(&mail.bcc),
        "attachments": attachments(&mail.attachments),
    });
    if reply {
        // Graph quotes the original under the comment itself.
        return json!({"message": message, "comment": mail.body});
    }
    message["subject"] = json!(mail.subject);
    message["body"] = json!({"contentType": "Text", "content": mail.body});
    json!({"message": message, "saveToSentItems": true})
}

pub async fn send(http: &Http, base: &str, token: &str, mail: &Outgoing, reply_id: Option<&str>) -> CResult<()> {
    let url = match reply_id {
        Some(id) => format!("{base}/me/messages/{}/reply", encode(id)),
        None => format!("{base}/me/sendMail"),
    };
    http.json("POST", &url, &auth(token), Some(&send_body(mail, reply_id.is_some())), SERVICE).await.map(|_| ())
}

/// The calendar between two moments, in UTC.
pub async fn events(http: &Http, base: &str, token: &str, from: DateTime<Utc>, to: DateTime<Utc>) -> CResult<Vec<Event>> {
    let url = with_query(
        &format!("{base}/me/calendarView"),
        &[
            ("startDateTime", from.to_rfc3339()),
            ("endDateTime", to.to_rfc3339()),
            ("$select", "id,subject,start,end,isAllDay,showAs,location,isCancelled".into()),
            ("$top", "250".into()),
        ],
    );
    let headers = [("Authorization", format!("Bearer {token}")), ("Prefer", "outlook.timezone=\"UTC\"".into())];
    Ok(parse_events(&http.get(&url, &headers, SERVICE).await?))
}

/// Graph gives "2026-11-23T12:00:00.0000000" in the zone it was asked for (UTC).
fn utc(v: &Value) -> Option<DateTime<Utc>> {
    let text = v["dateTime"].as_str()?;
    let head: String = text.chars().take(19).collect();
    chrono::NaiveDateTime::parse_from_str(&head, "%Y-%m-%dT%H:%M:%S").ok().map(|n| n.and_utc())
}

pub fn parse_events(v: &Value) -> Vec<Event> {
    list(&v["value"])
        .iter()
        .filter(|e| e["isCancelled"].as_bool() != Some(true))
        .filter_map(|e| {
            Some(Event {
                id: e["id"].as_str()?.into(),
                title: e["subject"].as_str().unwrap_or("").into(),
                start: utc(&e["start"])?,
                end: utc(&e["end"])?,
                all_day: e["isAllDay"].as_bool().unwrap_or(false),
                busy: !matches!(e["showAs"].as_str(), Some("free") | Some("workingElsewhere")),
                location: e["location"]["displayName"].as_str().unwrap_or("").into(),
            })
        })
        .collect()
}

pub fn event_body(event: &NewEvent) -> Value {
    let at = |t: DateTime<Utc>| json!({"dateTime": t.format("%Y-%m-%dT%H:%M:%S").to_string(), "timeZone": "UTC"});
    json!({
        "subject": event.title,
        "start": at(event.start),
        "end": at(event.end),
        "location": {"displayName": event.location},
        "body": {"contentType": "Text", "content": event.notes},
    })
}

pub async fn create_event(http: &Http, base: &str, token: &str, event: &NewEvent) -> CResult<String> {
    let v = http.json("POST", &format!("{base}/me/events"), &auth(token), Some(&event_body(event)), SERVICE).await?;
    Ok(v["id"].as_str().unwrap_or("").to_string())
}

/// The account's own address, after signing in.
pub async fn me(http: &Http, base: &str, token: &str) -> CResult<(String, String)> {
    let v = http.get(&format!("{base}/me?$select=displayName,mail,userPrincipalName"), &auth(token), SERVICE).await?;
    let address = v["mail"].as_str().or(v["userPrincipalName"].as_str()).unwrap_or("").to_string();
    Ok((v["displayName"].as_str().unwrap_or("").to_string(), address))
}

fn encode(id: &str) -> String {
    percent_encoding::utf8_percent_encode(id, percent_encoding::NON_ALPHANUMERIC).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;

    const INBOX: &str = r#"{"value":[{"id":"AAMk1","subject":"Lunch?","from":{"emailAddress":{"name":"Anna","address":"anna@example.com"}},
        "toRecipients":[{"emailAddress":{"name":"Me","address":"me@example.com"}}],"receivedDateTime":"2026-11-20T09:00:00Z",
        "isRead":false,"flag":{"flagStatus":"flagged"},"bodyPreview":"Shall we?","conversationId":"c1","internetMessageId":"<m1@x>"}]}"#;

    #[tokio::test]
    async fn reads_the_inbox_and_changes_and_sends() {
        let server = TestServer::start(vec![
            ("/me/mailFolders/inbox/messages", 200, INBOX.into()),
            ("POST /me/messages/AAMk1/move", 201, "{}".into()),
            ("PATCH /me/messages/AAMk1", 200, "{}".into()),
            ("POST /me/sendMail", 202, String::new()),
            ("POST /me/messages/AAMk1/reply", 202, String::new()),
        ])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let http = Http::new();
        let mails = inbox(&http, &base, "tok", "work", Utc::now(), true, 10).await.unwrap();
        assert_eq!(mails.len(), 1);
        let m = &mails[0];
        assert_eq!((m.id.as_str(), m.from_name.as_str(), m.unread, m.flagged), ("work:AAMk1", "Anna", true, true));
        assert_eq!(m.to, vec!["Me <me@example.com>"]);
        change(&http, &base, "tok", "AAMk1", Change::Trash).await.unwrap();
        change(&http, &base, "tok", "AAMk1", Change::Read).await.unwrap();
        let out = Outgoing {
            to: vec!["Anna <anna@example.com>".into()],
            subject: "Hi".into(),
            body: "Hello".into(),
            attachments: vec![Attachment { name: "invite.ics".into(), mime: "text/calendar".into(), bytes: b"BEGIN".to_vec() }],
            ..Default::default()
        };
        send(&http, &base, "tok", &out, None).await.unwrap();
        send(&http, &base, "tok", &out, Some("AAMk1")).await.unwrap();
        let got = server.received.lock().unwrap().clone();
        assert!(got[0].path.contains("isRead+eq+false") || got[0].path.contains("isRead%20eq%20false"));
        assert_eq!(got[0].header("authorization"), Some("Bearer tok"));
        assert!(got[1].body.contains("deleteditems"));
        assert!(got[2].body.contains("\"isRead\":true"));
        let sent: Value = serde_json::from_str(&got[3].body).unwrap();
        assert_eq!(sent["message"]["toRecipients"][0]["emailAddress"]["address"], "anna@example.com");
        assert_eq!(sent["message"]["attachments"][0]["contentBytes"], "QkVHSU4=");
        let reply: Value = serde_json::from_str(&got[4].body).unwrap();
        assert_eq!(reply["comment"], "Hello");
    }

    #[test]
    fn events_come_in_utc_and_free_ones_are_not_busy() {
        let v: Value = serde_json::from_str(
            r#"{"value":[{"id":"e1","subject":"Standup","start":{"dateTime":"2026-11-23T08:30:00.0000000","timeZone":"UTC"},
            "end":{"dateTime":"2026-11-23T08:45:00.0000000","timeZone":"UTC"},"isAllDay":false,"showAs":"busy","location":{"displayName":"Teams"}},
            {"id":"e2","subject":"Lunch","start":{"dateTime":"2026-11-23T12:00:00"},"end":{"dateTime":"2026-11-23T13:00:00"},"showAs":"free"},
            {"id":"e3","subject":"Gone","isCancelled":true,"start":{"dateTime":"2026-11-23T12:00:00"},"end":{"dateTime":"2026-11-23T13:00:00"}}]}"#,
        )
        .unwrap();
        let events = parse_events(&v);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].start.to_rfc3339(), "2026-11-23T08:30:00+00:00");
        assert!(events[0].busy && !events[1].busy);
        assert_eq!(events[0].location, "Teams");
        let body = event_body(&NewEvent { title: "Lunch".into(), start: events[1].start, end: events[1].end, location: String::new(), notes: String::new() });
        assert_eq!(body["start"]["dateTime"], "2026-11-23T12:00:00");
    }
}
