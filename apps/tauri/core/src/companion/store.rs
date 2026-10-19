//! De telefoons die met deze computer gekoppeld zijn (`CompanionStore.swift`). Sleutels staan in de kluis
//! ([`SecretStore`]), de lijst (namen, data) in `companion.json`; een sleutel die niet meer in de kluis staat kan geen
//! bericht openen, dus een toestel verwijderen is zijn sleutel wissen.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::OsRng;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::models::{base64url_decode, base64url_encode, is_control, PairedDevice, KEY_LENGTH, PAIRING_WINDOW};
use super::push::PushSettings;
use crate::secrets::SecretStore;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Stored {
    enabled: bool,
    /// Een vaste poort houdt gekoppelde telefoons werkend na een herstart.
    port: Option<u16>,
    devices: Vec<PairedDevice>,
    push: PushSettings,
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
}

fn account(id: &str) -> String {
    format!("companion.key.{id}")
}

impl CompanionStore {
    pub fn load(path: PathBuf, secrets: Arc<dyn SecretStore>) -> Self {
        let mut stored: Stored = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        stored.devices.retain(|d| key_from(&*secrets, &d.id).is_some());
        Self { path, secrets, stored: Mutex::new(stored), pending: Mutex::new(None) }
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

    pub fn push(&self) -> PushSettings {
        self.with(|s| s.push.clone(), false)
    }

    pub fn set_push_settings(&self, push: PushSettings) {
        self.with(|s| s.push = push, true);
    }

    pub fn key(&self, id: &str) -> Option<Vec<u8>> {
        key_from(&*self.secrets, id)
    }

    /// Opent een koppelvenster en geeft de sleutel om te tonen. De sleutel wordt pas een toestel als de telefoon
    /// bewijst dat ze hem heeft.
    pub fn begin_pairing(&self, now: DateTime<Utc>) -> Vec<u8> {
        let mut key = vec![0u8; KEY_LENGTH];
        OsRng.fill_bytes(&mut key);
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
        };
        self.with(
            |s| {
                s.devices.retain(|d| d.id != id);
                s.devices.push(device.clone());
            },
            true,
        );
        self.cancel_pairing();
        Some(device)
    }

    pub fn set_push_token(&self, id: &str, token: Option<String>, production: Option<bool>) {
        self.with(
            |s| {
                if let Some(d) = s.devices.iter_mut().find(|d| d.id == id) {
                    d.push_production = if token.is_none() { None } else { production };
                    d.push_token = token;
                }
            },
            true,
        );
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
