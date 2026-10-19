import Foundation
import AppKit
import CoreGraphics

/// Think-along: determines when Nook proactively observes and when it may offer assistance.
/// The thinking itself is done by AppModel; this keeps suggestions calm and learns from your responses.
///
/// - Only after staying with the same window for a while (not on every switch between apps).
/// - Revisits the same window only after a few minutes, and only if something changed.
/// - If declined multiple times, Nook waits progressively longer. If accepted, resets back to normal.
/// - At most a handful of offers a day: interrupting costs attention, so only the best ones should get through.
/// - Never offers the same thing twice in a day, even reworded; a declined topic stays quiet for a week.
/// - Remembers "Not in this app" permanently (resettable in Settings).
@MainActor
final class ThinkAlong: ObservableObject {
    private struct Offer {
        let date: Date
        let text: String
        var declined: Bool
    }

    /// Apps where Nook never proactively assists (bundle ID → name), at your request.
    @Published private(set) var mutedApps: [String: String]

    private var focusKey = ""
    private var focusSince = Date()
    private var lastLook = Date.distantPast
    private var lastOffer = Date.distantPast
    private var looked: [String: (date: Date, print: UInt64)] = [:]
    /// Recent offers and whether they were declined; kept across launches so a restart does not repeat them.
    private var offered: [Offer]
    private var declines = 0

    /// Duration of focus on the same window required before Nook observes.
    private let settle: TimeInterval = 25
    private let minLookGap: TimeInterval = 120
    private let sameWindowGap: TimeInterval = 240
    private let baseOfferGap: TimeInterval = 180
    private let repeatGap: TimeInterval = 24 * 3600
    private let declinedGap: TimeInterval = 7 * 24 * 3600
    private let dailyLimit = 6

    init() {
        mutedApps = (UserDefaults.standard.dictionary(forKey: "thinkAlongMuted") as? [String: String]) ?? [:]
        let stored = UserDefaults.standard.array(forKey: "thinkAlongOffered") as? [[String: Any]] ?? []
        offered = stored.compactMap { entry -> Offer? in
            guard let date = entry["date"] as? Date, let text = entry["text"] as? String else { return nil }
            return Offer(date: date, text: text, declined: entry["declined"] as? Bool ?? false)
        }
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
              now.timeIntervalSince(lastOffer) >= offerGap,
              offered.filter({ now.timeIntervalSince($0.date) < repeatGap }).count < dailyLimit else { return false }
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

    /// Did Nook already offer this (or something nearly identical) today, or was it declined this week?
    func alreadyOffered(_ text: String, now: Date = Date()) -> Bool {
        offered.contains { entry in
            let gap = entry.declined ? declinedGap : repeatGap
            return now.timeIntervalSince(entry.date) < gap && NudgeFilter.similar(entry.text, text)
        }
    }

    /// Recent offers made by Nook, so the brain does not repeat itself.
    var recentOffers: [String] {
        let cutoff = Date().addingTimeInterval(-repeatGap)
        return offered.filter { $0.date > cutoff }.suffix(6).map { $0.text }
    }

    func didOffer(_ text: String) {
        lastOffer = Date()
        offered.append(Offer(date: Date(), text: NudgeFilter.normalize(text), declined: false))
        saveOffered()
    }

    func accepted() { declines = 0 }

    /// A declined offer counts against its topic for a week, not just against the next few minutes.
    func declined(_ text: String? = nil) {
        declines += 1
        guard let text else { return }
        let key = NudgeFilter.normalize(text)
        if let index = offered.lastIndex(where: { NudgeFilter.similar($0.text, key) }) {
            offered[index].declined = true
            saveOffered()
        }
    }

    private func saveOffered() {
        let cutoff = Date().addingTimeInterval(-declinedGap)
        offered = Array(offered.filter { $0.date > cutoff }.suffix(40))
        let stored: [[String: Any]] = offered.map { ["date": $0.date, "text": $0.text, "declined": $0.declined] }
        UserDefaults.standard.set(stored, forKey: "thinkAlongOffered")
    }

    func mute(bundleID: String, name: String) {
        guard !bundleID.isEmpty else { return }
        mutedApps[bundleID] = name
        UserDefaults.standard.set(mutedApps, forKey: "thinkAlongMuted")
    }

    func unmuteAll() {
        mutedApps = [:]
        UserDefaults.standard.removeObject(forKey: "thinkAlongMuted")
    }
}
