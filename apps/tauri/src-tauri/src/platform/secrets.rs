//! Geheimen: Windows Credential Manager, Secret Service op Linux (GNOME Keyring/KWallet), Keychain op macOS.
//! Op Android (en waar het systeem geen kluis heeft) een bestand in de afgeschermde app-map.

use std::sync::Arc;

use nook_core::secrets::{clean_secret, SecretStore};

/// Zelfde servicenaam als de Keychain op de Mac.
pub const SERVICE: &str = "nl.imdigital.nook";

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
pub struct SystemSecrets;

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
impl SecretStore for SystemSecrets {
    fn read(&self, account: &str) -> Option<String> {
        let value = keyring::Entry::new(SERVICE, account).ok()?.get_password().ok()?;
        let trimmed = value.trim().to_string();
        (!trimmed.is_empty()).then_some(trimmed)
    }

    fn write(&self, account: &str, value: &str) -> Result<(), String> {
        let cleaned = clean_secret(value);
        if cleaned.is_empty() {
            return self.remove(account);
        }
        keyring::Entry::new(SERVICE, account).and_then(|e| e.set_password(&cleaned)).map_err(|e| e.to_string())
    }

    fn remove(&self, account: &str) -> Result<(), String> {
        match keyring::Entry::new(SERVICE, account).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

/// Een JSON-bestand met alleen-eigenaar-rechten in de app-map. Op Android is die map al per app afgeschermd.
pub struct FileSecrets {
    path: std::path::PathBuf,
    lock: std::sync::Mutex<()>,
}

impl FileSecrets {
    pub fn new(path: std::path::PathBuf) -> Self {
        Self { path, lock: std::sync::Mutex::new(()) }
    }

    fn load(&self) -> std::collections::BTreeMap<String, String> {
        std::fs::read(&self.path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    fn store(&self, map: &std::collections::BTreeMap<String, String>) -> Result<(), String> {
        let bytes = serde_json::to_vec(map).map_err(|e| e.to_string())?;
        nook_core::paths::write_atomic(&self.path, &bytes).map_err(|e| e.to_string())
    }
}

impl SecretStore for FileSecrets {
    fn read(&self, account: &str) -> Option<String> {
        let _g = self.lock.lock().ok()?;
        self.load().get(account).cloned().filter(|v| !v.is_empty())
    }

    fn write(&self, account: &str, value: &str) -> Result<(), String> {
        let cleaned = clean_secret(value);
        let _g = self.lock.lock().map_err(|e| e.to_string())?;
        let mut map = self.load();
        if cleaned.is_empty() {
            map.remove(account);
        } else {
            map.insert(account.into(), cleaned);
        }
        self.store(&map)
    }

    fn remove(&self, account: &str) -> Result<(), String> {
        self.write(account, "")
    }
}

/// De kluis van dit systeem. Werkt de systeemkluis niet (Linux zonder Secret Service), dan het bestand.
pub fn system_store() -> Arc<dyn SecretStore> {
    let fallback = || Arc::new(FileSecrets::new(nook_core::paths::support_directory().join("secrets.json"))) as Arc<dyn SecretStore>;
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        let probe = keyring::Entry::new(SERVICE, "nook-probe").and_then(|e| match e.get_password() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => Err(err),
        });
        if probe.is_ok() {
            return Arc::new(SystemSecrets);
        }
        log::warn!("Geen systeemkluis beschikbaar; geheimen gaan in een afgeschermd bestand");
    }
    fallback()
}
