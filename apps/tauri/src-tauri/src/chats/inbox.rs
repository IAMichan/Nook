//! The Chats tab's view of the shared inbox (`ChatsTab`, `ChatsEntry` on the Mac): every chat app's chats in one list,
//! one chat's messages, and what can be done with a chat, the same for every app. Each step goes to the chat's own app
//! where it can (WhatsApp through its gateway, the others through Nook's chat helper) and is kept in the inbox either
//! way. The interface hears of every change through `chats-changed`.

use chrono::{DateTime, Utc};
use nook_core::chats::chatd::{network_id, ID_PREFIX};
use nook_core::chats::{ChatInbox, ChatKind, ChatReadState, InboxMessage, InboxThread};
use nook_core::connectors::whatsapp;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::connectors::Connectors;

type Res<T> = Result<T, String>;

/// One chat as a row of the list.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSummary {
    /// The inbox's key: `app#id` or `app|name`.
    key: String,
    app: String,
    name: String,
    kind: Option<ChatKind>,
    account: Option<String>,
    read: ChatReadState,
    /// The newest message, when Nook has it.
    last: Option<InboxMessage>,
    /// When it last moved.
    activity: DateTime<Utc>,
    members: usize,
    muted_in_app: bool,
    /// Nook can write in it from here (its app is linked through the helper or the gateway).
    sends: bool,
}

/// One chat with its messages, oldest first.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatThread {
    #[serde(flatten)]
    summary: ChatSummary,
    messages: Vec<InboxMessage>,
    /// A group's people by name.
    people: Vec<String>,
    has_older: bool,
}

fn summary(thread: &InboxThread, sends: bool) -> ChatSummary {
    ChatSummary {
        key: thread.id.clone(),
        app: thread.app.clone(),
        name: thread.name.clone(),
        kind: thread.kind,
        account: thread.account.clone(),
        read: thread.read_state(),
        last: thread.messages.last().cloned(),
        activity: thread.last(),
        members: thread.members.as_ref().map_or(0, Vec::len),
        muted_in_app: thread.muted_in_app.unwrap_or(false),
        sends,
    }
}

/// The app's own id of the chat behind a key, for asking its app.
fn chat_id(c: &Connectors, key: &str) -> Option<(String, String)> {
    c.env.chats.read(|inbox| inbox.threads.get(key).map(|t| (t.app.clone(), t.chat_id.clone().unwrap_or_default())))
}

fn sends(c: &Connectors, app: &str) -> bool {
    if app == whatsapp::APP {
        c.whatsapp_accounts.is_connected()
    } else {
        c.chat_helper.bridge.client().is_some()
    }
}

fn changed(app: &AppHandle) {
    let _ = app.emit("chats-changed", ());
}

/// Every chat of every app, newest first. WhatsApp's are in it too: the Chats tab takes their read state from here.
#[tauri::command]
pub fn chat_inbox_list(c: State<'_, Connectors>) -> Vec<ChatSummary> {
    let now = Utc::now();
    let helper = c.chat_helper.bridge.client().is_some();
    let wa = c.whatsapp_accounts.is_connected();
    c.env.chats.read(|inbox| {
        inbox
            .sorted()
            .into_iter()
            // A chat Nook knows only from disk, without a message, shows once its app lists it or brings one again.
            .filter(|t| !t.messages.is_empty() || ChatInbox::is_listed(t, now))
            .map(|t| summary(t, if t.app == whatsapp::APP { wa } else { helper }))
            .collect()
    })
}

/// One chat with its messages; `None` once it is gone.
#[tauri::command]
pub fn chat_inbox_thread(c: State<'_, Connectors>, key: String) -> Option<ChatThread> {
    let can = chat_id(&c, &key).is_some_and(|(app, _)| sends(&c, &app));
    c.env.chats.read(|inbox| {
        inbox.threads.get(&key).map(|t| ChatThread {
            summary: summary(t, can),
            messages: t.messages.clone(),
            people: t.members.clone().unwrap_or_default(),
            has_older: t.has_older.unwrap_or(false),
        })
    })
}

/// Read: in Nook only (`in_app` false: the badge goes, the people who wrote do not see it), or in the chat's app too.
#[tauri::command]
pub async fn chat_inbox_mark_read(app: AppHandle, c: State<'_, Connectors>, key: String, in_app: bool) -> Res<()> {
    let Some((source, id)) = chat_id(&c, &key) else { return Ok(()) };
    let now = Utc::now();
    if !in_app {
        c.env.chats.with(|inbox| inbox.mark_read(&key, now));
    } else if source == whatsapp::APP {
        // WhatsApp's gateway reads up to the newest message from someone else.
        c.wa(&id).mark_read(&id);
        c.env.chats.with(|inbox| inbox.mark_read_in_app(&key, now, None));
    } else {
        let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
        let through = c.env.chats.read(|inbox| inbox.read_mark(&key));
        client.mark_read(&id).await?;
        c.env.chats.with(|inbox| inbox.mark_read_in_app(&key, now, through));
    }
    changed(&app);
    Ok(())
}

/// Unread again: a badge in Nook until it is read, and in the chat's app too where its app takes it (WhatsApp's gateway
/// has no way to say it, so there it stays in Nook).
#[tauri::command]
pub async fn chat_inbox_mark_unread(app: AppHandle, c: State<'_, Connectors>, key: String) -> Res<()> {
    let Some((source, id)) = chat_id(&c, &key) else { return Ok(()) };
    c.env.chats.with(|inbox| inbox.mark_unread(&key, Utc::now()));
    if source != whatsapp::APP {
        if let Some(client) = c.chat_helper.bridge.client() {
            if client.mark_unread(&id).await.is_ok() {
                c.env.chats.with(|inbox| inbox.mark_unread_in_app(&key));
            }
        }
    }
    changed(&app);
    Ok(())
}

/// Every chat with something new read in Nook.
#[tauri::command]
pub fn chat_inbox_mark_all_read(app: AppHandle, c: State<'_, Connectors>, keys: Vec<String>) {
    let now = Utc::now();
    c.env.chats.with(|inbox| keys.iter().for_each(|k| inbox.mark_read(k, now)));
    changed(&app);
}

/// Sends text to the chat, after your own Return or click, as an answer to `reply_to` (a message's id) when given.
#[tauri::command]
pub async fn chat_inbox_send(app: AppHandle, c: State<'_, Connectors>, key: String, text: String, reply_to: Option<String>) -> Res<()> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Ok(());
    }
    let (source, id) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if source == whatsapp::APP {
        c.wa(&id).send_reply(&text, &id, reply_to.as_deref()).await.map_err(|e| e.message)?;
    } else {
        let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
        // The helper names a message by its own id; Nook keeps it as `nook-<chat>-<id>`.
        let quoted = reply_to.as_deref().map(|r| network_id(r, &id).unwrap_or_else(|| r.trim_start_matches(ID_PREFIX).to_string()));
        let mentions = c.chat_helper.bridge.chat(&source, &id).map(|chat| nook_core::chats::chatd::tagged(&text, &chat)).unwrap_or_default();
        client.send_tagging(&id, &text, quoted.as_deref(), &mentions).await?;
        c.chat_helper.bridge.changed(&id, None);
        // Answering reads the chat, in its app too.
        let now = Utc::now();
        c.env.chats.with(|inbox| inbox.mark_read_in_app(&key, now, None));
    }
    changed(&app);
    Ok(())
}

/// Sends a file you chose, dropped, pasted or recorded (`voice`: a voice note), with the typed text as its caption,
/// after your own click; as an answer when `reply_to` names a message. WhatsApp through its gateway, the helper's apps
/// through the helper.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn chat_inbox_send_file(
    app: AppHandle,
    c: State<'_, Connectors>,
    key: String,
    name: String,
    mime: String,
    base64: String,
    caption: String,
    reply_to: Option<String>,
    voice: Option<bool>,
) -> Res<()> {
    use base64::Engine;
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(base64.as_bytes()).map_err(|_| "The file could not be read.".to_string())?;
    if bytes.len() > 100 * 1024 * 1024 {
        return Err("The file is larger than 100 MB.".into());
    }
    let mut mime = if mime.is_empty() { "application/octet-stream".to_string() } else { mime };
    let (mut bytes, mut name) = (bytes, name);
    // A voice note recorded in the window is Opus in WebM; the chat apps take Opus in Ogg (`OggOpus`).
    if voice.unwrap_or(false) && mime.contains("webm") {
        bytes = nook_core::chats::voice::webm_to_ogg(&bytes).ok_or_else(|| "The recording could not be read.".to_string())?;
        mime = "audio/ogg; codecs=opus".into();
        name = "voice-note.ogg".into();
    }
    if source == whatsapp::APP {
        use nook_core::connectors::whatsapp::provider::{FileKind, OutgoingFile};
        let file = OutgoingFile { kind: FileKind::of(&mime, voice.unwrap_or(false)), name: &name, mime: &mime, bytes: &bytes, caption: &caption };
        c.wa(&chat).send_file(&chat, &file, reply_to.as_deref()).await.map_err(|e| e.message)?;
    } else {
        let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
        client.send_file(&chat, &name, &mime, &bytes, caption.trim(), voice.unwrap_or(false)).await?;
        c.chat_helper.bridge.changed(&chat, None);
    }
    changed(&app);
    Ok(())
}

/// A group's people by name (for "@" in the field): WhatsApp's from its gateway's group info, the helper's apps from
/// the helper's chat list. Empty for a person's chat.
#[tauri::command]
pub async fn chat_inbox_people(c: State<'_, Connectors>, key: String) -> Res<Vec<String>> {
    let Some((source, chat)) = chat_id(&c, &key) else { return Ok(vec![]) };
    if source == whatsapp::APP {
        return Ok(c.wa(&chat).group_members(&chat).await.into_iter().map(|(_, name)| name).filter(|n| !n.is_empty()).collect());
    }
    let chat = c.chat_helper.bridge.chat(&source, &chat);
    Ok(chat.map(|c| {
        let mut names: Vec<String> = c.people.iter().filter(|(id, _)| Some(id.as_str()) != c.me.as_deref()).map(|(_, n)| n.clone()).filter(|n| !n.is_empty()).collect();
        names.sort();
        names
    }).unwrap_or_default())
}

/// Removes the chat from Nook (not from its app); its app brings back only what is newer.
#[tauri::command]
pub fn chat_inbox_remove(app: AppHandle, c: State<'_, Connectors>, key: String) {
    c.env.chats.with(|inbox| inbox.remove(&key, Utc::now()));
    changed(&app);
}

/// One step on one message, after your own click (`MessageMenuItems`): `edit` (with `text`), `revoke` (deleted for
/// everyone), `deleteForMe`, or `react` (with `text` the emoji, "" to take yours off). WhatsApp through its gateway, the
/// helper's apps through the helper; deleting for you stays in Nook for the helper's apps.
#[tauri::command]
pub async fn chat_inbox_message(app: AppHandle, c: State<'_, Connectors>, key: String, message: String, step: String, text: Option<String>) -> Res<()> {
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    let text = text.unwrap_or_default();
    if source == whatsapp::APP {
        use nook_core::connectors::whatsapp::provider::MessageStep;
        let step = match step.as_str() {
            "edit" => MessageStep::Edit(text.trim()),
            "revoke" => MessageStep::Revoke,
            "deleteForMe" => MessageStep::DeleteForMe,
            "react" => MessageStep::React(&text),
            _ => return Err(format!("Unknown step {step}")),
        };
        c.wa(&chat).message_step(&chat, &message, step).await.map_err(|e| e.message)?;
    } else {
        let net = network_id(&message, &chat).unwrap_or_else(|| message.clone());
        if step != "deleteForMe" {
            let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
            match step.as_str() {
                "edit" => client.edit(&chat, &net, text.trim()).await?,
                "revoke" => client.redact(&chat, &net).await?,
                "react" => {
                    // One reaction of yours: the one there goes first.
                    let mine = c.env.chats.read(|inbox| {
                        inbox.threads.get(&key).and_then(|t| t.messages.iter().find(|m| m.id == message)).and_then(|m| m.reactions.clone())
                    });
                    for r in mine.unwrap_or_default().iter().filter(|r| r.mine) {
                        let _ = client.react(&chat, &net, &r.emoji, true).await;
                    }
                    if !text.is_empty() {
                        client.react(&chat, &net, &text, false).await?;
                    }
                }
                _ => return Err(format!("Unknown step {step}")),
            }
            c.chat_helper.bridge.changed(&chat, Some(&net));
        }
        c.env.chats.with(|inbox| match step.as_str() {
            "edit" => inbox.edit_message(&key, &message, text.trim()),
            "revoke" => inbox.withdraw_message(&key, &message),
            "deleteForMe" => inbox.forget_message(&key, &message),
            _ => inbox.react_mine(&key, &message, &text),
        });
    }
    changed(&app);
    Ok(())
}

/// Older messages of the chat, scrolling back (`ChatHistoryBridge`). True while its app has still more.
#[tauri::command]
pub async fn chat_inbox_older(app: AppHandle, c: State<'_, Connectors>, key: String) -> Res<bool> {
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if source == whatsapp::APP {
        let more = c.wa(&chat).load_history(&chat).await;
        changed(&app);
        return Ok(more);
    }
    // Room for one more page of messages in Nook, then the app is asked for them.
    let capacity = c.env.chats.with(|inbox| inbox.grow(&key, nook_core::chats::chatd::HISTORY)).unwrap_or(ChatInbox::KEEP);
    let Some(bridged) = c.chat_helper.bridge.older(&source, &chat, capacity).await? else { return Ok(false) };
    let more = bridged.has_older.unwrap_or(false);
    c.env.chats.with(|inbox| inbox.merge(bridged, Utc::now()));
    changed(&app);
    Ok(more)
}

/// Pins, mutes or archives the chat in its app itself (`ChatAbilities`), where its app lets Nook: the helper's apps.
#[tauri::command]
pub async fn chat_inbox_in_app(app: AppHandle, c: State<'_, Connectors>, key: String, pinned: Option<bool>, muted: Option<bool>, archived: Option<bool>) -> Res<()> {
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if source == whatsapp::APP {
        return Err("WhatsApp's gateway cannot pin, mute or archive a chat on your phone.".into());
    }
    let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
    if pinned.is_some() || muted.is_some() {
        client.set_chat(&chat, pinned, muted).await?;
    }
    if let Some(archived) = archived {
        client.archive(&chat, archived).await?;
    }
    if let Some(m) = muted {
        c.env.chats.with(|inbox| {
            if let Some(t) = inbox.threads.get_mut(&key) {
                t.muted_in_app = Some(m);
            }
        });
    }
    c.chat_helper.bridge.changed(&chat, None);
    changed(&app);
    Ok(())
}

fn helper_off() -> String {
    "Nook's chat helper is not running, so this app cannot be reached right now.".to_string()
}
