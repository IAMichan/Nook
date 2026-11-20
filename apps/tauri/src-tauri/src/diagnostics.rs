//! Nook's own log in the Windows and Linux app (`nook_core::diagnostics`): every `log::…` line from Nook goes to a
//! rotating file in the data folder, and Settings › System › Diagnostics copies a redacted report of the last half hour.

use log::{Level, LevelFilter, Log, Metadata, Record};
use tauri::{AppHandle, Manager};

use crate::state::AppState;

struct FileLogger;

impl Log for FileLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        // Nook's own lines from Info; the libraries under it only when something goes wrong.
        let ours = metadata.target().starts_with("nook");
        metadata.level() <= if ours { Level::Info } else { Level::Warn }
    }

    fn log(&self, record: &Record) {
        if self.enabled(record.metadata()) {
            nook_core::diagnostics::log().append(chrono::Local::now(), record.level().as_str(), record.target(), &record.args().to_string());
        }
    }

    fn flush(&self) {}
}

/// Called first thing at launch.
pub fn start() {
    static LOGGER: FileLogger = FileLogger;
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(LevelFilter::Info);
    }
    log::info!("Nook {} started on {} {}", env!("CARGO_PKG_VERSION"), std::env::consts::OS, std::env::consts::ARCH);
}

/// The redacted report: versions, how Nook is set up, and the log of the last half hour (`copyRedactedDiagnostics`).
#[tauri::command]
pub fn diagnostics_report(app: AppHandle) -> String {
    let settings = app.state::<AppState>().settings();
    let header = vec![
        ("Nook".to_string(), env!("CARGO_PKG_VERSION").to_string()),
        ("System".to_string(), format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)),
        ("Brain".to_string(), format!("{:?}", settings.provider)),
        ("Interface language".to_string(), settings.app_language.clone()),
        ("Theme".to_string(), format!("{} (dark {}, light {})", settings.theme, settings.dark_theme, settings.light_theme)),
        ("Placement".to_string(), settings.placement.clone()),
        ("Energy".to_string(), format!("{:?}", settings.energy_mode)),
    ];
    let user = std::env::var("USERNAME").or_else(|_| std::env::var("USER")).unwrap_or_default();
    let mut report = nook_core::diagnostics::report(&header, &user);
    if !settings.user_name.trim().is_empty() {
        report = nook_core::diagnostics::redact(&report, &settings.user_name);
    }
    report
}

/// Opens the folder with the log files ("Show log files").
#[tauri::command]
pub fn diagnostics_show_logs(app: AppHandle) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let folder = nook_core::diagnostics::log_dir();
    let _ = std::fs::create_dir_all(&folder);
    app.opener().open_path(folder.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}
