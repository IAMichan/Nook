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

    /// Leest de vensters van één open app, ook als die achter andere vensters ligt. `query` is de naam ("Notities",
    /// "Slack") of een deel van de bundel-id. Zo kan Nook in elke app kijken, ook zonder koppeling.
    func captureApp(_ query: String, totalLimit: Int = 8000) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { throw NookError("Welke app?") }
        if let excluded = NSWorkspace.shared.runningApplications.first(where: {
            Self.excludedBundles.contains($0.bundleIdentifier ?? "") && ($0.localizedName ?? "").lowercased() == wanted
        }) {
            throw ScreenError.excluded(excluded.localizedName ?? query)
        }
        let apps = Self.openApps()
        let exact = apps.filter { ($0.localizedName ?? "").lowercased() == wanted }
        let loose = apps.filter {
            ($0.localizedName ?? "").lowercased().contains(wanted) || ($0.bundleIdentifier ?? "").lowercased().contains(wanted)
        }
        guard let app = exact.first ?? loose.first else {
            let open = apps.compactMap(\.localizedName).sorted().joined(separator: ", ")
            throw NookError("\(query) is niet open. Open apps: \(open). Stel open_app voor als de gebruiker hem wil openen.")
        }
        let name = app.localizedName ?? query

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 100
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }.prefix(3)
        guard !windows.isEmpty else {
            throw NookError("\(name) is open maar heeft geen zichtbaar venster (verborgen of in het Dock). Vraag de gebruiker het venster te tonen.")
        }

        var sections: [String] = []
        var remaining = totalLimit
        for window in windows where remaining > 200 {
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
        return ScreenSnapshot(appName: name, windowTitle: name, text: sections.joined(separator: "\n\n"))
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
