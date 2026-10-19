import Foundation
import AppKit
import CoreGraphics

/// Think-along: determines when Nook proactively observes and when it may offer assistance.
/// The thinking itself is done by AppModel; this keeps suggestions calm and learns from your responses.
///
/// - Only after staying with the same window for a while (not on every switch between apps).
/// - Revisits the same window only after a few minutes, and only if something changed.
/// - If declined multiple times, Nook waits progressively longer. If accepted, resets back to normal.
/// - Remembers "Not in this app" permanently (resettable in Settings).
@MainActor
final class ThinkAlong: ObservableObject {
    /// Apps where Nook never proactively assists (bundle ID → name), at your request.
    @Published private(set) var mutedApps: [String: String]

    private var focusKey = ""
    private var focusSince = Date()
    private var lastLook = Date.distantPast
    private var lastOffer = Date.distantPast
    private var looked: [String: (date: Date, print: UInt64)] = [:]
    private var offered: [(date: Date, text: String)] = []
    private var declines = 0

    /// Duration of focus on the same window required before Nook observes.
    private let settle: TimeInterval = 25
    private let minLookGap: TimeInterval = 120
    private let sameWindowGap: TimeInterval = 240
    private let baseOfferGap: TimeInterval = 180

    init() {
        mutedApps = (UserDefaults.standard.dictionary(forKey: "thinkAlongMuted") as? [String: String]) ?? [:]
    }

    /// How long Nook waits after an offer: longer after each decline, up to at most half an hour.
    private var offerGap: TimeInterval {
        min(1800, baseOfferGap * pow(2, Double(min(declines, 4))))
    }

    /// Should Nook observe now? `bundleID` and `window` describe the frontmost window, `print` its content fingerprint.
    func shouldLook(bundleID: String, window: String, print: UInt64, now: Date = Date()) -> Bool {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier, mutedApps[bundleID] == nil,
              !ScreenReader.excludedBundles.contains(bundleID) else { return false }
        // Away from the Mac: nothing to proactively assist with.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120 else { return false }

        let key = bundleID + "|" + window
        if key != focusKey {
            focusKey = key
            focusSince = now
            return false
        }
        guard now.timeIntervalSince(focusSince) >= settle,
              now.timeIntervalSince(lastLook) >= minLookGap,
              now.timeIntervalSince(lastOffer) >= offerGap else { return false }
        if let previous = looked[key] {
            guard previous.print != print, now.timeIntervalSince(previous.date) >= sameWindowGap else { return false }
        }
        return true
    }

    func didLook(bundleID: String, window: String, print: UInt64) {
        lastLook = Date()
        looked[bundleID + "|" + window] = (Date(), print)
        if looked.count > 60 {
            let cutoff = Date().addingTimeInterval(-3600)
            looked = looked.filter { $0.value.date > cutoff }
        }
    }

    /// Did Nook already offer this (or something nearly identical) in recent hours?
    func alreadyOffered(_ text: String) -> Bool {
        let key = Self.normalize(text)
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        return offered.contains { $0.date > cutoff && $0.text == key }
    }

    /// Recent offers made by Nook, so the brain does not repeat itself.
    var recentOffers: [String] {
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        return offered.filter { $0.date > cutoff }.suffix(6).map { $0.text }
    }

    func didOffer(_ text: String) {
        lastOffer = Date()
        offered.append((Date(), Self.normalize(text)))
        offered = Array(offered.suffix(30))
    }

    func accepted() { declines = 0 }
    func declined() { declines += 1 }

    func mute(bundleID: String, name: String) {
        guard !bundleID.isEmpty else { return }
        mutedApps[bundleID] = name
        UserDefaults.standard.set(mutedApps, forKey: "thinkAlongMuted")
    }

    func unmuteAll() {
        mutedApps = [:]
        UserDefaults.standard.removeObject(forKey: "thinkAlongMuted")
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }
}
