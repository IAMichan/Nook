//! De koppelingen in de app: één hub met alle bronnen (GitHub, Stripe, agenda's, MCP-servers, WhatsApp, …), op de
//! achtergrond ververst. De interface hoort het via het event `connectors-changed`; een nieuw WhatsApp-bericht komt
//! als `whatsapp-message`, nieuwe vinkjes als `whatsapp-receipt`.

use std::sync::{Arc, OnceLock};

use nook_core::connectors::cloud::{Calcom, N8n, Notion, Resend, Stripe, Vercel};
use nook_core::connectors::custom::CustomSources;
use nook_core::connectors::feeds::CalendarFeeds;
use nook_core::connectors::github::GitHub;
use nook_core::connectors::hub::Env;
use nook_core::connectors::{mcp, whatsapp, ConnectorHub, ConnectorStore};
use tauri::{AppHandle, Emitter, Manager};

use crate::state::AppState;

/// Alles wat de commando's en tools van de koppelingen delen.
pub struct Connectors {
    pub env: Arc<Env>,
    pub hub: Arc<ConnectorHub>,
    pub github: Arc<GitHub>,
    /// The first WhatsApp account (the one registered as a connector, with the brain's WhatsApp tools).
    pub whatsapp: Arc<whatsapp::WhatsAppLink>,
    /// Every WhatsApp account, the first one included (`WhatsAppAccounts`).
    pub whatsapp_accounts: Arc<whatsapp::accounts::WhatsAppAccounts>,
    /// Nook's chat helper (Telegram, Signal, Messenger, Instagram, X, LinkedIn, Slack), read into the same inbox.
    pub chat_helper: Arc<crate::chats::helper::ChatHelper>,
}

impl Connectors {
    /// The WhatsApp account a chat is in, by its key across accounts (a bare JID: the first account).
    pub fn wa(&self, chat: &str) -> Arc<whatsapp::WhatsAppLink> {
        self.whatsapp_accounts.route(chat)
    }

    /// Brengt de MCP-koppelingen in lijn met de servers in de instellingen.
    pub fn sync_mcp(&self) {
        mcp::connector::sync(&self.hub, &self.env);
        self.hub.changed();
    }
}

static HANDLE: OnceLock<AppHandle> = OnceLock::new();

/// De app, voor plekken zonder `ToolCtx` (de samenvatting op een plankaart).
pub fn handle() -> Option<AppHandle> {
    HANDLE.get().cloned()
}

/// Maakt de hub met alle bronnen en start het verversen. Wordt vanuit `setup` in `lib.rs` aangeroepen.
pub fn setup(app: &AppHandle) {
    let _ = HANDLE.set(app.clone());
    let secrets = app.state::<AppState>().secrets.clone();
    // One inbox for every chat app, kept in `chat-inbox.json` (an app whose messages stay in the app, WhatsApp through
    // its gateway, is saved without them).
    let chats = Arc::new(nook_core::chats::InboxStore::open_default());
    let env = Env::with_chats(secrets, Arc::new(ConnectorStore::open_default()), chats.clone());
    let hub = ConnectorHub::new(env.store.clone());
    let github = GitHub::new(env.clone());
    let whatsapp = whatsapp::WhatsAppLink::new(env.clone(), cfg!(desktop));
    hub.register(github.clone());
    hub.register(Vercel::new(env.clone()));
    hub.register(Stripe::new(env.clone()));
    hub.register(Notion::new(env.clone()));
    hub.register(Calcom::new(env.clone()));
    hub.register(N8n::new(env.clone()));
    hub.register(Resend::new(env.clone()));
    hub.register(CalendarFeeds::new(env.clone()));
    hub.register(CustomSources::new(env.clone()));
    hub.register(whatsapp.clone());

    let handle = app.clone();
    hub.on_change(move || {
        let _ = handle.emit("connectors-changed", ());
    });
    let whatsapp_accounts = whatsapp::accounts::WhatsAppAccounts::new(env.clone(), cfg!(desktop), whatsapp.clone());
    let app_for_wa = app.clone();
    let weak = Arc::downgrade(&whatsapp_accounts);
    whatsapp_accounts.wire(move |link| wire_whatsapp(&app_for_wa, link, weak.clone()));

    let chat_helper = crate::chats::helper::setup(app, env.chats.clone());
    app.manage(Connectors {
        env: env.clone(),
        hub: hub.clone(),
        github,
        whatsapp: whatsapp.clone(),
        whatsapp_accounts: whatsapp_accounts.clone(),
        chat_helper,
    });
    crate::chats::follow_up::setup(app);
    // Verversen en luisteren draaien op de runtime van Tauri.
    tauri::async_runtime::spawn(async move {
        // Saved at most every few seconds, and only when something changed.
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            if let Err(error) = chats.save() {
                log::warn!("chat inbox not saved: {error}");
            }
        }
    });
    tauri::async_runtime::spawn(async move {
        mcp::connector::sync(&hub, &env);
        hub.start();
        whatsapp.start();
        whatsapp_accounts.start();
    });
}

/// Bij afsluiten: de GOWA die Nook startte gaat mee uit.
pub fn shutdown(app: &AppHandle) {
    if let Some(c) = app.try_state::<Connectors>() {
        c.whatsapp.stop_gowa();
        // Files fetched for the WhatsApp card never outlive Nook.
        for link in c.whatsapp_accounts.links() {
            link.clear_files();
        }
        c.chat_helper.stop();
        let _ = c.env.chats.save();
    }
}

/// What one WhatsApp account reports goes to the app: changes, new messages (automations, the notice rules) and ticks.
fn wire_whatsapp(app: &AppHandle, link: &Arc<whatsapp::WhatsAppLink>, accounts: std::sync::Weak<whatsapp::accounts::WhatsAppAccounts>) {
    let handle = app.clone();
    link.on_changed(move || {
        // An account that linked or let go changes whether chats say which account they are in.
        if let Some(accounts) = accounts.upgrade() {
            accounts.label();
        }
        let _ = handle.emit("connectors-changed", ());
    });
    let handle = app.clone();
    link.on_arrived(move |arrived| {
        // Automations that start on a message (BR-16). WhatsApp reports one notifying arrival with the chat's newest
        // text; the shared chat inbox hands every other app's messages to the same entry point.
        crate::workspace::automation::messages_arrived(
            &handle,
            vec![nook_core::workspace::arrivals::ArrivedMessage {
                chat_id: format!("whatsapp:{}", arrived.chat),
                app: "whatsapp".into(),
                chat: arrived.name.clone(),
                sender: arrived.name.clone(),
                text: arrived.preview.clone(),
                date: chrono::Utc::now(),
                is_group: arrived.chat.ends_with("@g.us"),
                id: String::new(),
            }],
        );
        // As Settings › Notifications says (`notices::decide`): a system notification with Reply and Mark as read, the
        // bar's card or strip, or nothing popping up at all.
        let key = arrived.key.clone();
        match crate::chats::notify::style(&handle, "whatsapp", false) {
            Some(nook_core::services::notice_rules::NoticeStyle::System) => {
                crate::chats::notify::toast(&handle, &key, "whatsapp", &arrived.name, &arrived.preview, true)
            }
            Some(_) => {
                let _ = handle.emit("whatsapp-message", &arrived);
            }
            None => {}
        }
    });
    let handle = app.clone();
    link.on_receipt(move |chat| {
        let _ = handle.emit("whatsapp-receipt", &chat);
    });
}
