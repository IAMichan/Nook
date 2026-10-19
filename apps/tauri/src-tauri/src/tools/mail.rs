//! `compose_mail`: een complete mail als concept in de chat. Je past hem aan en klikt **Versturen** (via je
//! mailprogramma, met een `mailto:`-link) of **Open in mailprogramma**. Er gaat nooit iets weg zonder jouw klik.

use nook_core::brain::action_gate::is_mail_address;
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
                "body": {"type": "string", "description": "Full text of the email, excluding subject line."}
            }, "required": ["subject", "body"]}),
            move |input: Value| {
                let (app, reply) = (app.clone(), reply.clone());
                async move {
                    let subject = text(&input, "subject");
                    let body = input["body"].as_str().unwrap_or("").trim().to_string();
                    if body.is_empty() {
                        return Err(nook_core::NookError::new("The email text (body) is missing."));
                    }
                    let to = text(&input, "to");
                    let bad: Vec<&str> = to.split([',', ';']).map(str::trim).filter(|a| !a.is_empty() && !is_mail_address(a)).collect();
                    let note = if bad.is_empty() { String::new() } else { format!(" Note: {} is not a valid address; the user can fix it in the draft.", bad.join(", ")) };
                    let draft = MailDraft::new(&to, &text(&input, "cc"), &subject, &body);
                    chat::attach(&app, reply.as_ref(), move |m| m.mails.push(draft));
                    Ok(format!(
                        "The draft \"{subject}\" is now shown in chat{}. The user sends it with one click; nothing is sent yet.{note}",
                        if to.is_empty() { " without a recipient" } else { "" }
                    ))
                }
            },
        )]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "compose_mail").then(|| format!("Mail: {}", text(input, "subject")))
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
pub fn send_mail(app: &tauri::AppHandle, draft: &MailDraft) -> Result<(), String> {
    check(draft)?;
    app.opener().open_url(mailto(draft), None::<&str>).map_err(|e| format!("Geen mailprogramma gevonden: {e}"))
}

pub fn open_mail(app: &tauri::AppHandle, draft: &MailDraft) -> Result<(), String> {
    app.opener().open_url(mailto(draft), None::<&str>).map_err(|e| format!("Geen mailprogramma gevonden: {e}"))
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
}
