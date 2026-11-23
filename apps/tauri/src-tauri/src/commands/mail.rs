//! Tauri commands for linked Microsoft and Google mail/calendar accounts: listing, OAuth sign-in (Microsoft device
//! code, Google PKCE loopback), toggling calendar sync, renaming, removing, saving custom OAuth app IDs, and sending a
//! `MailDraft` directly through a linked account.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use nook_core::brain::action_gate::is_mail_address;
use nook_core::connectors::mail::auth::DeviceCode;
use nook_core::connectors::mail::service::{ClientConfig, MailService};
use nook_core::connectors::mail::{Attachment, MailAccount, Outgoing};
use nook_core::i18n::{tr, trf};
use nook_core::nooks::MailDraft;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_opener::OpenerExt;

use crate::connectors::Connectors;
use crate::state::AppState;

type Res<T> = Result<T, String>;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MailAccountsView {
    pub accounts: Vec<MailAccount>,
    pub microsoft_ready: bool,
    pub google_ready: bool,
    pub has_custom_microsoft: bool,
    pub has_custom_google: bool,
}

fn service(app: &AppHandle) -> Res<Arc<MailService>> {
    static SERVICE: OnceLock<Arc<MailService>> = OnceLock::new();
    if let Some(svc) = SERVICE.get() {
        return Ok(svc.clone());
    }
    let connectors = app
        .try_state::<Connectors>()
        .ok_or_else(|| tr("Koppelingen zijn nog niet gestart.", "Connections are not ready yet.").to_string())?;
    let svc = MailService::new(connectors.env.clone());
    let _ = SERVICE.set(svc.clone());
    Ok(SERVICE.get().cloned().unwrap_or(svc))
}

fn pending_device_codes() -> &'static Mutex<HashMap<String, DeviceCode>> {
    static CODES: OnceLock<Mutex<HashMap<String, DeviceCode>>> = OnceLock::new();
    CODES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn build_view(svc: &MailService) -> MailAccountsView {
    let ClientConfig { microsoft_ready, google_ready, has_custom_microsoft, has_custom_google } = svc.client_config();
    MailAccountsView { accounts: svc.accounts(), microsoft_ready, google_ready, has_custom_microsoft, has_custom_google }
}

fn notify(app: &AppHandle) {
    let _ = app.emit("connectors-changed", ());
}

/// Lists all linked Microsoft and Google mail/calendar accounts and OAuth readiness.
#[tauri::command]
pub fn mail_accounts_list(app: AppHandle) -> Res<MailAccountsView> {
    let svc = service(&app)?;
    Ok(build_view(&svc))
}

/// Starts the Microsoft device-code flow and keeps the secret `device_code` in memory until `mail_microsoft_finish`.
#[tauri::command]
pub async fn mail_microsoft_start(app: AppHandle) -> Res<DeviceCode> {
    let svc = service(&app)?;
    let code = svc.start_microsoft_sign_in().await.map_err(|e| e.message)?;
    {
        let mut guard = pending_device_codes().lock().unwrap_or_else(|e| e.into_inner());
        if guard.len() > 20 {
            guard.clear();
        }
        guard.insert(code.user_code.clone(), code.clone());
    }
    Ok(code)
}

/// Waits for the user to approve the Microsoft device code in their browser and links the account.
#[tauri::command]
pub async fn mail_microsoft_finish(app: AppHandle, user_code: String, name: Option<String>) -> Res<MailAccount> {
    let svc = service(&app)?;
    let code = pending_device_codes()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(user_code.trim())
        .ok_or_else(|| tr("Deze aanmeldcode is verlopen. Begin opnieuw.", "This sign-in code has expired. Start again.").to_string())?;
    let account = svc.finish_microsoft_sign_in(&code, name.as_deref().unwrap_or("")).await.map_err(|e| e.message)?;
    notify(&app);
    Ok(account)
}

/// Starts the Google PKCE browser sign-in flow and links the Gmail / Google Calendar account once approved.
#[tauri::command]
pub async fn mail_google_sign_in(app: AppHandle, name: Option<String>) -> Res<MailAccount> {
    let svc = service(&app)?;
    let opener = app.clone();
    let account = svc
        .sign_in_google(name.as_deref().unwrap_or(""), move |url| {
            let _ = opener.opener().open_url(url, None::<&str>);
        })
        .await
        .map_err(|e| e.message)?;
    notify(&app);
    Ok(account)
}

/// Toggles calendar reading and writing on a linked mail account.
#[tauri::command]
pub fn mail_account_set_calendar(app: AppHandle, id: String, calendar: bool) -> Res<MailAccount> {
    let svc = service(&app)?;
    let account = svc.set_calendar(&id, calendar).map_err(|e| e.message)?;
    notify(&app);
    Ok(account)
}

/// Renames a linked mail account.
#[tauri::command]
pub fn mail_account_rename(app: AppHandle, id: String, name: String) -> Res<MailAccount> {
    let svc = service(&app)?;
    let account = svc.rename_account(&id, &name).map_err(|e| e.message)?;
    notify(&app);
    Ok(account)
}

/// Unlinks a mail account and deletes its refresh token from the keychain.
#[tauri::command]
pub fn mail_account_remove(app: AppHandle, id: String) -> Res<()> {
    let svc = service(&app)?;
    svc.remove_account(&id).map_err(|e| e.message)?;
    notify(&app);
    Ok(())
}

/// Saves optional custom Microsoft / Google OAuth client IDs (in the keychain) for self-built apps.
#[tauri::command]
pub fn mail_save_client_config(
    app: AppHandle,
    microsoft_client_id: Option<String>,
    google_client_id: Option<String>,
    google_client_secret: Option<String>,
) -> Res<MailAccountsView> {
    let svc = service(&app)?;
    svc.save_client_config(microsoft_client_id.as_deref(), google_client_id.as_deref(), google_client_secret.as_deref())
        .map_err(|e| e.message)?;
    notify(&app);
    Ok(build_view(&svc))
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

/// Sends a `MailDraft` directly through a linked Microsoft or Google account (including attachments like `invite.ics`
/// and optional `reply_to` threading). Returns the label of the account used.
#[tauri::command]
pub async fn mail_send_linked(app: AppHandle, mut draft: MailDraft, account: Option<String>, reply_to: Option<String>) -> Res<String> {
    let to = split_addresses(&draft.to);
    if to.is_empty() {
        return Err(tr("Vul eerst een ontvanger in.", "Enter a recipient first.").into());
    }
    let cc = split_addresses(&draft.cc);
    let bcc = split_addresses(&draft.bcc);
    if let Some(bad) = to.iter().chain(cc.iter()).chain(bcc.iter()).find(|a| !is_mail_address(a)) {
        return Err(trf("{address} is geen geldig mailadres.", "{address} is not a valid email address.", &[("address", bad)]));
    }
    crate::tools::sync_invite(&mut draft);
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
    let outgoing = Outgoing {
        to,
        cc,
        bcc,
        subject: draft.subject.clone(),
        body: draft.body.clone(),
        reply_to: reply_to.filter(|s| !s.trim().is_empty()),
        attachments,
    };
    let svc = service(&app)?;
    let used = svc.send_mail(&outgoing, account.as_deref()).await.map_err(|e| e.message)?;
    app.state::<AppState>().store.audit("send_mail", &format!("{} · {}", draft.to, draft.subject), &used);
    Ok(used)
}
