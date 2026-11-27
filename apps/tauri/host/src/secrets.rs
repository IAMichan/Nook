//! Owner-only (0600) file-backed `SecretStore` for headless servers without a desktop keyring.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nook_core::secrets::{clean_secret, SecretStore};

pub struct FileSecrets {
    path: PathBuf,
    values: Mutex<BTreeMap<String, String>>,
}

impl FileSecrets {
    pub fn open(path: PathBuf) -> Self {
        let values: BTreeMap<String, String> = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { path, values: Mutex::new(values) }
    }

    fn save(&self, map: &BTreeMap<String, String>) -> Result<(), String> {
        if let Some(dir) = self.path.parent() {
            ensure_private_dir(dir)?;
        }
        let bytes = serde_json::to_vec_pretty(map).map_err(|e| e.to_string())?;
        let tmp = self.path.with_extension("json.tmp");
        write_private_file(&tmp, &bytes)?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }
}

impl SecretStore for FileSecrets {
    fn read(&self, account: &str) -> Option<String> {
        self.values.lock().ok()?.get(account).cloned().filter(|v| !v.is_empty())
    }

    fn write(&self, account: &str, value: &str) -> Result<(), String> {
        let cleaned = clean_secret(value);
        if cleaned.is_empty() {
            return self.remove(account);
        }
        let mut guard = self.values.lock().map_err(|e| e.to_string())?;
        guard.insert(account.to_string(), cleaned);
        self.save(&guard)
    }

    fn remove(&self, account: &str) -> Result<(), String> {
        let mut guard = self.values.lock().map_err(|e| e.to_string())?;
        guard.remove(account);
        self.save(&guard)
    }
}

fn ensure_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file =
            std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(path).map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes).map_err(|e| e.to_string())
    }
}
