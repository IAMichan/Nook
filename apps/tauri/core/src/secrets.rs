use std::collections::HashMap;
use std::sync::Mutex;

/// De enige plek waar geheimen (API-sleutels, tokens) gelezen en geschreven worden.
/// Op Windows is dat Credential Manager, op Linux de Secret Service (GNOME Keyring/KWallet),
/// op Android de Keystore; de implementaties staan in `src-tauri/src/platform`.
pub trait SecretStore: Send + Sync {
    /// Het geheim, getrimd; `None` als het ontbreekt of leeg is.
    fn read(&self, account: &str) -> Option<String>;
    /// Bewaart het geheim; een lege waarde haalt het weg.
    fn write(&self, account: &str, value: &str) -> Result<(), String>;
    fn remove(&self, account: &str) -> Result<(), String>;
}

/// Gekopieerde sleutels hebben vaak een witregel of aanhalingstekens eromheen.
pub fn clean_secret(value: &str) -> String {
    value.trim().trim_matches(|c| c == '"' || c == '\'' || c == '`').trim().to_string()
}

/// Laat alleen het begin en eind van een sleutel zien: `sk-ant-…a1b2`.
pub fn mask(secret: &str) -> String {
    let chars: Vec<char> = secret.chars().collect();
    if chars.len() <= 10 {
        return "••••".into();
    }
    let head: String = chars[..7].iter().collect();
    let tail: String = chars[chars.len() - 4..].iter().collect();
    format!("{head}…{tail}")
}

/// Geheimen in het geheugen, voor tests en als laatste uitweg wanneer het systeem geen kluis heeft.
#[derive(Default)]
pub struct MemorySecrets(Mutex<HashMap<String, String>>);

impl SecretStore for MemorySecrets {
    fn read(&self, account: &str) -> Option<String> {
        self.0.lock().ok()?.get(account).cloned().filter(|v| !v.is_empty())
    }

    fn write(&self, account: &str, value: &str) -> Result<(), String> {
        let cleaned = clean_secret(value);
        if cleaned.is_empty() {
            return self.remove(account);
        }
        self.0.lock().map_err(|e| e.to_string())?.insert(account.into(), cleaned);
        Ok(())
    }

    fn remove(&self, account: &str) -> Result<(), String> {
        self.0.lock().map_err(|e| e.to_string())?.remove(account);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_pasted_keys() {
        assert_eq!(clean_secret(" \"sk-abc\"\n"), "sk-abc");
    }

    #[test]
    fn empty_write_removes() {
        let s = MemorySecrets::default();
        s.write("a", "x").unwrap();
        assert_eq!(s.read("a").as_deref(), Some("x"));
        s.write("a", "  ").unwrap();
        assert_eq!(s.read("a"), None);
    }

    #[test]
    fn masks() {
        assert_eq!(mask("sk-ant-1234567890abcd"), "sk-ant-…abcd");
    }
}
