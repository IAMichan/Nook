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

    /// Leest de vensters van één app, ook als die achter andere vensters ligt, verborgen is of nog dicht is.
    /// `query` is de naam ("Notities", "Slack") of een deel van de bundel-id. Is de app dicht, dan start Nook hem op de
    /// achtergrond (zonder hem naar voren te halen), leest hem en sluit hem daarna weer. Verborgen apps gaan na het lezen
    /// terug in hun schuilplaats. Zo kan Nook in elke app kijken, ook zonder koppeling.
    func captureApp(_ query: String, totalLimit: Int = 8000) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { throw NookError("Welke app?") }
        let apps = Self.openApps()
        let exact = apps.filter { ($0.localizedName ?? "").lowercased() == wanted }
        let loose = apps.filter {
            ($0.localizedName ?? "").lowercased().contains(wanted) || ($0.bundleIdentifier ?? "").lowercased().contains(wanted)
        }

        let front = NSWorkspace.shared.frontmostApplication
        var app = exact.first ?? loose.first
        var launched = false
        var unhid = false
        if app == nil {
            // Dicht: zoek hem op en start hem op de achtergrond.
            guard let url = Self.installedApp(named: query) else {
                throw NookError("Ik vind geen app die \(query) heet op deze Mac.")
            }
            if let bundle = Bundle(url: url)?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
                throw ScreenError.excluded(FileManager.default.displayName(atPath: url.path))
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched = app != nil
        }
        guard let app else { throw NookError("\(query) wilde niet starten.") }
        if let bundle = app.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(app.localizedName ?? query)
        }
        let name = app.localizedName ?? query
        if app.isHidden {
            app.unhide()
            unhid = true
        }
        defer {
            // Netjes achterlaten: wat Nook opende gaat weer dicht, wat verborgen was weer weg, en de focus blijft waar hij was.
            if launched { app.terminate() } else if unhid { app.hide() }
            if let front, front.processIdentifier != app.processIdentifier, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                front.activate(options: [])
            }
        }

        // Wachten tot er een venster is. Heeft een open app geen venster (Mail met het venster dicht), dan vraagt Nook
        // de app er een te openen, zoals een klik op het Dock-icoon, maar zonder hem naar voren te halen.
        var windows: [SCWindow] = []
        var reopened = false
        for attempt in 0..<24 {
            windows = await Self.windows(of: app)
            if !windows.isEmpty { break }
            if !reopened, attempt >= (launched ? 8 : 0), let url = app.bundleURL {
                reopened = true
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !windows.isEmpty else {
            throw NookError("\(name) laat geen venster zien (misschien geminimaliseerd of in een ander bureaublad), dus ik kan er niet in lezen.")
        }
        // Een net gestarte app heeft even nodig om zijn inhoud te laden.
        if launched || reopened { try? await Task.sleep(nanoseconds: 1_200_000_000) }

        var sections: [String] = []
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
            let title = (window.title ?? "").isEmpty ? "" : " — \(window.title ?? "")"
            sections.append("### \(name)\(title)\n\(chunk)")
        }
        guard !sections.isEmpty else { throw ScreenError.nothing }
        let note = launched ? "(\(name) was dicht; Nook opende hem even op de achtergrond om te lezen en sloot hem weer.)\n\n" : ""
        return ScreenSnapshot(appName: name, windowTitle: name, text: note + sections.joined(separator: "\n\n"))
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
