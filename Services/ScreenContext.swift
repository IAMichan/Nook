import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Houdt op de achtergrond de tekst bij van alle zichtbare vensters op al je schermen, zodat Nook een vraag
/// meteen kan beantwoorden met wat je ziet. Lezen gebeurt op je Mac (OCR); er gaat pas iets naar het brein als je iets vraagt.
///
/// Snel en zuinig:
/// - Elk venster krijgt een vingerafdruk van een piepklein grijs plaatje. Is die gelijk, dan wordt er niet opnieuw gelezen.
/// - Het voorste venster wordt nauwkeurig gelezen, de rest met de snelle herkenning en minder vaak.
/// - Ben je een paar minuten weg van je Mac, of staat het uit, dan doet hij niets.
@MainActor
final class ScreenContext: ObservableObject {
    struct WindowText: Identifiable, Equatable {
        var id: CGWindowID
        var app: String
        var bundleID: String
        var title: String
        var display: String
        var text: String
        var isFront: Bool
        var captured: Date
        var fingerprint: UInt64
        var frame: CGRect
    }

    /// Wat Nook nu ziet, voorste venster eerst.
    @Published private(set) var windows: [WindowText] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isRunning = false

    var enabled: () -> Bool = { true }

    private var timer: Timer?
    private var busy = false
    private var pendingFrontRefresh: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cache: [CGWindowID: WindowText] = [:]

    private let maxWindows = 10
    private let interval: TimeInterval = 7
    /// Andere vensters dan het voorste worden hooguit zo vaak opnieuw bekeken.
    private let backgroundMaxAge: TimeInterval = 30

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Aantal schermen waarop Nook nu vensters ziet.
    var displayCount: Int { Set(windows.map(\.display)).count }

    // MARK: Aan en uit

    func start() {
        guard timer == nil else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        // Wissel je van app, dan kijkt Nook meteen even naar het nieuwe voorste venster.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleFrontRefresh() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clear() }
        })
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        clear()
    }

    /// Vergeet alles wat gelezen is.
    func clear() {
        cache = [:]
        windows = []
        lastUpdate = nil
    }

    private func scheduleFrontRefresh() {
        pendingFrontRefresh?.cancel()
        pendingFrontRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(frontOnly: true, accurateFront: true)
        }
    }

    private func tick() async {
        guard enabled(), hasPermission else { return }
        // Even weg van de Mac: niets bijhouden.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { return }
        await refresh(frontOnly: false, accurateFront: true)
    }

    // MARK: Voor een vraag

    /// Wat er nu op je schermen staat. Is het voorste venster ouder dan `maxAge` seconden, dan leest Nook dat eerst opnieuw
    /// (alleen dat venster, dus snel); de rest komt uit de cache.
    func snapshot(maxAge: TimeInterval = 2.5, totalLimit: Int = 12_000) async throws -> ScreenSnapshot {
        guard hasPermission else {
            CGRequestScreenCaptureAccess()
            throw ScreenError.noPermission
        }
        let front = windows.first { $0.isFront }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let stale = front == nil || Date().timeIntervalSince(front?.captured ?? .distantPast) > maxAge
            || front?.bundleID != (frontApp?.bundleIdentifier ?? "")
        if stale || windows.isEmpty {
            await refresh(frontOnly: windows.count > 1, accurateFront: true)
        }
        if windows.isEmpty {
            await refresh(frontOnly: false, accurateFront: true)
        }
        guard !windows.isEmpty else {
            if let bundle = frontApp?.bundleIdentifier, ScreenReader.excludedBundles.contains(bundle) {
                throw ScreenError.excluded(frontApp?.localizedName ?? "deze app")
            }
            throw ScreenError.nothing
        }
        return format(totalLimit: totalLimit)
    }

    /// Alleen uit de cache, zonder te wachten. Leeg als Nook nog niets zag.
    func cachedSnapshot(totalLimit: Int = 12_000) -> ScreenSnapshot? {
        windows.isEmpty ? nil : format(totalLimit: totalLimit)
    }

    private func format(totalLimit: Int) -> ScreenSnapshot {
        var sections: [String] = []
        var remaining = totalLimit
        let multipleDisplays = displayCount > 1
        let now = Date()
        for (index, window) in windows.enumerated() where remaining > 200 {
            let trimmed = window.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Het voorste venster krijgt de meeste ruimte, de andere elk een eerlijk deel.
            let share = index == 0 ? min(remaining, max(4000, totalLimit / 2)) : min(remaining, max(900, totalLimit / 6))
            let chunk = String(trimmed.prefix(share))
            remaining -= chunk.count
            let title = window.title.isEmpty ? "" : " — \(window.title)"
            let place = multipleDisplays ? " · scherm \(window.display)" : ""
            let age = Int(now.timeIntervalSince(window.captured))
            let fresh = age < 5 ? "" : " · \(age) s geleden gelezen"
            let label = window.isFront ? "Voorste venster" : "Venster"
            sections.append("### \(label): \(window.app)\(title)\(place)\(fresh)\n\(chunk)")
        }
        let frontName = windows.first?.app ?? "deze app"
        let screens = displayCount
        let label = "\(windows.count) vensters" + (screens > 1 ? " op \(screens) schermen" : "")
        return ScreenSnapshot(appName: frontName, windowTitle: label, text: sections.joined(separator: "\n\n"))
    }

    // MARK: Lezen

    private func refresh(frontOnly: Bool, accurateFront: Bool) async {
        guard !busy, hasPermission else { return }
        busy = true
        defer { busy = false }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let names = Self.displayNames()

        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.isOnScreen, window.frame.width > 200, window.frame.height > 100,
                  let owner = window.owningApplication else { return false }
            return !ScreenReader.excludedBundles.contains(owner.bundleIdentifier)
        }
        // Voorste app eerst; daarna de grootste vensters. Vensters die grotendeels onder andere liggen, ziet de gebruiker
        // toch niet, maar die laten we gewoon meetellen: ScreenCaptureKit leest ze onbedekt.
        let ordered = candidates.sorted { a, b in
            let aFront = a.owningApplication?.processID == frontPID
            let bFront = b.owningApplication?.processID == frontPID
            if aFront != bFront { return aFront }
            return a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }.prefix(maxWindows)

        let now = Date()
        var jobs: [(window: SCWindow, isFront: Bool, accurate: Bool)] = []
        var kept: [CGWindowID: WindowText] = [:]
        var firstFront = true
        for window in ordered {
            let isFront = window.owningApplication?.processID == frontPID && firstFront
            if isFront { firstFront = false }
            let old = cache[window.windowID]
            let titleChanged = old?.title != (window.title ?? "") || old?.frame != window.frame
            let age = now.timeIntervalSince(old?.captured ?? .distantPast)
            let due: Bool
            if isFront {
                due = true
            } else if frontOnly {
                due = old == nil
            } else {
                due = old == nil || titleChanged || age > backgroundMaxAge
            }
            if due {
                jobs.append((window, isFront, isFront && accurateFront))
            }
            if var entry = old {
                entry.isFront = isFront
                kept[window.windowID] = entry
            }
        }

        // Vastleggen gaat via de GPU en is snel; het lezen (OCR) draait parallel en alleen als het beeld echt veranderde.
        var captured: [(window: SCWindow, isFront: Bool, accurate: Bool, image: CGImage, print: UInt64)] = []
        for job in jobs {
            let configuration = SCStreamConfiguration()
            let scale: CGFloat = job.accurate ? 1.5 : 1.0
            configuration.width = min(Int(job.window.frame.width * scale), 2400)
            configuration.height = min(Int(job.window.frame.height * scale), 2400)
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: job.window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            captured.append((job.window, job.isFront, job.accurate, image, Self.fingerprint(image)))
        }

        let toRead = captured.filter { item in
            guard let old = cache[item.window.windowID] else { return true }
            // Zelfde beeld: niet opnieuw lezen. Wel opnieuw als het voorste venster eerder alleen snel gelezen werd.
            return old.fingerprint != item.print
        }

        var texts: [CGWindowID: String] = [:]
        await withTaskGroup(of: (CGWindowID, String?).self) { group in
            for item in toRead {
                let id = item.window.windowID
                let image = item.image
                let fast = !item.accurate
                group.addTask {
                    let text = try? await ScreenReader.recognize(image, fast: fast)
                    return (id, text)
                }
            }
            for await (id, text) in group {
                if let text { texts[id] = text }
            }
        }

        for item in captured {
            let window = item.window
            let old = cache[window.windowID]
            let text = texts[window.windowID] ?? old?.text ?? ""
            kept[window.windowID] = WindowText(
                id: window.windowID,
                app: window.owningApplication?.applicationName ?? "app",
                bundleID: window.owningApplication?.bundleIdentifier ?? "",
                title: window.title ?? "",
                display: Self.display(for: window.frame, in: content.displays, names: names),
                text: text,
                isFront: item.isFront,
                captured: Date(),
                fingerprint: item.print,
                frame: window.frame
            )
        }

        // Alleen vensters die er nog zijn, in de volgorde van nu.
        let order = ordered.map(\.windowID)
        cache = kept
        windows = order.compactMap { kept[$0] }.filter { !$0.text.isEmpty }
        lastUpdate = Date()
    }

    // MARK: Hulpjes

    /// Een vingerafdruk van het beeld: 16×16 grijswaarden, grof afgerond. Kleine dingen als een knipperende cursor tellen niet.
    nonisolated static func fingerprint(_ image: CGImage) -> UInt64 {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let made: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard made else { return UInt64(image.width &* 31 &+ image.height) }
        var hash: UInt64 = 1469598103934665603
        for value in pixels {
            hash = (hash ^ UInt64(value >> 3)) &* 1099511628211
        }
        return hash ^ UInt64(image.width << 16 | image.height)
    }

    private static func displayNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }
        return names
    }

    private static func display(for frame: CGRect, in displays: [SCDisplay], names: [CGDirectDisplayID: String]) -> String {
        var best: (area: CGFloat, name: String) = (0, "")
        for display in displays {
            let overlap = display.frame.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > best.area {
                best = (area, names[display.displayID] ?? "\(display.displayID)")
            }
        }
        return best.name.isEmpty ? (names.values.first ?? "hoofdscherm") : best.name
    }
}
