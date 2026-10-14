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
            return "Nook mag het scherm nog niet lezen. Zet dat aan bij Systeminstellingen › Privacy en beveiliging › Scherm- en systeemopname, en start Nook daarna opnieuw."
        case .excluded(let app):
            return "Ik kijk niet mee in \(app)."
        case .nothing:
            return "Ik zie niets om te lezen."
        }
    }
}

/// Maakt een momentopname van het voorste venster en leest de tekst erin (OCR, op je eigen Mac).
/// De afbeelding zelf verlaat je Mac nooit; alleen de herkende tekst kan naar het brein gaan.
@MainActor
final class ScreenReader {
    static let excludedBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.bitwarden.desktop", "nl.imdigital.nook"
    ]

    func capture() async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenError.nothing }
        let appName = app.localizedName ?? "deze app"
        if let bundle = app.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(appName)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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

    /// Apps die nu open zijn (met een venster in het Dock), zonder Nook en apps waar Nook nooit in kijkt.
    static func openApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !excludedBundles.contains(app.bundleIdentifier ?? "")
        }
    }

    /// Mappen waarin Nook naar apps zoekt die nog dicht zijn.
    private static var appFolders: [URL] {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                       URL(fileURLWithPath: "/Applications/Utilities"), URL(fileURLWithPath: "/System/Applications/Utilities")]
        folders.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return folders
    }

    /// Zoekt een geïnstalleerde app op naam, ook in de taal van de Mac ("Notities" vindt Notes.app).
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

    /// Leest één app, helemaal op de achtergrond: de gebruiker ziet er niets van. `query` is de naam ("Notities", "Slack")
    /// of een deel van de bundel-id.
    /// - Nook leest via de toegankelijkheidslaag van macOS, dus ook verborgen apps en vensters onder andere vensters.
    /// - Is de app dicht, dan start Nook hem verborgen (geen venster, niet naar voren), leest hem en sluit hem weer.
    /// - Er wordt nooit iets getoond, naar voren gehaald of van verbergen gehaald. Alleen zonder toestemming voor
    ///   Toegankelijkheid valt Nook terug op schermtekst, en dan alleen van vensters die al zichtbaar zijn.
    func captureApp(_ query: String, totalLimit: Int = 8000) async throws -> ScreenSnapshot {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { throw NookError("Welke app?") }
        let apps = Self.openApps()
        let exact = apps.filter { ($0.localizedName ?? "").lowercased() == wanted }
        let loose = apps.filter {
            ($0.localizedName ?? "").lowercased().contains(wanted) || ($0.bundleIdentifier ?? "").lowercased().contains(wanted)
        }
        var app = exact.first ?? loose.first
        let canRead = AppTextReader.hasPermission

        if app == nil {
            guard let url = Self.installedApp(named: query) else {
                throw NookError("Ik vind geen app die \(query) heet op deze Mac.")
            }
            if let bundle = Bundle(url: url)?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
                throw ScreenError.excluded(FileManager.default.displayName(atPath: url.path))
            }
            guard canRead else {
                AppTextReader.requestPermission()
                throw NookError("Om apps die dicht zijn op de achtergrond te lezen, heeft Nook toestemming nodig voor Toegankelijkheid: Systeeminstellingen › Privacy en beveiliging › Toegankelijkheid. Zet Nook daar aan en vraag het opnieuw.")
            }
            app = try await Self.launchHidden(url)
            guard let app else { throw NookError("\(query) wilde niet op de achtergrond starten.") }
            defer { app.terminate() }
            let name = app.localizedName ?? query
            let sections = await Self.readHidden(app, launched: true, limit: totalLimit)
            guard !sections.isEmpty else {
                throw NookError("\(name) toont na het starten nog niets om te lezen (hij opent zonder venster).")
            }
            return Self.snapshot(name, sections, note: "(\(name) was dicht; Nook las hem op de achtergrond en sloot hem weer.)")
        }

        guard let app else { throw NookError("Ik vind \(query) niet.") }
        let name = app.localizedName ?? query
        if canRead {
            let sections = await Self.readHidden(app, launched: false, limit: totalLimit)
            if !sections.isEmpty { return Self.snapshot(name, sections, note: nil) }
        }

        // Geen toegankelijkheid of niets gevonden: alleen wat al zichtbaar op het scherm staat, zonder iets te verschuiven.
        guard CGPreflightScreenCaptureAccess() else {
            if !canRead { AppTextReader.requestPermission() }
            throw ScreenError.noPermission
        }
        let windows = await Self.windows(of: app)
        guard !windows.isEmpty else {
            if !canRead { AppTextReader.requestPermission() }
            throw NookError(canRead
                ? "\(name) heeft nu geen venster met inhoud."
                : "\(name) staat niet in beeld. Geef Nook toestemming voor Toegankelijkheid (Systeeminstellingen › Privacy en beveiliging › Toegankelijkheid), dan leest hij apps op de achtergrond.")
        }
        var sections: [(title: String, text: String)] = []
        var remaining = totalLimit
        for window in windows.prefix(3) where remaining > 200 {
            let configuration = SCStreamConfiguration()
            configuration.width = min(Int(window.frame.width * 1.5), 2400)
            configuration.height = min(Int(window.frame.height * 1.5), 2400)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                  let text = try? await Self.recognize(image, fast: false) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chunk = String(trimmed.prefix(remaining))
            remaining -= chunk.count
            sections.append((window.title ?? "", chunk))
        }
        guard !sections.isEmpty else { throw ScreenError.nothing }
        return Self.snapshot(name, sections, note: nil)
    }

    /// Start een app verborgen en zonder hem naar voren te halen, en wacht tot hij draait.
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

    /// Leest via de toegankelijkheidslaag. Heeft de app (nog) geen venster, dan vraagt Nook er een, met de app verborgen,
    /// zodat het venster nooit in beeld komt.
    private static func readHidden(_ app: NSRunningApplication, launched: Bool, limit: Int) async -> [(title: String, text: String)] {
        AppTextReader.wake(pid: app.processIdentifier)
        var reopened = false
        for attempt in 0..<(launched ? 30 : 12) {
            let sections = await AppTextReader.text(pid: app.processIdentifier, limit: limit)
            // Net gestart: nog even laten laden als er weinig staat.
            if !sections.isEmpty, !launched || attempt >= 8 || sections.reduce(0, { $0 + $1.text.count }) > 400 { return sections }
            // Geen venster: alleen als de app verborgen is mag Nook er een vragen, want dan blijft het onzichtbaar.
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

    /// De vensters van een app op het scherm (ook onder andere vensters), grootste eerst.
    private static func windows(of app: NSRunningApplication) async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        return content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 100
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    /// Leest alle zichtbare vensters op alle schermen (voorste eerst), zodat Nook uit het geheel context kan halen.
    /// Elk venster krijgt een eigen kopje; samen blijft de tekst binnen een vast budget.
    func captureAll(maxWindows: Int = 6, totalLimit: Int = 9000) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.localizedName ?? "deze app"
        if let bundle = front?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(frontName)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width > 200, window.frame.height > 100,
                  let owner = window.owningApplication else { return false }
            return !Self.excludedBundles.contains(owner.bundleIdentifier)
        }
        // Voorste app eerst, binnen een app de grootste vensters eerst.
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
            sections.append("### \(index == 0 ? "Voorste venster" : "Venster"): \(name)\(title)\n\(chunk)")
        }
        guard !sections.isEmpty else { throw ScreenError.nothing }
        return ScreenSnapshot(appName: frontName, windowTitle: "alle zichtbare vensters", text: sections.joined(separator: "\n\n"))
    }

    /// `fast`: de snelle herkenning van Vision (ruim vijf keer sneller, iets minder nauwkeurig), voor het bijhouden op de achtergrond.
    nonisolated static func recognize(_ image: CGImage, fast: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
