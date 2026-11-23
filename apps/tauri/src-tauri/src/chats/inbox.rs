//! The Chats tab's view of the shared inbox (`ChatsTab`, `ChatsEntry` on the Mac): every chat app's chats in one list,
//! one chat's messages, and what can be done with a chat, the same for every app. Each step goes to the chat's own app
//! where it can (WhatsApp through its gateway, the others through Nook's chat helper) and is kept in the inbox either
//! way. The interface hears of every change through `chats-changed`.

use chrono::{DateTime, Utc};
use nook_core::chats::chatd::{network_id, ID_PREFIX};
use nook_core::chats::{ChatAbilities, ChatInbox, ChatKind, ChatReadState, FilledMessage, InboxThread, NoticeScore};
use nook_core::connectors::whatsapp;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

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
    #[serde(skip_serializing_if = "Option::is_none")]
    handle: Option<String>,
    read: ChatReadState,
    /// The newest message, when Nook has it (with filled ticks and read details).
    last: Option<FilledMessage>,
    /// When it last moved.
    activity: DateTime<Utc>,
    members: usize,
    muted_in_app: bool,
    pinned: bool,
    archived: bool,
    /// Nook can write in it from here (its app is linked through the helper or the gateway).
    sends: bool,
    /// Per-chat capabilities (`ChatAbilities`, CH-58).
    abilities: ChatAbilities,
    /// Notice priority for the newest incoming message when unread or elevated (`ChatNoticePriority`, CH-64).
    #[serde(skip_serializing_if = "Option::is_none")]
    priority: Option<NoticeScore>,
    /// People currently typing in this chat, when the app reports it.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    typing: Vec<String>,
}

/// One chat with its messages, oldest first.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatThread {
    #[serde(flatten)]
    summary: ChatSummary,
    messages: Vec<FilledMessage>,
    /// A group's people by name.
    people: Vec<String>,
    has_older: bool,
    /// What the chat's app says of the chat itself (`ChatProfile`), when it says.
    #[serde(skip_serializing_if = "Option::is_none")]
    profile: Option<nook_core::chats::ChatProfile>,
}

fn summary(thread: &InboxThread, sends: bool, mut typing: Vec<String>) -> ChatSummary {
    for who in &thread.typing {
        if !who.is_empty() && !typing.iter().any(|existing| existing.eq_ignore_ascii_case(who)) {
            typing.push(who.clone());
        }
    }
    let pinned = thread.pinned || thread.pinned_in_app.unwrap_or(false);
    let muted = thread.muted_in_app.unwrap_or(false);
    let archived = thread.archived;
    let mut abilities = ChatAbilities::for_app(&thread.app, sends, pinned, muted, archived);
    if thread.app == whatsapp::APP {
        // Voting is the gateway's: OpenWA votes, GOWA has no call for it.
        abilities.vote = wa_votes(thread);
    }
    let scored = super::notify::score_thread(thread);
    let priority = (scored.raises || (thread.unread > 0 && scored.score > 0)).then_some(scored);
    ChatSummary {
        key: thread.id.clone(),
        app: thread.app.clone(),
        name: thread.name.clone(),
        kind: thread.kind,
        account: thread.account.clone(),
        handle: thread.handle.clone(),
        read: thread.read_state(),
        last: thread.filled_last(),
        activity: thread.last(),
        members: thread.members.as_ref().map_or(0, Vec::len),
        muted_in_app: muted,
        pinned,
        archived,
        sends,
        abilities,
        priority,
        typing,
    }
}

static WA_VOTES: std::sync::OnceLock<Box<dyn Fn(&str) -> bool + Send + Sync>> = std::sync::OnceLock::new();

/// Whether the WhatsApp account of this chat can vote on a poll (set once the connectors are up).
fn wa_votes(thread: &InboxThread) -> bool {
    WA_VOTES.get().is_some_and(|f| f(thread.chat_id.as_deref().unwrap_or("")))
}

pub(crate) fn set_wa_votes(f: impl Fn(&str) -> bool + Send + Sync + 'static) {
    let _ = WA_VOTES.set(Box::new(f));
}

/// The app's own id of the chat behind a key, for asking its app.
pub(crate) fn chat_id(c: &Connectors, key: &str) -> Option<(String, String)> {
    c.env.chats.read(|inbox| inbox.threads.get(key).map(|t| (t.app.clone(), t.chat_id.clone().unwrap_or_default())))
}

pub(crate) fn sends(c: &Connectors, app: &str) -> bool {
    if app == whatsapp::APP {
        c.whatsapp_accounts.is_connected()
    } else {
        c.chat_helper.bridge.client().is_some()
    }
}

/// Computes `ChatAbilities` for a thread key in the shared inbox (or a WhatsApp chat key).
pub(crate) fn abilities_for(c: &Connectors, key: &str) -> Option<ChatAbilities> {
    c.env.chats.read(|inbox| {
        inbox.threads.get(key).map(|t| {
            let connected = sends(c, &t.app);
            let pinned = t.pinned || t.pinned_in_app.unwrap_or(false);
            let muted = t.muted_in_app.unwrap_or(false);
            ChatAbilities::for_app(&t.app, connected, pinned, muted, t.archived)
        })
    })
}

pub(crate) fn changed(app: &AppHandle) {
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
            .map(|t| summary(t, if t.app == whatsapp::APP { wa } else { helper }, c.chat_helper.typing_in(&t.id)))
            .collect()
    })
}

/// One chat with its messages; `None` once it is gone.
#[tauri::command]
pub fn chat_inbox_thread(c: State<'_, Connectors>, key: String) -> Option<ChatThread> {
    let can = chat_id(&c, &key).is_some_and(|(app, _)| sends(&c, &app));
    let typing = c.chat_helper.typing_in(&key);
    c.env.chats.read(|inbox| {
        inbox.threads.get(&key).map(|t| ChatThread {
            summary: summary(t, can, typing),
            messages: t.filled_messages(),
            people: t.members.clone().unwrap_or_default(),
            has_older: t.has_older.unwrap_or(false),
            profile: t.profile.clone(),
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
    if source == whatsapp::APP {
        c.wa(&id).mark_unread(&id);
    } else if let Some(client) = c.chat_helper.bridge.client() {
        if client.mark_unread(&id).await.is_ok() {
            c.env.chats.with(|inbox| inbox.mark_unread_in_app(&key));
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

/// Marks a chat read after replying to it, across WhatsApp and helper apps (CH-68).
async fn mark_read_after_reply(c: &Connectors, key: &str, source: &str, id: &str) {
    let now = Utc::now();
    if source == whatsapp::APP {
        let link = c.wa(id);
        if link.settings().mark_read_on_reply {
            link.mark_read(id);
            c.env.chats.with(|inbox| inbox.mark_read_in_app(key, now, None));
        } else {
            c.env.chats.with(|inbox| inbox.mark_read(key, now));
        }
    } else {
        if let Some(client) = c.chat_helper.bridge.client() {
            let _ = client.mark_read(id).await;
        }
        c.env.chats.with(|inbox| inbox.mark_read_in_app(key, now, None));
    }
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
    }
    mark_read_after_reply(&c, &key, &source, &id).await;
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
    mark_read_after_reply(&c, &key, &source, &chat).await;
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

/// Sends a poll you wrote (`ChatPollForm`), where the chat's app takes one: WhatsApp's gateways. The helper's apps have
/// no polls another app can send.
#[tauri::command]
pub async fn chat_inbox_send_poll(app: AppHandle, c: State<'_, Connectors>, key: String, poll: nook_core::chats::poll::PollDraft) -> Res<()> {
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if let Some(problem) = poll.problem() {
        return Err(serde_json::to_value(problem).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default());
    }
    if source != whatsapp::APP {
        return Err(nook_core::i18n::tr("Deze app kan vanuit Nook geen peiling ontvangen.", "This app cannot take a poll from Nook.").into());
    }
    c.wa(&chat).send_poll(&chat, &poll).await.map_err(|e| e.message)?;
    changed(&app);
    Ok(())
}

/// Your vote on a poll (`ChatPollView`): its options' texts, an empty choice takes it back. WhatsApp through a gateway
/// that votes (OpenWA), the helper's apps through the helper.
#[tauri::command]
pub async fn chat_inbox_vote(app: AppHandle, c: State<'_, Connectors>, key: String, message: String, choice: Vec<String>) -> Res<()> {
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if source == whatsapp::APP {
        c.wa(&chat).vote(&chat, &message, &choice).await.map_err(|e| e.message)?;
    } else {
        let net = network_id(&message, &chat).unwrap_or_else(|| message.clone());
        let client = c.chat_helper.bridge.client().ok_or_else(helper_off)?;
        client.vote(&chat, &net, &choice).await.map_err(|_| nook_core::i18n::tr("De stem kwam niet aan.", "The vote did not go through.").to_string())?;
        c.env.chats.with(|inbox| inbox.vote_mine(&key, &message, &choice));
        c.chat_helper.bridge.changed(&chat, Some(&net));
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
    use nook_core::chats::ChatAction;
    let (source, chat) = chat_id(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    let abilities = abilities_for(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    if pinned.is_some() && !abilities.allows(ChatAction::Pin) {
        return Err("This chat's app does not support pinning from Nook.".into());
    }
    if muted.is_some() && !abilities.allows(ChatAction::Mute) {
        return Err("This chat's app does not support muting from Nook.".into());
    }
    if archived.is_some() && !abilities.allows(ChatAction::Archive) {
        return Err("This chat's app does not support archiving from Nook.".into());
    }
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
    c.env.chats.with(|inbox| {
        if let Some(p) = pinned {
            inbox.set_pinned(&key, p, true);
        }
        if let Some(m) = muted {
            inbox.set_muted(&key, m);
        }
        if let Some(a) = archived {
            inbox.set_archived(&key, a);
        }
    });
    c.chat_helper.bridge.changed(&chat, None);
    changed(&app);
    Ok(())
}

/// A link's preview for its bubble (`ChatLinkPreviews`): fetched once, kept in memory only (at most 200).
#[tauri::command]
pub async fn chat_link_preview(url: String) -> Option<nook_core::chats::link_preview::Preview> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<HashMap<String, Option<nook_core::chats::link_preview::Preview>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Mutex::default);
    if let Some(known) = cache.lock().unwrap_or_else(|e| e.into_inner()).get(&url) {
        return known.clone();
    }
    let preview = nook_core::chats::link_preview::fetch(&url).await;
    let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() >= 200 {
        cache.clear();
    }
    cache.insert(url, preview.clone());
    preview
}

/// The chat's newest thirty messages as the brain reads them: you as "You", everyone else by name.
fn transcript(c: &Connectors, key: &str) -> Option<(String, String, String, bool)> {
    c.env.chats.read(|inbox| {
        let t = inbox.threads.get(key)?;
        let kept: Vec<&nook_core::chats::InboxMessage> = t.messages.iter().filter(|m| !m.deleted).collect();
        let lines: Vec<String> = kept[kept.len().saturating_sub(30)..]
            .iter()
            .map(|m| format!("{}: {}", if m.from_me { "You" } else if m.sender.is_empty() { t.name.as_str() } else { m.sender.as_str() }, if m.text.is_empty() { "(a file)" } else { m.text.as_str() }))
            .collect();
        let last_is_theirs = t.messages.last().is_some_and(|m| !m.from_me);
        Some((super::notify::app_name(&t.app).to_string(), t.name.clone(), lines.join("\n"), last_is_theirs))
    })
}

async fn write_message(app: &AppHandle, c: &Connectors, key: &str, instruction: &str, timeout: u64) -> Res<Option<String>> {
    use nook_core::brain::service;
    use nook_core::chats::draft;
    let state = app.state::<crate::state::AppState>();
    let settings = state.settings();
    if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        return Err("Nook has no brain ready to write with. Choose one in Settings › Brain.".into());
    }
    let (app_name, name, lines, _) = transcript(c, key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
    let env = crate::commands::chat::brain_env(app, &settings);
    let prompt = draft::prompt(&app_name, &name, &lines, instruction);
    match tokio::time::timeout(std::time::Duration::from_secs(timeout), service::complete(&settings, &env, draft::SYSTEM, &prompt)).await {
        Ok(Ok(answer)) => Ok(draft::clean(&answer)),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("Nook took too long to write it.".into()),
    }
}

/// Edits one of your own messages in `key` (`chat_inbox_edit_message`, CH-47).
#[tauri::command]
pub async fn chat_inbox_edit_message(
    app: AppHandle,
    c: State<'_, Connectors>,
    key: String,
    message: String,
    text: String,
) -> Res<()> {
    chat_inbox_message(app, c, key, message, "edit".into(), Some(text)).await
}

/// Deletes a message for everyone in `key` (`chat_inbox_delete_for_everyone`, CH-47).
#[tauri::command]
pub async fn chat_inbox_delete_for_everyone(
    app: AppHandle,
    c: State<'_, Connectors>,
    key: String,
    message: String,
) -> Res<()> {
    chat_inbox_message(app, c, key, message, "revoke".into(), None).await
}

/// Deletes a message for you alone in `key`, recording it in `ChatHiddenMessages` (`chat_inbox_delete_for_me`, CH-47).
#[tauri::command]
pub async fn chat_inbox_delete_for_me(
    app: AppHandle,
    c: State<'_, Connectors>,
    key: String,
    message: String,
) -> Res<()> {
    chat_inbox_message(app, c, key, message, "deleteForMe".into(), None).await
}

/// Detailed metadata for one message in `key` (`MessageInfoPopover`, CH-47).
#[tauri::command]
pub fn chat_inbox_message_info(
    c: State<'_, Connectors>,
    key: String,
    message: String,
) -> Option<nook_core::chats::inbox::MessageInfo> {
    c.env.chats.read(|inbox| inbox.message_info(&key, &message))
}

/// Result of an inline `@nook` request in a chat composer (`chat_inline_nook`, CH-63).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InlineNookResult {
    /// `"draft"` when the text should be placed in the composer field; `"answer"` when it answers a lookup question.
    pub kind: String,
    pub text: String,
    pub instruction: String,
}

fn is_lookup_question(instruction: &str) -> bool {
    let lower = instruction.trim().to_lowercase();
    if lower.is_empty() {
        return false;
    }
    if lower.ends_with('?') {
        return true;
    }
    const LOOKUP_PREFIXES: [&str; 22] = [
        "what ",
        "when ",
        "where ",
        "who ",
        "why ",
        "how ",
        "which ",
        "summarize",
        "summary",
        "explain",
        "find ",
        "search ",
        "look up",
        "lookup",
        "check ",
        "did ",
        "wat ",
        "wanneer ",
        "waar ",
        "wie ",
        "waarom ",
        "hoe ",
    ];
    LOOKUP_PREFIXES.iter().any(|p| lower.starts_with(p))
}

/// Inline `@nook <instruction>` in a chat composer (`ChatDraft`, CH-63): drafts a reply, refines an existing draft
/// when `current_draft` is provided, or answers a lookup question about the chat in a dismissible popover.
#[tauri::command]
pub async fn chat_inline_nook(
    app: AppHandle,
    c: State<'_, Connectors>,
    key: String,
    instruction: String,
    current_draft: Option<String>,
) -> Res<InlineNookResult> {
    use nook_core::brain::service;
    use nook_core::chats::draft;

    let clean_inst = draft::instruction(&instruction).unwrap_or_else(|| instruction.trim().to_string());
    let existing = current_draft.unwrap_or_default().trim().to_string();
    let is_lookup = existing.is_empty() && is_lookup_question(&clean_inst);

    if is_lookup {
        let state = app.state::<crate::state::AppState>();
        let settings = state.settings();
        if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
            return Err("Nook has no brain ready to answer with. Choose one in Settings › Brain.".into());
        }
        let (app_name, name, lines, _) =
            transcript(&c, &key).ok_or_else(|| "This chat is no longer in Nook.".to_string())?;
        let env = crate::commands::chat::brain_env(&app, &settings);
        let system = "You answer the user's question about the chat transcript below concisely and accurately, in the user's language. Do not draft a message to send; answer the user directly in 1–3 sentences.";
        let prompt = format!(
            "{app_name} chat with {name}. The newest messages, oldest first (\"You\" is the user):\n{}\n\nThe user's question about this chat:\n{clean_inst}",
            if lines.is_empty() { "(no messages yet)" } else { &lines }
        );
        let answer = match tokio::time::timeout(
            std::time::Duration::from_secs(60),
            service::complete(&settings, &env, system, &prompt),
        )
        .await
        {
            Ok(Ok(ans)) => ans.trim().to_string(),
            Ok(Err(e)) => return Err(e.to_string()),
            Err(_) => return Err("Nook took too long to answer.".into()),
        };
        if answer.is_empty() {
            return Err("Nook could not find an answer in this chat.".into());
        }
        return Ok(InlineNookResult {
            kind: "answer".into(),
            text: answer,
            instruction: clean_inst,
        });
    }

    let full_instruction = if !existing.is_empty() {
        let change = if clean_inst.is_empty() {
            "Try another version in a similar tone."
        } else {
            clean_inst.as_str()
        };
        format!("Your draft so far:\n{existing}\n\nThe change: {change}")
    } else {
        clean_inst.clone()
    };

    let text = write_message(&app, &c, &key, &full_instruction, 90)
        .await?
        .ok_or_else(|| "Nook could not write a message for this chat.".to_string())?;

    Ok(InlineNookResult {
        kind: "draft".into(),
        text,
        instruction: clean_inst,
    })
}

/// "@nook …" in a chat's field: the message Nook writes from the chat and what you asked, for the field. Never sent.
#[tauri::command]
pub async fn chat_draft(app: AppHandle, c: State<'_, Connectors>, key: String, instruction: String) -> Res<String> {
    write_message(&app, &c, &key, instruction.trim(), 90).await?.ok_or_else(|| "Nook could not write a message for this chat.".into())
}

/// The answer you will likely send, as grey text in the empty field of a chat whose newest message is someone else's
/// (`ChatReplySuggestion`); `None` when there is nothing to answer, the chat looks like phishing/scam (CH-39), or no brain.
#[tauri::command]
pub async fn chat_suggest_reply(app: AppHandle, c: State<'_, Connectors>, key: String) -> Res<Option<String>> {
    let allowed = c
        .env
        .chats
        .read(|inbox| inbox.threads.get(&key).is_some_and(nook_core::chats::follow_up::should_suggest_reply));
    if !allowed {
        return Ok(None);
    }
    Ok(write_message(&app, &c, &key, "", 60).await.ok().flatten())
}

fn helper_off() -> String {
    "Nook's chat helper is not running, so this app cannot be reached right now.".to_string()
}
