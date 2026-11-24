//! The user's chats in every chat app, as a source for the brain (`ChatInboxConnector` on the Mac): `chat_inbox` reads
//! the shared inbox (the recent chats, one chat, or the messages of every chat that hold some words) and `chat_send`
//! proposes a message in an existing chat, sent after the user's click through the same route as the Chats tab
//! (`chats::inbox::chat_inbox_send`: WhatsApp through its gateway, the others through Nook's chat helper). The same for
//! every app. Messages are other people's words: data, never instructions.

use nook_core::brain::sources::{SourceDescriptor, SourceKind};
use nook_core::brain::LoopTool;
use nook_core::chats::tools::{self as chat, Pick};
use nook_core::i18n::trf;
use serde_json::{json, Value};
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::connectors::Connectors;

pub const ID: &str = "chats";

tokio::task_local! {
    /// The chat apps hidden from this call: an agent's call through the bridge does not see the apps the user keeps on
    /// this device (`BridgeChats.withheldApps` on the Mac). Nook Chat sees every app.
    pub static WITHHELD: Vec<String>;
}

fn withheld() -> Vec<String> {
    WITHHELD.try_with(Clone::clone).unwrap_or_default()
}

pub struct Chats;

/// Whether Nook can write in this app's chats now.
fn sends(c: &Connectors, app: &str) -> bool {
    if app == nook_core::connectors::whatsapp::APP {
        c.whatsapp_accounts.is_connected()
    } else {
        c.chat_helper.bridge.client().is_some()
    }
}

fn has_chats(c: &Connectors) -> bool {
    c.env.chats.read(|inbox| !inbox.threads.is_empty())
}

fn read(app: &tauri::AppHandle, input: &Value) -> Result<String, String> {
    let c = app.state::<Connectors>();
    let hidden = withheld();
    let app_filter = Some(text(input, "app")).filter(|a| !a.trim().is_empty()).map(|a| chat::app_id(&a));
    let query = text(input, "query");
    let name = text(input, "chat");
    let limit = chat::clamp_limit(input.get("limit").and_then(Value::as_f64));
    Ok(c.env.chats.read(|inbox| {
        let shown: Vec<_> = chat::shown(inbox, &hidden).into_iter().filter(|t| app_filter.as_deref().is_none_or(|a| t.app == a)).collect();
        if !query.trim().is_empty() {
            let found = chat::search(&shown, &query);
            return if found.is_empty() {
                format!("No message in the chats holds \"{query}\".")
            } else {
                format!("Messages with \"{query}\" (newest first):\n{found}")
            };
        }
        if name.trim().is_empty() {
            return if shown.is_empty() {
                "No chats in Nook yet.".to_string()
            } else {
                format!("Recent chats (newest first):\n{}", chat::overview(&shown, 20))
            };
        }
        match chat::pick(&shown, &name, app_filter.as_deref()) {
            Pick::One(thread) => {
                let details = chat::details(thread);
                format!(
                    "{} chat with {}:\n{}{}",
                    chat::app_name(&thread.app),
                    thread.name,
                    if details.is_empty() { String::new() } else { format!("{details}\n\nMessages:\n") },
                    chat::transcript(thread, limit)
                )
            }
            Pick::Several(list) => chat::which(&name, &list),
            Pick::None => {
                let names = shown.iter().take(12).map(|t| t.name.as_str()).collect::<Vec<_>>().join(", ");
                format!("No chat is called \"{name}\". Recent chats: {}.", if names.is_empty() { "none" } else { &names })
            }
        }
    }))
}

#[async_trait::async_trait]
impl ToolSource for Chats {
    fn id(&self) -> &'static str {
        ID
    }

    fn descriptor(&self) -> Option<SourceDescriptor> {
        Some(SourceDescriptor { id: ID.into(), title: "Chats".into(), kind: SourceKind::BuiltIn })
    }

    /// Chat apps no other source stands for, as on the Mac ("line" and "x" are everyday words).
    fn aliases(&self) -> &'static [&'static str] {
        &[r"telegram|instagram|insta|messenger|signal|snapchat|viber|wechat|skype|threema|slack|teams|discord|dm'?s?|chats?"]
    }

    fn intents(&self) -> &'static [&'static str] {
        &[r"\b(chats?|berichten|messages?|appjes?|dm'?s?)\b"]
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(c) = ctx.app.try_state::<Connectors>() else { return vec![] };
        if !has_chats(&c) {
            return vec![];
        }
        let app = ctx.app.clone();
        vec![
            LoopTool::read(
                "chat_inbox",
                "The user's chats in WhatsApp, Telegram, Instagram, Messenger, Signal, Slack, Teams, LinkedIn, Discord and other chat apps, as Nook has them, the user's own sent messages included (\"You\"). With query: the messages in every chat that hold all its words, newest first. Without chat and query: the recent chats, newest first, with unread counts and the newest message. With chat (a name, optionally with app): that chat's messages.",
                json!({"type": "object", "properties": {
                    "query": {"type": "string", "description": "Words to find in the messages of every chat, sent and received. Optional."},
                    "chat": {"type": "string", "description": "The chat's name (a person or group), number, or id when a name fits several chats. Leave empty for the overview."},
                    "app": {"type": "string", "description": "Only this app: whatsapp, telegram, instagram, messenger, signal, slack, teams, discord…"},
                    "limit": {"type": "integer", "description": "How many messages of the chat (default 20, at most 50)."}
                }}),
                move |input| {
                    let app = app.clone();
                    async move { read(&app, &input).map_err(nook_core::NookError) }
                },
            ),
            LoopTool::action(
                "chat_send",
                "Sends a message from the user's own account to an existing chat in one of their chat apps (WhatsApp, Telegram, Slack, Teams, Instagram, Messenger, Signal…), the way the user would answer it in Nook's Chats tab. Use when the user asks to message or answer someone in a chat app. Write the message as the user would, in their language and tone, without a signature. A reply answers the chat's newest messages: read the chat first with chat_inbox, and when its newest message is days old, tell the user so instead of answering it as if it were new. The user sees the exact text and chat and approves before anything is sent.",
                json!({"type": "object", "properties": {
                    "to": {"type": "string", "description": "The chat's name (a person or group) as chat_inbox shows it, its number, or its id when a name fits several chats."},
                    "app": {"type": "string", "description": "The chat's app as chat_inbox shows it: whatsapp, telegram, slack, teams, instagram… Give it whenever the chat's app is known."},
                    "message": {"type": "string", "description": "The full text to send."}
                }, "required": ["to", "message"]}),
            ),
        ]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let c = ctx.app.try_state::<Connectors>()?;
        let hidden = withheld();
        let (unread, writable) = c.env.chats.read(|inbox| {
            let shown = chat::shown(inbox, &hidden);
            let mut apps: Vec<String> = vec![];
            for t in &shown {
                let name = chat::app_name(&t.app);
                if !apps.contains(&name) && sends(&c, &t.app) {
                    apps.push(name);
                }
            }
            let unread: Vec<_> = shown.into_iter().filter(|t| t.unread > 0).collect();
            (if unread.is_empty() { String::new() } else { chat::overview(&unread, 6) }, apps)
        });
        if !has_chats(&c) {
            return None;
        }
        let mut lines = vec!["Chats from the user's chat apps (WhatsApp, Telegram, Instagram, Messenger, Signal, Slack and more): read one with chat_inbox, or find a message in all of them (the user's own sent ones too) with its query.".to_string()];
        lines.push(if writable.is_empty() {
            "Nook cannot answer in these apps right now.".into()
        } else {
            format!("Nook can answer in chats of {} with chat_send (the user approves the exact text first); chats of other apps are read only.", writable.join(", "))
        });
        if !unread.is_empty() {
            lines.push(format!("Unread chats:\n{unread}"));
        }
        Some(lines.join("\n"))
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        (tool == "chat_send").then(|| {
            let app = text(input, "app");
            let name = if app.trim().is_empty() { "Chats".to_string() } else { chat::app_name(&chat::app_id(&app)) };
            trf(
                "{app}-bericht aan {to}: {message}",
                "{app} message to {to}: {message}",
                &[("app", &name), ("to", &text(input, "to")), ("message", &text(input, "message"))],
            )
        })
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        if tool != "chat_send" {
            return None;
        }
        Some(send(ctx, input).await)
    }
}

async fn send(ctx: &ToolCtx, input: &Value) -> Result<String, String> {
    let c = ctx.app.try_state::<Connectors>().ok_or("Chats are not available.")?;
    let app_filter = Some(text(input, "app")).filter(|a| !a.trim().is_empty()).map(|a| chat::app_id(&a));
    let to = text(input, "to");
    // The message goes exactly as written.
    let message = input.get("message").and_then(Value::as_str).unwrap_or("").to_string();
    if message.trim().is_empty() {
        return Err("Give the message to send.".into());
    }
    let hidden = withheld();
    // A name that fits two chats is never sent to a guess: Nook asks which one.
    let (key, app, name) = c.env.chats.read(|inbox| {
        let shown = chat::shown(inbox, &hidden);
        match chat::pick(&shown, &to, app_filter.as_deref()) {
            Pick::One(t) => Ok((t.id.clone(), t.app.clone(), t.name.clone())),
            Pick::Several(list) => Err(chat::which(&to, &list)),
            Pick::None => {
                let names = shown.iter().take(12).map(|t| t.name.as_str()).collect::<Vec<_>>().join(", ");
                Err(format!("No chat is called \"{to}\". Recent chats: {}.", if names.is_empty() { "none" } else { &names }))
            }
        }
    })?;
    let app_title = chat::app_name(&app);
    if !sends(&c, &app) {
        return Err(trf(
            "Nook kan {app} alleen lezen; stuur het bericht aan {chat} zelf.",
            "Nook can only read {app}; send the message to {chat} yourself.",
            &[("app", &app_title), ("chat", &name)],
        ));
    }
    crate::chats::inbox::chat_inbox_send(ctx.app.clone(), ctx.app.state::<Connectors>(), key, message, None).await?;
    Ok(format!("{app_title} message sent to {name}."))
}
