//! De telefoons die met deze computer gekoppeld zijn (`CompanionStore.swift`). Sleutels staan in de kluis
//! ([`SecretStore`]), de lijst (namen, data) in `companion.json`; een sleutel die niet meer in de kluis staat kan geen
//! bericht openen, dus een toestel verwijderen is zijn sleutel wissen.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Duration, Utc};
use rand::TryRng;
use serde::{Deserialize, Serialize};

use super::keep_awake::KeepAwakeMode;
use super::models::{base64url_decode, base64url_encode, is_control, PairedDevice, KEY_LENGTH, PAIRING_WINDOW};
use super::push::PushSettings;
use super::relay_push::PushRoute;
use super::scopes::{self, Scopes};
use crate::secrets::SecretStore;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Stored {
    enabled: bool,
    /// Een vaste poort houdt gekoppelde telefoons werkend na een herstart.
    port: Option<u16>,
    devices: Vec<PairedDevice>,
    push: PushSettings,
    /// Het sleutel-id en team-id van je APNs-sleutel (Apple Developer); de .p8 zelf staat in de kluis.
    apns_key_id: String,
    apns_team_id: Option<String>,
    /// Reaching this computer away from home through a relay (Settings › Companion › Away from home).
    relay: RelaySettings,
    /// The relay code version (`cloudflare_relay::version`) deployed by Nook to `relay.address` (`"<version> <address>"`).
    relay_deployed: Option<String>,
    /// The Cloudflare account id used when Nook deployed the relay, so updates target the same account.
    relay_cloudflare_account: Option<String>,
    keep_awake: KeepAwakeMode,
    /// How pushes reach the phones; none until chosen (`relay_push::PushRoute::default_for`).
    push_route: Option<PushRoute>,
}

/// Whose relay, and whether it is on (`CompanionRelayClient` settings on the Mac).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RelaySettings {
    pub enabled: bool,
    /// Use the user's own relay at `address` instead of Nook's (also when this build has none of its own).
    pub own: bool,
    pub address: String,
}

struct Pending {
    key: Vec<u8>,
    until: DateTime<Utc>,
}

pub struct CompanionStore {
    path: PathBuf,
    secrets: Arc<dyn SecretStore>,
    stored: Mutex<Stored>,
    pending: Mutex<Option<Pending>>,
    /// What the phone that pairs now may do, chosen next to the pairing code; everything by default.
    pending_scopes: Mutex<Scopes>,
}

const APNS_KEY_ACCOUNT: &str = "companion.apns.key";
/// Het team van Nook Companion in de App Store (zelfde standaard als op de Mac).
const DEFAULT_TEAM: &str = "35SMNHP9K7";

fn account(id: &str) -> String {
    format!("companion.key.{id}")
}

impl CompanionStore {
    pub fn load(path: PathBuf, secrets: Arc<dyn SecretStore>) -> Self {
        let mut stored: Stored = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        stored.devices.retain(|d| key_from(&*secrets, &d.id).is_some());
        Self { path, secrets, stored: Mutex::new(stored), pending: Mutex::new(None), pending_scopes: Mutex::new(scopes::all()) }
    }

    pub fn load_default(secrets: Arc<dyn SecretStore>) -> Self {
        Self::load(crate::paths::support_directory().join("companion.json"), secrets)
    }

    fn with<T>(&self, f: impl FnOnce(&mut Stored) -> T, save: bool) -> T {
        let mut guard = self.stored.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut guard);
        if save {
            if let Ok(bytes) = serde_json::to_vec_pretty(&*guard) {
                let _ = crate::paths::write_atomic(&self.path, &bytes);
            }
        }
        out
    }

    pub fn enabled(&self) -> bool {
        self.with(|s| s.enabled, false)
    }

    pub fn set_enabled(&self, on: bool) {
        self.with(|s| s.enabled = on, true);
    }

    pub fn port(&self) -> Option<u16> {
        self.with(|s| s.port.filter(|p| *p >= 1024), false)
    }

    pub fn set_port(&self, port: Option<u16>) {
        self.with(|s| s.port = port, true);
    }

    pub fn devices(&self) -> Vec<PairedDevice> {
        self.with(|s| s.devices.clone(), false)
    }

    pub fn device(&self, id: &str) -> Option<PairedDevice> {
        self.with(|s| s.devices.iter().find(|d| d.id == id).cloned(), false)
    }

    pub fn relay(&self) -> RelaySettings {
        self.with(|s| s.relay.clone(), false)
    }

    pub fn set_relay(&self, relay: RelaySettings) {
        self.with(|s| s.relay = relay, true);
    }

    pub fn relay_cloudflare_token(&self) -> Option<String> {
        self.secrets.read(super::cloudflare_relay::TOKEN_ACCOUNT)
    }

    pub fn set_relay_cloudflare_token(&self, token: &str) {
        let _ = self.secrets.write(super::cloudflare_relay::TOKEN_ACCOUNT, token);
    }

    pub fn relay_deployed(&self) -> Option<String> {
        self.with(|s| s.relay_deployed.clone(), false)
    }

    pub fn set_relay_deployed(&self, version: &str, address: &str) {
        self.with(|s| s.relay_deployed = Some(format!("{version} {address}")), true);
    }

    pub fn relay_cloudflare_account(&self) -> Option<String> {
        self.with(|s| s.relay_cloudflare_account.clone(), false)
    }

    pub fn set_relay_cloudflare_account(&self, account: Option<String>) {
        self.with(|s| s.relay_cloudflare_account = account, true);
    }

    /// Whether the current own relay was set up by Nook (so Nook keeps its Worker up to date).
    pub fn own_relay_is_managed(&self) -> bool {
        self.with(
            |s| {
                s.relay.own
                    && !s.relay.address.is_empty()
                    && s.relay_deployed.as_deref().is_some_and(|d| d.ends_with(&format!(" {}", s.relay.address)))
            },
            false,
        )
    }

    /// Forgets the user's own relay locally (the Worker stays on Cloudflare until deleted there).
    pub fn forget_own_relay(&self) {
        let _ = self.secrets.remove(super::cloudflare_relay::TOKEN_ACCOUNT);
        self.with(
            |s| {
                s.relay_deployed = None;
                s.relay_cloudflare_account = None;
                s.relay.address.clear();
            },
            true,
        );
    }

    pub fn keep_awake(&self) -> KeepAwakeMode {
        self.with(|s| s.keep_awake, false)
    }

    pub fn set_keep_awake(&self, mode: KeepAwakeMode) {
        self.with(|s| s.keep_awake = mode, true);
    }

    pub fn push(&self) -> PushSettings {
        self.with(|s| s.push.clone(), false)
    }

    pub fn set_push_settings(&self, push: PushSettings) {
        self.with(|s| s.push = push, true);
    }

    pub fn apns_ids(&self) -> (String, String) {
        self.with(|s| (s.apns_key_id.clone(), s.apns_team_id.clone().unwrap_or_else(|| DEFAULT_TEAM.into())), false)
    }

    pub fn set_apns_ids(&self, key_id: &str, team_id: &str) {
        self.with(
            |s| {
                s.apns_key_id = key_id.trim().into();
                s.apns_team_id = Some(team_id.trim().into());
            },
            true,
        );
    }

    pub fn apns_pem(&self) -> Option<String> {
        self.secrets.read(APNS_KEY_ACCOUNT)
    }

    /// Bewaart de inhoud van het .p8-bestand in de kluis; onwaar als het geen geldige sleutel is.
    pub fn save_apns_pem(&self, pem: &str) -> bool {
        super::apns::valid_pem(pem) && self.secrets.write(APNS_KEY_ACCOUNT, pem.trim()).is_ok()
    }

    pub fn remove_apns_pem(&self) {
        let _ = self.secrets.remove(APNS_KEY_ACCOUNT);
    }

    /// Sleutel, sleutel-id en team-id zijn er: meldingen sturen kan.
    pub fn can_push(&self) -> bool {
        let (key_id, team_id) = self.apns_ids();
        self.apns_pem().is_some() && super::push::valid_identifier(&key_id) && super::push::valid_identifier(&team_id)
    }

    pub fn key(&self, id: &str) -> Option<Vec<u8>> {
        key_from(&*self.secrets, id)
    }

    /// Opent een koppelvenster en geeft de sleutel om te tonen. De sleutel wordt pas een toestel als de telefoon
    /// bewijst dat ze hem heeft.
    pub fn begin_pairing(&self, now: DateTime<Utc>) -> Vec<u8> {
        let mut key = vec![0u8; KEY_LENGTH];
        rand::rngs::SysRng.try_fill_bytes(&mut key).expect("de systeemgenerator geeft willekeurige bytes");
        *self.pending.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(Pending { key: key.clone(), until: now + Duration::seconds(PAIRING_WINDOW) });
        key
    }

    pub fn cancel_pairing(&self) {
        *self.pending.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// De koppelsleutel, zolang het venster open is.
    pub fn active_pending(&self, now: DateTime<Utc>) -> Option<Vec<u8>> {
        let mut guard = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        match &*guard {
            Some(p) if p.until > now => Some(p.key.clone()),
            _ => {
                *guard = None;
                None
            }
        }
    }

    /// Tot wanneer het koppelvenster open is.
    pub fn pending_until(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        self.active_pending(now)?;
        self.pending.lock().ok()?.as_ref().map(|p| p.until)
    }

    /// De telefoon bewees de sleutel: vanaf nu is het een toestel.
    pub fn complete_pairing(&self, name: &str, now: DateTime<Utc>) -> Option<PairedDevice> {
        let key = self.active_pending(now)?;
        let id = PairedDevice::identifier(&key);
        self.secrets.write(&account(&id), &base64url_encode(&key)).ok()?;
        let clean: String = name.chars().filter(|c| !is_control(*c)).take(60).collect();
        let device = PairedDevice {
            id: id.clone(),
            name: if clean.trim().is_empty() { "Telefoon".into() } else { clean },
            paired_at: now,
            last_seen: Some(now),
            push_token: None,
            push_production: None,
            push_service: None,
            scopes: Some(scopes::names(&self.pending_scopes())),
            device_key: None,
            protocol_version: None,
            app_version: None,
        };
        self.with(
            |s| {
                s.devices.retain(|d| d.id != id);
                s.devices.push(device.clone());
            },
            true,
        );
        self.cancel_pairing();
        self.set_pending_scopes(scopes::all());
        Some(device)
    }

    /// What the phone that pairs next may do.
    pub fn pending_scopes(&self) -> Scopes {
        self.pending_scopes.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn set_pending_scopes(&self, scopes: Scopes) {
        *self.pending_scopes.lock().unwrap_or_else(|e| e.into_inner()) = scopes;
    }

    /// What a paired phone may do; nothing for an id that is no paired phone.
    pub fn scopes_of(&self, id: &str) -> Scopes {
        self.device(id).map(|d| d.granted_scopes()).unwrap_or_default()
    }

    /// Changes what a paired phone may do (the server drops its live connection, `CompanionServer::set_scopes`).
    pub fn set_scopes(&self, id: &str, granted: &Scopes) {
        self.with(
            |s| {
                if let Some(d) = s.devices.iter_mut().find(|d| d.id == id) {
                    d.scopes = Some(scopes::names(granted));
                }
            },
            true,
        );
    }

    pub fn set_push_token(&self, id: &str, token: Option<String>, production: Option<bool>) {
        self.set_push(id, token, production, None);
    }

    /// The phone's push token, its environment and whose it is (`service`: none for Apple, "fcm" for Firebase).
    pub fn set_push(&self, id: &str, token: Option<String>, production: Option<bool>, service: Option<&str>) {
        self.with(
            |s| {
                if let Some(d) = s.devices.iter_mut().find(|d| d.id == id) {
                    d.push_production = if token.is_none() { None } else { production };
                    d.push_service = token.as_ref().and(service.map(Into::into));
                    d.push_token = token;
                }
            },
            true,
        );
    }

    /// How pushes reach the phones; `build_has_relay` decides the first choice (`PushRoute::default_for`).
    pub fn push_route(&self, build_has_relay: bool) -> PushRoute {
        let stored = self.with(|s| s.push_route, false);
        stored.unwrap_or_else(|| PushRoute::default_for(self.can_push(), build_has_relay))
    }

    pub fn set_push_route(&self, route: PushRoute) {
        self.with(|s| s.push_route = Some(route), true);
    }

    /// The public half of a phone's device key (`device_key`), once it bound one.
    pub fn device_key(&self, id: &str) -> Option<Vec<u8>> {
        use base64::Engine;
        let encoded = self.device(id)?.device_key?;
        base64::engine::general_purpose::STANDARD.decode(encoded.as_bytes()).ok()
    }

    /// Keeps the phone's device key: the first one it sends for this pairing (trust on first use). True when it is the
    /// one kept now (new, or the same again); false when the phone already bound another, which only pairing again
    /// replaces.
    pub fn bind_key(&self, id: &str, public_key: &[u8]) -> bool {
        use base64::Engine;
        let encoded = base64::engine::general_purpose::STANDARD.encode(public_key);
        let (kept, changed) = self.with(
            |s| match s.devices.iter_mut().find(|d| d.id == id) {
                None => (false, false),
                Some(d) => match &d.device_key {
                    Some(bound) => (*bound == encoded, false),
                    None => {
                        d.device_key = Some(encoded.clone());
                        (true, true)
                    }
                },
            },
            false,
        );
        if changed {
            self.with(|_| (), true);
        }
        kept
    }

    /// What the phone said it runs (`noteVersions`); saved only when it changed.
    pub fn note_versions(&self, id: &str, protocol_version: Option<i64>, app_version: Option<String>) {
        let changed = self.with(
            |s| match s.devices.iter_mut().find(|d| d.id == id) {
                Some(d) if d.protocol_version != protocol_version || d.app_version != app_version => {
                    d.protocol_version = protocol_version;
                    d.app_version = app_version.clone();
                    true
                }
                _ => false,
            },
            false,
        );
        if changed {
            self.with(|_| (), true);
        }
    }

    /// Niet bij elke aanvraag opslaan: een minuut is precies genoeg voor "laatst gezien".
    pub fn touch(&self, id: &str, now: DateTime<Utc>) {
        let changed = self.with(
            |s| match s.devices.iter_mut().find(|d| d.id == id) {
                Some(d) if d.last_seen.is_none_or(|last| now - last >= Duration::seconds(60)) => {
                    d.last_seen = Some(now);
                    true
                }
                _ => false,
            },
            false,
        );
        if changed {
            self.with(|_| (), true);
        }
    }

    pub fn remove(&self, id: &str) {
        let _ = self.secrets.remove(&account(id));
        self.with(|s| s.devices.retain(|d| d.id != id), true);
    }

    pub fn remove_all(&self) {
        for device in self.devices() {
            let _ = self.secrets.remove(&account(&device.id));
        }
        self.with(|s| s.devices.clear(), true);
    }
}

fn key_from(secrets: &dyn SecretStore, id: &str) -> Option<Vec<u8>> {
    let key = base64url_decode(&secrets.read(&account(id))?)?;
    (key.len() == KEY_LENGTH).then_some(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;

    fn store(dir: &std::path::Path, secrets: Arc<dyn SecretStore>) -> CompanionStore {
        CompanionStore::load(dir.join("companion.json"), secrets)
    }

    #[test]
    fn pairing_window_completes_once_and_expires() {
        let dir = tempdir();
        let secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let s = store(&dir, secrets.clone());
        let now = Utc::now();
        let key = s.begin_pairing(now);
        assert_eq!(s.active_pending(now + Duration::seconds(299)), Some(key.clone()));
        let device = s.complete_pairing("Pixel\u{7} 8", now).unwrap();
        assert_eq!(device.name, "Pixel 8");
        assert_eq!(device.id, PairedDevice::identifier(&key));
        assert_eq!(s.key(&device.id), Some(key));
        assert!(s.complete_pairing("again", now).is_none(), "een code werkt één keer");

        s.begin_pairing(now);
        assert!(s.active_pending(now + Duration::seconds(301)).is_none(), "vijf minuten");

        s.note_versions(&device.id, Some(3), Some("1.4.0".into()));
        assert_eq!(
            store(&dir, secrets.clone()).device(&device.id).map(|d| (d.protocol_version, d.app_version)),
            Some((Some(3), Some("1.4.0".into())))
        );

        // Opnieuw laden houdt het toestel; zonder sleutel in de kluis valt het weg.
        assert_eq!(store(&dir, secrets.clone()).devices().len(), 1);
        secrets.remove(&account(&device.id)).unwrap();
        assert!(store(&dir, secrets).devices().is_empty());
    }

    #[test]
    fn remove_deletes_the_key() {
        let dir = tempdir();
        let secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let s = store(&dir, secrets.clone());
        let now = Utc::now();
        s.begin_pairing(now);
        let device = s.complete_pairing("", now).unwrap();
        assert_eq!(device.name, "Telefoon");
        s.set_push_token(&device.id, Some("ab".repeat(32)), Some(false));
        assert_eq!(s.device(&device.id).unwrap().push_production, Some(false));
        s.remove(&device.id);
        assert!(s.devices().is_empty());
        assert!(s.key(&device.id).is_none());
    }

    fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-companion-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
