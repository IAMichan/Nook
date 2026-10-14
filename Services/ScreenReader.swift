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
            return "Nook does not have screen recording permission yet. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, and restart Nook."
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
        let appName = app.localizedName ?? "this app"
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

    /// Reads all visible windows across all screens (frontmost first), providing holistic context to Nook.
    /// Each window receives its own heading; together the text respects a fixed budget.
    func captureAll(maxWindows: Int = 6, totalLimit: Int = 9000) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.localizedName ?? "this app"
        if let bundle = front?.bundleIdentifier, Self.excludedBundles.contains(bundle) {
            throw ScreenError.excluded(frontName)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width > 200, window.frame.height > 100,
                  let owner = window.owningApplication else { return false }
            return !Self.excludedBundles.contains(owner.bundleIdentifier)
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

    /// `fast`: Vision fast recognition level (significantly faster, slightly less accurate), for background tracking.
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
