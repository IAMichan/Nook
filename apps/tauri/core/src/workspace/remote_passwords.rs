//! SSH passwords you typed (`RemotePasswords` on the Mac): in memory for this run of Nook, and in the system's secret
//! store (Windows Credential Manager, the Secret Service) only when you chose "Keep". Never anywhere else on disk.
//! ssh gets one through `SSH_ASKPASS` (see `askpass_environment`), answered by Nook itself in its askpass mode, so a
//! password is typed once, not on every turn.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, LazyLock, Mutex};

use base64::Engine;

use crate::secrets::SecretStore;

/// The environment variable that turns Nook into ssh's askpass program, and the one that carries the password.
pub const ASKPASS_MODE: &str = "NOOK_SSH_ASKPASS";
pub const PASSWORD_VARIABLE: &str = "NOOK_SSH_PASSWORD";

#[derive(Default)]
struct Inner {
    passwords: HashMap<String, String>,
    /// Machines whose stored entry was looked up this run, found or not: one lookup each.
    looked: HashSet<String>,
    kept: HashSet<String>,
    store: Option<Arc<dyn SecretStore>>,
}

pub struct RemotePasswords(Mutex<Inner>);

static SHARED: LazyLock<RemotePasswords> = LazyLock::new(RemotePasswords::new);

impl Default for RemotePasswords {
    fn default() -> Self {
        Self::new()
    }
}

impl RemotePasswords {
    pub fn new() -> Self {
        Self(Mutex::new(Inner::default()))
    }

    /// The one the app uses; it gives it the system's secret store at launch.
    pub fn shared() -> &'static RemotePasswords {
        &SHARED
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_store(&self, store: Arc<dyn SecretStore>) {
        let mut s = self.lock();
        s.store = Some(store);
        s.looked.clear();
    }

    /// The account of a machine's password in the secret store.
    pub fn account(machine_id: &str) -> String {
        format!("ssh.password.{machine_id}")
    }

    /// The password Nook has for the machine: typed in this run, or kept.
    pub fn password(&self, machine_id: &str) -> Option<String> {
        let mut s = self.lock();
        if let Some(p) = s.passwords.get(machine_id) {
            return Some(p.clone());
        }
        if !s.looked.insert(machine_id.to_string()) {
            return None;
        }
        // Base64, because the store trims its values and a password may start or end with a space.
        let stored = s.store.as_ref()?.read(&Self::account(machine_id))?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(stored.trim()).ok()?;
        let password = String::from_utf8(bytes).ok().filter(|p| !p.is_empty())?;
        s.passwords.insert(machine_id.to_string(), password.clone());
        s.kept.insert(machine_id.to_string());
        Some(password)
    }

    /// Keeps a password in memory, and in the store when `keep`; `None` or empty forgets it in both. `Err` when it
    /// should have gone to the store and could not (it is still kept for this run).
    pub fn set(&self, machine_id: &str, password: Option<&str>, keep: bool) -> Result<(), String> {
        let mut s = self.lock();
        let account = Self::account(machine_id);
        // Never looked up: an older kept password may be there, so not keeping now removes it too.
        let may_be_kept = s.kept.remove(machine_id) || !s.looked.contains(machine_id);
        s.looked.insert(machine_id.to_string());
        let Some(password) = password.filter(|p| !p.is_empty()) else {
            s.passwords.remove(machine_id);
            if may_be_kept {
                if let Some(store) = &s.store {
                    let _ = store.remove(&account);
                }
            }
            return Ok(());
        };
        s.passwords.insert(machine_id.to_string(), password.to_string());
        if !keep {
            if may_be_kept {
                if let Some(store) = &s.store {
                    let _ = store.remove(&account);
                }
            }
            return Ok(());
        }
        let store = s.store.clone().ok_or_else(|| "No secret store on this computer.".to_string())?;
        store.write(&account, &base64::engine::general_purpose::STANDARD.encode(password))?;
        s.kept.insert(machine_id.to_string());
        Ok(())
    }

    /// Whether the machine's password is in the store, not only in memory.
    pub fn is_kept(&self, machine_id: &str) -> bool {
        let _ = self.password(machine_id);
        self.lock().kept.contains(machine_id)
    }
}

/// What ssh needs in its environment to get the password: Nook itself as the askpass program (forced, also without a
/// display), its askpass mode, and the password. Empty without a password.
pub fn askpass_environment(password: Option<&str>) -> BTreeMap<String, String> {
    let (Some(password), Ok(program)) = (password, std::env::current_exe()) else { return BTreeMap::new() };
    [
        ("SSH_ASKPASS".to_string(), program.to_string_lossy().into_owned()),
        ("SSH_ASKPASS_REQUIRE".to_string(), "force".to_string()),
        ("DISPLAY".to_string(), ":0".to_string()),
        (ASKPASS_MODE.to_string(), "1".to_string()),
        (PASSWORD_VARIABLE.to_string(), password.to_string()),
    ]
    .into()
}

/// Nook as ssh's askpass program: it answers only a password prompt, with the password Nook put in its environment.
/// A host key question or anything else gets no answer, so ssh stops instead of trusting a new machine on your behalf.
/// `None` when Nook was not started as askpass.
pub fn askpass_answer(prompt: &str, mode: Option<&str>, password: Option<&str>) -> Option<Result<String, ()>> {
    if mode != Some("1") {
        return None;
    }
    if !prompt.to_lowercase().contains("assword") {
        return Some(Err(()));
    }
    Some(password.map(String::from).ok_or(()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;

    #[test]
    fn kept_only_when_asked_and_read_back_after_a_restart() {
        let store: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
        let p = RemotePasswords::new();
        p.set_store(store.clone());
        p.set("m1", Some(" pass word "), false).unwrap();
        assert_eq!(p.password("m1").as_deref(), Some(" pass word "));
        assert!(store.read(&RemotePasswords::account("m1")).is_none(), "not kept unless asked");
        p.set("m1", Some(" pass word "), true).unwrap();
        assert!(p.is_kept("m1"));
        let again = RemotePasswords::new();
        again.set_store(store.clone());
        assert_eq!(again.password("m1").as_deref(), Some(" pass word "), "spaces survive the store");
        again.set("m1", None, false).unwrap();
        assert!(store.read(&RemotePasswords::account("m1")).is_none());
        assert!(again.password("m1").is_none());
    }

    #[test]
    fn askpass_answers_only_a_password_prompt() {
        assert_eq!(askpass_answer("me@box's password: ", None, Some("x")), None, "not in askpass mode");
        assert_eq!(askpass_answer("me@box's password: ", Some("1"), Some("x")), Some(Ok("x".into())));
        assert_eq!(askpass_answer("Are you sure you want to continue connecting (yes/no)?", Some("1"), Some("x")), Some(Err(())));
        assert_eq!(askpass_answer("Password:", Some("1"), None), Some(Err(())));
        assert!(askpass_environment(None).is_empty());
        let env = askpass_environment(Some("pw"));
        assert_eq!(env.get(ASKPASS_MODE).map(String::as_str), Some("1"));
        assert_eq!(env.get("SSH_ASKPASS_REQUIRE").map(String::as_str), Some("force"));
    }
}
