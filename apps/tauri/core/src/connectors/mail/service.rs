//! Multi-account mail and calendar orchestration across Microsoft Graph (Outlook, Microsoft 365) and Google (Gmail,
//! Google Calendar). Access tokens live in memory only; refresh tokens live in the keychain (`SecretStore`) under
//! [`MailAccount::token_key`]. Nothing of a mail is ever written to disk.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::Serialize;

use super::{auth, gmail, graph, split_id, Change, Event, Mail, MailAccount, NewEvent, Outgoing, Provider, Selection, MAX_CHANGE};
use crate::connectors::agenda::{AgendaEntry, AgendaResult};
use crate::connectors::hub::{Connector, Env};
use crate::connectors::{api_base, CResult, ConnectorError, ConnectorStatus, ErrorKind};
use crate::i18n::{tr, trf};

pub const ID: &str = "mail";

/// API endpoints used by [`MailService`]. Defaults point at Microsoft Graph, Gmail, Google Calendar and their OAuth
/// endpoints (overridable via debug env vars or [`MailService::with_bases`] in tests).
#[derive(Debug, Clone)]
pub struct Bases {
    pub graph: String,
    pub gmail: String,
    pub calendar: String,
    pub microsoft_authority: String,
    pub google_token: String,
}

impl Default for Bases {
    fn default() -> Self {
        Self {
            graph: api_base(graph::BASE, "NOOK_GRAPH_BASE"),
            gmail: api_base(gmail::GMAIL, "NOOK_GMAIL_BASE"),
            calendar: api_base(gmail::CALENDAR, "NOOK_GCAL_BASE"),
            microsoft_authority: api_base(auth::MICROSOFT_AUTHORITY, "NOOK_MICROSOFT_AUTHORITY"),
            google_token: api_base(auth::GOOGLE_TOKEN, "NOOK_GOOGLE_TOKEN"),
        }
    }
}

/// Whether OAuth app ids are available for signing in (from build-time env vars or custom entries in the keychain).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientConfig {
    pub microsoft_ready: bool,
    pub google_ready: bool,
    pub has_custom_microsoft: bool,
    pub has_custom_google: bool,
}

#[derive(Clone)]
struct CachedToken {
    access: String,
    expires_at: Instant,
}

pub struct MailService {
    env: Arc<Env>,
    bases: Bases,
    tokens: Mutex<HashMap<String, CachedToken>>,
    cached_events: Mutex<Vec<AgendaEntry>>,
    status: Mutex<ConnectorStatus>,
}

impl MailService {
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Self::with_bases(env, Bases::default())
    }

    pub fn with_bases(env: Arc<Env>, bases: Bases) -> Arc<Self> {
        Arc::new(Self {
            env,
            bases,
            tokens: Mutex::new(HashMap::new()),
            cached_events: Mutex::new(Vec::new()),
            status: Mutex::new(ConnectorStatus::default()),
        })
    }

    // Account management

    pub fn accounts(&self) -> Vec<MailAccount> {
        self.env.store.read(|c| c.mail_accounts.clone())
    }

    pub fn has_accounts(&self) -> bool {
        self.env.store.read(|c| !c.mail_accounts.is_empty())
    }

    pub fn has_calendar_accounts(&self) -> bool {
        self.env.store.read(|c| c.mail_accounts.iter().any(|a| a.calendar))
    }

    pub fn account(&self, id: &str) -> Option<MailAccount> {
        self.env.store.read(|c| c.mail_accounts.iter().find(|a| a.id == id).cloned())
    }

    /// Saves a linked account (deduplicating by provider + address) and stores its refresh token in the keychain.
    pub fn add_account(&self, mut account: MailAccount, refresh_token: &str) -> CResult<MailAccount> {
        let refresh = refresh_token.trim();
        if refresh.is_empty() {
            return Err(ConnectorError::kind(
                tr("Geen vernieuwingstoken ontvangen. Log opnieuw in.", "No refresh token received. Sign in again."),
                ErrorKind::Auth,
            ));
        }
        account.address = account.address.trim().to_string();
        account.name = account.name.trim().to_string();
        if account.address.is_empty() {
            return Err(ConnectorError::new(tr(
                "Het mailadres van dit account kon niet worden gelezen.",
                "Could not read the email address for this account.",
            )));
        }

        // Reuse the existing id when re-linking the same provider + address so ids stay stable.
        let existing_id = self.env.store.read(|c| {
            c.mail_accounts
                .iter()
                .find(|a| a.provider == account.provider && a.address.eq_ignore_ascii_case(&account.address))
                .map(|a| a.id.clone())
        });
        if let Some(id) = existing_id {
            account.id = id;
        } else if account.id.trim().is_empty() {
            account.id = make_account_id(account.provider, &account.address, &self.accounts());
        }

        self.env.secrets.write(&account.token_key(), refresh).map_err(ConnectorError::new)?;
        self.invalidate_token(&account.id);

        let saved = account.clone();
        self.env.store.update(|c| {
            if let Some(existing) = c.mail_accounts.iter_mut().find(|a| a.id == saved.id) {
                existing.address = saved.address.clone();
                if !saved.name.is_empty() {
                    existing.name = saved.name.clone();
                }
                existing.calendar = saved.calendar;
            } else {
                c.mail_accounts.push(saved.clone());
            }
        });
        Ok(self.account(&account.id).unwrap_or(account))
    }

    /// Removes a linked account from configuration and deletes its refresh token from the keychain.
    pub fn remove_account(&self, id: &str) -> CResult<()> {
        let Some(account) = self.account(id) else {
            return Err(ConnectorError::new(tr("Dit mailaccount bestaat niet meer.", "This mail account no longer exists.")));
        };
        self.invalidate_token(&account.id);
        let _ = self.env.secrets.remove(&account.token_key());
        self.env.store.update(|c| {
            c.mail_accounts.retain(|a| a.id != id);
        });
        Ok(())
    }

    /// Enables or disables calendar reading and writing for a linked account.
    pub fn set_calendar(&self, id: &str, enabled: bool) -> CResult<MailAccount> {
        let updated = self.env.store.update(|c| {
            let acct = c.mail_accounts.iter_mut().find(|a| a.id == id)?;
            acct.calendar = enabled;
            Some(acct.clone())
        });
        updated.ok_or_else(|| ConnectorError::new(tr("Dit mailaccount bestaat niet meer.", "This mail account no longer exists.")))
    }

    /// Renames a linked account (empty name falls back to showing its email address).
    pub fn rename_account(&self, id: &str, name: &str) -> CResult<MailAccount> {
        let trimmed = name.trim().to_string();
        let updated = self.env.store.update(|c| {
            let acct = c.mail_accounts.iter_mut().find(|a| a.id == id)?;
            acct.name = trimmed;
            Some(acct.clone())
        });
        updated.ok_or_else(|| ConnectorError::new(tr("Dit mailaccount bestaat niet meer.", "This mail account no longer exists.")))
    }

    pub fn client_config(&self) -> ClientConfig {
        ClientConfig {
            microsoft_ready: auth::microsoft_client(&self.env).is_some(),
            google_ready: auth::google_client(&self.env).is_some(),
            has_custom_microsoft: self.env.secret(auth::MICROSOFT_CLIENT_KEY).is_some(),
            has_custom_google: self.env.secret(auth::GOOGLE_CLIENT_KEY).is_some(),
        }
    }

    pub fn save_client_config(
        &self,
        microsoft_client_id: Option<&str>,
        google_client_id: Option<&str>,
        google_client_secret: Option<&str>,
    ) -> CResult<ClientConfig> {
        if let Some(id) = microsoft_client_id {
            self.env.secrets.write(auth::MICROSOFT_CLIENT_KEY, id).map_err(ConnectorError::new)?;
        }
        if let Some(id) = google_client_id {
            self.env.secrets.write(auth::GOOGLE_CLIENT_KEY, id).map_err(ConnectorError::new)?;
        }
        if let Some(secret) = google_client_secret {
            self.env.secrets.write(auth::GOOGLE_SECRET_KEY, secret).map_err(ConnectorError::new)?;
        }
        Ok(self.client_config())
    }

    // OAuth sign-in flows

    /// Step 1 of Microsoft device-code sign-in: returns the user code and verification URL.
    pub async fn start_microsoft_sign_in(&self) -> CResult<auth::DeviceCode> {
        let client = auth::microsoft_client(&self.env).ok_or_else(|| {
            ConnectorError::kind(
                tr(
                    "Geen Microsoft app-id ingesteld. Vul eerst je eigen client-id in bij Instellingen.",
                    "No Microsoft client ID is configured. Enter your own client ID in Settings first.",
                ),
                ErrorKind::Config,
            )
        })?;
        auth::start_device(&self.env.http, &self.bases.microsoft_authority, &client).await
    }

    /// Step 2 of Microsoft device-code sign-in: waits for approval, fetches the profile, and stores the account.
    pub async fn finish_microsoft_sign_in(&self, code: &auth::DeviceCode, name: &str) -> CResult<MailAccount> {
        let client = auth::microsoft_client(&self.env).ok_or_else(|| ConnectorError::not_set_up("Microsoft"))?;
        let tokens = auth::finish_device(&self.env.http, &self.bases.microsoft_authority, &client, code).await?;
        let refresh = tokens.refresh.as_deref().ok_or_else(|| {
            ConnectorError::kind(
                tr(
                    "Microsoft gaf geen vernieuwingstoken terug. Probeer opnieuw in te loggen.",
                    "Microsoft returned no refresh token. Try signing in again.",
                ),
                ErrorKind::Auth,
            )
        })?;
        let (display_name, address) = graph::me(&self.env.http, &self.bases.graph, &tokens.access).await?;
        let label = if name.trim().is_empty() { display_name } else { name.trim().to_string() };
        let account = self
            .add_account(MailAccount { id: String::new(), provider: Provider::Microsoft, address, name: label, calendar: true }, refresh)?;
        self.cache_token(&account.id, &tokens.access, tokens.expires_in);
        Ok(account)
    }

    /// Google PKCE browser sign-in: opens the consent URL, receives the loopback callback, fetches the Gmail address,
    /// and stores the account.
    pub async fn sign_in_google(&self, name: &str, open: impl FnOnce(&str)) -> CResult<MailAccount> {
        let tokens = auth::google_sign_in_at(&self.env.http, &self.env, &self.bases.google_token, open).await?;
        let refresh = tokens.refresh.as_deref().ok_or_else(|| {
            ConnectorError::kind(
                tr(
                    "Google gaf geen vernieuwingstoken terug. Probeer opnieuw in te loggen.",
                    "Google returned no refresh token. Try signing in again.",
                ),
                ErrorKind::Auth,
            )
        })?;
        let address = gmail::me(&self.env.http, &self.bases.gmail, &tokens.access).await?;
        let account = self.add_account(
            MailAccount { id: String::new(), provider: Provider::Google, address, name: name.trim().to_string(), calendar: true },
            refresh,
        )?;
        self.cache_token(&account.id, &tokens.access, tokens.expires_in);
        Ok(account)
    }

    // Access tokens

    fn cache_token(&self, account_id: &str, access: &str, expires_in: i64) {
        let ttl = expires_in.max(60) as u64;
        self.tokens.lock().unwrap_or_else(|e| e.into_inner()).insert(
            account_id.to_string(),
            CachedToken { access: access.to_string(), expires_at: Instant::now() + Duration::from_secs(ttl) },
        );
    }

    pub fn invalidate_token(&self, account_id: &str) {
        self.tokens.lock().unwrap_or_else(|e| e.into_inner()).remove(account_id);
    }

    /// Returns a valid bearer access token for `account`, refreshing through the stored refresh token when needed.
    pub async fn access_token(&self, account: &MailAccount) -> CResult<String> {
        {
            let guard = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = guard.get(&account.id) {
                if cached.expires_at > Instant::now() + Duration::from_secs(60) {
                    return Ok(cached.access.clone());
                }
            }
        }
        let refresh_token = self.env.secret(&account.token_key()).ok_or_else(|| {
            ConnectorError::kind(
                trf(
                    "Geen toegangstoken voor {account}. Log opnieuw in bij Instellingen › Accounts & koppelingen.",
                    "No token found for {account}. Sign in again in Settings › Accounts & connections.",
                    &[("account", &account.label())],
                ),
                ErrorKind::Auth,
            )
        })?;
        let refreshed = auth::refresh_at(
            &self.env.http,
            account.provider,
            &self.env,
            &refresh_token,
            &self.bases.microsoft_authority,
            &self.bases.google_token,
        )
        .await?;
        if let Some(new_refresh) = refreshed.refresh.as_deref().filter(|r| !r.is_empty() && *r != refresh_token) {
            let _ = self.env.secrets.write(&account.token_key(), new_refresh);
        }
        self.cache_token(&account.id, &refreshed.access, refreshed.expires_in);
        Ok(refreshed.access)
    }

    // Mail operations

    fn require_accounts(&self) -> CResult<Vec<MailAccount>> {
        let list = self.accounts();
        if list.is_empty() {
            return Err(ConnectorError::not_set_up("Mail"));
        }
        Ok(list)
    }

    /// `mail_unread`: total unread count, per account, per day over the last 14 days, and top senders.
    pub async fn unread(&self) -> CResult<String> {
        let accounts = self.require_accounts()?;
        let now = Utc::now();
        let since = now - chrono::Duration::days(14);
        let mut per_account = Vec::new();
        let mut recent = Vec::new();
        let mut errors = Vec::new();

        for account in &accounts {
            let token = match self.access_token(account).await {
                Ok(t) => t,
                Err(e) => {
                    errors.push(format!("{}: {}", account.label(), e.message));
                    continue;
                }
            };
            let count_res = match account.provider {
                Provider::Microsoft => graph::unread_count(&self.env.http, &self.bases.graph, &token).await,
                Provider::Google => gmail::unread_count(&self.env.http, &self.bases.gmail, &token).await,
            };
            match count_res {
                Ok(n) => per_account.push((account.label(), n)),
                Err(e) => {
                    if e.kind == ErrorKind::Auth {
                        self.invalidate_token(&account.id);
                    }
                    errors.push(format!("{}: {}", account.label(), e.message));
                    continue;
                }
            }
            let mails_res = match account.provider {
                Provider::Microsoft => graph::inbox(&self.env.http, &self.bases.graph, &token, &account.id, since, true, 50).await,
                Provider::Google => {
                    gmail::query(&self.env.http, &self.bases.gmail, &token, &account.id, &gmail::inbox_query(14, true), 50).await
                }
            };
            if let Ok(mails) = mails_res {
                recent.extend(mails);
            }
        }

        if per_account.is_empty() && !errors.is_empty() {
            return Err(ConnectorError::new(errors.join("; ")));
        }
        let mut out = super::unread_summary(&per_account, &recent, now);
        if !errors.is_empty() {
            out.push_str(&format!("\nCould not read: {}.", errors.join("; ")));
        }
        Ok(out)
    }

    /// `inbox_mail`: recent inbox messages across all linked accounts, newest first.
    pub async fn inbox(&self, days: i64, unanswered_only: bool, unread_only: bool, limit: usize) -> CResult<Vec<Mail>> {
        let accounts = self.require_accounts()?;
        let days = days.clamp(1, 30);
        let limit = limit.clamp(1, 40);
        let since = Utc::now() - chrono::Duration::days(days);
        let mut all = Vec::new();
        let mut errors = Vec::new();

        for account in &accounts {
            let token = match self.access_token(account).await {
                Ok(t) => t,
                Err(e) => {
                    errors.push(format!("{}: {}", account.label(), e.message));
                    continue;
                }
            };
            let res = match account.provider {
                Provider::Microsoft => {
                    graph::inbox(&self.env.http, &self.bases.graph, &token, &account.id, since, unread_only, limit).await
                }
                Provider::Google => {
                    gmail::query(&self.env.http, &self.bases.gmail, &token, &account.id, &gmail::inbox_query(days, unread_only), limit)
                        .await
                }
            };
            match res {
                Ok(mails) => all.extend(mails),
                Err(e) => {
                    if e.kind == ErrorKind::Auth {
                        self.invalidate_token(&account.id);
                    }
                    errors.push(format!("{}: {}", account.label(), e.message));
                }
            }
        }

        if all.is_empty() && !errors.is_empty() && errors.len() == accounts.len() {
            return Err(ConnectorError::new(errors.join("; ")));
        }
        if unanswered_only {
            all.retain(|m| m.replied != Some(true));
        }
        all.sort_by_key(|b| std::cmp::Reverse(b.date));
        all.truncate(limit);
        Ok(all)
    }

    /// `search_mail`: keyword search in inbox or sent across all linked accounts, newest first.
    pub async fn search(&self, query: &str, sent: bool, limit: usize) -> CResult<Vec<Mail>> {
        let query = query.trim();
        if query.is_empty() {
            return Err(ConnectorError::new("Search query is missing."));
        }
        let accounts = self.require_accounts()?;
        let limit = limit.clamp(1, 40);
        let mut all = Vec::new();
        let mut errors = Vec::new();

        for account in &accounts {
            let token = match self.access_token(account).await {
                Ok(t) => t,
                Err(e) => {
                    errors.push(format!("{}: {}", account.label(), e.message));
                    continue;
                }
            };
            let res = match account.provider {
                Provider::Microsoft => graph::search(&self.env.http, &self.bases.graph, &token, &account.id, query, sent, limit).await,
                Provider::Google => {
                    gmail::query(&self.env.http, &self.bases.gmail, &token, &account.id, &gmail::search_query(query, sent), limit).await
                }
            };
            match res {
                Ok(mails) => all.extend(mails),
                Err(e) => {
                    if e.kind == ErrorKind::Auth {
                        self.invalidate_token(&account.id);
                    }
                    errors.push(format!("{}: {}", account.label(), e.message));
                }
            }
        }

        if all.is_empty() && !errors.is_empty() && errors.len() == accounts.len() {
            return Err(ConnectorError::new(errors.join("; ")));
        }
        all.sort_by_key(|b| std::cmp::Reverse(b.date));
        all.truncate(limit);
        Ok(all)
    }

    /// `read_mail`: fetches one full message by tool id (`"<account>:<provider_id>"`).
    pub async fn read(&self, id: &str) -> CResult<Mail> {
        let (acct_id, msg_id) =
            split_id(id).ok_or_else(|| ConnectorError::new("Invalid message id; use the id from inbox_mail or search_mail."))?;
        let account = self.account(acct_id).ok_or_else(|| ConnectorError::new(format!("Unknown mail account \"{acct_id}\".")))?;
        let token = self.access_token(&account).await?;
        let res = match account.provider {
            Provider::Microsoft => graph::read(&self.env.http, &self.bases.graph, &token, &account.id, msg_id).await,
            Provider::Google => gmail::read(&self.env.http, &self.bases.gmail, &token, &account.id, msg_id).await,
        };
        if let Err(ref e) = res {
            if e.kind == ErrorKind::Auth {
                self.invalidate_token(&account.id);
            }
        }
        res
    }

    /// `trash_mail` and `mark_mail`: applies `change` to the messages selected by `ids` or filter.
    pub async fn apply_change(&self, selection: &Selection, change: Change) -> CResult<String> {
        let problems = selection.problems();
        if !problems.is_empty() {
            return Err(ConnectorError::new(problems.join(" ")));
        }
        let accounts = self.require_accounts()?;
        let by_id: HashMap<String, MailAccount> = accounts.iter().cloned().map(|a| (a.id.clone(), a)).collect();

        let targets: Vec<(String, String)> = if !selection.ids.is_empty() {
            let mut out = Vec::new();
            for raw in selection.ids.iter().take(MAX_CHANGE) {
                let Some((acct, msg)) = split_id(raw) else {
                    return Err(ConnectorError::new(format!("Invalid message id \"{raw}\".")));
                };
                out.push((acct.to_string(), msg.to_string()));
            }
            out
        } else {
            let days = selection.days.unwrap_or(30).clamp(1, 365);
            let now = Utc::now();
            let since = now - chrono::Duration::days(days);
            let mut matched = Vec::new();
            for account in &accounts {
                let token = match self.access_token(account).await {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                let candidates = match account.provider {
                    Provider::Microsoft => {
                        graph::inbox(&self.env.http, &self.bases.graph, &token, &account.id, since, selection.unread_only, MAX_CHANGE)
                            .await
                            .unwrap_or_default()
                    }
                    Provider::Google => gmail::query(
                        &self.env.http,
                        &self.bases.gmail,
                        &token,
                        &account.id,
                        &gmail::inbox_query(days, selection.unread_only),
                        MAX_CHANGE,
                    )
                    .await
                    .unwrap_or_default(),
                };
                for mail in candidates {
                    if selection.matches(&mail, now) {
                        if let Some((a, m)) = split_id(&mail.id) {
                            matched.push((a.to_string(), m.to_string()));
                            if matched.len() >= MAX_CHANGE {
                                break;
                            }
                        }
                    }
                }
                if matched.len() >= MAX_CHANGE {
                    break;
                }
            }
            matched
        };

        if targets.is_empty() {
            return Ok("No matching messages found.".into());
        }

        let mut changed = 0usize;
        let mut errors = Vec::new();
        for (acct_id, msg_id) in targets {
            let Some(account) = by_id.get(&acct_id) else {
                errors.push(format!("Unknown account {acct_id}"));
                continue;
            };
            let token = match self.access_token(account).await {
                Ok(t) => t,
                Err(e) => {
                    errors.push(e.message);
                    continue;
                }
            };
            let res = match account.provider {
                Provider::Microsoft => graph::change(&self.env.http, &self.bases.graph, &token, &msg_id, change).await,
                Provider::Google => gmail::change(&self.env.http, &self.bases.gmail, &token, &msg_id, change).await,
            };
            match res {
                Ok(()) => changed += 1,
                Err(e) => {
                    if e.kind == ErrorKind::Auth {
                        self.invalidate_token(&account.id);
                    }
                    errors.push(e.message);
                }
            }
        }

        if changed == 0 && !errors.is_empty() {
            return Err(ConnectorError::new(errors.join("; ")));
        }
        let noun = if changed == 1 { "message" } else { "messages" };
        let summary = match change {
            Change::Trash => format!("Moved {changed} {noun} to Trash."),
            Change::Read => format!("Marked {changed} {noun} as read."),
            Change::Unread => format!("Marked {changed} {noun} as unread."),
            Change::Flagged => format!("Flagged {changed} {noun}."),
            Change::Unflagged => format!("Unflagged {changed} {noun}."),
        };
        if errors.is_empty() {
            Ok(summary)
        } else {
            Ok(format!("{summary} ({} failed: {})", errors.len(), errors.join("; ")))
        }
    }

    /// Sends a mail through a linked account. Picks the account from `outgoing.reply_to` (so replies stay on the same
    /// account), else matches `from_account` (id, email, name, or provider), else uses the first linked account.
    /// Returns the label of the account that sent the mail.
    pub async fn send_mail(&self, outgoing: &Outgoing, from_account: Option<&str>) -> CResult<String> {
        let accounts = self.require_accounts()?;
        let reply_parts = outgoing.reply_to.as_deref().and_then(split_id);
        let account = if let Some((acct_id, _)) = reply_parts {
            accounts.iter().find(|a| a.id == acct_id).ok_or_else(|| ConnectorError::new(format!("Unknown mail account \"{acct_id}\".")))?
        } else if let Some(hint) = from_account.map(str::trim).filter(|s| !s.is_empty()) {
            match_account(&accounts, hint).ok_or_else(|| {
                ConnectorError::new(trf(
                    "Geen gekoppeld mailaccount gevonden voor \"{hint}\".",
                    "No linked mail account matches \"{hint}\".",
                    &[("hint", &hint)],
                ))
            })?
        } else {
            &accounts[0]
        };

        let token = self.access_token(account).await?;
        let reply_msg_id = reply_parts.filter(|(a, _)| *a == account.id).map(|(_, m)| m);

        let res = match account.provider {
            Provider::Microsoft => graph::send(&self.env.http, &self.bases.graph, &token, outgoing, reply_msg_id).await,
            Provider::Google => {
                let original = match reply_msg_id {
                    Some(msg_id) => gmail::read(&self.env.http, &self.bases.gmail, &token, &account.id, msg_id).await.ok(),
                    None => None,
                };
                let from_header =
                    if account.name.is_empty() { account.address.clone() } else { format!("{} <{}>", account.name, account.address) };
                gmail::send(&self.env.http, &self.bases.gmail, &token, &from_header, outgoing, original.as_ref()).await
            }
        };
        if let Err(ref e) = res {
            if e.kind == ErrorKind::Auth {
                self.invalidate_token(&account.id);
            }
        }
        res?;
        Ok(account.label())
    }

    // Calendar operations

    /// Lists events across all linked accounts that have calendar sync enabled.
    pub async fn list_events(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> CResult<AgendaResult> {
        let accounts: Vec<MailAccount> = self.accounts().into_iter().filter(|a| a.calendar).collect();
        let mut entries = Vec::new();
        let mut problems = Vec::new();

        for account in &accounts {
            let token = match self.access_token(account).await {
                Ok(t) => t,
                Err(e) => {
                    problems.push(format!("{}: {}", account.label(), e.message));
                    continue;
                }
            };
            let res = match account.provider {
                Provider::Microsoft => graph::events(&self.env.http, &self.bases.graph, &token, from, to).await,
                Provider::Google => gmail::events(&self.env.http, &self.bases.calendar, &token, from, to).await,
            };
            match res {
                Ok(list) => {
                    let cal = account.label();
                    entries.extend(list.into_iter().map(|e| to_agenda_entry(e, &cal)));
                }
                Err(e) => {
                    if e.kind == ErrorKind::Auth {
                        self.invalidate_token(&account.id);
                    }
                    problems.push(format!("{}: {}", account.label(), e.message));
                }
            }
        }
        entries.sort_by_key(|e| e.start);
        Ok(AgendaResult { entries, problems })
    }

    /// Creates a new event in a calendar-enabled account (matching `calendar` hint when supplied, else the first).
    /// Returns `(account_label, event_id)`.
    pub async fn create_event(&self, event: &NewEvent, calendar: Option<&str>) -> CResult<(String, String)> {
        let accounts: Vec<MailAccount> = self.accounts().into_iter().filter(|a| a.calendar).collect();
        if accounts.is_empty() {
            return Err(ConnectorError::kind(
                tr("Geen gekoppeld mailaccount met agenda-synchronisatie gevonden.", "No linked mail account with calendar sync enabled."),
                ErrorKind::Config,
            ));
        }
        let account = match calendar.map(str::trim).filter(|s| !s.is_empty()) {
            Some(hint) => match_account(&accounts, hint).unwrap_or(&accounts[0]),
            None => &accounts[0],
        };
        let token = self.access_token(account).await?;
        let res = match account.provider {
            Provider::Microsoft => graph::create_event(&self.env.http, &self.bases.graph, &token, event).await,
            Provider::Google => gmail::create_event(&self.env.http, &self.bases.calendar, &token, event).await,
        };
        if let Err(ref e) = res {
            if e.kind == ErrorKind::Auth {
                self.invalidate_token(&account.id);
            }
        }
        let id = res?;
        Ok((account.label(), id))
    }

    /// Formats a label for an account id (for [`super::lines`]).
    pub fn label_for(&self, account_id: &str) -> String {
        self.account(account_id).map(|a| a.label()).unwrap_or_else(|| account_id.to_string())
    }
}

fn to_agenda_entry(event: Event, calendar: &str) -> AgendaEntry {
    AgendaEntry {
        title: event.title,
        start: event.start,
        end: event.end,
        all_day: event.all_day,
        busy: event.busy,
        location: event.location,
        calendar: calendar.to_string(),
    }
}

fn match_account<'a>(accounts: &'a [MailAccount], hint: &str) -> Option<&'a MailAccount> {
    let needle = hint.trim().to_lowercase();
    if needle.is_empty() {
        return None;
    }
    accounts
        .iter()
        .find(|a| a.id.eq_ignore_ascii_case(&needle) || a.address.eq_ignore_ascii_case(&needle))
        .or_else(|| {
            accounts.iter().find(|a| {
                (!a.name.is_empty() && a.name.to_lowercase().contains(&needle))
                    || a.label().to_lowercase().contains(&needle)
                    || a.address.to_lowercase().contains(&needle)
            })
        })
        .or_else(|| {
            let provider = match needle.as_str() {
                s if s.contains("gmail") || s.contains("google") => Some(Provider::Google),
                s if s.contains("outlook") || s.contains("microsoft") || s.contains("hotmail") || s.contains("365") => {
                    Some(Provider::Microsoft)
                }
                _ => None,
            }?;
            accounts.iter().find(|a| a.provider == provider)
        })
}

fn make_account_id(provider: Provider, address: &str, existing: &[MailAccount]) -> String {
    let prefix = match provider {
        Provider::Microsoft => "ms",
        Provider::Google => "google",
    };
    let local: String = address
        .split('@')
        .next()
        .unwrap_or("acct")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(20)
        .collect();
    let base = if local.is_empty() { prefix.to_string() } else { format!("{prefix}-{local}") };
    if !existing.iter().any(|a| a.id == base) {
        return base;
    }
    for n in 2..1000 {
        let candidate = format!("{base}-{n}");
        if !existing.iter().any(|a| a.id == candidate) {
            return candidate;
        }
    }
    format!("{prefix}-{}", uuid::Uuid::new_v4().simple())
}

#[async_trait]
impl Connector for MailService {
    fn id(&self) -> String {
        ID.into()
    }

    fn title(&self) -> String {
        tr("Mail en agenda", "Mail & calendar").into()
    }

    fn configured(&self) -> bool {
        self.has_accounts()
    }

    fn active(&self) -> bool {
        self.configured() && self.env.store.is_on(ID)
    }

    fn status(&self) -> ConnectorStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    async fn refresh(&self) {
        if !self.active() {
            *self.status.lock().unwrap_or_else(|e| e.into_inner()) = ConnectorStatus::default();
            return;
        }
        let now = Utc::now();
        let to = now + chrono::Duration::days(7);
        let accounts = self.accounts();
        match self.list_events(now, to).await {
            Ok(result) => {
                *self.cached_events.lock().unwrap_or_else(|e| e.into_inner()) = result.entries;
                let headline = format!("{} linked", crate::connectors::plural(accounts.len(), "account", "accounts"));
                let detail = if result.problems.is_empty() {
                    accounts.iter().map(MailAccount::label).collect::<Vec<_>>().join(", ")
                } else {
                    result.problems.join("; ")
                };
                *self.status.lock().unwrap_or_else(|e| e.into_inner()) =
                    ConnectorStatus::ok(headline, detail, vec![], !result.problems.is_empty());
            }
            Err(e) => {
                self.status.lock().unwrap_or_else(|e| e.into_inner()).fail(&e);
            }
        }
    }

    fn agenda_names(&self) -> Vec<String> {
        self.accounts().into_iter().filter(|a| a.calendar).map(|a| a.label()).collect()
    }

    async fn agenda(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> Option<CResult<AgendaResult>> {
        if !self.has_calendar_accounts() {
            return None;
        }
        Some(self.list_events(from, to).await)
    }

    fn cached_agenda(&self) -> Vec<AgendaEntry> {
        self.cached_events.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;
    use crate::connectors::ConnectorStore;
    use crate::secrets::{MemorySecrets, SecretStore};
    use base64::Engine;
    use serde_json::{json, Value};

    fn test_env() -> Arc<Env> {
        let secrets = Arc::new(MemorySecrets::default());
        secrets.write(auth::MICROSOFT_CLIENT_KEY, "ms-cid").unwrap();
        secrets.write(auth::GOOGLE_CLIENT_KEY, "g-cid").unwrap();
        secrets.write(auth::GOOGLE_SECRET_KEY, "g-sec").unwrap();
        Env::new(secrets, Arc::new(ConnectorStore::in_memory()))
    }

    fn b64(text: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(text)
    }

    #[test]
    fn account_lifecycle_persists_and_cleans_keychain() {
        let env = test_env();
        let svc = MailService::new(env.clone());
        assert!(!svc.has_accounts());

        let work = svc
            .add_account(
                MailAccount {
                    id: String::new(),
                    provider: Provider::Microsoft,
                    address: "work@acme.nl".into(),
                    name: "Work".into(),
                    calendar: true,
                },
                "rt-ms-1",
            )
            .unwrap();
        assert_eq!(work.id, "ms-work");
        assert_eq!(env.secret(&work.token_key()).as_deref(), Some("rt-ms-1"));
        assert!(svc.has_accounts());
        assert!(svc.has_calendar_accounts());

        // Re-linking same provider + address deduplicates and updates token.
        let relinked = svc
            .add_account(
                MailAccount {
                    id: String::new(),
                    provider: Provider::Microsoft,
                    address: "WORK@ACME.NL".into(),
                    name: String::new(),
                    calendar: true,
                },
                "rt-ms-2",
            )
            .unwrap();
        assert_eq!(relinked.id, "ms-work");
        assert_eq!(svc.accounts().len(), 1);
        assert_eq!(env.secret(&work.token_key()).as_deref(), Some("rt-ms-2"));

        // Toggle calendar & rename.
        let toggled = svc.set_calendar(&work.id, false).unwrap();
        assert!(!toggled.calendar);
        assert!(!svc.has_calendar_accounts());
        let renamed = svc.rename_account(&work.id, "Office").unwrap();
        assert_eq!(renamed.name, "Office");

        // Remove cleans up both store and keychain.
        svc.remove_account(&work.id).unwrap();
        assert!(!svc.has_accounts());
        assert_eq!(env.secret(&work.token_key()), None);
    }

    #[tokio::test]
    async fn token_refresh_caches_and_rotates_refresh_token() {
        let server = TestServer::start(vec![(
            "POST /token",
            200,
            r#"{"access_token":"access-1","refresh_token":"rt-rotated","expires_in":3600}"#.into(),
        )])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(
            env.clone(),
            Bases { microsoft_authority: base.clone(), google_token: format!("{base}/token"), ..Default::default() },
        );
        let acct = svc
            .add_account(
                MailAccount {
                    id: "work".into(),
                    provider: Provider::Microsoft,
                    address: "me@work.nl".into(),
                    name: "Work".into(),
                    calendar: true,
                },
                "rt-initial",
            )
            .unwrap();

        let tok1 = svc.access_token(&acct).await.unwrap();
        let tok2 = svc.access_token(&acct).await.unwrap();
        assert_eq!(tok1, "access-1");
        assert_eq!(tok2, "access-1");
        // Second call hit the in-memory cache; only one token request was made.
        assert_eq!(server.requests().len(), 1);
        // Rotated refresh token was written back to SecretStore.
        assert_eq!(env.secret(&acct.token_key()).as_deref(), Some("rt-rotated"));
    }

    #[tokio::test]
    async fn multi_account_unread_inbox_search_read_and_changes() {
        let now = Utc::now();
        let newer = (now - chrono::Duration::hours(1)).to_rfc3339();
        let older_ms = (now - chrono::Duration::hours(3)).timestamp_millis().to_string();

        let graph_inbox = json!({
            "value": [{
                "id": "G1",
                "subject": "Quarterly review",
                "from": {"emailAddress": {"name": "Anna", "address": "anna@acme.nl"}},
                "toRecipients": [{"emailAddress": {"name": "Me", "address": "me@acme.nl"}}],
                "receivedDateTime": newer,
                "isRead": false,
                "flag": {"flagStatus": "notFlagged"},
                "bodyPreview": "Can we review the numbers?",
                "conversationId": "conv1",
                "internetMessageId": "<g1@acme.nl>"
            }]
        });
        let graph_full = json!({
            "id": "G1",
            "subject": "Quarterly review",
            "from": {"emailAddress": {"name": "Anna", "address": "anna@acme.nl"}},
            "toRecipients": [{"emailAddress": {"name": "Me", "address": "me@acme.nl"}}],
            "receivedDateTime": newer,
            "isRead": false,
            "flag": {"flagStatus": "notFlagged"},
            "bodyPreview": "Can we review the numbers?",
            "body": {"contentType": "text", "content": "Full body from Anna."}
        });
        let gmail_msg = json!({
            "id": "M1",
            "threadId": "t-1",
            "labelIds": ["INBOX", "UNREAD"],
            "snippet": "Dinner tonight?",
            "internalDate": older_ms,
            "payload": {
                "mimeType": "text/plain",
                "headers": [
                    {"name": "From", "value": "Ben <ben@gmail.com>"},
                    {"name": "To", "value": "me@gmail.com"},
                    {"name": "Subject", "value": "Dinner"},
                    {"name": "Message-ID", "value": "<m1@gmail.com>"}
                ],
                "body": {"data": b64("Let's grab pizza at 7.")}
            }
        });

        let server = TestServer::start(vec![
            ("POST /ms/token", 200, r#"{"access_token":"ms-tok","expires_in":3600}"#.into()),
            ("POST /google/token", 200, r#"{"access_token":"g-tok","expires_in":3600}"#.into()),
            ("GET /graph/me/mailFolders/inbox", 200, r#"{"unreadItemCount":4}"#.into()),
            ("GET /graph/me/mailFolders/inbox/messages", 200, graph_inbox.to_string()),
            ("GET /graph/me/mailFolders/sentitems/messages", 200, r#"{"value":[]}"#.into()),
            ("GET /graph/me/messages/G1", 200, graph_full.to_string()),
            ("POST /graph/me/messages/G1/move", 201, "{}".into()),
            ("GET /gmail/labels/INBOX", 200, r#"{"messagesUnread":2}"#.into()),
            ("GET /gmail/messages", 200, r#"{"messages":[{"id":"M1"}]}"#.into()),
            ("GET /gmail/messages/M1", 200, gmail_msg.to_string()),
            ("POST /gmail/messages/M1/modify", 200, "{}".into()),
        ])
        .await;

        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(
            env,
            Bases {
                graph: format!("{base}/graph"),
                gmail: format!("{base}/gmail"),
                calendar: format!("{base}/gcal"),
                microsoft_authority: format!("{base}/ms"),
                google_token: format!("{base}/google/token"),
            },
        );
        svc.add_account(
            MailAccount {
                id: "work".into(),
                provider: Provider::Microsoft,
                address: "me@acme.nl".into(),
                name: "Work".into(),
                calendar: true,
            },
            "rt-ms",
        )
        .unwrap();
        svc.add_account(
            MailAccount {
                id: "home".into(),
                provider: Provider::Google,
                address: "me@gmail.com".into(),
                name: "Home".into(),
                calendar: true,
            },
            "rt-g",
        )
        .unwrap();

        // unread aggregates across both providers.
        let summary = svc.unread().await.unwrap();
        assert!(summary.contains("Unread mail in the inbox: 6."), "{summary}");
        assert!(summary.contains("Work (Microsoft): 4, Home (Google): 2"), "{summary}");

        // inbox merges and sorts newest first (Graph message is 1h ago, Gmail is 3h ago).
        let mails = svc.inbox(7, false, false, 10).await.unwrap();
        assert_eq!(mails.len(), 2);
        assert_eq!(mails[0].id, "work:G1");
        assert_eq!(mails[1].id, "home:M1");

        // search works across both accounts.
        let found = svc.search("review", false, 10).await.unwrap();
        assert_eq!(found.len(), 2);

        // read fetches full body from either account.
        let full_ms = svc.read("work:G1").await.unwrap();
        assert_eq!(full_ms.body.as_deref(), Some("Full body from Anna."));
        let full_g = svc.read("home:M1").await.unwrap();
        assert_eq!(full_g.body.as_deref(), Some("Let's grab pizza at 7."));

        // trash by id on Graph.
        let trashed = svc.apply_change(&Selection { ids: vec!["work:G1".into()], ..Default::default() }, Change::Trash).await.unwrap();
        assert_eq!(trashed, "Moved 1 message to Trash.");

        // mark read by filter (from "ben") hits Gmail.
        let marked = svc.apply_change(&Selection { from: "ben".into(), ..Default::default() }, Change::Read).await.unwrap();
        assert_eq!(marked, "Marked 1 message as read.");

        // Empty selection is refused.
        assert!(svc.apply_change(&Selection::default(), Change::Trash).await.is_err());
    }

    #[tokio::test]
    async fn send_mail_routes_replies_attachments_and_from_hints() {
        let gmail_orig = json!({
            "id": "M9",
            "threadId": "thr-9",
            "labelIds": ["INBOX"],
            "payload": {
                "headers": [
                    {"name": "From", "value": "Ben <ben@example.com>"},
                    {"name": "Subject", "value": "Plans"},
                    {"name": "Message-ID", "value": "<orig-9@mail.gmail.com>"}
                ]
            }
        });
        let server = TestServer::start(vec![
            ("POST /ms/token", 200, r#"{"access_token":"ms-tok","expires_in":3600}"#.into()),
            ("POST /google/token", 200, r#"{"access_token":"g-tok","expires_in":3600}"#.into()),
            ("POST /graph/me/sendMail", 202, String::new()),
            ("POST /graph/me/messages/G5/reply", 202, String::new()),
            ("GET /gmail/messages/M9", 200, gmail_orig.to_string()),
            ("POST /gmail/messages/send", 200, r#"{"id":"sent-1"}"#.into()),
        ])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(
            env,
            Bases {
                graph: format!("{base}/graph"),
                gmail: format!("{base}/gmail"),
                calendar: format!("{base}/gcal"),
                microsoft_authority: format!("{base}/ms"),
                google_token: format!("{base}/google/token"),
            },
        );
        svc.add_account(
            MailAccount {
                id: "work".into(),
                provider: Provider::Microsoft,
                address: "me@work.nl".into(),
                name: "Work".into(),
                calendar: true,
            },
            "rt-ms",
        )
        .unwrap();
        svc.add_account(
            MailAccount {
                id: "home".into(),
                provider: Provider::Google,
                address: "me@gmail.com".into(),
                name: "Home".into(),
                calendar: true,
            },
            "rt-g",
        )
        .unwrap();

        // Default account sends through Graph with attachment.
        let out = Outgoing {
            to: vec!["anna@example.com".into()],
            subject: "Invite".into(),
            body: "See attached.".into(),
            attachments: vec![super::super::Attachment {
                name: "invite.ics".into(),
                mime: "text/calendar".into(),
                bytes: b"BEGIN:VCALENDAR".to_vec(),
            }],
            ..Default::default()
        };
        let used = svc.send_mail(&out, None).await.unwrap();
        assert_eq!(used, "Work (Microsoft)");

        // Reply to Graph message uses /reply.
        let ms_reply = Outgoing {
            to: vec!["anna@example.com".into()],
            subject: "Re: Hi".into(),
            body: "Sounds good".into(),
            reply_to: Some("work:G5".into()),
            ..Default::default()
        };
        svc.send_mail(&ms_reply, None).await.unwrap();

        // Reply to Gmail message routes automatically to "home" and threads with threadId + In-Reply-To.
        let g_reply = Outgoing {
            to: vec!["ben@example.com".into()],
            subject: "Re: Plans".into(),
            body: "Count me in!".into(),
            reply_to: Some("home:M9".into()),
            ..Default::default()
        };
        let used_g = svc.send_mail(&g_reply, None).await.unwrap();
        assert_eq!(used_g, "Home (Google)");

        let reqs = server.requests();
        assert!(reqs.iter().any(|r| r.path == "/graph/me/sendMail" && r.body.contains("invite.ics")));
        assert!(reqs.iter().any(|r| r.path == "/graph/me/messages/G5/reply" && r.body.contains("Sounds good")));
        let gmail_sent = reqs.iter().find(|r| r.path == "/gmail/messages/send").expect("gmail send request");
        let sent_json: Value = serde_json::from_str(&gmail_sent.body).unwrap();
        assert_eq!(sent_json["threadId"], "thr-9");
        let raw_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(sent_json["raw"].as_str().unwrap()).unwrap();
        let raw_text = String::from_utf8(raw_bytes).unwrap();
        assert!(raw_text.contains("In-Reply-To: <orig-9@mail.gmail.com>"));
    }

    #[tokio::test]
    async fn calendar_events_merge_across_enabled_accounts_and_create_event() {
        let graph_events = json!({
            "value": [{
                "id": "ge1",
                "subject": "Sprint planning",
                "start": {"dateTime": "2026-11-23T09:00:00.0000000", "timeZone": "UTC"},
                "end": {"dateTime": "2026-11-23T10:00:00.0000000", "timeZone": "UTC"},
                "isAllDay": false,
                "showAs": "busy",
                "location": {"displayName": "Room A"}
            }]
        });
        let google_events = json!({
            "items": [{
                "id": "ce1",
                "summary": "Dentist",
                "start": {"dateTime": "2026-11-23T14:00:00Z"},
                "end": {"dateTime": "2026-11-23T14:30:00Z"}
            }]
        });
        let server = TestServer::start(vec![
            ("POST /ms/token", 200, r#"{"access_token":"ms-tok","expires_in":3600}"#.into()),
            ("POST /google/token", 200, r#"{"access_token":"g-tok","expires_in":3600}"#.into()),
            ("GET /graph/me/calendarView", 200, graph_events.to_string()),
            ("POST /graph/me/events", 201, r#"{"id":"new-ms-ev"}"#.into()),
            ("GET /gcal/events", 200, google_events.to_string()),
            ("POST /gcal/events", 200, r#"{"id":"new-g-ev"}"#.into()),
        ])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(
            env,
            Bases {
                graph: format!("{base}/graph"),
                gmail: format!("{base}/gmail"),
                calendar: format!("{base}/gcal"),
                microsoft_authority: format!("{base}/ms"),
                google_token: format!("{base}/google/token"),
            },
        );
        svc.add_account(
            MailAccount {
                id: "work".into(),
                provider: Provider::Microsoft,
                address: "me@work.nl".into(),
                name: "Work".into(),
                calendar: true,
            },
            "rt-ms",
        )
        .unwrap();
        svc.add_account(
            MailAccount {
                id: "home".into(),
                provider: Provider::Google,
                address: "me@gmail.com".into(),
                name: "Home".into(),
                calendar: true,
            },
            "rt-g",
        )
        .unwrap();

        let from = crate::connectors::dates::parse("2026-11-23T00:00:00Z").unwrap();
        let to = crate::connectors::dates::parse("2026-11-24T00:00:00Z").unwrap();
        let res = svc.list_events(from, to).await.unwrap();
        assert!(res.problems.is_empty());
        assert_eq!(res.entries.len(), 2);
        assert_eq!(res.entries[0].title, "Sprint planning");
        assert_eq!(res.entries[0].calendar, "Work (Microsoft)");
        assert_eq!(res.entries[1].title, "Dentist");
        assert_eq!(res.entries[1].calendar, "Home (Google)");

        // Create event targeting Google calendar via hint.
        let new_ev = NewEvent::from_input(&json!({
            "title": "Coffee",
            "start": "2026-11-23T15:00:00Z",
            "location": "Cafe"
        }))
        .unwrap();
        let (cal, id) = svc.create_event(&new_ev, Some("gmail")).await.unwrap();
        assert_eq!((cal.as_str(), id.as_str()), ("Home (Google)", "new-g-ev"));

        // Disable Google calendar -> only Graph events remain, and create_event defaults to Microsoft.
        svc.set_calendar("home", false).unwrap();
        let res2 = svc.list_events(from, to).await.unwrap();
        assert_eq!(res2.entries.len(), 1);
        assert_eq!(res2.entries[0].title, "Sprint planning");
        let (cal2, id2) = svc.create_event(&new_ev, None).await.unwrap();
        assert_eq!((cal2.as_str(), id2.as_str()), ("Work (Microsoft)", "new-ms-ev"));
    }

    #[tokio::test]
    async fn microsoft_device_sign_in_adds_account_and_caches_token() {
        let server = TestServer::start(vec![
            (
                "POST /ms/devicecode",
                200,
                r#"{"user_code":"WXYZ-1234","device_code":"dev-1","verification_uri":"https://microsoft.com/devicelogin","interval":1,"expires_in":30}"#
                    .into(),
            ),
            ("POST /ms/token", 200, r#"{"access_token":"ms-at","refresh_token":"ms-rt","expires_in":3600}"#.into()),
            ("GET /graph/me", 200, r#"{"displayName":"Lisa Dev","mail":"lisa@contoso.com"}"#.into()),
        ])
        .await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(
            env.clone(),
            Bases { graph: format!("{base}/graph"), microsoft_authority: format!("{base}/ms"), ..Default::default() },
        );

        let code = svc.start_microsoft_sign_in().await.unwrap();
        assert_eq!(code.user_code, "WXYZ-1234");
        let acct = svc.finish_microsoft_sign_in(&code, "").await.unwrap();
        assert_eq!(acct.address, "lisa@contoso.com");
        assert_eq!(acct.name, "Lisa Dev");
        assert_eq!(env.secret(&acct.token_key()).as_deref(), Some("ms-rt"));
        // Access token is already cached from sign-in.
        assert_eq!(svc.access_token(&acct).await.unwrap(), "ms-at");
    }

    #[tokio::test]
    async fn error_handling_for_unlinked_invalid_id_and_auth_failure() {
        let server = TestServer::start(vec![("POST /ms/token", 400, r#"{"error":"invalid_grant"}"#.into())]).await;
        let base = format!("http://127.0.0.1:{}", server.port);
        let env = test_env();
        let svc = MailService::with_bases(env, Bases { microsoft_authority: format!("{base}/ms"), ..Default::default() });

        // Unlinked errors.
        assert!(svc.unread().await.is_err());
        assert!(svc.read("bad-id").await.is_err());
        assert!(svc.search("  ", false, 5).await.is_err());

        // Auth failure propagates Auth ErrorKind.
        let acct = svc
            .add_account(
                MailAccount {
                    id: "work".into(),
                    provider: Provider::Microsoft,
                    address: "a@b.nl".into(),
                    name: "Work".into(),
                    calendar: true,
                },
                "expired-rt",
            )
            .unwrap();
        let err = svc.access_token(&acct).await.unwrap_err();
        assert_eq!(err.kind, ErrorKind::Auth);
    }
}
