//! Linking a chat app through Nook's chat helper (`ChatLinker` and `ChatSignInWindow` on the Mac): the login's steps,
//! and the window of a "sign in on the website" step. That window is the app's own login page (instagram.com,
//! messenger.com, slack.com…) in a fresh, private browser of its own. You sign in there as you always do; once the
//! cookies (and the headers, local storage and script values) the step asks for are there and the page says you are in,
//! they go to the chat helper on this computer, and nowhere else, and the window closes. Closing it yourself stops the
//! login.
//!
//! The website never talks to Nook: the window has no access to Nook's commands, and the page scripts only leave what
//! they found in a page variable that Nook reads each second.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use nook_core::chats::chatd::ChatdClient;
use nook_core::chats::link::{self, agent, Network, PageRead, Session, Source, Step};
use nook_core::i18n::trf;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tokio::sync::oneshot;

use crate::connectors::Connectors;

/// The one sign-in window: a new one closes the old, so none is ever left behind out of sight.
const LABEL: &str = "chat-sign-in";
/// How often the window looks for what the step asks for: a login can finish in the page without a page load.
const LOOK_GAP: Duration = Duration::from_secs(1);

async fn client(c: &Connectors) -> Result<ChatdClient, String> {
    if let Some(client) = c.chat_helper.bridge.client() {
        return Ok(client);
    }
    // Linking is what creates the helper's data directory, so it starts here the first time.
    if c.chat_helper.start().await {
        if let Some(client) = c.chat_helper.bridge.client() {
            return Ok(client);
        }
    }
    Err(c.chat_helper.problem().unwrap_or_else(|| "nook-chatd".into()))
}

/// The apps the helper links and their accounts.
#[tauri::command]
pub async fn chat_link_networks(c: State<'_, Connectors>) -> Result<Vec<Network>, String> {
    client(&c).await?.networks(|_| None).await
}

#[tauri::command]
pub async fn chat_link_start(c: State<'_, Connectors>, network: String) -> Result<Session, String> {
    client(&c).await?.start_login(&network).await
}

#[tauri::command]
pub async fn chat_link_session(c: State<'_, Connectors>, network: String, session: String) -> Result<Session, String> {
    client(&c).await?.login(&network, &session).await
}

/// Answers a step with fields (a phone number, a code, a password).
#[tauri::command]
pub async fn chat_link_submit(
    c: State<'_, Connectors>,
    network: String,
    session: String,
    values: HashMap<String, String>,
) -> Result<Session, String> {
    let client = client(&c).await?;
    let current = client.login(&network, &session).await?;
    let step = current.step.ok_or_else(|| "step".to_string())?;
    client.submit_step(&network, &session, &step, link::answer(&step, &values, None)).await
}

#[tauri::command]
pub async fn chat_link_cancel(app: AppHandle, c: State<'_, Connectors>, network: String, session: String) -> Result<(), String> {
    close(&app);
    client(&c).await?.cancel_login(&network, &session).await
}

/// Unlinks an account.
#[tauri::command]
pub async fn chat_link_remove(c: State<'_, Connectors>, network: String, login: String) -> Result<(), String> {
    client(&c).await?.remove_login(&network, &login).await
}

/// Opens the sign-in window of the login's current "sign in on the website" step. When it is done, what it collected
/// goes to the helper and `chat-link-changed` tells the interface; closing it stops the login.
#[tauri::command]
pub async fn chat_link_sign_in(
    app: AppHandle,
    c: State<'_, Connectors>,
    network: String,
    session: String,
    name: String,
) -> Result<(), String> {
    let client = client(&c).await?;
    let current = client.login(&network, &session).await?;
    let Some(step @ Step::Browser { .. }) = current.step else { return Err("step".into()) };
    let (done, finished) = oneshot::channel();
    open(&app, &step, &name, done)?;
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let outcome = match finished.await {
            Ok(Some((values, last))) => {
                client.submit_step(&network, &session, &step, link::answer(&step, &values, last.as_deref())).await.map(Some)
            }
            // Closed by hand: the login stops.
            _ => client.cancel_login(&network, &session).await.map(|_| None),
        };
        if let Err(error) = &outcome {
            log::info!("Chats: sign-in for {network} failed: {error}");
        }
        let _ = app.emit("chat-link-changed", outcome.ok().flatten());
    });
    Ok(())
}

/// Closes the sign-in window, if one is open.
pub fn close(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.destroy();
    }
}

type Done = oneshot::Sender<Option<(HashMap<String, String>, Option<String>)>>;

fn open(app: &AppHandle, step: &Step, name: &str, done: Done) -> Result<(), String> {
    let Step::Browser { url, user_agent, collect, done: pattern, extract, .. } = step else { return Err("step".into()) };
    close(app);
    let start = url::Url::parse(url).map_err(|e| e.to_string())?;
    let mut builder = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::External(start))
        .title(trf("Inloggen bij {app}", "Log in to {app}", &[("app", &name)]))
        .inner_size(520.0, 720.0)
        .center()
        .focused(true)
        // Its own store, gone with the window: the sign-in lives in the chat helper, not in Nook.
        .incognito(true)
        .initialization_script(agent::GOOGLE_PASSKEYS);
    if let Some(script) = link::header_script(&link::page_headers(collect)) {
        builder = builder.initialization_script(script);
    }
    if let Some(agent) = user_agent.as_deref().filter(|a| !a.is_empty()) {
        builder = builder.user_agent(agent);
    }
    let window = builder.build().map_err(|e| e.to_string())?;
    let done = Arc::new(std::sync::Mutex::new(Some(done)));
    // Closed by hand before it finished: the login stops.
    let closed = done.clone();
    window.on_window_event(move |event| {
        if matches!(event, tauri::WindowEvent::Destroyed) {
            if let Some(sender) = closed.lock().unwrap_or_else(|e| e.into_inner()).take() {
                let _ = sender.send(None);
            }
        }
    });
    let collect = collect.clone();
    let pattern = pattern.clone();
    let extract = extract.clone().filter(|_| collect.iter().any(|c| c.source == Source::Special));
    let storage_keys: Vec<String> = collect.iter().filter(|c| c.source == Source::LocalStorage).map(|c| c.name.clone()).collect();
    let start = url.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(LOOK_GAP).await;
            // Cookies are read off the main thread: WebView2 deadlocks when they are read in an event handler.
            let Ok(cookies) = window.cookies() else { return };
            let cookies: Vec<(String, String, String)> = cookies
                .into_iter()
                .map(|c| (c.domain().unwrap_or_default().to_string(), c.name().to_string(), c.value().to_string()))
                .collect();
            if let Some(script) = &extract {
                let _ = window.eval(link::extract_script(script));
            }
            let (tx, rx) = oneshot::channel();
            let tx = std::sync::Mutex::new(Some(tx));
            if window
                .eval_with_callback(link::read_script(&storage_keys), move |answer| {
                    if let Some(tx) = tx.lock().unwrap_or_else(|e| e.into_inner()).take() {
                        let _ = tx.send(answer);
                    }
                })
                .is_err()
            {
                return;
            }
            let page = match tokio::time::timeout(Duration::from_secs(5), rx).await {
                Ok(Ok(answer)) => PageRead::parse(&answer).unwrap_or_default(),
                _ => PageRead::default(),
            };
            let jar = link::jar(&cookies, &start);
            let values = link::collected(&collect, &jar, &page.storage, &page.headers, &page.special);
            if !link::has_cookies(&collect, &values) {
                continue;
            }
            // A pattern for the page after signing in waits for it; without one the values are enough.
            if pattern.is_some() && !link::is_done(&page.address, pattern.as_deref()) {
                continue;
            }
            let address = (!page.address.is_empty()).then_some(page.address);
            if let Some(sender) = done.lock().unwrap_or_else(|e| e.into_inner()).take() {
                let _ = sender.send(Some((values, address)));
            }
            let _ = window.destroy();
            return;
        }
    });
    Ok(())
}
