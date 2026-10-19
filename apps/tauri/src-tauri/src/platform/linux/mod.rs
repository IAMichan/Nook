//! Linux: scherm lezen via AT-SPI (met X11 voor de volgorde van vensters en OCR met tesseract als terugval), muziek
//! via MPRIS, apps uit `.desktop`-bestanden, volume via PipeWire/PulseAudio/ALSA, voorlezen met espeak-ng.

mod apps;
mod atspi;
mod mpris;
pub mod speech;
mod x11;

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::platform::{
    Capture, InstalledApp, MediaCommand, MediaControl, NowPlaying, RunningApp, ScreenReader, SeenWindow, SystemControl, WindowText,
};
use nook_core::services::{files, fuzzy, screen};
use tauri::AppHandle;

use super::{imaging, process};

/// AT-SPI opnieuw proberen na een mislukte verbinding, hooguit zo vaak.
const RETRY: Duration = Duration::from_secs(30);

pub struct LinuxScreen {
    x11: Option<x11::X11>,
    /// WM_CLASS (kleine letters) → de naam van de app uit zijn `.desktop`-bestand.
    names: std::sync::OnceLock<std::collections::HashMap<String, String>>,
    atspi: Mutex<(Option<atspi::Atspi>, Option<Instant>)>,
    ocr: Option<String>,
}

impl LinuxScreen {
    pub fn new() -> Self {
        let screen = Self {
            x11: x11::X11::connect(),
            names: std::sync::OnceLock::new(),
            atspi: Mutex::new((None, None)),
            ocr: imaging::tesseract_languages(),
        };
        screen.with_atspi(|_| ());
        screen
    }

    fn with_atspi<T>(&self, f: impl FnOnce(&atspi::Atspi) -> T) -> Option<T> {
        let mut guard = self.atspi.lock().unwrap_or_else(|e| e.into_inner());
        if guard.0.is_none() && guard.1.is_none_or(|t| t.elapsed() > RETRY) {
            match atspi::Atspi::connect() {
                Ok(a) => guard.0 = Some(a),
                Err(e) => {
                    log::info!("AT-SPI: {e}");
                    guard.1 = Some(Instant::now());
                }
            }
        }
        guard.0.as_ref().map(f)
    }

    pub fn has_atspi(&self) -> bool {
        self.with_atspi(|_| ()).is_some()
    }

    pub fn has_ocr(&self) -> bool {
        self.ocr.is_some() && self.x11.is_some()
    }

    fn own(pid: u32, class: &str) -> bool {
        pid == std::process::id() || screen::is_excluded(class)
    }

    fn x_windows(&self) -> Vec<x11::XWindow> {
        let names = self.names.get_or_init(apps::names_by_class);
        self.x11
            .as_ref()
            .map(|x| x.windows())
            .unwrap_or_default()
            .into_iter()
            .filter(|w| !Self::own(w.pid, &w.class))
            .map(|mut w| {
                if let Some(name) = names.get(&w.class.to_lowercase()) {
                    w.class = name.clone();
                }
                w
            })
            .collect()
    }

    fn frames(&self) -> Vec<atspi::Frame> {
        self.with_atspi(|a| a.frames()).unwrap_or_default().into_iter().filter(|f| !screen::is_excluded(&f.app)).collect()
    }

    /// Het AT-SPI-venster dat bij een X11-venster hoort: zelfde proces, en bij voorkeur dezelfde titel.
    fn frame_for(&self, window: &x11::XWindow, frames: &[atspi::Frame]) -> Option<atspi::Frame> {
        let same: Vec<&atspi::Frame> = frames.iter().filter(|f| window.pid != 0 && f.pid == window.pid).collect();
        same.iter()
            .find(|f| f.title == window.title)
            .or_else(|| same.iter().find(|f| !f.title.is_empty() && window.title.contains(&f.title)))
            .or_else(|| same.iter().find(|f| f.active))
            .or(same.first())
            .map(|f| (*f).clone())
    }

    fn ocr_window(&self, window: &x11::XWindow) -> Option<(String, u64)> {
        let x11 = self.x11.as_ref()?;
        let (rgba, w, h) = x11.capture_window(window).ok()?;
        let print = imaging::rgba_fingerprint(&rgba, w, h);
        let text = match &self.ocr {
            Some(langs) => imaging::png(&rgba, w, h).ok().and_then(|png| imaging::ocr(&png, langs).ok()).unwrap_or_default(),
            None => String::new(),
        };
        Some((text, print))
    }

    fn read(&self, id: &str, frames: &[atspi::Frame], limit: usize) -> Option<(String, u64)> {
        if let Some(raw) = id.strip_prefix("x11:") {
            let xid: u32 = raw.parse().ok()?;
            let window = self.x_windows().into_iter().find(|w| w.id == xid)?;
            let text = self.frame_for(&window, frames).and_then(|f| self.with_atspi(|a| a.text(&f, limit, 3000))).unwrap_or_default();
            if !text.trim().is_empty() {
                let print = self.fingerprint(id).unwrap_or_else(|| hash(&text));
                return Some((text, print));
            }
            return self.ocr_window(&window);
        }
        let frame = frames.iter().find(|f| f.id() == id)?;
        let text = self.with_atspi(|a| a.text(frame, limit, 3000))?;
        Some((text.clone(), hash(&text)))
    }

    fn app_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.x_windows().into_iter().map(|w| w.class).collect();
        names.extend(self.frames().into_iter().map(|f| f.app));
        names.sort();
        names.dedup();
        names.retain(|n| !n.is_empty());
        names
    }
}

fn hash(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut h);
    h.finish()
}

impl ScreenReader for LinuxScreen {
    fn available(&self) -> bool {
        self.has_atspi() || self.has_ocr()
    }

    fn status(&self) -> String {
        match (self.has_atspi(), self.x11.is_some(), self.ocr.is_some()) {
            (true, _, _) => String::new(),
            (false, true, true) => "AT-SPI draait niet; Nook leest vensters met tekstherkenning (tesseract).".into(),
            (false, true, false) => "Nook kan geen vensters lezen: de toegankelijkheidslaag (at-spi2-core) draait niet en tesseract voor tekstherkenning ontbreekt.".into(),
            (false, false, _) => "Nook kan geen vensters lezen: de toegankelijkheidslaag (at-spi2-core) draait niet, en zonder X11 is er geen schermafbeelding.".into(),
        }
    }

    fn windows(&self) -> Vec<SeenWindow> {
        if self.x11.is_some() {
            let active = self.x11.as_ref().and_then(|x| x.active());
            let windows = self.x_windows();
            let front = active.filter(|a| windows.iter().any(|w| w.id == *a)).or(windows.first().map(|w| w.id));
            return windows
                .into_iter()
                .map(|w| SeenWindow {
                    id: format!("x11:{}", w.id),
                    app: w.class,
                    title: w.title,
                    display: "1".into(),
                    frontmost: Some(w.id) == front,
                })
                .collect();
        }
        let mut frames: Vec<atspi::Frame> = self.frames().into_iter().filter(|f| f.showing).collect();
        frames.sort_by_key(|f| !f.active);
        frames
            .into_iter()
            .map(|f| SeenWindow { id: f.id(), app: f.app.clone(), title: f.title.clone(), display: "1".into(), frontmost: f.active })
            .collect()
    }

    fn read_window(&self, id: &str) -> Option<(String, u64)> {
        let frames = self.frames();
        self.read(id, &frames, 8000)
    }

    fn fingerprint(&self, id: &str) -> Option<u64> {
        let xid: u32 = id.strip_prefix("x11:")?.parse().ok()?;
        let x11 = self.x11.as_ref()?;
        let window = self.x_windows().into_iter().find(|w| w.id == xid)?;
        let (rgba, w, h) = x11.capture_window(&window).ok()?;
        Some(imaging::rgba_fingerprint(&rgba, w, h))
    }

    fn frontmost(&self) -> Option<WindowText> {
        let front = self.windows().into_iter().find(|w| w.frontmost)?;
        let (text, _) = self.read_window(&front.id)?;
        Some(WindowText { app: front.app, title: front.title, text, frontmost: true })
    }

    fn all_windows(&self) -> Vec<WindowText> {
        let frames = self.frames();
        self.windows()
            .into_iter()
            .take(6)
            .filter_map(|w| {
                let (text, _) = self.read(&w.id, &frames, 6000)?;
                Some(WindowText { app: w.app, title: w.title, text, frontmost: w.frontmost })
            })
            .collect()
    }

    fn read_app(&self, query: &str, limit: usize) -> Result<Vec<(String, String)>, String> {
        let wanted = query.trim();
        if wanted.is_empty() {
            return Err("Welke app wil je lezen?".into());
        }
        let Some(name) = fuzzy::best(wanted, &self.app_names()) else {
            if let Some(app) =
                fuzzy::best(wanted, &apps::installed().into_iter().map(|a| a.local_name.unwrap_or(a.name)).collect::<Vec<_>>())
            {
                return Err(format!(
                    "{app} staat geïnstalleerd maar is nu niet geopend. Vraag Nook \"open {app}\", dan kan hij daarna meelezen."
                ));
            }
            return Err(format!("Ik kan geen app genaamd \"{wanted}\" vinden op deze computer."));
        };
        if screen::is_excluded(&name) {
            return Err(format!("In {name} kijk ik niet."));
        }
        let frames = self.frames();
        let mut sections = Vec::new();
        let mut remaining = limit;
        for frame in frames.iter().filter(|f| f.app == name).take(3) {
            if remaining <= 200 {
                break;
            }
            let text = self.with_atspi(|a| a.text(frame, remaining, 5000)).unwrap_or_default();
            if !text.is_empty() {
                remaining = remaining.saturating_sub(text.chars().count());
                sections.push((frame.title.clone(), text));
            }
        }
        if sections.is_empty() {
            for window in self.x_windows().into_iter().filter(|w| w.class == name).take(3) {
                if let Some((text, _)) = self.ocr_window(&window).filter(|(t, _)| !t.is_empty()) {
                    sections.push((window.title.clone(), screen::prefix(&text, remaining)));
                }
            }
        }
        if sections.is_empty() {
            return Err(match self.status() {
                s if s.is_empty() => format!("{name} heeft op dit moment geen leesbare tekst."),
                s => s,
            });
        }
        Ok(sections)
    }

    fn active_app(&self) -> Option<RunningApp> {
        let front = self.windows().into_iter().find(|w| w.frontmost)?;
        let pid = front
            .id
            .strip_prefix("x11:")
            .and_then(|id| id.parse::<u32>().ok())
            .and_then(|id| self.x_windows().into_iter().find(|w| w.id == id))
            .map(|w| w.pid);
        Some(RunningApp { name: front.app.clone(), id: front.app, pid: pid.unwrap_or(0), frontmost: true, title: front.title })
    }

    fn running_apps(&self) -> Vec<RunningApp> {
        let front = self.active_app().map(|a| a.id);
        let mut apps: Vec<RunningApp> = Vec::new();
        for w in self.x_windows() {
            if !apps.iter().any(|a| a.id == w.class) {
                apps.push(RunningApp {
                    name: w.class.clone(),
                    id: w.class.clone(),
                    pid: w.pid,
                    frontmost: front.as_deref() == Some(&w.class),
                    title: w.title,
                });
            }
        }
        for f in self.frames() {
            if !apps.iter().any(|a| a.pid == f.pid || a.name.eq_ignore_ascii_case(&f.app)) {
                apps.push(RunningApp { name: f.app.clone(), id: f.app.clone(), pid: f.pid, frontmost: f.active, title: f.title });
            }
        }
        apps
    }

    fn can_capture(&self) -> bool {
        self.x11.is_some()
    }

    fn capture_screen(&self) -> Result<Capture, String> {
        let x11 = self.x11.as_ref().ok_or("Een schermdeel kan alleen onder X11 (Wayland laat apps geen schermafbeelding maken).")?;
        let (w, h) = x11.screen_size();
        let (rgba, width, height) = x11.capture(0, 0, w, h)?;
        Ok(Capture { png: imaging::png(&rgba, width, height)?, width, height })
    }

    fn idle_seconds(&self) -> f64 {
        self.x11.as_ref().and_then(|x| x.idle_ms()).map(|ms| ms as f64 / 1000.0).unwrap_or(0.0)
    }
}

pub struct LinuxMedia {
    mpris: Mutex<Option<mpris::Mpris>>,
}

impl LinuxMedia {
    pub fn new() -> Self {
        Self { mpris: Mutex::new(mpris::Mpris::connect()) }
    }

    fn with<T>(&self, f: impl FnOnce(&mpris::Mpris) -> Result<T, String>) -> Result<T, String> {
        let mut guard = self.mpris.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = mpris::Mpris::connect();
        }
        f(guard.as_ref().ok_or("Geen sessiebus (D-Bus): muziek bedienen kan niet.")?)
    }
}

impl MediaControl for LinuxMedia {
    fn now_playing(&self) -> Option<NowPlaying> {
        self.with(|m| Ok(m.now_playing())).ok().flatten()
    }

    fn send(&self, command: MediaCommand) -> Result<(), String> {
        self.with(|m| m.send(command))
    }

    fn set_volume(&self, percent: u8) -> Result<(), String> {
        let percent = percent.min(100);
        let t = Duration::from_secs(4);
        if process::which("wpctl")
            && process::run_text("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", &format!("{:.2}", percent as f64 / 100.0)], t).is_ok()
        {
            return Ok(());
        }
        if process::which("pactl") && process::run_text("pactl", &["set-sink-volume", "@DEFAULT_SINK@", &format!("{percent}%")], t).is_ok()
        {
            return Ok(());
        }
        if process::which("amixer") && process::run_text("amixer", &["-q", "sset", "Master", &format!("{percent}%")], t).is_ok() {
            return Ok(());
        }
        Err("Het volume zetten lukte niet: geen PipeWire (wpctl), PulseAudio (pactl) of ALSA (amixer) gevonden.".into())
    }

    fn volume(&self) -> Option<u8> {
        let t = Duration::from_secs(3);
        if let Ok(out) = process::run_text("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"], t) {
            let value: f64 = out.split_whitespace().nth(1)?.parse().ok()?;
            return Some((value * 100.0).round().clamp(0.0, 100.0) as u8);
        }
        let out = process::run_text("pactl", &["get-sink-volume", "@DEFAULT_SINK@"], t).ok()?;
        out.split('/').nth(1)?.trim().trim_end_matches('%').trim().parse().ok()
    }

    fn seek(&self, seconds: f64) -> Result<(), String> {
        self.with(|m| m.seek(seconds))
    }

    fn set_shuffle(&self, on: bool) -> Result<(), String> {
        self.with(|m| m.set_shuffle(on))
    }

    fn set_repeat(&self, on: bool) -> Result<(), String> {
        self.with(|m| m.set_repeat(on))
    }

    fn set_player_volume(&self, percent: u8) -> Result<(), String> {
        self.with(|m| m.set_volume(percent))
    }
}

pub struct LinuxSystem {
    app: AppHandle,
    /// Op X11 levert het klembord alleen zolang het object leeft; Nook houdt het even vast na plakken.
    clipboard: Mutex<Option<arboard::Clipboard>>,
}

impl LinuxSystem {
    pub fn new(app: &AppHandle) -> Self {
        Self { app: app.clone(), clipboard: Mutex::new(None) }
    }

    fn clipboard<T>(&self, f: impl FnOnce(&mut arboard::Clipboard) -> Result<T, arboard::Error>) -> Result<T, String> {
        let mut guard = self.clipboard.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Some(arboard::Clipboard::new().map_err(|e| format!("Het klembord is niet bereikbaar: {e}"))?);
        }
        f(guard.as_mut().expect("net gezet")).map_err(|e| e.to_string())
    }
}

/// Of de app een terminal is (die plakt met Ctrl+Shift+V).
fn is_terminal(class: &str) -> bool {
    nook_core::services::flow::FlowStyle::suggested(Some(class)) == nook_core::services::flow::FlowStyle::Verbatim
        && !["code", "cursor", "zed"].contains(&class.to_lowercase().as_str())
}

impl SystemControl for LinuxSystem {
    fn open_app(&self, name: &str) -> Result<(), String> {
        let clean = name.trim();
        if clean.is_empty() || clean.starts_with('-') || clean.contains('/') {
            return Err("Ongeldige appnaam.".into());
        }
        let installed = apps::installed();
        let mut names: Vec<String> = Vec::new();
        for app in &installed {
            names.extend(app.local_name.iter().cloned());
            names.push(app.name.clone());
            names.push(app.id.trim_end_matches(".desktop").rsplit('.').next().unwrap_or("").to_string());
        }
        let found = fuzzy::best(clean, &names).ok_or_else(|| format!("Geen app met de naam {clean} gevonden op deze computer."))?;
        let app = installed
            .iter()
            .find(|a| {
                a.local_name.as_deref() == Some(found.as_str())
                    || a.name == found
                    || a.id.trim_end_matches(".desktop").rsplit('.').next() == Some(found.as_str())
            })
            .ok_or_else(|| format!("Geen app met de naam {clean} gevonden op deze computer."))?;
        apps::launch(app)
    }

    fn open_url(&self, url: &str) -> Result<(), String> {
        use tauri_plugin_opener::OpenerExt;
        self.app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
    }

    fn notify(&self, title: &str, body: &str) {
        super::notify(&self.app, title, body);
    }

    fn installed_apps(&self) -> Vec<InstalledApp> {
        apps::installed()
            .into_iter()
            .map(|a| InstalledApp { name: a.local_name.unwrap_or(a.name), launch: a.path.display().to_string() })
            .collect()
    }

    fn clipboard_text(&self) -> Result<Option<String>, String> {
        let text = self.clipboard(|c| c.get_text()).ok();
        Ok(text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()))
    }

    fn paste_text(&self, text: &str) -> Result<bool, String> {
        let previous = self.clipboard(|c| c.get_text()).ok();
        self.clipboard(|c| c.set_text(text.to_string()))?;
        let Some(x11) = x11::X11::connect() else { return Ok(false) };
        let terminal =
            x11.active().and_then(|id| x11.windows().into_iter().find(|w| w.id == id)).map(|w| is_terminal(&w.class)).unwrap_or(false);
        std::thread::sleep(Duration::from_millis(80));
        x11.paste_keys(terminal)?;
        // Even later zetten we terug wat er op het klembord stond.
        if let Some(previous) = previous {
            let pasted = text.to_string();
            std::thread::sleep(Duration::from_millis(1500));
            let now = self.clipboard(|c| c.get_text()).ok();
            if now.as_deref() == Some(pasted.as_str()) {
                let _ = self.clipboard(|c| c.set_text(previous));
            }
        }
        Ok(true)
    }

    fn copy_image(&self, png: &[u8]) -> Result<(), String> {
        let image = image::load_from_memory(png).map_err(|e| e.to_string())?.to_rgba8();
        let (w, h) = image.dimensions();
        self.clipboard(|c| c.set_image(arboard::ImageData { width: w as usize, height: h as usize, bytes: image.into_raw().into() }))
    }

    fn search_index(&self, query: &str, limit: usize) -> Option<Vec<PathBuf>> {
        if !process::which("locate") {
            return None;
        }
        let home = dirs::home_dir()?;
        let words = files::words(query);
        if words.is_empty() {
            return Some(vec![]);
        }
        let mut args: Vec<&str> = vec!["-i", "-A", "-l", "400", "--"];
        args.extend(words.iter().map(String::as_str));
        let out = process::run_text("locate", &args, Duration::from_secs(5)).ok()?;
        Some(
            out.lines()
                .map(PathBuf::from)
                .filter(|p| p.is_file() && files::is_allowed(p, &home))
                // Alleen de bestandsnaam telt; een woord in een mapnaam alleen is te ruim.
                .filter(|p| {
                    let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                    words.iter().any(|w| name.contains(w.as_str()))
                })
                .take(limit)
                .collect(),
        )
    }

    fn recent_files(&self, limit: usize) -> Vec<PathBuf> {
        let Some(home) = dirs::home_dir() else { return vec![] };
        let xml = std::fs::read_to_string(home.join(".local/share/recently-used.xbel")).unwrap_or_default();
        files::parse_xbel(&xml).into_iter().filter(|p| p.is_file() && files::is_allowed(p, &home)).take(limit).collect()
    }

    fn pdf_text(&self, path: &Path) -> Result<String, String> {
        if !process::which("pdftotext") {
            return Err("PDF's lezen kan op deze computer niet: installeer pdftotext (poppler-utils).".into());
        }
        let path = path.to_string_lossy().to_string();
        process::run_text("pdftotext", &["-layout", "-enc", "UTF-8", "--", &path, "-"], Duration::from_secs(20))
    }
}
