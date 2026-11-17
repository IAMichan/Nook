//! `compose_mail`: een complete mail als concept in de chat. Je past hem aan en klikt **Versturen** (via je
//! mailprogramma, met een `mailto:`-link) of **Open in mailprogramma**. Er gaat nooit iets weg zonder jouw klik.

use std::path::Path;

use nook_core::brain::action_gate::is_mail_address;
use nook_core::brain::calendar_invite;
use nook_core::brain::dates;
use nook_core::brain::LoopTool;
use nook_core::nooks::MailDraft;
use serde_json::{json, Value};
use tauri_plugin_opener::OpenerExt;

use super::{text, ToolCtx, ToolSource};
use crate::commands::chat;

pub struct Mail;

#[async_trait::async_trait]
impl ToolSource for Mail {
    fn id(&self) -> &'static str {
        "compose"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let (app, reply) = (ctx.app.clone(), ctx.reply.clone());
        vec![LoopTool::read(
            "compose_mail",
            "Composes a complete email and displays it as a draft in chat. The user can review/edit it there and send with one click or open it in their mail app. ALWAYS use this when the user asks to write, draft, reply to, or forward an email. Write the entire email in body, including greeting and sign-off, in appropriate tone and language for the recipient. Look up the address in context, on screen, or using search_mail; if unknown, leave to empty and mention it in your answer. Do not repeat the email body in your answer: summarize what you wrote in one sentence.",
            json!({"type": "object", "properties": {
                "to": {"type": "string", "description": "Recipient email address(es), comma-separated. Empty if unknown."},
                "cc": {"type": "string", "description": "CC email address(es), optional."},
                "subject": {"type": "string", "description": "Subject line. For replies: \"Re: \" followed by original subject."},
                "body": {"type": "string", "description": "Full text of the email, excluding subject line."},
                "invite": {
                    "type": "object",
                    "description": "Makes this mail a real calendar invitation for everyone in to and cc (an invite.ics they accept or decline in their own calendar). Use it whenever the user plans a meeting, call or appointment with other people and wants them invited. Also put the appointment in the user's own calendar with create_event (same title and times).",
                    "properties": {
                        "title": {"type": "string", "description": "Title of the appointment."},
                        "start": {"type": "string", "description": "Start, ISO 8601 with timezone."},
                        "end": {"type": "string", "description": "End, ISO 8601 with timezone. Default one hour after start."},
                        "location": {"type": "string", "description": "Place or video link, optional."},
                        "notes": {"type": "string", "description": "Agenda or details, optional."}
                    },
                    "required": ["title", "start"]
                }
            }, "required": ["subject", "body"]}),
            move |input: Value| {
                let (app, reply) = (app.clone(), reply.clone());
                async move {
                    let folder = std::env::temp_dir().join("nook-invites");
                    let (draft, summary) = build_draft(&input, &folder)?;
                    chat::attach(&app, reply.as_ref(), move |m| m.mails.push(draft));
                    Ok(summary)
                }
            },
        )]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "compose_mail").then(|| format!("Mail: {}", text(input, "subject")))
    }
}

/// Builds a `MailDraft` (and tool output text) from `compose_mail` input, writing `invite.ics` under `folder` when
/// `invite` is present.
pub fn build_draft(input: &Value, folder: &Path) -> nook_core::Result<(MailDraft, String)> {
    let subject = text(input, "subject");
    let body = input["body"].as_str().unwrap_or("").trim().to_string();
    if body.is_empty() {
        return Err(nook_core::NookError::new("The email text (body) is missing."));
    }
    let to = text(input, "to");
    let cc = text(input, "cc");
    let bad: Vec<&str> = to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty() && !is_mail_address(a)).collect();
    let note = if bad.is_empty() {
        String::new()
    } else {
        format!(" Note: {} is not a valid address; the user can fix it in the draft.", bad.join(", "))
    };
    let mut draft = MailDraft::new(&to, &cc, &subject, &body);
    let mut invited = String::new();
    if let Some(fields) = input.get("invite").filter(|v| !v.is_null()) {
        let mut attendees = calendar_invite::addresses(&draft.to);
        attendees.extend(calendar_invite::addresses(&draft.cc));
        let event = calendar_invite::event_from_input(fields, attendees.clone(), "")
            .ok_or_else(|| nook_core::NookError::new("The invitation needs a title and a start time (ISO 8601)."))?;
        let file = calendar_invite::write(&event, folder)
            .map_err(|e| nook_core::NookError::new(format!("Could not write the invitation file: {e}")))?;
        let when = dates::iso(event.start.fixed_offset());
        let who = if attendees.is_empty() { "nobody yet: the address is missing, say so".to_string() } else { attendees.join(", ") };
        invited = format!(" It carries a calendar invitation ({}, {}) for {who}.", event.title, when);
        draft.attachments.push(file.to_string_lossy().into_owned());
        draft.invite = Some(event);
    }
    Ok((
        draft,
        format!(
            "The draft \"{subject}\" is now shown in chat{}. The user sends it with one click; nothing is sent yet.{note}{invited}",
            if to.is_empty() { " without a recipient" } else { "" }
        ),
    ))
}

/// Keeps `invite.ics` on disk aligned with the draft's current `To` and `Cc` recipients.
pub fn sync_invite(draft: &mut MailDraft) {
    let Some(event) = draft.invite.as_mut() else { return };
    let mut attendees = calendar_invite::addresses(&draft.to);
    attendees.extend(calendar_invite::addresses(&draft.cc));
    event.attendees = attendees;
    if let Some(path) = draft.attachments.iter().find(|p| p.ends_with("invite.ics")) {
        let _ = std::fs::write(path, calendar_invite::ics(event).as_bytes());
    }
}

/// Een `mailto:`-adres met ontvanger, cc, onderwerp en tekst (percent-gecodeerd, zoals RFC 6068 vraagt).
pub fn mailto(draft: &MailDraft) -> String {
    let encode = |s: &str| url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>().replace('+', "%20");
    let recipients: Vec<String> =
        draft.to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).map(|a| encode(a).replace("%40", "@")).collect();
    let mut query = vec![
        format!("subject={}", encode(&draft.subject)),
        format!("body={}", encode(&draft.body.replace("\r\n", "\n").replace('\n', "\r\n"))),
    ];
    if !draft.cc.trim().is_empty() {
        query.insert(0, format!("cc={}", encode(draft.cc.trim())));
    }
    format!("mailto:{}?{}", recipients.join(","), query.join("&"))
}

fn check(draft: &MailDraft) -> Result<(), String> {
    let addresses: Vec<&str> = draft.to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).collect();
    if addresses.is_empty() {
        return Err("Vul eerst een ontvanger in.".into());
    }
    if let Some(bad) = addresses
        .iter()
        .chain(draft.cc.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).collect::<Vec<_>>().iter())
        .find(|a| !is_mail_address(a))
    {
        return Err(format!("{bad} is geen geldig mailadres."));
    }
    Ok(())
}

/// Versturen: op Windows, Linux en Android gaat het concept naar je eigen mailprogramma, klaar om te verzenden.
/// Nook verstuurt zelf nooit iets zonder klik; hier is de klik de knop Versturen.
pub fn send_mail(app: &tauri::AppHandle, draft: &mut MailDraft) -> Result<(), String> {
    check(draft)?;
    sync_invite(draft);
    app.opener().open_url(mailto(draft), None::<&str>).map_err(|e| format!("Geen mailprogramma gevonden: {e}"))
}

pub fn open_mail(app: &tauri::AppHandle, draft: &mut MailDraft) -> Result<(), String> {
    sync_invite(draft);
    app.opener().open_url(mailto(draft), None::<&str>).map_err(|e| format!("Geen mailprogramma gevonden: {e}"))
}

pub fn open_invite(app: &tauri::AppHandle, draft: &mut MailDraft) -> Result<(), String> {
    sync_invite(draft);
    let path = draft
        .attachments
        .iter()
        .find(|p| p.ends_with("invite.ics"))
        .cloned()
        .ok_or_else(|| "This draft has no calendar invitation file.".to_string())?;
    if !Path::new(&path).exists() {
        if let Some(event) = draft.invite.as_ref() {
            if let Some(parent) = Path::new(&path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(&path, calendar_invite::ics(event).as_bytes()).map_err(|e| format!("Could not write invitation: {e}"))?;
        }
    }
    app.opener().open_path(path, None::<&str>).map_err(|e| format!("Could not open invitation: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mailto_is_encoded() {
        let draft = MailDraft::new("lisa@example.nl, jan@example.nl", "", "Later & morgen", "Hoi Lisa,\nIk ben later.\n\nGroet");
        let link = mailto(&draft);
        assert!(link.starts_with("mailto:lisa@example.nl,jan@example.nl?subject=Later%20%26%20morgen&body=Hoi%20Lisa%2C%0D%0AIk"));
        assert!(check(&MailDraft::new("", "", "x", "y")).is_err());
        assert!(check(&MailDraft::new("lisa", "", "x", "y")).is_err());
        assert!(check(&draft).is_ok());
    }

    #[test]
    fn compose_mail_writes_and_syncs_invite_ics() {
        let dir = std::env::temp_dir().join(format!("nook-mail-invite-test-{}", uuid::Uuid::new_v4()));
        let input = json!({
            "to": "Jan <jan@example.com>",
            "cc": "sara@example.nl",
            "subject": "Lunch Tuesday",
            "body": "Hi Jan,\nShall we do Tuesday at 12:30?",
            "invite": {
                "title": "Lunch",
                "start": "2026-11-17T12:30:00+01:00",
                "location": "Cafe de Jaren"
            }
        });
        let (mut draft, summary) = build_draft(&input, &dir).unwrap();
        assert!(summary.contains("calendar invitation (Lunch"), "{summary}");
        assert_eq!(draft.attachments.len(), 1);
        let path = draft.attachments[0].clone();
        assert!(path.ends_with("invite.ics"));
        let ics_before = std::fs::read_to_string(&path).unwrap().replace("\r\n ", "");
        assert!(ics_before.contains("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:jan@example.com\r\n"));
        assert!(ics_before.contains("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:sara@example.nl\r\n"));

        draft.to = "piet@example.com".into();
        draft.cc.clear();
        sync_invite(&mut draft);
        let ics_after = std::fs::read_to_string(&path).unwrap().replace("\r\n ", "");
        assert!(ics_after.contains("mailto:piet@example.com\r\n"));
        assert!(!ics_after.contains("jan@example.com"));

        assert!(build_draft(&json!({"to": "a@b.nl", "subject": "Hi", "body": "Text", "invite": {"title": "Call"}}), &dir).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
