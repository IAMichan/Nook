import Foundation

// Where things are in System Settings (macOS 13 and later): the pane, the link that opens it straight away, and what a
// person finds there. A task Nook takes over ("zet Night Shift aan", "verander mijn standaardbrowser", "laat het
// batterijpercentage zien") gets the panes that fit it, so Nook opens the right place at once and knows which button
// leads further, instead of searching the sidebar.

struct SettingsPane: Equatable {
    /// The id after `x-apple.systempreferences:`.
    var id: String
    /// The pane's title, in English first.
    var name: String
    /// What is there, in English, for the brain: options, sub-pages, the button that opens a sheet.
    var holds: String
    /// Words a request about this pane uses, in every language Nook speaks; matched as the start of a word.
    var keywords: [String]

    var url: String { "x-apple.systempreferences:" + id }
}

enum SettingsPanes {
    static let all: [SettingsPane] = [
        SettingsPane(id: "com.apple.wifi-settings-extension", name: "Wi-Fi",
                     holds: "Wi-Fi on/off switch, networks, \"Details…\" per network (IP, DNS, forget this network). Turning Wi-Fi on or off now is quicker in Control Center.",
                     keywords: ["wifi", "wi-fi", "wlan", "netwerk", "network", "réseau", "draadloos", "wireless"]),
        SettingsPane(id: "com.apple.BluetoothSettings", name: "Bluetooth",
                     holds: "Bluetooth switch, devices (connect, disconnect, \"ⓘ\" for options, forget).",
                     keywords: ["bluetooth", "airpods", "koptelefoon", "headphones", "kopfhörer", "écouteurs", "auriculares", "speaker"]),
        SettingsPane(id: "com.apple.Network-Settings.extension", name: "Network",
                     holds: "Ethernet, VPN, firewall, \"…\" menu for locations and services.",
                     keywords: ["ethernet", "vpn", "firewall", "proxy", "dns", "ip-adres", "ip address"]),
        SettingsPane(id: "com.apple.Notifications-Settings.extension", name: "Notifications",
                     holds: "Notification previews, and per app: allow notifications, banners or alerts, sounds, badges.",
                     keywords: ["melding", "notificati", "notification", "mitteilung", "benachrichtigung", "notificación", "badge", "banner"]),
        SettingsPane(id: "com.apple.Sound-Settings.extension", name: "Sound",
                     holds: "Output and input devices, output volume, alert sound, play sound on startup, sound effects.",
                     keywords: ["geluid", "sound", "sonido", "volume", "lautstärke", "microfoon", "microphone", "mikrofon", "speaker", "luidspreker", "alert", "waarschuwingsgeluid"]),
        SettingsPane(id: "com.apple.Focus-Settings.extension", name: "Focus",
                     holds: "Focus modes (Do Not Disturb, Sleep, Work), their schedules, allowed people and apps. Turning a Focus on now is done in Control Center.",
                     keywords: ["focus", "fokus", "concentratie", "concentration", "concentración", "niet storen", "do not disturb", "nicht stören", "ne pas déranger", "no molestar"]),
        SettingsPane(id: "com.apple.Screen-Time-Settings.extension", name: "Screen Time",
                     holds: "App and website activity, downtime, app limits, content and privacy.",
                     keywords: ["schermtijd", "screen time", "bildschirmzeit", "temps d'écran", "tiempo de uso", "app limit", "downtime"]),
        SettingsPane(id: "com.apple.systempreferences.GeneralSettings", name: "General",
                     holds: "Sub-pages: About, Software Update, Storage, AirDrop & Handoff, Login Items & Extensions, Language & Region, Date & Time, Sharing, Time Machine, Transfer or Reset, Startup Disk.",
                     keywords: ["algemeen", "general", "allgemein", "général", "generales"]),
        SettingsPane(id: "com.apple.Software-Update-Settings.extension", name: "Software Update",
                     holds: "Check for updates, \"Update Now\", automatic updates (ⓘ).",
                     keywords: ["bijwerk", "software", "aktualisier", "mise à jour", "actualiza", "macos"]),
        SettingsPane(id: "com.apple.settings.Storage", name: "Storage",
                     holds: "Disk usage per category, recommendations, empty Trash automatically.",
                     keywords: ["opslag", "storage", "speicher", "stockage", "almacenamiento", "schijfruimte", "disk space"]),
        SettingsPane(id: "com.apple.AirDrop-Handoff-Settings.extension", name: "AirDrop & Handoff",
                     holds: "AirDrop receiving (Contacts Only, Everyone for 10 minutes), Handoff, AirPlay Receiver.",
                     keywords: ["airdrop", "handoff", "airplay"]),
        SettingsPane(id: "com.apple.LoginItems-Settings.extension", name: "Login Items & Extensions",
                     holds: "Apps that open at login (+ and −), apps allowed in the background, extensions.",
                     keywords: ["inlog", "login", "anmelde", "ouverture", "inicio de sesión", "opstart", "startup", "achtergrond", "background"]),
        SettingsPane(id: "com.apple.Localization-Settings.extension", name: "Language & Region",
                     holds: "Preferred languages, region, calendar, temperature, measurement system, first day of week, date and number format, per-app languages.",
                     keywords: ["taal", "language", "sprache", "langue", "idioma", "regio", "region", "région", "región", "datumnotatie", "date format", "temperatu", "celsius", "fahrenheit"]),
        SettingsPane(id: "com.apple.Date-Time-Settings.extension", name: "Date & Time",
                     holds: "Set time automatically, time zone, 24-hour time.",
                     keywords: ["datum", "date", "tijd", "time", "uhrzeit", "heure", "hora", "tijdzone", "time zone", "zeitzone", "24-uurs", "24-hour"]),
        SettingsPane(id: "com.apple.Sharing-Settings.extension", name: "Sharing",
                     holds: "Computer name (\"Local hostname\" under Edit…), File Sharing, Screen Sharing, Remote Login, Media Sharing.",
                     keywords: ["delen", "sharing", "freigabe", "partage", "compartir", "computernaam", "computer name", "hostname", "scherm delen", "screen sharing", "remote"]),
        SettingsPane(id: "com.apple.Time-Machine-Settings.extension", name: "Time Machine",
                     holds: "Backup disks (+ to add), back up automatically, options.",
                     keywords: ["time machine", "backup", "reservekopie", "sicherung", "sauvegarde", "copia de seguridad"]),
        SettingsPane(id: "com.apple.Appearance-Settings.extension", name: "Appearance",
                     holds: "Light, Dark or Auto, accent and highlight colour, sidebar icon size, scroll bars, click in the scroll bar.",
                     keywords: ["weergave", "appearance", "erscheinungsbild", "apparence", "apariencia", "donker", "dark", "dunkel", "sombre", "oscuro", "licht", "light", "accentkleur", "accent", "scrollbalk", "scroll bar"]),
        SettingsPane(id: "com.apple.Accessibility-Settings.extension", name: "Accessibility",
                     holds: "VoiceOver, Zoom, Display (reduce motion, increase contrast, pointer size), Spoken Content, Keyboard, Pointer Control.",
                     keywords: ["toegankelijk", "accessib", "bedienungshilfen", "accessibilité", "accesibilidad", "voiceover", "contrast", "kontrast", "beweging", "motion", "aanwijzer", "pointer", "cursorgrootte", "cursor size"]),
        SettingsPane(id: "com.apple.ControlCenter-Settings.extension", name: "Control Center",
                     holds: "Which items show in the menu bar (Wi-Fi, Bluetooth, Sound, Focus, Battery with \"Show Percentage\", Clock options), automatically hide the menu bar.",
                     keywords: ["bedieningspaneel", "control center", "kontrollzentrum", "centre de contrôle", "centro de control", "menubalk", "menu bar", "menüleiste", "percentage", "prozent", "pourcentage", "porcentaje", "klok", "clock"]),
        SettingsPane(id: "com.apple.Siri-Settings.extension", name: "Siri / Apple Intelligence & Siri",
                     holds: "Siri on/off, keyboard shortcut, voice, language; Spotlight results on older versions.",
                     keywords: ["siri", "apple intelligence", "spotlight"]),
        SettingsPane(id: "com.apple.settings.PrivacySecurity.extension", name: "Privacy & Security",
                     holds: "Location Services, Contacts, Calendars, Camera, Microphone, Accessibility, Full Disk Access, Screen Recording, Automation per app; FileVault, Lockdown Mode, allow apps from.",
                     keywords: ["privacy", "beveiliging", "security", "datenschutz", "sicherheit", "confidentialité", "sécurité", "privacidad", "seguridad", "locatie", "location", "standort", "camera", "kamera", "microfoon", "filevault", "schijftoegang", "disk access", "schermopname", "screen recording"]),
        SettingsPane(id: "com.apple.Desktop-Settings.extension", name: "Desktop & Dock",
                     holds: "Dock size, magnification, position on screen, automatically hide the Dock, minimise effect, show recent apps; Stage Manager; default web browser; Mission Control; \"Hot Corners…\" button.",
                     keywords: ["dock", "bureaublad", "desktop", "schreibtisch", "bureau", "escritorio", "standaardbrowser", "default browser", "standardbrowser", "navigateur par défaut", "navegador predeterminado", "hoeken", "hot corner", "stage manager", "mission control", "verbergen", "hide"]),
        SettingsPane(id: "com.apple.Displays-Settings.extension", name: "Displays",
                     holds: "Brightness, automatically adjust brightness, True Tone, resolution (\"Larger Text\" to \"More Space\"), arrangement, \"Night Shift…\" button (schedule, turn on until tomorrow, colour temperature), refresh rate.",
                     keywords: ["beeldscherm", "display", "monitor", "bildschirm", "écran", "pantalla", "helderheid", "brightness", "helligkeit", "luminosité", "brillo", "night shift", "nachtmodus", "true tone", "resolutie", "resolution", "auflösung", "résolution", "resolución"]),
        SettingsPane(id: "com.apple.Wallpaper-Settings.extension", name: "Wallpaper",
                     holds: "Desktop pictures, dynamic wallpapers, colours, \"Add Folder…\".",
                     keywords: ["achtergrond", "wallpaper", "hintergrund", "fond d'écran", "fondo de pantalla", "bureaubladachtergrond"]),
        SettingsPane(id: "com.apple.ScreenSaver-Settings.extension", name: "Screen Saver",
                     holds: "Screen savers, show as wallpaper.",
                     keywords: ["schermbeveiliging", "screen saver", "screensaver", "bildschirmschoner", "économiseur", "salvapantallas"]),
        SettingsPane(id: "com.apple.Battery-Settings.extension", name: "Battery / Energy",
                     holds: "Low Power Mode, battery health, \"Options…\" (wake for network access, prevent automatic sleeping); Energy on desktop Macs.",
                     keywords: ["batterij", "battery", "batterie", "batería", "energie", "energy", "énergie", "energía", "stroom", "low power", "energiebesparing", "slaapstand", "sleep"]),
        SettingsPane(id: "com.apple.Lock-Screen-Settings.extension", name: "Lock Screen",
                     holds: "Start screen saver when inactive, turn display off when inactive, require password after sleep, show user name and photo, show message.",
                     keywords: ["vergrendel", "lock screen", "sperrbildschirm", "écran verrouillé", "pantalla bloqueada", "inactief", "inactive", "scherm uit", "display off"]),
        SettingsPane(id: "com.apple.Touch-ID-Settings.extension", name: "Touch ID & Password",
                     holds: "Fingerprints, use Touch ID for unlocking and Apple Pay. Passwords are the user's to type.",
                     keywords: ["touch id", "vingerafdruk", "fingerprint", "fingerabdruck", "empreinte", "huella"]),
        SettingsPane(id: "com.apple.Users-Groups-Settings.extension", name: "Users & Groups",
                     holds: "Users (ⓘ for details), guest user, automatic login.",
                     keywords: ["gebruiker", "user", "benutzer", "utilisateur", "usuario", "gast", "guest", "account"]),
        SettingsPane(id: "com.apple.Internet-Accounts-Settings.extension", name: "Internet Accounts",
                     holds: "Mail, calendar and contacts accounts (iCloud, Google, Exchange) and what each syncs.",
                     keywords: ["internetaccount", "internet accounts", "internetaccounts", "comptes internet", "cuentas de internet", "google account", "exchange"]),
        SettingsPane(id: "com.apple.Keyboard-Settings.extension", name: "Keyboard",
                     holds: "Key repeat rate, delay until repeat, keyboard brightness, press 🌐 key to, \"Keyboard Shortcuts…\" button, Text Input \"Edit…\" (input sources, correct spelling, capitalise), Dictation.",
                     keywords: ["toetsenbord", "keyboard", "tastatur", "clavier", "teclado", "sneltoets", "shortcut", "kurzbefehl", "raccourci", "atajo", "dicteer", "dictation", "diktat", "dictée", "dictado", "autocorrect", "spelling", "invoerbron", "input source", "toetsherhaling", "key repeat"]),
        SettingsPane(id: "com.apple.Mouse-Settings.extension", name: "Mouse",
                     holds: "Tracking speed, natural scrolling, secondary click, double-click speed.",
                     keywords: ["muis", "mouse", "maus", "souris", "ratón", "raton", "natuurlijk scrollen", "natural scrolling", "scroll"]),
        SettingsPane(id: "com.apple.Trackpad-Settings.extension", name: "Trackpad",
                     holds: "Tabs Point & Click (tap to click, secondary click, tracking speed, force click), Scroll & Zoom (natural scrolling), More Gestures.",
                     keywords: ["trackpad", "tik om te klikken", "tap to click", "tippen zum klicken", "toucher pour cliquer", "tocar para hacer clic", "gebaren", "gestures", "gesten", "gestes", "gestos", "natuurlijk scrollen", "natural scrolling"]),
        SettingsPane(id: "com.apple.Print-Scan-Settings.extension", name: "Printers & Scanners",
                     holds: "Printers and scanners (\"Add Printer, Scanner or Fax…\"), default printer, default paper size.",
                     keywords: ["printer", "drucker", "imprimante", "impresora", "scanner", "afdruk", "print"])
    ]

    /// The panes a task is about, best first: those whose keywords it uses most. Empty when it is not about a setting.
    static func matching(_ task: String, limit: Int = 3) -> [SettingsPane] {
        let lowered = " " + task.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }
            .joined(separator: " ") + " "
        let scored = all.enumerated().compactMap { index, pane -> (pane: SettingsPane, score: Int, index: Int)? in
            let words = pane.keywords + [pane.name.lowercased()]
            let score = words.reduce(0) { total, word in
                lowered.contains(" " + word.lowercased()) ? total + (word.contains(" ") ? 2 : 1) : total
            }
            return score > 0 ? (pane, score, index) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map(\.pane)
    }

    /// Lines for a task's prompt: where in System Settings it probably is, with the link to open it. Empty when no pane fits.
    static func guide(for task: String) -> String {
        let panes = matching(task)
        guard !panes.isEmpty else { return "" }
        var lines = ["Where this probably is in System Settings (open it with control_ui action open and this url, then read_ui):"]
        lines += panes.map { "- \($0.name): \($0.url) — \($0.holds)" }
        return lines.joined(separator: "\n")
    }
}
