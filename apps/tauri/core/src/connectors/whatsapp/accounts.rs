//! Every WhatsApp account Nook links through the gateway (`WhatsAppAccounts` on the Mac): the first one and the ones
//! added after it in Settings (a business number, a second phone), each a [`WhatsAppLink`] of its own on a device (GOWA)
//! or session (OpenWA) of its own, with its own QR and webhook port. The rest of Nook knows a chat by its key across
//! accounts ([`chat_key`]): [`WhatsAppAccounts::route`] finds the account it is in.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use super::link::{Link, WhatsAppLink};
use crate::connectors::hub::Env;

/// What separates an added account's id from a JID in a chat's key. No JID holds one.
pub const SEPARATOR: char = '~';

/// An account added after the first (`WAAccount`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaAccount {
    /// The gateway's device id (GOWA) or session name (OpenWA), and what the keys of its chats start with.
    pub id: String,
    /// What you call it ("Business"); empty, it goes by its number.
    #[serde(default)]
    pub name: String,
}

impl WaAccount {
    /// The id of a new account: "nook-" and six random letters and digits, never one already taken.
    pub fn new_id(taken: &[String]) -> String {
        const CHARACTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
        loop {
            let mut bytes = [0u8; 6];
            rand::TryRng::try_fill_bytes(&mut rand::rngs::SysRng, &mut bytes).expect("the system generator gives random bytes");
            let tail: String = bytes.iter().map(|b| CHARACTERS[usize::from(*b) % CHARACTERS.len()] as char).collect();
            let id = format!("nook-{tail}");
            if id != "nook" && !taken.contains(&id) {
                return id;
            }
        }
    }

    /// A name as Settings takes it: trimmed, at most 40 characters; empty stays empty.
    pub fn clean_name(name: &str) -> String {
        name.trim().chars().take(40).collect()
    }
}

/// A WhatsApp chat as the rest of Nook knows it, whichever account it is in: a chat of the first account by its JID alone
/// (so what Nook kept of it from before there were more accounts still holds), one of another account as
/// "<account id>~<JID>".
pub fn chat_key(jid: &str, account: &str) -> String {
    if account.is_empty() {
        jid.to_string()
    } else {
        format!("{account}{SEPARATOR}{jid}")
    }
}

/// The account (empty: the first) and the chat's JID at its gateway.
pub fn split(key: &str) -> (&str, &str) {
    key.split_once(SEPARATOR).unwrap_or(("", key))
}

/// One account as Settings lists it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountView {
    /// Empty for the first account.
    pub id: String,
    /// What it is called in the Chats tab and Settings: what you called it, else its number, else "WhatsApp".
    pub title: String,
    /// What you called it (empty: by its number).
    pub given: String,
    pub link: Link,
    pub status_line: String,
    pub me: Option<String>,
    /// The QR as a data URL while there is one to scan.
    pub qr: Option<String>,
    /// The webhook's port could not be opened.
    pub port_busy: bool,
    pub port: Option<u16>,
}

type Wire = Arc<dyn Fn(&Arc<WhatsAppLink>) + Send + Sync>;

/// The first account and the ones added after it.
pub struct WhatsAppAccounts {
    env: Arc<Env>,
    desktop: bool,
    first: Arc<WhatsAppLink>,
    others: Mutex<Vec<Arc<WhatsAppLink>>>,
    /// What every account reports to the app (new messages, ticks, changes), set once by the app.
    wire: Mutex<Option<Wire>>,
}

impl WhatsAppAccounts {
    pub fn new(env: Arc<Env>, desktop: bool, first: Arc<WhatsAppLink>) -> Arc<Self> {
        let others = env.store.read(|c| c.whatsapp.accounts.clone());
        let others = others.iter().map(|a| WhatsAppLink::for_account(env.clone(), desktop, &a.id)).collect();
        Arc::new(Self { env, desktop, first, others: Mutex::new(others), wire: Mutex::default() })
    }

    /// How the app hears of every account, now and the ones added later.
    pub fn wire(&self, f: impl Fn(&Arc<WhatsAppLink>) + Send + Sync + 'static) {
        let f: Wire = Arc::new(f);
        for link in self.links() {
            f(&link);
        }
        *self.wire.lock().unwrap_or_else(|e| e.into_inner()) = Some(f);
    }

    pub fn first(&self) -> &Arc<WhatsAppLink> {
        &self.first
    }

    /// The first account first, then the others in the order they were added.
    pub fn links(&self) -> Vec<Arc<WhatsAppLink>> {
        let mut all = vec![self.first.clone()];
        all.extend(self.others.lock().unwrap_or_else(|e| e.into_inner()).iter().cloned());
        all
    }

    /// The accounts linked now.
    pub fn connected(&self) -> Vec<Arc<WhatsAppLink>> {
        self.links().into_iter().filter(|l| l.is_connected()).collect()
    }

    pub fn is_connected(&self) -> bool {
        self.links().iter().any(|l| l.is_connected())
    }

    /// Whether more than one account is linked: only then do chats say which account they are in.
    pub fn shows_accounts(&self) -> bool {
        self.connected().len() > 1
    }

    /// Called once at launch: the added accounts start (the first starts with the other connectors).
    pub fn start(&self) {
        for link in self.others.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            link.start();
        }
        self.label();
    }

    /// Settings changed (on/off, gateway, address, password, port): every account starts over.
    pub fn settings_changed(&self) {
        for link in self.links() {
            link.settings_changed();
        }
        self.label();
    }

    /// The account a chat is in by its key; a key of an account that is gone goes to the first account.
    pub fn route(&self, key: &str) -> Arc<WhatsAppLink> {
        let (account, _) = split(key);
        if account.is_empty() {
            return self.first.clone();
        }
        self.others
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|l| l.account() == account)
            .cloned()
            .unwrap_or_else(|| self.first.clone())
    }

    /// An account as the Chats tab and Settings name it: what you called it, else its number, else "WhatsApp".
    pub fn name_of(&self, link: &WhatsAppLink) -> String {
        let settings = self.env.store.read(|c| c.whatsapp.clone());
        let given = if link.account().is_empty() {
            settings.main_name.clone()
        } else {
            settings.accounts.iter().find(|a| a.id == link.account()).map(|a| a.name.clone()).unwrap_or_default()
        };
        if !given.is_empty() {
            return given;
        }
        link.me().map(|me| super::jid::display_number(&me)).unwrap_or_else(|| "WhatsApp".into())
    }

    /// Every account's chats carry its name while more than one is linked, none while one is.
    pub fn label(&self) {
        let shows = self.shows_accounts();
        for link in self.links() {
            link.set_label(shows.then(|| self.name_of(&link)));
        }
    }

    /// Another account, after your click in Settings: its device or session is made at the gateway and its QR shows.
    pub fn add(&self, name: &str) -> String {
        let taken: Vec<String> = self.env.store.read(|c| c.whatsapp.accounts.iter().map(|a| a.id.clone()).collect());
        let id = WaAccount::new_id(&taken);
        let account = WaAccount { id: id.clone(), name: WaAccount::clean_name(name) };
        self.env.store.update(|c| c.whatsapp.accounts.push(account));
        let link = WhatsAppLink::for_account(self.env.clone(), self.desktop, &id);
        if let Some(wire) = self.wire.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            wire(&link);
        }
        self.others.lock().unwrap_or_else(|e| e.into_inner()).push(link.clone());
        // Only the new account starts: the others keep their device and their webhook port (the new one takes the next).
        link.start();
        // The first account learns of the new device, which it must leave alone.
        self.first.settings_changed();
        log::info!("WhatsApp: account added");
        id
    }

    /// An account you removed: it is unlinked at the gateway and forgotten on this computer. The first account stays.
    pub async fn remove(&self, id: &str) {
        if id.is_empty() {
            return;
        }
        let (link, later) = {
            let mut others = self.others.lock().unwrap_or_else(|e| e.into_inner());
            let Some(index) = others.iter().position(|l| l.account() == id) else { return };
            let link = others.remove(index);
            (link, others[index..].to_vec())
        };
        link.remove().await;
        self.env.store.update(|c| c.whatsapp.accounts.retain(|a| a.id != id));
        // The accounts after it moved down one webhook port: only they start over.
        for l in later {
            l.settings_changed();
        }
        self.label();
        log::info!("WhatsApp: account removed");
    }

    /// What you call an account (empty id: the first); empty, it goes by its number.
    pub fn rename(&self, id: &str, name: &str) {
        let name = WaAccount::clean_name(name);
        self.env.store.update(|c| {
            if id.is_empty() {
                c.whatsapp.main_name = name.clone();
            } else if let Some(a) = c.whatsapp.accounts.iter_mut().find(|a| a.id == id) {
                a.name = name.clone();
            }
        });
        self.label();
    }

    /// Every account as Settings lists it.
    pub fn views(&self) -> Vec<AccountView> {
        let settings = self.env.store.read(|c| c.whatsapp.clone());
        self.links()
            .iter()
            .map(|link| {
                let view = link.view();
                let given = if link.account().is_empty() {
                    settings.main_name.clone()
                } else {
                    settings.accounts.iter().find(|a| a.id == link.account()).map(|a| a.name.clone()).unwrap_or_default()
                };
                AccountView {
                    id: link.account().to_string(),
                    title: self.name_of(link),
                    given,
                    port_busy: view.webhook == super::link::Webhook::PortBusy,
                    port: settings.webhook_port_of(link.account()),
                    link: view.link,
                    status_line: view.status_line,
                    me: view.me,
                    qr: view.qr,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_chat_key_names_its_account_except_for_the_first() {
        assert_eq!(chat_key("31611111111@s.whatsapp.net", ""), "31611111111@s.whatsapp.net");
        let key = chat_key("31611111111@s.whatsapp.net", "nook-abc123");
        assert_eq!(key, "nook-abc123~31611111111@s.whatsapp.net");
        assert_eq!(split(&key), ("nook-abc123", "31611111111@s.whatsapp.net"));
        assert_eq!(split("123@g.us"), ("", "123@g.us"));
        // Every link takes a key as well as a JID.
        assert_eq!(super::super::jid::normalized("nook-abc123~31611111111:4@c.us"), "31611111111@s.whatsapp.net");
    }

    #[test]
    fn new_ids_are_fresh_and_names_are_trimmed() {
        let taken = vec!["nook-aaaaaa".to_string()];
        let id = WaAccount::new_id(&taken);
        assert!(id.starts_with("nook-") && id.len() == 11 && !taken.contains(&id));
        assert_eq!(WaAccount::clean_name("  Business  "), "Business");
        assert_eq!(WaAccount::clean_name(&"x".repeat(60)).chars().count(), 40);
    }

    #[test]
    fn each_added_account_listens_one_port_up() {
        let mut s = super::super::WhatsAppSettings::default();
        s.accounts = vec![WaAccount { id: "nook-a".into(), name: String::new() }, WaAccount { id: "nook-b".into(), name: String::new() }];
        assert_eq!(s.webhook_port_of(""), Some(super::super::DEFAULT_PORT));
        assert_eq!(s.webhook_port_of("nook-b"), Some(super::super::DEFAULT_PORT + 2));
        assert_eq!(s.webhook_port_of("gone"), None);
    }
}
