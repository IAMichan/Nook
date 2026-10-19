use std::path::PathBuf;
use std::sync::OnceLock;

static SUPPORT: OnceLock<PathBuf> = OnceLock::new();

/// Zet de map met Nooks gegevens. De app doet dit bij de start met de map die Tauri geeft
/// (op Android is er geen thuismap); tests kunnen een tijdelijke map zetten.
pub fn set_support_directory(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    restrict(&dir, 0o700);
    let _ = SUPPORT.set(dir);
}

/// De map met al Nooks gegevens: `%APPDATA%\Nook` op Windows, `~/.local/share/Nook` op Linux.
pub fn support_directory() -> PathBuf {
    SUPPORT
        .get_or_init(|| {
            let dir = dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Nook");
            let _ = std::fs::create_dir_all(&dir);
            restrict(&dir, 0o700);
            dir
        })
        .clone()
}

pub fn settings_file() -> PathBuf {
    support_directory().join("settings.json")
}

pub fn nooks_file() -> PathBuf {
    support_directory().join("nooks.json")
}

pub fn database_file() -> PathBuf {
    support_directory().join("nook.sqlite")
}

/// Lege werkmap voor het Claude Code-brein, buiten de gegevensmap, zodat hij Nooks eigen data nooit ziet.
pub fn brain_scratch_directory() -> PathBuf {
    let dir = std::env::temp_dir().join("nook-brain");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// `~/.nook`: paden zonder spaties voor agents (hook-script, MCP-brug).
pub fn dot_nook() -> PathBuf {
    let dir = dirs::home_dir().unwrap_or_else(support_directory).join(".nook");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Alleen de gebruiker mag erin (op Windows staat de profielmap al per gebruiker afgeschermd).
pub fn restrict(path: &std::path::Path, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
}

/// Schrijft eerst naar een tijdelijk bestand en zet het dan op zijn plek, zodat een crash nooit een half bestand achterlaat.
pub fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    restrict(&tmp, 0o600);
    std::fs::rename(&tmp, path)
}
