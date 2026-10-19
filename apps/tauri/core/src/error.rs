use std::fmt;

/// Een fout met een zin die de gebruiker begrijpt. Net als `NookError` in de macOS-app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NookError(pub String);

impl NookError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for NookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NookError {}

impl From<std::io::Error> for NookError {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}

impl From<serde_json::Error> for NookError {
    fn from(e: serde_json::Error) -> Self {
        Self(format!("Ongeldige JSON: {e}"))
    }
}

impl From<rusqlite::Error> for NookError {
    fn from(e: rusqlite::Error) -> Self {
        Self(format!("Database: {e}"))
    }
}

impl From<reqwest::Error> for NookError {
    fn from(e: reqwest::Error) -> Self {
        Self(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, NookError>;

/// Korte schrijfwijze: `bail!("…")`.
#[macro_export]
macro_rules! nook_err {
    ($($arg:tt)*) => { $crate::error::NookError(format!($($arg)*)) };
}
