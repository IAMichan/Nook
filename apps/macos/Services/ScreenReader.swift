import Foundation
import AppKit
import ScreenCaptureKit
import Vision

struct ScreenSnapshot {
    var appName: String
    var windowTitle: String
    var text: String
}

enum ScreenError: LocalizedError {
    case noPermission
    case excluded(String)
    case nothing

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Nook does not have screen recording permission yet. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, and restart Nook. Is it already on? Remove Nook from that list with −, add it again and restart Nook."
        case .excluded(let app):
            return "I don't look inside \(app)."
        case .nothing:
            return "I don't see anything to read."
        }
    }
}

/// Captures a snapshot of the frontmost window and reads text within it (on-device OCR).
/// The image never leaves your Mac; only recognized text may be sent to the model.
@MainActor
final class ScreenReader {
    /// Password managers and Nook itself, plus the apps the user picked in Settings › Privacy, are never read: not by OCR,
    /// not through accessibility, not through scripting.
    nonisolated static var excludedBundles: Set<String> {
        builtInExcluded.union(UserDefaults.standard.stringArray(forKey: AppSettings.neverReadAppsKey) ?? [])
    }

    /// Password managers and Nook itself: always excluded, whatever the settings say.
    nonisolated static let builtInExcluded: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane",
        "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop", "org.keepassxc.keepassxc", "com.keepassium.ios",
        "in.sinew.Enpass-Desktop", "in.sinew.Enpass7", "me.proton.pass.electron", "ch.protonmail.pass", "com.nordpass.macos.NordPass",
        "com.roboform.mac", "com.keeper.keeper", "com.apple.SecurityAgent", "nl.imdigital.nook"
    ]

    func capture() async throws -> ScreenSnapshot {
        // No CGRequestScreenCaptureAccess here: this runs without the user asking (think-along, the brain's read_screen),
        // and a build macOS no longer matches to its switch would get the system prompt on every read.
        guard ScreenAccess.isUsable else { throw ScreenError.noPermission }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenError.nothing }
        let appName = app.localizedName ?? "this app"
        if let bundle = app.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(appName)
        }

        let content = try await Self.shareableContent()
        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200
        }
        let target = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        let configuration = SCStreamConfiguration()
        let image: CGImage
        if let window = target {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.width = min(Int(window.frame.width * 1.5), 2400)
            configuration.height = min(Int(window.frame.height * 1.5), 2400)
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } else if let display = content.displays.first {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            configuration.width = min(Int(Double(display.width) * 1.5), 2400)
            configuration.height = min(Int(Double(display.height) * 1.5), 2400)
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } else {
            throw ScreenError.nothing
        }

        let text = try await Self.recognize(image, fast: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScreenError.nothing }
        return ScreenSnapshot(appName: appName, windowTitle: target?.title ?? "", text: String(text.prefix(6000)))
    }

    /// Apps that are open now (regular Dock apps), excluding Nook and apps Nook never looks into.
    static func openApps() -> [NSRunningApplication] {
        let excluded = excludedBundles
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !excluded.contains(app.bundleIdentifier ?? "")
        }
    }

    /// Folders where Nook looks for apps that are closed.
    private static var appFolders: [URL] {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                       URL(fileURLWithPath: "/Applications/Utilities"), URL(fileURLWithPath: "/System/Applications/Utilities")]
        folders.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return folders
    }

    /// Finds an installed app by name, also in the Mac's language ("Notities" finds Notes.app).
    static func installedApp(named query: String) -> URL? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let fm = FileManager.default
        var loose: URL?
        for folder in appFolders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                let file = url.deletingPathExtension().lastPathComponent.lowercased()
                let shown = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension.lowercased()
                if file == wanted || shown == wanted { return url }
                if loose == nil, file.contains(wanted) || shown.contains(wanted) { loose = url }
            }
        }
        return loose
    }

    /// Reads one app entirely in the background: the user sees nothing. `query` is the name ("Notes", "Slack")
    /// or part of the bundle id.
    /// - Nook reads through the macOS accessibility layer, so hidden apps and covered windows work too.
    /// - If the app is closed, Nook launches it hidden (no window, not frontmost), reads it and quits it again.
    /// - Nothing is ever shown, activated or unhidden. Only without Accessibility permission does Nook fall back to
    ///   screen text, and then only from windows that are already visible.
    static let appAliases: [String: String] = [
        "notities": "Notes",
        "notes": "Notes",
        "agenda": "Calendar",
        "calendar": "Calendar",
        "herinneringen": "Reminders",
        "reminders": "Reminders",
        "berichten": "Messages",
        "messages": "Messages",
        "muziek": "Music",
        "music": "Music",
        "teksteditor": "TextEdit",
        "textedit": "TextEdit",
        "instellingen": "System Settings",
        "systeeminstellingen": "System Settings",
        "terminal": "Terminal",
        "finder": "Finder"
    ]

    /// Specialized extractors for standard scriptable macOS applications.
    static func readScriptableApp(_ query: String) async -> [(title: String, text: String)]? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Notes / Notities
        if q == "notes" || q == "notities" || q.contains("notitie") || q.contains("note") {
            let script = """
            tell application "Notes"
                set total to count of notes
                set n to total
                if n > 6 then set n to 6
                set out to ""
                repeat with i from 1 to n
                    set notitem to note i
                    set nname to name of notitem
                    set ndate to ((modification date of notitem) as «class isot» as string)
                    set nfolder to ""
                    try
                        set nfolder to name of container of notitem
                    end try
                    set nbody to ""
                    try
                        set nbody to plaintext of notitem
                    end try
                    if (length of nbody) > 800 then set nbody to text 1 thru 800 of nbody
                    set folderStr to ""
                    if nfolder is not "" then set folderStr to " [" & nfolder & "]"
                    set out to out & "### " & nname & folderStr & " (" & (text 1 thru 10 of ndate) & ")" & linefeed & nbody & linefeed & linefeed
                end repeat
                return out
            end tell
            """
            let res = await ScriptText.run(script, timeout: 3.5)
            if let text = res.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [("Apple Notities", text)]
            }
        }

        // Browsers: Safari, Google Chrome, Microsoft Edge, Arc
        if q == "safari" || q == "chrome" || q == "google chrome" || q == "edge" || q == "microsoft edge" || q == "arc" || q == "browser" {
            let appName = q.contains("safari") ? "Safari" : (q.contains("chrome") ? "Google Chrome" : (q.contains("edge") ? "Microsoft Edge" : "Arc"))
            let jsScript = appName == "Safari"
                ? "tell application \"Safari\" to if (count of documents) > 0 then return (name of front document) & \"|||\" & (URL of front document) & linefeed & (text of front document) end if"
                : "tell application \"\(appName)\" to if (count of windows) > 0 then set t to active tab of front window; return (title of t) & \"|||\" & (URL of t) & linefeed & (execute front window's active tab javascript \"document.body.innerText\") end if"
            let res = await ScriptText.run(jsScript, timeout: 3.5)
            if let text = res.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let header = String(lines.first ?? "").components(separatedBy: "|||")
                let body = lines.count > 1 ? String(lines[1]) : ""
                let title = header.first ?? "Webpagina"
                let url = header.count > 1 ? header[1] : ""
                let content = "URL: \(url)\n\n" + String(body.prefix(8000))
                return [(title, content)]
            }
        }

        // Terminal / iTerm
        if q == "terminal" {
            let script = """
            tell application "Terminal"
                if (count of windows) > 0 then
                    return contents of selected tab of front window
                end if
            end tell
            """
            let res = await ScriptText.run(script, timeout: 2.5)
            if let text = res.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [("Terminal venster", String(text.suffix(4000)))]
            }
        }

        // Finder
        if q == "finder" {
            let script = """
            tell application "Finder"
                set out to ""
                try
                    set sel to selection as alias list
                    if (count of sel) > 0 then
                        set out to "Geselecteerd in Finder:" & linefeed
                        repeat with f in sel
                            set out to out & "- " & (POSIX path of f) & linefeed
                        end repeat
                    end if
                end try
                try
                    set targetFolder to (target of front window) as alias
                    set out to out & "Huidige map in Finder: " & (POSIX path of targetFolder) & linefeed
                end try
                return out
            end tell
            """
            let res = await ScriptText.run(script, timeout: 2.5)
            if let text = res.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [("Finder", text)]
            }
        }

        // Spotify / Music
        if q == "spotify" || q == "muziek" || q == "music" {
            let targetApp = q == "spotify" ? "Spotify" : "Music"
            let script = """
            tell application "\(targetApp)"
                if player state is playing then
                    return (name of current track) & "|||" & (artist of current track) & "|||" & (album of current track)
                else
                    return "PAUSED"
                end if
            end tell
            """
            let res = await ScriptText.run(script, timeout: 2.0)
            if let text = res.text, text != "PAUSED", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parts = text.components(separatedBy: "|||")
                if parts.count >= 2 {
                    return [("Spelend in \(targetApp)", "Nummer: \(parts[0])\nArtiest: \(parts[1])" + (parts.count > 2 ? "\nAlbum: \(parts[2])" : ""))]
                }
            }
        }

        return nil
    }

    /// Reads one app: first checks specialized native AppleScript, then accessibility tree, then window OCR.
    func captureApp(_ query: String, totalLimit: Int = 8000) async throws -> ScreenSnapshot {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NookError("Welke app wil je lezen?") }
        let canonicalName = Self.appAliases[trimmed.lowercased()] ?? trimmed
        let wanted = canonicalName.lowercased()
        // An app the user asked Nook never to read stays closed to every route below, the scripted ones included. The
        // built-in exclusions have no scripted route, so the app folders are only searched when the user picked apps.
        let picked = Set(UserDefaults.standard.stringArray(forKey: AppSettings.neverReadAppsKey) ?? [])
        if !picked.isEmpty {
            let named = NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased() == wanted }?.bundleIdentifier
                ?? Self.installedApp(named: canonicalName).flatMap { Bundle(url: $0)?.bundleIdentifier }
            if let named, picked.contains(named) { throw ScreenError.excluded(canonicalName) }
        }

        // 1. Direct specialized native script reading (Notes, Safari, Chrome, Edge, Terminal, Finder, Music)
        if let scriptSections = await Self.readScriptableApp(wanted), !scriptSections.isEmpty {
            return Self.snapshot(canonicalName, scriptSections, note: nil)
        }

        let apps = Self.openApps()
        let exact = apps.filter { ($0.localizedName ?? "").lowercased() == wanted }
        let loose = apps.filter {
            ($0.localizedName ?? "").lowercased().contains(wanted) || ($0.bundleIdentifier ?? "").lowercased().contains(wanted)
                || wanted.contains(($0.localizedName ?? "").lowercased())
        }
        let app = exact.first ?? loose.first
        let canRead = AppTextReader.hasPermission

        // 2. Closed app handling
        if app == nil {
            guard let url = Self.installedApp(named: canonicalName) else {
                throw NookError("Ik kan geen app genaamd \"\(query)\" vinden op deze Mac.")
            }
            if let bundle = Bundle(url: url)?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
                throw ScreenError.excluded(FileManager.default.displayName(atPath: url.path))
            }

            // Closed app: check if scriptable reading can wake it
            if let scriptSections = await Self.readScriptableApp(wanted), !scriptSections.isEmpty {
                return Self.snapshot(canonicalName, scriptSections, note: nil)
            }

            // Report clearly that app is installed but closed
            let appTitle = FileManager.default.displayName(atPath: url.path)
            throw NookError("\(appTitle) staat geïnstalleerd op je Mac maar is momenteel niet geopend. Vraag Nook 'open \(appTitle)' om de app te starten, waarna Nook de inhoud kan inzien.")
        }

        guard let app else { throw NookError("Kan app \"\(query)\" niet vinden.") }
        let name = app.localizedName ?? canonicalName

        // 3. Accessibility reading (fast & non-intrusive)
        if canRead {
            let sections = await Self.readHidden(app, launched: false, limit: totalLimit)
            if !sections.isEmpty { return Self.snapshot(name, sections, note: nil) }
        }

        // 4. Window OCR via ScreenCaptureKit (reads visible windows without activating)
        if ScreenAccess.isUsable {
            let windows = await Self.windows(of: app)
            if !windows.isEmpty {
                var sections: [(title: String, text: String)] = []
                var remaining = totalLimit
                for window in windows.prefix(3) where remaining > 200 {
                    let configuration = SCStreamConfiguration()
                    configuration.width = min(Int(window.frame.width * 1.5), 2400)
                    configuration.height = min(Int(window.frame.height * 1.5), 2400)
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                          let text = try? await Self.recognize(image, fast: false) else { continue }
                    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanText.isEmpty else { continue }
                    let chunk = String(cleanText.prefix(remaining))
                    remaining -= chunk.count
                    sections.append((window.title ?? "", chunk))
                }
                if !sections.isEmpty {
                    return Self.snapshot(name, sections, note: nil)
                }
            }
        }

        if !canRead {
            AppTextReader.requestPermission()
            throw NookError("\(name) is geopend, maar Nook heeft Toegankelijkheid-toestemming nodig om de tekst uit de vensters te lezen: Systeeminstellingen › Privacy en beveiliging › Toegankelijkheid.")
        }

        throw NookError("\(name) heeft op dit moment geen leesbare tekst of vensterinhoud.")
    }

    /// Launches an app hidden and without activating it, and waits until it runs.
    private static func launchHidden(_ url: URL) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !app.isFinishedLaunching {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return app
    }

    /// Reads through the accessibility layer. If the app has no window (yet), Nook asks for one while the app stays hidden,
    /// so the window never appears on screen.
    private static func readHidden(_ app: NSRunningApplication, launched: Bool, limit: Int) async -> [(title: String, text: String)] {
        AppTextReader.wake(pid: app.processIdentifier)
        var reopened = false
        for attempt in 0..<(launched ? 30 : 12) {
            let sections = await AppTextReader.text(pid: app.processIdentifier, limit: limit)
            // Just launched: let it load a little longer if there is little text.
            if !sections.isEmpty, !launched || attempt >= 8 || sections.reduce(0, { $0 + $1.text.count }) > 400 { return sections }
            // No window: only ask for one when the app is hidden, because then it stays invisible.
            if !reopened, attempt >= 4, app.isHidden, let url = app.bundleURL {
                reopened = true
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                configuration.addsToRecentItems = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await AppTextReader.text(pid: app.processIdentifier, limit: limit)
    }

    private static func snapshot(_ name: String, _ sections: [(title: String, text: String)], note: String?) -> ScreenSnapshot {
        let body = sections.map { "### \(name)\($0.title.isEmpty ? "" : " — \($0.title)")\n\($0.text)" }.joined(separator: "\n\n")
        return ScreenSnapshot(appName: name, windowTitle: name, text: (note.map { $0 + "\n\n" } ?? "") + body)
    }

    /// The on-screen windows and displays; a refusal turns automatic reads off (`ScreenAccess`).
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            ScreenAccess.note(error)
            throw ScreenAccess.refused ? ScreenError.noPermission : error
        }
    }

    /// An app's on-screen windows (including covered ones), largest first.
    private static func windows(of app: NSRunningApplication) async -> [SCWindow] {
        guard let content = try? await shareableContent() else { return [] }
        return content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 100
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    /// Reads all visible windows across all screens (frontmost first), providing holistic context to Nook.
    /// Each window receives its own heading; together the text respects a fixed budget.
    func captureAll(maxWindows: Int = 6, totalLimit: Int = 9000) async throws -> ScreenSnapshot {
        // No CGRequestScreenCaptureAccess here: this runs without the user asking (think-along, the brain's read_screen),
        // and a build macOS no longer matches to its switch would get the system prompt on every read.
        guard ScreenAccess.isUsable else { throw ScreenError.noPermission }
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.localizedName ?? "this app"
        if let bundle = front?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(frontName)
        }

        let content = try await Self.shareableContent()
        let excluded = Self.excludedBundles
        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width > 200, window.frame.height > 100,
                  let owner = window.owningApplication else { return false }
            return !excluded.contains(owner.bundleIdentifier)
        }
        // Frontmost app first; within an app, largest windows first.
        let ordered = candidates.sorted { a, b in
            let aFront = a.owningApplication?.processID == front?.processIdentifier
            let bFront = b.owningApplication?.processID == front?.processIdentifier
            if aFront != bFront { return aFront }
            return a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }.prefix(maxWindows)
        guard !ordered.isEmpty else { return try await capture() }

        var sections: [String] = []
        var remaining = totalLimit
        for (index, window) in ordered.enumerated() where remaining > 200 {
            let configuration = SCStreamConfiguration()
            configuration.width = min(Int(window.frame.width * 1.5), 2400)
            configuration.height = min(Int(window.frame.height * 1.5), 2400)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                  let text = try? await Self.recognize(image, fast: true) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let share = index == 0 ? remaining : min(remaining, max(1200, totalLimit / 4))
            let name = window.owningApplication?.applicationName ?? "app"
            let title = (window.title ?? "").isEmpty ? "" : " — \(window.title ?? "")"
            let chunk = String(trimmed.prefix(share))
            remaining -= chunk.count
            sections.append("### \(index == 0 ? "Frontmost window" : "Window"): \(name)\(title)\n\(chunk)")
        }
        guard !sections.isEmpty else { throw ScreenError.nothing }
        return ScreenSnapshot(appName: frontName, windowTitle: "all visible windows", text: sections.joined(separator: "\n\n"))
    }

    private nonisolated static let ocrQueue = DispatchQueue(label: "nook.screen.ocr", attributes: .concurrent)

    /// `fast`: Vision fast recognition level (significantly faster, slightly less accurate), for background tracking.
    nonisolated static func recognize(_ image: CGImage, fast: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // No QoS on purpose: Vision waits on its own worker threads, which have no QoS class. Running this at
            // user-initiated made a higher-priority thread wait on a lower one (a priority inversion).
            ocrQueue.async(flags: .noQoS) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = fast ? .fast : .accurate
                request.recognitionLanguages = ["nl-NL", "en-US"]
                request.usesLanguageCorrection = !fast
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
