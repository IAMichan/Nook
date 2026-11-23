//! Known Windows Settings pages (`ms-settings:`) and Linux control center panels (GNOME / KDE), with what sits in each
//! one. When Nook opens or guides the user through system settings, it adds the closest pages to the prompt so the
//! brain can open the right page straight away instead of clicking through the main menu (port of macOS `SettingsPanes`).

use serde::Serialize;

/// A system settings page with its Windows `ms-settings:` URI, Linux GNOME/KDE equivalents, and the controls inside it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPane {
    pub id: &'static str,
    pub name: &'static str,
    /// The `ms-settings:` URI that opens this page directly on Windows 10 and 11.
    pub uri: &'static str,
    /// The `gnome-control-center` panel name on Linux.
    pub gnome_panel: &'static str,
    /// The KDE `systemsettings` module name on Linux.
    pub kde_module: &'static str,
    /// What sits on this page, in the words the user sees on screen.
    pub holds: &'static str,
    /// Dutch and English words a task may use when it means this page.
    pub keywords: &'static [&'static str],
}

pub const ALL: &[SettingsPane] = &[
    SettingsPane {
        id: "wifi",
        name: "Wi-Fi",
        uri: "ms-settings:network-wifi",
        gnome_panel: "wifi",
        kde_module: "kcm_networkmanagement",
        holds: "Turn Wi-Fi on or off, current network, known networks, metered connection, random hardware addresses, hotspot",
        keywords: &["wifi", "wi-fi", "draadloos", "wireless", "netwerk", "hotspot", "internet", "ssid"],
    },
    SettingsPane {
        id: "bluetooth",
        name: "Bluetooth & devices",
        uri: "ms-settings:bluetooth",
        gnome_panel: "bluetooth",
        kde_module: "kcm_bluetooth",
        holds: "Turn Bluetooth on or off, paired devices, connect or remove headphones, AirPods, keyboard, mouse, speaker",
        keywords: &["bluetooth", "airpods", "koptelefoon", "headphones", "oordopjes", "earbuds", "speaker", "koppelen", "pair"],
    },
    SettingsPane {
        id: "network",
        name: "Network & internet",
        uri: "ms-settings:network",
        gnome_panel: "network",
        kde_module: "kcm_networkmanagement",
        holds: "Ethernet, VPN, proxy, DNS, firewall, mobile hotspot, airplane mode, data usage, advanced network settings",
        keywords: &["ethernet", "vpn", "firewall", "dns", "ip", "proxy", "netwerk", "network", "vliegtuigstand", "airplane"],
    },
    SettingsPane {
        id: "notifications",
        name: "Notifications",
        uri: "ms-settings:notifications",
        gnome_panel: "notifications",
        kde_module: "kcm_notifications",
        holds: "Notification banners, lock screen notifications, notification sounds, per-app notification toggles, do not disturb rules",
        keywords: &["melding", "meldingen", "notificatie", "notification", "notifications", "banner", "banners", "badge", "badges", "alert"],
    },
    SettingsPane {
        id: "sound",
        name: "Sound",
        uri: "ms-settings:sound",
        gnome_panel: "sound",
        kde_module: "kcm_pulseaudio",
        holds: "Output device (speakers, headphones), output volume, input device (microphone), input volume, spatial audio, volume mixer",
        keywords: &["geluid", "sound", "volume", "speaker", "luidspreker", "microfoon", "microphone", "input", "output", "uitvoer", "invoer", "mute", "dempen", "audio"],
    },
    SettingsPane {
        id: "focus",
        name: "Focus / Do Not Disturb",
        uri: "ms-settings:quiethours",
        gnome_panel: "notifications",
        kde_module: "kcm_notifications",
        holds: "Focus session, Do Not Disturb, quiet hours, priority notifications, automatic rules during screen share or full-screen games",
        keywords: &["focus", "niet storen", "do not disturb", "dnd", "slaap", "werk", "stil", "stille uren", "quiet hours"],
    },
    SettingsPane {
        id: "screen-time",
        name: "Screen Time & family",
        uri: "ms-settings:family-group",
        gnome_panel: "wellbeing",
        kde_module: "kcm_feedback",
        holds: "Screen time limits, app and game limits, downtime schedule, content restrictions, activity reporting",
        keywords: &["schermtijd", "screen time", "applimieten", "app limits", "apparaatvrij", "downtime"],
    },
    SettingsPane {
        id: "about",
        name: "System › About",
        uri: "ms-settings:about",
        gnome_panel: "system",
        kde_module: "kcm_about-distro",
        holds: "Device name, processor, installed RAM, Windows edition and version, system type, rename this PC, device encryption",
        keywords: &["algemeen", "general", "info", "about", "over deze", "versie", "version", "chip", "geheugen", "serienummer", "pc-naam", "computer name"],
    },
    SettingsPane {
        id: "windows-update",
        name: "Windows Update",
        uri: "ms-settings:windowsupdate",
        gnome_panel: "system",
        kde_module: "kcm_updates",
        holds: "Check for updates, download and install updates, pause updates, active hours, update history, Insider Program",
        keywords: &["update", "updates", "software-update", "software update", "windows update", "bijwerken", "updaten", "upgrade"],
    },
    SettingsPane {
        id: "storage",
        name: "Storage",
        uri: "ms-settings:storagesense",
        gnome_panel: "system",
        kde_module: "kcm_disks",
        holds: "Disk usage breakdown, Temporary files, Storage Sense automatic cleanup, installed apps size, cleanup recommendations",
        keywords: &["opslag", "storage", "schijf", "disk", "ruimte", "space", "vol", "opruimen", "prullenbak", "storagesense"],
    },
    SettingsPane {
        id: "nearby-sharing",
        name: "Nearby sharing",
        uri: "ms-settings:crossdevice",
        gnome_panel: "sharing",
        kde_module: "kcm_kdeconnect",
        holds: "Nearby sharing (Off, My devices only, Everyone nearby), save received files folder, Phone Link and cross-device experience",
        keywords: &["airdrop", "handoff", "nearby sharing", "nabij delen", "doorgeven", "universeel klembord", "universal clipboard", "phone link"],
    },
    SettingsPane {
        id: "startup",
        name: "Startup Apps",
        uri: "ms-settings:startupapps",
        gnome_panel: "applications",
        kde_module: "kcm_autostart",
        holds: "Apps that start automatically when you sign in, startup impact (high, medium, low), enable or disable login items",
        keywords: &["inlogonderdelen", "login items", "opstarten", "startup", "automatisch starten", "achtergrond", "background", "extensies", "autostart"],
    },
    SettingsPane {
        id: "region",
        name: "Language & region",
        uri: "ms-settings:regionlanguage",
        gnome_panel: "region",
        kde_module: "kcm_regionandlang",
        holds: "Windows display language, preferred languages, country or region, regional format, keyboard layout, temperature and measurement units",
        keywords: &["taal", "language", "regio", "region", "temperatuur", "celsius", "fahrenheit", "eenheden", "datumnotatie", "locale"],
    },
    SettingsPane {
        id: "date-time",
        name: "Date & time",
        uri: "ms-settings:dateandtime",
        gnome_panel: "system",
        kde_module: "kcm_clock",
        holds: "Set time automatically, set time zone automatically, time zone picker, sync clock now, additional clocks, 24-hour time format",
        keywords: &["datum", "tijd", "date", "time", "tijdzone", "timezone", "klok", "clock", "24-uurs"],
    },
    SettingsPane {
        id: "sharing",
        name: "Sharing & Remote Desktop",
        uri: "ms-settings:remotedesktop",
        gnome_panel: "sharing",
        kde_module: "kcm_smb",
        holds: "Remote Desktop, computer name on the local network, file and printer sharing, network profile (private or public)",
        keywords: &["delen", "sharing", "computernaam", "hostname", "schermdeling", "bestandsdeling", "ssh", "remote login", "remote desktop"],
    },
    SettingsPane {
        id: "backup",
        name: "Windows Backup",
        uri: "ms-settings:backup",
        gnome_panel: "system",
        kde_module: "kcm_kup",
        holds: "Folder backup, remember my apps and preferences, File History backup disk, restore from a previous backup",
        keywords: &["time machine", "back-up", "backup", "reservekopie", "file history"],
    },
    SettingsPane {
        id: "appearance",
        name: "Personalization › Colors",
        uri: "ms-settings:colors",
        gnome_panel: "appearance",
        kde_module: "kcm_colors",
        holds: "Choose your mode (Light, Dark, Custom), transparency effects, accent color, show accent color on Start and taskbar or title bars",
        keywords: &["weergave", "appearance", "donker", "dark", "dark mode", "donkere modus", "licht", "light", "light mode", "lichte modus", "accentkleur", "accent", "schuifbalk", "scrollbar", "kleuren", "colors"],
    },
    SettingsPane {
        id: "accessibility",
        name: "Accessibility",
        uri: "ms-settings:easeofaccess",
        gnome_panel: "universal-access",
        kde_module: "kcm_access",
        holds: "Text size, magnifier, high contrast themes, Narrator screen reader, live captions, sticky keys, mouse keys, visual effects",
        keywords: &["toegankelijkheid", "accessibility", "voiceover", "narrator", "zoom", "zoomen", "contrast", "beweging", "reduce motion", "transparantie", "grotere tekst", "voorlezen", "captions"],
    },
    SettingsPane {
        id: "taskbar",
        name: "Taskbar & System Tray",
        uri: "ms-settings:taskbar",
        gnome_panel: "multitasking",
        kde_module: "kcm_plasmasearch",
        holds: "Taskbar items (Search, Task View, Widgets), system tray icons, other system tray icons, taskbar alignment (Center or Left), auto-hide taskbar, show seconds in system tray clock",
        keywords: &["bedieningspaneel", "control center", "menubalk", "menu bar", "taakbalk", "taskbar", "systeemvak", "system tray", "dock", "batterijpercentage", "battery percentage", "klokopties"],
    },
    SettingsPane {
        id: "privacy",
        name: "Privacy & security",
        uri: "ms-settings:privacy",
        gnome_panel: "privacy",
        kde_module: "kcm_privacy",
        holds: "Windows Security, virus & threat protection, location, camera, microphone, voice activation, notifications, account info, file system access",
        keywords: &["privacy", "beveiliging", "security", "locatie", "location", "camera", "microfoon", "schermopname", "screen recording", "filevault", "bitlocker", "toestemming", "permission", "machtigingen"],
    },
    SettingsPane {
        id: "microphone-privacy",
        name: "Privacy › Microphone",
        uri: "ms-settings:privacy-microphone",
        gnome_panel: "privacy",
        kde_module: "kcm_pulseaudio",
        holds: "Microphone access for this device, allow apps to access your microphone, allow desktop apps to access your microphone",
        keywords: &["microfoontoegang", "microphone access", "microphone permission", "microfoon machtiging", "privacy microphone"],
    },
    SettingsPane {
        id: "camera-privacy",
        name: "Privacy › Camera",
        uri: "ms-settings:privacy-webcam",
        gnome_panel: "privacy",
        kde_module: "kcm_privacy",
        holds: "Camera access for this device, allow apps to access your camera, allow desktop apps to access your camera, camera effects",
        keywords: &["cameratoegang", "camera access", "webcam", "camera permission", "camera machtiging"],
    },
    SettingsPane {
        id: "multitasking",
        name: "Multitasking & Desktops",
        uri: "ms-settings:multitasking",
        gnome_panel: "multitasking",
        kde_module: "kcm_kwinoptions",
        holds: "Snap windows, virtual desktops, Alt+Tab window switcher behavior, title bar window shake, hot corners",
        keywords: &["dock", "stage manager", "mission control", "multitasking", "snap", "vensters", "virtual desktop", "bureaubladen", "spaces", "hot corners", "actieve hoeken", "minimaliseren", "automatisch verbergen"],
    },
    SettingsPane {
        id: "default-apps",
        name: "Apps › Default apps",
        uri: "ms-settings:defaultapps",
        gnome_panel: "applications",
        kde_module: "kcm_componentchooser",
        holds: "Default web browser, default email app, default music and video player, choose defaults by file type or link type",
        keywords: &["standaardbrowser", "default browser", "default apps", "standaard-apps", "standaardprogramma", "openen met"],
    },
    SettingsPane {
        id: "displays",
        name: "Display",
        uri: "ms-settings:display",
        gnome_panel: "display",
        kde_module: "kcm_kscreen",
        holds: "Brightness, Night light, HDR, scale & layout (100%, 125%, 150%), display resolution, orientation, refresh rate (Hz), multiple displays arrangement",
        keywords: &["scherm", "beeldscherm", "beeldschermen", "display", "displays", "monitor", "resolutie", "resolution", "helder", "helderheid", "brightness", "night shift", "night light", "nachtlamp", "true tone", "verversingssnelheid", "refresh rate", "hz", "schalen", "scale", "rangschikken"],
    },
    SettingsPane {
        id: "wallpaper",
        name: "Personalization › Background",
        uri: "ms-settings:personalization-background",
        gnome_panel: "background",
        kde_module: "kcm_wallpaper",
        holds: "Personalize your background (Picture, Solid color, Slideshow, Windows spotlight), choose a photo, fit (Fill, Fit, Stretch, Tile, Center, Span)",
        keywords: &["achtergrond", "wallpaper", "bureaubladachtergrond", "desktop picture", "background"],
    },
    SettingsPane {
        id: "screensaver",
        name: "Screen Saver",
        uri: "ms-settings:lockscreen",
        gnome_panel: "privacy",
        kde_module: "kcm_screenlocker",
        holds: "Screen saver choice, wait time before starting, on resume display logon screen",
        keywords: &["schermbeveiliging", "screen saver", "screensaver"],
    },
    SettingsPane {
        id: "battery",
        name: "Power & battery",
        uri: "ms-settings:powersleep",
        gnome_panel: "power",
        kde_module: "kcm_powerdevilprofilesconfig",
        holds: "Screen and sleep timeouts, power mode (Best power efficiency, Balanced, Best performance), battery saver / Energy Saver, battery usage per app, lid close action",
        keywords: &["batterij", "battery", "energie", "power", "opladen", "charging", "energiebesparing", "low power mode", "battery saver", "slaapstand", "sleep", "adapter"],
    },
    SettingsPane {
        id: "lock-screen",
        name: "Lock screen",
        uri: "ms-settings:lockscreen",
        gnome_panel: "privacy",
        kde_module: "kcm_screenlocker",
        holds: "Lock screen background (Windows spotlight, picture, slideshow), lock screen status app, screen timeout and screen saver settings",
        keywords: &["toegangsscherm", "lock screen", "vergrendel", "lock", "scherm uitschakelen", "wachtwoord vragen"],
    },
    SettingsPane {
        id: "signin-options",
        name: "Accounts › Sign-in options",
        uri: "ms-settings:signinoptions",
        gnome_panel: "users",
        kde_module: "kcm_users",
        holds: "Windows Hello Face, Windows Hello Fingerprint, PIN, security key, password, dynamic lock, require sign-in after waking from sleep",
        keywords: &["touch id", "windows hello", "vingerafdruk", "fingerprint", "wachtwoord", "password", "pincode", "pin", "sign-in", "inlogopties"],
    },
    SettingsPane {
        id: "users",
        name: "Accounts › Other users",
        uri: "ms-settings:otherusers",
        gnome_panel: "users",
        kde_module: "kcm_users",
        holds: "Your Microsoft or local account, family and other users, add account, change account type (Administrator or Standard user)",
        keywords: &["gebruikers", "users", "account", "gastgebruiker", "guest", "beheerder", "admin", "administrator"],
    },
    SettingsPane {
        id: "keyboard",
        name: "Keyboard",
        uri: "ms-settings:keyboard",
        gnome_panel: "keyboard",
        kde_module: "kcm_keyboard",
        holds: "Key repeat rate and delay, keyboard shortcuts, input language hotkeys, touch keyboard, typing insights and autocorrect",
        keywords: &["toetsenbord", "keyboard", "sneltoets", "sneltoetsen", "shortcut", "shortcuts", "herhaalsnelheid", "key repeat", "autocorrectie", "autocorrect", "dicteren", "dictation", "fn", "caps lock"],
    },
    SettingsPane {
        id: "mouse",
        name: "Mouse",
        uri: "ms-settings:mousetouchpad",
        gnome_panel: "mouse",
        kde_module: "kcm_Libinput",
        holds: "Primary mouse button (Left or Right), mouse pointer speed, roll the mouse wheel to scroll (multiple lines or one screen), scroll direction, pointer size and color",
        keywords: &["muis", "mouse", "scrollen", "scroll", "aanwijzer", "cursor", "pointer", "dubbelklik", "primaire knop"],
    },
    SettingsPane {
        id: "touchpad",
        name: "Touchpad",
        uri: "ms-settings:devices-touchpad",
        gnome_panel: "mouse",
        kde_module: "kcm_touchpad",
        holds: "Touchpad on or off, cursor speed, tap with a single finger to single-click, tap with two fingers to right-click, two-finger scroll direction (natural scrolling), three- and four-finger gestures",
        keywords: &["trackpad", "touchpad", "tik om te klikken", "tap to click", "natuurlijk scrollen", "natural scrolling", "veeg", "swipe", "gebaren", "gestures"],
    },
    SettingsPane {
        id: "printers",
        name: "Printers & scanners",
        uri: "ms-settings:printers",
        gnome_panel: "printers",
        kde_module: "kcm_printer_manager",
        holds: "Add printer or scanner, default printer, print queue, printer preferences, Let Windows manage my default printer",
        keywords: &["printer", "printers", "scanner", "afdrukken", "print"],
    },
];

/// Returns every known system settings page.
pub fn all() -> &'static [SettingsPane] {
    ALL
}

/// True when `uri` is a Windows `ms-settings:` deep link or a macOS `x-apple.systempreferences:` link.
pub fn is_settings_uri(uri: &str) -> bool {
    let trimmed = uri.trim();
    trimmed.starts_with("ms-settings:") || trimmed.starts_with("x-apple.systempreferences:")
}

/// Finds a settings page by its id, exact `ms-settings:` URI, or display name.
pub fn find(id_or_uri: &str) -> Option<&'static SettingsPane> {
    let needle = id_or_uri.trim().to_lowercase();
    if needle.is_empty() {
        return None;
    }
    ALL.iter().find(|p| {
        p.id.eq_ignore_ascii_case(&needle)
            || p.uri.eq_ignore_ascii_case(&needle)
            || p.name.to_lowercase() == needle
    })
}

/// The settings pages that best match a task description, scored by keyword and control matches.
pub fn matching(task: &str, limit: usize) -> Vec<&'static SettingsPane> {
    if limit == 0 {
        return Vec::new();
    }
    let low = task.to_lowercase();
    let words: Vec<&str> = low
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();

    let mut scored: Vec<(&'static SettingsPane, i32)> = ALL
        .iter()
        .filter_map(|pane| {
            let mut score = 0i32;
            for &kw in pane.keywords {
                if kw.contains(' ') || kw.contains('-') {
                    if low.contains(kw) {
                        score += 4;
                    }
                } else if words.contains(&kw) {
                    score += 4;
                } else if kw.len() >= 4 && words.iter().any(|w| w.starts_with(kw) || kw.starts_with(w)) {
                    score += 2;
                }
            }
            for word in &words {
                if word.len() >= 4 && pane.holds.to_lowercase().contains(word) {
                    score += 1;
                }
            }
            (score > 0).then_some((pane, score))
        })
        .collect();

    scored.sort_by(|a, b| b.1.cmp(&a.1));
    scored.into_iter().take(limit).map(|(p, _)| p).collect()
}

/// Prompt hint for the brain when a task is about OS settings, so it can open the right page straight away.
pub fn guide(task: &str) -> String {
    let hits = matching(task, 5);
    let mut lines = vec![
        "For Windows Settings: open the right page directly with `open_url` and its `ms-settings:` URI instead of clicking through the Settings sidebar.".to_string(),
    ];
    if !hits.is_empty() {
        lines.push("Pages matching this task:".to_string());
        for pane in hits {
            lines.push(format!(
                "- {}: `{}` (Linux GNOME: `gnome-control-center {}`, KDE: `systemsettings {}`) — {}",
                pane.name, pane.uri, pane.gnome_panel, pane.kde_module, pane.holds
            ));
        }
    } else {
        lines.push("Common pages: `ms-settings:colors` (Appearance / Dark mode), `ms-settings:display` (Display), `ms-settings:sound` (Sound), `ms-settings:bluetooth` (Bluetooth), `ms-settings:network-wifi` (Wi-Fi), `ms-settings:devices-touchpad` (Touchpad), `ms-settings:keyboard` (Keyboard), `ms-settings:powersleep` (Power & battery), `ms-settings:privacy` (Privacy & security), `ms-settings:taskbar` (Taskbar).".to_string());
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_pane_for_common_dutch_and_english_tasks() {
        assert_eq!(matching("Zet dark mode aan", 3).first().map(|p| p.id), Some("appearance"));
        assert_eq!(matching("Zet donkere modus aan in systeeminstellingen", 3).first().map(|p| p.id), Some("appearance"));
        assert_eq!(matching("Turn on night light on my display", 3).first().map(|p| p.id), Some("displays"));
        assert_eq!(matching("Zet natuurlijk scrollen uit op mijn touchpad", 3).first().map(|p| p.id), Some("touchpad"));
        assert_eq!(matching("Verbind mijn AirPods via bluetooth", 3).first().map(|p| p.id), Some("bluetooth"));
        assert_eq!(matching("Show battery percentage in taskbar", 3).first().map(|p| p.id), Some("taskbar"));
        assert_eq!(matching("Check for Windows updates", 3).first().map(|p| p.id), Some("windows-update"));
        assert_eq!(matching("Geef microfoontoegang aan Nook", 3).first().map(|p| p.id), Some("microphone-privacy"));
    }

    #[test]
    fn every_pane_has_valid_ms_settings_uri_and_linux_targets() {
        for pane in all() {
            assert!(pane.uri.starts_with("ms-settings:"), "{} URI must start with ms-settings:", pane.id);
            assert!(!pane.name.is_empty());
            assert!(!pane.holds.is_empty());
            assert!(!pane.keywords.is_empty());
            assert!(!pane.gnome_panel.is_empty());
            assert!(!pane.kde_module.is_empty());
            assert!(is_settings_uri(pane.uri));
        }
    }

    #[test]
    fn find_looks_up_by_id_uri_and_name() {
        assert_eq!(find("appearance").map(|p| p.uri), Some("ms-settings:colors"));
        assert_eq!(find("ms-settings:display").map(|p| p.id), Some("displays"));
        assert_eq!(find("Sound").map(|p| p.id), Some("sound"));
        assert_eq!(find(""), None);
    }

    #[test]
    fn guide_includes_direct_uri_and_contents() {
        let g = guide("Maak mijn scherm helderder");
        assert!(g.contains("ms-settings:display"));
        assert!(g.contains("Brightness"));
    }
}
