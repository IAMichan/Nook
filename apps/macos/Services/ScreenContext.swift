import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Background tracking of text across all visible windows on all screens, allowing Nook to answer queries
/// with immediate screen context. Text recognition runs locally (OCR); data is only sent to the model upon request.
///
/// Fast and resource-efficient:
/// - Each window gets a tiny greyscale thumbnail fingerprint; if unchanged, OCR is skipped.
/// - The frontmost window is read accurately; others use fast recognition and refresh less frequently.
/// - Idles when the Mac is inactive for several minutes or when disabled.
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

    /// Current windows seen by Nook, frontmost window first. Not published itself: it changes on every read, while the
    /// interface only shows `shown`, and the whole app redrawing every few seconds for nothing visible is what this avoids.
    private(set) var windows: [WindowText] = [] {
        didSet {
            let front = windows.first { $0.isFront }
            let now = Shown(count: windows.count, displays: displayCount, frontApp: front?.app ?? "",
                            frontBundle: front?.bundleID ?? "", frontTitle: front?.title ?? "")
            if now != shown { shown = now }
        }
    }
    private(set) var lastUpdate: Date?
    @Published private(set) var isRunning = false

    /// What views read of `windows`: how many, on how many displays, and which window is in front.
    struct Shown: Equatable {
        var count = 0
        var displays = 0
        var frontApp = ""
        var frontBundle = ""
        var frontTitle = ""
    }
    @Published private(set) var shown = Shown()

    var enabled: () -> Bool = { true }

    private var timer: Timer?
    private var busy = false
    private var pendingFrontRefresh: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cache: [CGWindowID: WindowText] = [:]

    private let maxWindows = 10
    private let interval: TimeInterval = 7
    /// Non-frontmost windows are refreshed at most this frequently.
    private let backgroundMaxAge: TimeInterval = 30
    private var lastFailure: Date?
    private let failureCooldown: TimeInterval = 60
    /// Per window: on how many periodic ticks in a row its picture changed, and when its text was last read. A window
    /// that changes on every tick (a video, a scrolling log, a game) is read at most every `volatileReadInterval`
    /// instead of a full capture and OCR every seven seconds; a question still reads it fresh (`snapshot`).
    private var changeStreak: [CGWindowID: Int] = [:]
    private var lastRead: [CGWindowID: Date] = [:]
    private let volatileAfter = 3
    private let volatileReadInterval: TimeInterval = 30

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Number of displays containing visible windows.
    var displayCount: Int { Set(windows.map(\.display)).count }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        isRunning = true
        timer = Timer.scheduledCoalesced(withTimeInterval: interval) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        // When switching apps, immediately observe the new frontmost window.
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

    /// Clears all captured screen text.
    func clear() {
        cache = [:]
        changeStreak = [:]
        lastRead = [:]
        windows = []
        lastUpdate = nil
        lastFailure = nil
    }

    private func scheduleFrontRefresh() {
        if let failure = lastFailure, Date().timeIntervalSince(failure) < failureCooldown { return }
        pendingFrontRefresh?.cancel()
        pendingFrontRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(frontOnly: true, accurateFront: false)
        }
    }

    private func tick() async {
        guard enabled(), hasPermission else { return }
        if let failure = lastFailure, Date().timeIntervalSince(failure) < failureCooldown { return }
        // Idle away from Mac: skip capture.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { return }
        await refresh(frontOnly: false, accurateFront: false, periodic: true)
    }

    // MARK: Query Snapshot

    /// Snapshot of currently visible screens. If the front window is older than `maxAge` seconds, it is refreshed first
    /// (isolated to that window for speed); remaining windows are served from cache.
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
            await refresh(frontOnly: windows.count > 1, accurateFront: false)
        }
        if windows.isEmpty {
            await refresh(frontOnly: false, accurateFront: false)
        }
        guard !windows.isEmpty else {
            if let bundle = frontApp?.bundleIdentifier, ScreenReader.excludedBundles.contains(bundle) {
                throw ScreenError.excluded(frontApp?.localizedName ?? "this app")
            }
            throw ScreenError.nothing
        }
        return format(totalLimit: totalLimit)
    }

    /// Returns cached snapshot synchronously without waiting. Nil if nothing has been captured yet.
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
            // Frontmost window receives the largest allocation; remaining windows receive fair shares.
            let share = index == 0 ? min(remaining, max(4000, totalLimit / 2)) : min(remaining, max(900, totalLimit / 6))
            let chunk = String(trimmed.prefix(share))
            remaining -= chunk.count
            let title = window.title.isEmpty ? "" : " — \(window.title)"
            let place = multipleDisplays ? " · display \(window.display)" : ""
            let age = Int(now.timeIntervalSince(window.captured))
            let fresh = age < 5 ? "" : " · read \(age)s ago"
            let label = window.isFront ? "Frontmost window" : "Window"
            sections.append("### \(label): \(window.app)\(title)\(place)\(fresh)\n\(chunk)")
        }
        let frontName = windows.first?.app ?? "this app"
        let screens = displayCount
        let label = "\(windows.count) windows" + (screens > 1 ? " across \(screens) displays" : "")
        return ScreenSnapshot(appName: frontName, windowTitle: label, text: sections.joined(separator: "\n\n"))
    }

    // MARK: Reading

    /// `periodic`: the timer's own read, which may leave a window that keeps changing for later; a read for a question,
    /// an app switch or a snapshot never does.
    private func refresh(frontOnly: Bool, accurateFront: Bool, periodic: Bool = false) async {
        guard !busy, hasPermission else { return }
        busy = true
        defer { busy = false }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            lastFailure = nil
        } catch {
            lastFailure = Date()
            return
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let names = Self.displayNames()

        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0, window.isOnScreen, window.frame.width > 200, window.frame.height > 100,
                  let owner = window.owningApplication else { return false }
            return !ScreenReader.excludedBundles.contains(owner.bundleIdentifier)
        }
        // Frontmost app first, followed by largest windows. Even partially obscured windows are included:
        // ScreenCaptureKit captures them unobscured.
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

        // A tiny probe of each window decides whether anything changed. Only changed windows are captured at full size and
        // read by OCR, so a quiet screen costs a few thumbnails instead of megapixels of readback per window.
        var captured: [(window: SCWindow, isFront: Bool, image: CGImage?, print: UInt64)] = []
        // Windows whose text was kept although their picture changed: their capture time stays, so a question reads them.
        var behind: Set<CGWindowID> = []
        for job in jobs {
            let probe = SCStreamConfiguration()
            // Enough for the 32×32 fingerprint below; a quarter of the pixels of 256×256.
            probe.width = 128
            probe.height = 128
            probe.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: job.window)
            guard let small = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: probe) else { continue }
            // The window size is part of the print: the probe has a fixed size, but a resized window reflows its text. So is
            // the recognition level, so a window read fast is read again when an accurate read is asked for.
            let size = UInt64(Int(job.window.frame.width)) << 16 | UInt64(Int(job.window.frame.height))
            let print = Self.fingerprint(small, side: 32) ^ size ^ (job.accurate ? 1 << 63 : 0)
            let id = job.window.windowID
            if let old = cache[id], old.fingerprint == print {
                changeStreak[id] = 0
                captured.append((job.window, job.isFront, nil, print))
                continue
            }
            if periodic {
                let streak = (changeStreak[id] ?? 0) + 1
                changeStreak[id] = streak
                // Keeps changing: keep the text read last time (and its print, so it still counts as changed) for a while.
                if streak > volatileAfter, let old = cache[id], let read = lastRead[id], now.timeIntervalSince(read) < volatileReadInterval {
                    behind.insert(id)
                    captured.append((job.window, job.isFront, nil, old.fingerprint))
                    continue
                }
            }
            let configuration = SCStreamConfiguration()
            let scale: CGFloat = job.accurate ? 1.5 : 1.0
            configuration.width = min(Int(job.window.frame.width * scale), 2400)
            configuration.height = min(Int(job.window.frame.height * scale), 2400)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            lastRead[id] = Date()
            captured.append((job.window, job.isFront, image, print))
        }

        var texts: [CGWindowID: String] = [:]
        await withTaskGroup(of: (CGWindowID, String?).self) { group in
            for item in captured {
                guard let image = item.image else { continue }
                let id = item.window.windowID
                let fast = !(item.isFront && accurateFront)
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
                captured: behind.contains(window.windowID) ? (old?.captured ?? Date()) : Date(),
                fingerprint: item.print,
                frame: window.frame
            )
        }

        // Only retain windows that are still present, in current z-order.
        let order = ordered.map(\.windowID)
        cache = kept
        changeStreak = changeStreak.filter { kept[$0.key] != nil }
        lastRead = lastRead.filter { kept[$0.key] != nil }
        windows = order.compactMap { kept[$0] }.filter { !$0.text.isEmpty }
        lastUpdate = Date()
    }

    // MARK: Helpers

    /// Visual fingerprint: a `side`×`side` greyscale thumbnail, coarsened so minor artifacts like a blinking cursor don't
    /// invalidate it. Each cell averages its area, so changed text in it moves the value.
    nonisolated static func fingerprint(_ image: CGImage, side: Int = 16) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let made: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
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
        return best.name.isEmpty ? (names.values.first ?? "main display") : best.name
    }
}
