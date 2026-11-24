//! Mail & calendar tools: `compose_mail` (always available, sending through a linked Microsoft/Google account when
//! configured or falling back to `mailto:`), plus `mail_unread`, `inbox_mail`, `search_mail`, `read_mail`,
//! `trash_mail`, `mark_mail`, and `create_event` once Microsoft or Google mail accounts are linked.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use nook_core::brain::action_gate::is_mail_address;
use nook_core::brain::calendar_invite;
use nook_core::brain::dates;
use nook_core::brain::LoopTool;
use nook_core::connectors::mail::service::MailService;
use nook_core::connectors::mail::{self, Attachment, Change, NewEvent, Outgoing, Selection};
use nook_core::i18n::{tr, trf};
use nook_core::nooks::MailDraft;
use serde_json::{json, Value};
use tauri::Manager;
use tauri_plugin_opener::OpenerExt;

use super::{text, ToolCtx, ToolSource};
use crate::commands::chat;

#[derive(Debug, Clone, Default)]
struct DraftMeta {
    reply_to: Option<String>,
    from: Option<String>,
}

fn service_cell() -> &'static OnceLock<Arc<MailService>> {
    static SERVICE: OnceLock<Arc<MailService>> = OnceLock::new();
    &SERVICE
}

fn draft_meta_map() -> &'static Mutex<HashMap<String, DraftMeta>> {
    static META: OnceLock<Mutex<HashMap<String, DraftMeta>>> = OnceLock::new();
    META.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Shared [`MailService`] backed by the app's connector environment (`secrets`, `store`, `http`).
pub fn service(app: &tauri::AppHandle) -> Option<Arc<MailService>> {
    if let Some(svc) = service_cell().get() {
        return Some(svc.clone());
    }
    let connectors = app.try_state::<crate::connectors::Connectors>()?;
    let svc = MailService::new(connectors.env.clone());
    let _ = service_cell().set(svc.clone());
    Some(service_cell().get().cloned().unwrap_or(svc))
}

fn remember_meta(draft_id: &str, reply_to: Option<String>, from: Option<String>) {
    if reply_to.is_none() && from.is_none() {
        return;
    }
    let mut guard = draft_meta_map().lock().unwrap_or_else(|e| e.into_inner());
    if guard.len() > 200 {
        guard.clear();
    }
    guard.insert(draft_id.to_string(), DraftMeta { reply_to, from });
}

fn lookup_meta(draft_id: &str) -> DraftMeta {
    draft_meta_map().lock().unwrap_or_else(|e| e.into_inner()).get(draft_id).cloned().unwrap_or_default()
}

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
        let mut list = vec![LoopTool::read(
            "compose_mail",
            "Composes a complete email and displays it as a draft in chat. The user can review/edit it there and send with one click or open it in their mail app. ALWAYS use this when the user asks to write, draft, reply to, or forward an email. Write the entire email in body, including greeting and sign-off, in appropriate tone and language for the recipient. To answer a received mail, set reply_to to its id (from inbox_mail, search_mail or read_mail): Nook then sends it as a reply in the same thread, from the account it came to. Look up the address in context, on screen, or using search_mail; if unknown, leave to empty and mention it in your answer. Do not repeat the email body in your answer: summarize what you wrote in one sentence.",
            json!({"type": "object", "properties": {
                "to": {"type": "string", "description": "Recipient email address(es), comma-separated. Empty if unknown."},
                "cc": {"type": "string", "description": "CC email address(es), optional."},
                "bcc": {"type": "string", "description": "BCC email address(es), optional: only when the user asks for a blind copy."},
                "from": {"type": "string", "description": "The user's own address or account name to send from, only when they name one. Empty: the default account."},
                "subject": {"type": "string", "description": "Subject line. For replies: \"Re: \" followed by original subject."},
                "body": {"type": "string", "description": "Full text of the email, excluding subject line."},
                "reply_to": {"type": "string", "description": "For a reply: the id of the mail it answers (the part after \"id:\" in inbox_mail, search_mail or read_mail). Empty for a new mail."},
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
        )];

        let Some(svc) = service(&ctx.app) else {
            return list;
        };
        if !svc.has_accounts() {
            return list;
        }

        let private = ctx.settings.private_sources();
        let mail_allowed = !private.contains("mail") && ctx.scope.allows("mail");
        let calendar_allowed = !private.contains("calendar") && ctx.scope.allows("calendar");

        if mail_allowed {
            let s1 = svc.clone();
            list.push(
                LoopTool::read(
                    "mail_unread",
                    "Counts unread mail in the inbox of linked mail accounts, freshly fetched: total, per account, per day received (the last 14 days) and senders with the most unread mail. Use this for questions like 'how many unread emails do I have' and for an unread mail chart.",
                    json!({"type": "object", "properties": {}, "required": []}),
                    move |_| {
                        let svc = s1.clone();
                        async move { svc.unread().await.map_err(Into::into) }
                    },
                )
                .in_source("mail"),
            );

            let s2 = svc.clone();
            list.push(
                LoopTool::read(
                    "inbox_mail",
                    "Returns recent mail in the inbox of linked mail accounts (newest first): subject, sender, date, whether it is read, whether the user already replied, the account, its id and the start of the body text. Use this for questions like 'which emails do I still need to reply to', 'what arrived today', 'what happened in my mail' or 'did I miss anything important'. Open a message in full with read_mail and its id; answer it with compose_mail and reply_to set to that id.",
                    json!({"type": "object", "properties": {
                        "days": {"type": "integer", "description": "How many days back (default 7, at most 30). 1 for today and last night."},
                        "unanswered_only": {"type": "boolean", "description": "Only mail to which the user has not replied yet (default false)."},
                        "unread_only": {"type": "boolean", "description": "Only mail the user has not read yet (default false)."},
                        "limit": {"type": "integer", "description": "How many messages at most (default 15, at most 40)."}
                    }, "required": []}),
                    move |input: Value| {
                        let svc = s2.clone();
                        async move {
                            let days = nook_core::connectors::int(&input["days"]).unwrap_or(7).clamp(1, 30);
                            let unanswered = input["unanswered_only"].as_bool().unwrap_or(false);
                            let unread = input["unread_only"].as_bool().unwrap_or(false);
                            let limit = nook_core::connectors::int(&input["limit"]).unwrap_or(15).clamp(1, 40) as usize;
                            let mails = svc.inbox(days, unanswered, unread, limit).await?;
                            if mails.is_empty() {
                                return Ok("No matching messages in the inbox.".into());
                            }
                            Ok(mail::lines(&mails, &|id| svc.label_for(id)))
                        }
                    },
                )
                .in_source("mail"),
            );

            let s3 = svc.clone();
            list.push(
                LoopTool::read(
                    "search_mail",
                    "Searches linked mail accounts by subject or sender (inbox) or by subject or recipient (sent) and returns the best matches with the start of the text and an id. Give one or more separate keywords (a name, a topic), not a sentence. Use mailbox sent to find what the user wrote or promised. To read a whole message, call read_mail with its id.",
                    json!({"type": "object", "properties": {
                        "query": {"type": "string", "description": "One or more keywords, separated by spaces: words in the subject, or (part of) the sender or recipient."},
                        "mailbox": {"type": "string", "enum": ["inbox", "sent"], "description": "inbox (default) or sent."}
                    }, "required": ["query"]}),
                    move |input: Value| {
                        let svc = s3.clone();
                        async move {
                            let query = text(&input, "query");
                            let sent = text(&input, "mailbox").eq_ignore_ascii_case("sent");
                            let mails = svc.search(&query, sent, 15).await?;
                            if mails.is_empty() {
                                return Ok(format!("No mail found for \"{query}\"{}.", if sent { " in sent" } else { "" }));
                            }
                            Ok(mail::lines(&mails, &|id| svc.label_for(id)))
                        }
                    },
                )
                .in_source("mail"),
            );

            let s4 = svc.clone();
            list.push(
                LoopTool::read(
                    "read_mail",
                    "Reads one whole message from linked mail accounts (inbox or sent): subject, sender, recipients, date and the full text. Give the id from search_mail or inbox_mail. Use this when the start of a message is not enough to answer.",
                    json!({"type": "object", "properties": {
                        "id": {"type": "string", "description": "The message id from search_mail or inbox_mail (the part after \"id:\")."}
                    }, "required": ["id"]}),
                    move |input: Value| {
                        let svc = s4.clone();
                        async move {
                            let id = text(&input, "id");
                            let message = svc.read(&id).await?;
                            Ok(mail::full(&message))
                        }
                    },
                )
                .in_source("mail"),
            );

            list.push(
                LoopTool::action(
                    "trash_mail",
                    "Moves messages in the inbox to the Trash (recoverable from there). Use this when the user asks to delete, remove or clean up mail. Select the mail with ids from search_mail, or with a filter: from (part of the sender) and/or subject, optionally unread_only and days. Never guess: when it is unclear which mail is meant, search first. At most 200 messages per action.",
                    json!({"type": "object", "properties": {
                        "ids": {"type": "array", "items": {"type": "string"}, "description": "Message ids from search_mail (the part after \"id:\")."},
                        "from": {"type": "string", "description": "Part of the sender's name or address, e.g. \"linkedin\"."},
                        "subject": {"type": "string", "description": "Part of the subject."},
                        "unread_only": {"type": "boolean", "description": "Only unread messages (default false)."},
                        "days": {"type": "integer", "description": "Only mail received in the last this many days."}
                    }, "required": []}),
                )
                .in_source("mail"),
            );

            list.push(
                LoopTool::action(
                    "mark_mail",
                    "Marks messages in the inbox as read, unread, flagged or unflagged. Use this for 'mark everything from X as read', 'flag Lisa's mail'. Select the mail with ids from search_mail, or with a filter: from, subject, unread_only, days (unread_only with days alone is fine for 'mark all unread mail of this week as read'). At most 200 messages per action.",
                    json!({"type": "object", "properties": {
                        "state": {"type": "string", "enum": ["read", "unread", "flagged", "unflagged"], "description": "The new state."},
                        "ids": {"type": "array", "items": {"type": "string"}, "description": "Message ids from search_mail (the part after \"id:\")."},
                        "from": {"type": "string", "description": "Part of the sender's name or address, e.g. \"linkedin\"."},
                        "subject": {"type": "string", "description": "Part of the subject."},
                        "unread_only": {"type": "boolean", "description": "Only unread messages (default false)."},
                        "days": {"type": "integer", "description": "Only mail received in the last this many days."}
                    }, "required": ["state"]}),
                )
                .in_source("mail"),
            );
        }

        if calendar_allowed && svc.has_calendar_accounts() {
            list.push(
                LoopTool::action(
                    "create_event",
                    "Creates a new calendar event in the user's linked Microsoft or Google calendar. Only invoke when title and start time are clearly established; when the user asks you to find or plan a time, get one from find_time first. Other people are invited with compose_mail and its invite field, in the same answer.",
                    json!({"type": "object", "properties": {
                        "title": {"type": "string", "description": "Title of the event."},
                        "start": {"type": "string", "description": "Start time, ISO 8601 with timezone."},
                        "end": {"type": "string", "description": "End time, ISO 8601 with timezone. Defaults to one hour after start."},
                        "location": {"type": "string", "description": "Location, optional."},
                        "notes": {"type": "string", "description": "Notes, optional."},
                        "calendar": {"type": "string", "description": "Name or email of target account calendar, optional. Defaults to the first linked calendar."}
                    }, "required": ["title", "start"]}),
                )
                .in_source("calendar"),
            );
        }

        list
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let svc = service(&ctx.app)?;
        let accounts = svc.accounts();
        if accounts.is_empty() {
            return None;
        }
        let private = ctx.settings.private_sources();
        if private.contains("mail") || !ctx.scope.allows("mail") {
            return None;
        }
        let names: Vec<String> =
            accounts.iter().map(|a| format!("{} <{}>{}", a.label(), a.address, if a.calendar { " [calendar]" } else { "" })).collect();
        Some(format!("Mail accounts: {}. Use inbox_mail, mail_unread, search_mail or read_mail to read mail.", names.join(", ")))
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "compose_mail" => Some(format!("Mail: {}", text(input, "subject"))),
            "trash_mail" => Some(Selection::from_input(input).summary(Change::Trash)),
            "mark_mail" => {
                let change = Change::parse(&text(input, "state")).filter(|c| *c != Change::Trash);
                Some(change.map(|c| Selection::from_input(input).summary(c)).unwrap_or_else(|| "Change mail".into()))
            }
            "create_event" => {
                let title = text(input, "title");
                let title = if title.is_empty() { "Event".to_string() } else { title };
                let start = nook_core::connectors::dates::parse(&text(input, "start"))
                    .map(nook_core::connectors::dates::long)
                    .unwrap_or_else(|| text(input, "start"));
                let cal = text(input, "calendar");
                if cal.is_empty() {
                    Some(format!("{title} · {start}"))
                } else {
                    Some(format!("{title} · {start} · {cal}"))
                }
            }
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            "trash_mail" => {
                let svc = match service(&ctx.app) {
                    Some(s) => s,
                    None => return Some(Err(tr("Mail is nu niet beschikbaar.", "Mail is not available right now.").into())),
                };
                let sel = Selection::from_input(input);
                Some(svc.apply_change(&sel, Change::Trash).await.map_err(|e| e.message))
            }
            "mark_mail" => {
                let svc = match service(&ctx.app) {
                    Some(s) => s,
                    None => return Some(Err(tr("Mail is nu niet beschikbaar.", "Mail is not available right now.").into())),
                };
                let state = text(input, "state");
                let Some(change) = Change::parse(&state).filter(|c| *c != Change::Trash) else {
                    return Some(Err(format!("Unknown mail state \"{state}\". Use read, unread, flagged or unflagged.")));
                };
                let sel = Selection::from_input(input);
                Some(svc.apply_change(&sel, change).await.map_err(|e| e.message))
            }
            "create_event" => {
                let svc = match service(&ctx.app) {
                    Some(s) => s,
                    None => return Some(Err(tr("Agenda is nu niet beschikbaar.", "Calendar is not available right now.").into())),
                };
                let ev = match NewEvent::from_input(input) {
                    Ok(e) => e,
                    Err(err) => return Some(Err(err)),
                };
                let cal = text(input, "calendar");
                let cal_opt = (!cal.is_empty()).then_some(cal.as_str());
                Some(svc.create_event(&ev, cal_opt).await.map_err(|e| e.message).map(|(account, id)| {
                    let when = dates::iso(ev.start.fixed_offset());
                    if id.is_empty() {
                        format!("Event created: {} at {} ({account})", ev.title, when)
                    } else {
                        format!("Event created: {} at {} ({account}, id {id})", ev.title, when)
                    }
                }))
            }
            _ => None,
        }
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
    // A name for a recipient the screen brain read: its address, which never left this computer.
    let to =
        text(input, "to")
            .split([',', ';'])
            .map(str::trim)
            .filter(|a| !a.is_empty())
            .map(|a| {
                if is_mail_address(a) {
                    a.to_string()
                } else {
                    crate::commands::screen_work::address_for(a).unwrap_or_else(|| a.to_string())
                }
            })
            .collect::<Vec<_>>()
            .join(", ");
    let cc = text(input, "cc");
    let bcc = text(input, "bcc");
    let bad: Vec<&str> = [to.as_str(), cc.as_str(), bcc.as_str()]
        .into_iter()
        .flat_map(|list| list.split([',', ';']))
        .map(str::trim)
        .filter(|a| !a.is_empty() && !is_mail_address(a))
        .collect();
    let note = if bad.is_empty() {
        String::new()
    } else {
        format!(" Note: {} is not a valid address; the user can fix it in the draft.", bad.join(", "))
    };
    let mut draft = MailDraft::new(&to, &cc, &subject, &body);
    draft.bcc = bcc;

    let reply_to = text(input, "reply_to");
    let reply_to = (!reply_to.is_empty()).then_some(reply_to);
    let from = text(input, "from");
    let from = (!from.is_empty()).then_some(from);
    remember_meta(&draft.id, reply_to, from);

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

/// A `mailto:` link with recipients, cc, bcc, subject and text (percent-encoded, as RFC 6068 asks).
pub fn mailto(draft: &MailDraft) -> String {
    let encode = |s: &str| url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>().replace('+', "%20");
    let recipients: Vec<String> =
        draft.to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).map(|a| encode(a).replace("%40", "@")).collect();
    let mut query = vec![
        format!("subject={}", encode(&draft.subject)),
        format!("body={}", encode(&draft.body.replace("\r\n", "\n").replace('\n', "\r\n"))),
    ];
    if !draft.bcc.trim().is_empty() {
        query.insert(0, format!("bcc={}", encode(draft.bcc.trim())));
    }
    if !draft.cc.trim().is_empty() {
        query.insert(0, format!("cc={}", encode(draft.cc.trim())));
    }
    format!("mailto:{}?{}", recipients.join(","), query.join("&"))
}

fn split_addresses(raw: &str) -> Vec<String> {
    raw.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).map(str::to_string).collect()
}

fn mime_for(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("ics") => "text/calendar; charset=utf-8; method=REQUEST",
        Some("pdf") => "application/pdf",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("txt") => "text/plain; charset=utf-8",
        Some("csv") => "text/csv; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// Converts a `MailDraft` (including on-disk attachments such as `invite.ics`) into an [`Outgoing`] payload.
pub fn draft_to_outgoing(draft: &MailDraft, reply_to: Option<String>) -> Result<Outgoing, String> {
    let mut attachments = Vec::new();
    for raw_path in &draft.attachments {
        let path = Path::new(raw_path);
        let bytes = std::fs::read(path).map_err(|e| {
            trf(
                "Bijlage \"{name}\" kon niet worden gelezen: {error}",
                "Could not read attachment \"{name}\": {error}",
                &[("name", &path.file_name().and_then(|n| n.to_str()).unwrap_or(raw_path)), ("error", &e)],
            )
        })?;
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("attachment").to_string();
        attachments.push(Attachment { name, mime: mime_for(path).to_string(), bytes });
    }
    Ok(Outgoing {
        to: split_addresses(&draft.to),
        cc: split_addresses(&draft.cc),
        bcc: split_addresses(&draft.bcc),
        subject: draft.subject.clone(),
        body: draft.body.clone(),
        reply_to,
        attachments,
    })
}

fn check(draft: &MailDraft) -> Result<(), String> {
    let addresses: Vec<&str> = draft.to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty()).collect();
    if addresses.is_empty() {
        return Err("Vul eerst een ontvanger in.".into());
    }
    if let Some(bad) = addresses
        .iter()
        .copied()
        .chain([draft.cc.as_str(), draft.bcc.as_str()].into_iter().flat_map(|list| list.split([',', ';'])).map(str::trim))
        .filter(|a| !a.is_empty())
        .find(|a| !is_mail_address(a))
    {
        return Err(format!("{bad} is geen geldig mailadres."));
    }
    Ok(())
}

/// Sends a `MailDraft` directly through a linked Microsoft or Google account. Returns the account label used.
pub async fn send_draft_linked(
    app: &tauri::AppHandle,
    draft: &mut MailDraft,
    account: Option<&str>,
    reply_to: Option<String>,
) -> Result<String, String> {
    check(draft)?;
    sync_invite(draft);
    let svc = service(app).ok_or_else(|| tr("Mail is nu niet beschikbaar.", "Mail is not available right now.").to_string())?;
    let meta = lookup_meta(&draft.id);
    let reply = reply_to.filter(|s| !s.trim().is_empty()).or(meta.reply_to);
    let from = account.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).or(meta.from);
    let outgoing = draft_to_outgoing(draft, reply)?;
    svc.send_mail(&outgoing, from.as_deref()).await.map_err(|e| e.message)
}

fn block_on_future<F: std::future::Future>(fut: F) -> F::Output {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => tokio::task::block_in_place(|| handle.block_on(fut)),
        Err(_) => tauri::async_runtime::block_on(fut),
    }
}

/// Sends the draft after the user clicks Send: uses a linked Microsoft/Google account when available, otherwise falls
/// back to opening a `mailto:` link in the system mail app.
pub fn send_mail(app: &tauri::AppHandle, draft: &mut MailDraft) -> Result<(), String> {
    check(draft)?;
    sync_invite(draft);
    if let Some(svc) = service(app) {
        if svc.has_accounts() {
            block_on_future(send_draft_linked(app, draft, None, None))?;
            return Ok(());
        }
    }
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
    fn mailto_and_check_carry_bcc() {
        let mut draft = MailDraft::new("lisa@example.nl", "jan@example.nl", "Hi", "Text");
        draft.bcc = "boss@example.nl; me@example.nl".into();
        let link = mailto(&draft);
        assert!(
            link.starts_with("mailto:lisa@example.nl?cc=jan%40example.nl&bcc=boss%40example.nl%3B%20me%40example.nl&subject=Hi"),
            "{link}"
        );
        assert!(check(&draft).is_ok());
        draft.bcc = "boss".into();
        assert_eq!(check(&draft).unwrap_err(), "boss is geen geldig mailadres.");

        let (built, summary) =
            build_draft(&json!({"to": "a@b.nl", "bcc": "c@d.nl", "subject": "Hi", "body": "Text"}), &std::env::temp_dir()).unwrap();
        assert_eq!(built.bcc, "c@d.nl");
        assert!(!summary.contains("not a valid address"), "{summary}");
        let (_, summary) =
            build_draft(&json!({"to": "a@b.nl", "bcc": "nope", "subject": "Hi", "body": "Text"}), &std::env::temp_dir()).unwrap();
        assert!(summary.contains("nope is not a valid address"), "{summary}");
    }

    #[test]
    fn old_drafts_without_bcc_still_load() {
        let draft: MailDraft =
            serde_json::from_value(json!({"id": "1", "to": "a@b.nl", "subject": "Hi", "body": "Text", "state": "draft"})).unwrap();
        assert_eq!(draft.bcc, "");
    }

    #[test]
    fn compose_mail_writes_and_syncs_invite_ics() {
        let dir = std::env::temp_dir().join(format!("nook-mail-invite-test-{}", uuid::Uuid::new_v4()));
        let input = json!({
            "to": "Jan <jan@example.com>",
            "cc": "sara@example.nl",
            "subject": "Lunch Tuesday",
            "body": "Hi Jan,\nShall we do Tuesday at 12:30?",
            "reply_to": "work:AAMk1",
            "from": "work@example.com",
            "invite": {
                "title": "Lunch",
                "start": "2026-11-17T12:30:00+01:00",
                "location": "Cafe de Jaren"
            }
        });
        let (mut draft, summary) = build_draft(&input, &dir).unwrap();
        assert!(summary.contains("calendar invitation (Lunch"), "{summary}");
        assert_eq!(draft.attachments.len(), 1);
        let meta = lookup_meta(&draft.id);
        assert_eq!(meta.reply_to.as_deref(), Some("work:AAMk1"));
        assert_eq!(meta.from.as_deref(), Some("work@example.com"));

        let outgoing = draft_to_outgoing(&draft, meta.reply_to).unwrap();
        assert_eq!(outgoing.attachments.len(), 1);
        assert_eq!(outgoing.attachments[0].name, "invite.ics");
        assert!(outgoing.attachments[0].mime.starts_with("text/calendar"));
        assert_eq!(outgoing.reply_to.as_deref(), Some("work:AAMk1"));

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

    #[test]
    fn summarizes_mail_and_calendar_actions() {
        let m = Mail;
        assert_eq!(m.summarize("trash_mail", &json!({"from": "linkedin"})).as_deref(), Some("Move to Trash: from linkedin"));
        assert_eq!(
            m.summarize("mark_mail", &json!({"state": "read", "unread_only": true, "days": 7})).as_deref(),
            Some("Mark as read: unread, last 7 days")
        );
        let ev = m.summarize("create_event", &json!({"title": "Lunch", "start": "2026-11-23T12:00:00Z", "calendar": "Work"})).unwrap();
        assert!(ev.starts_with("Lunch · ") && ev.ends_with(" · Work"), "{ev}");
    }
}
