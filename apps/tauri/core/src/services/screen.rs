//! Wat er op het scherm staat, als tekst voor het brein. De platformlaag leest de vensters (UI Automation/OCR op
//! Windows, AT-SPI op Linux); hier zitten de regels van `ScreenReader` en `ScreenContext` op de Mac: welke apps
//! Nook nooit leest, wanneer een vraag over het scherm gaat, hoe vensters in een vast budget passen en wanneer een
//! venster opnieuw gelezen moet worden.

use std::collections::HashMap;
use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::platform::WindowText;

/// Wat het brein krijgt: de naam van de voorste app, een label en de tekst.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenSnapshot {
    pub app_name: String,
    pub window_title: String,
    pub text: String,
}

/// Wachtwoordbeheerders en Nook zelf worden nooit gelezen: niet via toegankelijkheid en niet via OCR.
/// Namen zoals ze op Windows (exe) en Linux (WM_CLASS, AT-SPI-naam) voorkomen, in kleine letters.
pub const EXCLUDED_APPS: [&str; 22] = [
    "1password",
    "bitwarden",
    "keepass",
    "keepassxc",
    "keepassx",
    "lastpass",
    "dashlane",
    "enpass",
    "proton pass",
    "protonpass",
    "nordpass",
    "roboform",
    "keeper",
    "seahorse",
    "kwalletmanager",
    "gnome-keyring",
    "credentialuibroker",
    "consent",
    "logonui",
    "pinentry",
    "polkit",
    "nook",
];

/// Of Nook in deze app nooit mag kijken. `app` is de naam, het exe-bestand of de WM_CLASS.
pub fn is_excluded(app: &str) -> bool {
    let lower = app.trim().to_lowercase();
    let stem = lower.strip_suffix(".exe").unwrap_or(&lower);
    if stem.is_empty() {
        return false;
    }
    EXCLUDED_APPS.iter().any(|name| stem == *name || stem.starts_with(&format!("{name} ")) || stem.starts_with(&format!("{name}-")))
        || stem.contains("password")
        || stem.contains("wachtwoord")
}

/// Woorden en zinnen waarmee een vraag naar iets op het scherm verwijst ("hier", "dit", "zet er een afspraak voor").
pub fn refers_to_screen(text: &str) -> bool {
    static CUE: OnceLock<Regex> = OnceLock::new();
    CUE.get_or_init(|| {
        Regex::new(
            r"(?i)\b(hier\w*|dit|deze|daar\w*|erbij|ervoor|ervan|erover|scherm|kijk mee|lees mee)\b|\ber\b.{0,25}\b(afspraak|herinnering|taak|mail|punt|agenda)\b",
        )
        .expect("geldig patroon")
    })
    .is_match(text)
}

/// Eén app gelezen, in stukken per venster (`read_app`).
pub fn app_snapshot(name: &str, sections: &[(String, String)]) -> ScreenSnapshot {
    let body = sections
        .iter()
        .map(|(title, text)| format!("### {name}{}\n{text}", if title.is_empty() { String::new() } else { format!(" — {title}") }))
        .collect::<Vec<_>>()
        .join("\n\n");
    ScreenSnapshot { app_name: name.into(), window_title: name.into(), text: body }
}

/// Alle zichtbare vensters, het voorste eerst, samen binnen `total_limit` tekens (`captureAll` op de Mac).
pub fn format_all(windows: &[WindowText], total_limit: usize) -> Option<ScreenSnapshot> {
    let mut ordered: Vec<&WindowText> = windows.iter().filter(|w| !is_excluded(&w.app) && !w.text.trim().is_empty()).collect();
    ordered.sort_by_key(|w| !w.frontmost);
    let mut sections = Vec::new();
    let mut remaining = total_limit;
    for (index, window) in ordered.iter().enumerate() {
        if remaining <= 200 {
            break;
        }
        let share = if index == 0 { remaining } else { remaining.min((total_limit / 4).max(1200)) };
        let chunk = prefix(window.text.trim(), share);
        remaining = remaining.saturating_sub(chunk.chars().count());
        let title = if window.title.is_empty() { String::new() } else { format!(" — {}", window.title) };
        let label = if index == 0 && window.frontmost { "Frontmost window" } else { "Window" };
        sections.push(format!("### {label}: {}{title}\n{chunk}", window.app));
    }
    if sections.is_empty() {
        return None;
    }
    let front = ordered.first().map(|w| w.app.clone()).unwrap_or_default();
    Some(ScreenSnapshot { app_name: front, window_title: "all visible windows".into(), text: sections.join("\n\n") })
}

/// "Nook keek in Kladblok" of "Nook keek in Kladblok en 2 andere vensters": de regel boven het antwoord.
pub fn looked_label(snapshot: &ScreenSnapshot) -> String {
    let count = snapshot.text.matches("\n### ").count() + usize::from(snapshot.text.starts_with("### "));
    match count {
        0 | 1 => snapshot.app_name.clone(),
        2 => format!("{} en 1 ander venster", snapshot.app_name),
        n => format!("{} en {} andere vensters", snapshot.app_name, n - 1),
    }
}

/// Een stuk tekst van hooguit `limit` tekens, op een tekengrens.
pub fn prefix(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// Een visuele vingerafdruk van een venster: een 16×16 grijs plaatje, grof gemaakt zodat een knipperende cursor hem
/// niet verandert. `gray` is rij voor rij, `width`×`height` pixels.
pub fn fingerprint(gray: &[u8], width: usize, height: usize) -> u64 {
    const SIDE: usize = 16;
    if width == 0 || height == 0 || gray.len() < width * height {
        return (width as u64).wrapping_mul(31).wrapping_add(height as u64);
    }
    let mut hash: u64 = 1_469_598_103_934_665_603;
    for y in 0..SIDE {
        for x in 0..SIDE {
            let (x0, x1) = (x * width / SIDE, ((x + 1) * width / SIDE).max(x * width / SIDE + 1));
            let (y0, y1) = (y * height / SIDE, ((y + 1) * height / SIDE).max(y * height / SIDE + 1));
            let mut sum = 0u64;
            let mut count = 0u64;
            for row in y0..y1.min(height) {
                for col in x0..x1.min(width) {
                    sum += gray[row * width + col] as u64;
                    count += 1;
                }
            }
            let value = (sum / count.max(1)) as u8;
            hash = (hash ^ (value >> 3) as u64).wrapping_mul(1_099_511_628_211);
        }
    }
    hash ^ ((width as u64) << 16 | height as u64)
}

/// Eén venster zoals het live bijhouden het kent.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveWindow {
    pub id: String,
    pub app: String,
    pub title: String,
    pub display: String,
    pub text: String,
    pub frontmost: bool,
    /// Seconden (een monotone klok) waarop het venster gelezen is.
    pub captured: f64,
    pub fingerprint: u64,
}

/// Een venster zoals de platformlaag het nu ziet, nog zonder tekst.
#[derive(Debug, Clone, PartialEq)]
pub struct SeenWindow {
    pub id: String,
    pub app: String,
    pub title: String,
    pub display: String,
    pub frontmost: bool,
}

/// Live bijhouden van alle vensters (`ScreenContext` op de Mac): het voorste venster elke ronde, de andere als ze
/// nieuw zijn, hun titel veranderde of ze ouder zijn dan 30 seconden. Een venster met dezelfde vingerafdruk wordt
/// niet opnieuw gelezen.
#[derive(Debug, Default)]
pub struct LiveScreen {
    cache: HashMap<String, LiveWindow>,
    order: Vec<String>,
    pub last_update: Option<f64>,
}

pub const MAX_WINDOWS: usize = 10;
/// Seconden tussen twee rondes.
pub const INTERVAL: f64 = 7.0;
/// Vensters achter het voorste worden hooguit zo vaak opnieuw gelezen.
pub const BACKGROUND_MAX_AGE: f64 = 30.0;

impl LiveScreen {
    /// Welke vensters nu gelezen moeten worden. `front_only`: alleen het voorste (na het wisselen van app).
    pub fn due(&self, seen: &[SeenWindow], front_only: bool, now: f64) -> Vec<String> {
        self.due_within(seen, front_only, now, MAX_WINDOWS, BACKGROUND_MAX_AGE)
    }

    /// Like [`due`](Self::due), within what the energy plan allows the timer: at most `limit` windows, and background
    /// windows only once they are older than `max_age` seconds.
    pub fn due_within(&self, seen: &[SeenWindow], front_only: bool, now: f64, limit: usize, max_age: f64) -> Vec<String> {
        seen.iter()
            .filter(|w| !is_excluded(&w.app))
            .take(limit.min(MAX_WINDOWS))
            .filter(|w| {
                let old = self.cache.get(&w.id);
                if w.frontmost {
                    return true;
                }
                match old {
                    None => true,
                    Some(_) if front_only => false,
                    Some(old) => old.title != w.title || now - old.captured > max_age,
                }
            })
            .map(|w| w.id.clone())
            .collect()
    }

    /// Of het venster opnieuw door OCR moet: alleen als de pixels veranderden.
    pub fn needs_text(&self, id: &str, fingerprint: u64) -> bool {
        self.cache.get(id).map(|old| old.fingerprint != fingerprint || old.text.is_empty()).unwrap_or(true)
    }

    /// Verwerkt een ronde: `seen` is de huidige volgorde, `read` wat er net gelezen is (id → tekst en vingerafdruk).
    pub fn update(&mut self, seen: &[SeenWindow], read: HashMap<String, (String, u64)>, now: f64) {
        let mut kept = HashMap::new();
        let mut order = Vec::new();
        for window in seen.iter().filter(|w| !is_excluded(&w.app)).take(MAX_WINDOWS) {
            let old = self.cache.remove(&window.id);
            let entry = match (read.get(&window.id), old) {
                (Some((text, print)), old) => LiveWindow {
                    id: window.id.clone(),
                    app: window.app.clone(),
                    title: window.title.clone(),
                    display: window.display.clone(),
                    text: if text.trim().is_empty() { old.map(|o| o.text).unwrap_or_default() } else { text.clone() },
                    frontmost: window.frontmost,
                    captured: now,
                    fingerprint: *print,
                },
                (None, Some(mut old)) => {
                    old.frontmost = window.frontmost;
                    old.title = window.title.clone();
                    old
                }
                (None, None) => continue,
            };
            order.push(window.id.clone());
            kept.insert(window.id.clone(), entry);
        }
        self.cache = kept;
        self.order = order;
        self.last_update = Some(now);
    }

    /// De vensters met tekst, het voorste eerst.
    pub fn windows(&self) -> Vec<&LiveWindow> {
        self.order.iter().filter_map(|id| self.cache.get(id)).filter(|w| !w.text.trim().is_empty()).collect()
    }

    pub fn front(&self) -> Option<&LiveWindow> {
        self.windows().into_iter().find(|w| w.frontmost)
    }

    pub fn clear(&mut self) {
        self.cache.clear();
        self.order.clear();
        self.last_update = None;
    }

    /// Het aantal schermen met vensters.
    pub fn display_count(&self) -> usize {
        let mut displays: Vec<&str> = self.windows().iter().map(|w| w.display.as_str()).collect();
        displays.sort();
        displays.dedup();
        displays.len()
    }

    /// Alle vensters als tekst: het voorste krijgt het grootste deel, de rest een eerlijk deel.
    pub fn snapshot(&self, total_limit: usize, now: f64) -> Option<ScreenSnapshot> {
        let windows = self.windows();
        if windows.is_empty() {
            return None;
        }
        let multiple = self.display_count() > 1;
        let mut sections = Vec::new();
        let mut remaining = total_limit;
        for (index, window) in windows.iter().enumerate() {
            if remaining <= 200 {
                break;
            }
            let share = if index == 0 { remaining.min((total_limit / 2).max(4000)) } else { remaining.min((total_limit / 6).max(900)) };
            let chunk = prefix(window.text.trim(), share);
            remaining = remaining.saturating_sub(chunk.chars().count());
            let title = if window.title.is_empty() { String::new() } else { format!(" — {}", window.title) };
            let place = if multiple { format!(" · display {}", window.display) } else { String::new() };
            let age = (now - window.captured).max(0.0) as u64;
            let fresh = if age < 5 { String::new() } else { format!(" · read {age}s ago") };
            let label = if window.frontmost { "Frontmost window" } else { "Window" };
            sections.push(format!("### {label}: {}{title}{place}{fresh}\n{chunk}", window.app));
        }
        let screens = self.display_count();
        let label = format!("{} windows{}", windows.len(), if screens > 1 { format!(" across {screens} displays") } else { String::new() });
        Some(ScreenSnapshot { app_name: windows[0].app.clone(), window_title: label, text: sections.join("\n\n") })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(app: &str, title: &str, text: &str, front: bool) -> WindowText {
        WindowText { app: app.into(), title: title.into(), text: text.into(), frontmost: front }
    }

    fn seen(id: &str, app: &str, title: &str, front: bool) -> SeenWindow {
        SeenWindow { id: id.into(), app: app.into(), title: title.into(), display: "1".into(), frontmost: front }
    }

    #[test]
    fn password_managers_and_nook_are_never_read() {
        assert!(is_excluded("KeePassXC"));
        assert!(is_excluded("1Password.exe"));
        assert!(is_excluded("nook"));
        assert!(is_excluded("Wachtwoorden"));
        assert!(!is_excluded("Notepad"));
        assert!(!is_excluded("notebook"));
    }

    #[test]
    fn questions_about_the_screen() {
        assert!(refers_to_screen("zet dit in mijn agenda"));
        assert!(refers_to_screen("Wat staat hier?"));
        assert!(refers_to_screen("maak er een afspraak van"));
        assert!(refers_to_screen("lees mee"));
        assert!(!refers_to_screen("wat is de hoofdstad van Frankrijk"));
    }

    #[test]
    fn all_windows_fit_the_budget_frontmost_first() {
        let long = "x".repeat(9000);
        let windows = vec![window("Firefox", "Nieuws", &long, false), window("Kladblok", "notities.txt", "Bel Lisa om 3 uur", true)];
        let snap = format_all(&windows, 3000).unwrap();
        assert!(snap.text.starts_with("### Frontmost window: Kladblok — notities.txt\nBel Lisa"));
        assert!(snap.text.chars().count() < 3200);
        assert_eq!(snap.app_name, "Kladblok");
        assert_eq!(looked_label(&snap), "Kladblok en 1 ander venster");
        assert!(format_all(&[window("KeePassXC", "", "geheim", true)], 3000).is_none());
    }

    #[test]
    fn live_screen_reads_only_what_changed() {
        let mut live = LiveScreen::default();
        let first = vec![seen("a", "Kladblok", "notities", true), seen("b", "Firefox", "Nieuws", false)];
        assert_eq!(live.due(&first, false, 0.0), vec!["a", "b"]);
        let read = HashMap::from([("a".to_string(), ("Bel Lisa".to_string(), 1)), ("b".to_string(), ("Kop".to_string(), 2))]);
        live.update(&first, read, 0.0);
        assert_eq!(live.due(&first, false, 10.0), vec!["a"], "alleen het voorste, de rest is vers");
        assert_eq!(live.due(&first, false, 40.0), vec!["a", "b"], "ouder dan 30 s");
        assert!(!live.needs_text("a", 1));
        assert!(live.needs_text("a", 9));
        let snap = live.snapshot(12_000, 2.0).unwrap();
        assert!(snap.text.starts_with("### Frontmost window: Kladblok — notities\nBel Lisa"));
        assert_eq!(snap.window_title, "2 windows");
        live.update(&first[..1], HashMap::new(), 3.0);
        assert_eq!(live.windows().len(), 1, "gesloten vensters vallen weg");
    }

    #[test]
    fn taking_it_easy_reads_fewer_and_older_windows() {
        let mut live = LiveScreen::default();
        let first =
            vec![seen("a", "Kladblok", "notities", true), seen("b", "Firefox", "Nieuws", false), seen("c", "Thunderbird", "Inbox", false)];
        assert_eq!(live.due_within(&first, false, 0.0, 2, 90.0), vec!["a", "b"], "only the first few windows");
        let read = HashMap::from([("a".to_string(), ("Bel Lisa".to_string(), 1)), ("b".to_string(), ("Kop".to_string(), 2))]);
        live.update(&first, read, 0.0);
        assert_eq!(live.due_within(&first, false, 40.0, 2, 90.0), vec!["a"], "background windows wait 90 s");
        assert_eq!(live.due_within(&first, false, 100.0, 2, 90.0), vec!["a", "b"]);
    }

    #[test]
    fn fingerprint_ignores_tiny_changes() {
        let mut gray = vec![204u8; 64 * 64];
        let a = fingerprint(&gray, 64, 64);
        gray[10] = 190;
        assert_eq!(a, fingerprint(&gray, 64, 64), "een cursor verandert niets");
        for value in gray.iter_mut().take(64 * 32) {
            *value = 20;
        }
        assert_ne!(a, fingerprint(&gray, 64, 64));
    }
}
