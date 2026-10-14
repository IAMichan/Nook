import Foundation
import AppKit
import CoreGraphics

/// Meedenken: bepaalt wanneer Nook ongevraagd even meekijkt en wanneer hij iets mag aanbieden.
/// Het denkwerk zelf doet AppModel; dit houdt het rustig en leert van je reacties.
///
/// - Pas als je een tijdje met hetzelfde venster bezig bent (niet bij elke klik naar een andere app).
/// - Hetzelfde venster pas na een paar minuten opnieuw, en alleen als er iets veranderde.
/// - Zeg je een paar keer nee, dan wacht Nook steeds langer. Zeg je ja, dan weer gewoon.
/// - "Niet in deze app" onthoudt Nook voorgoed (terug te zetten in Instellingen).
@MainActor
final class ThinkAlong: ObservableObject {
    /// Apps waarin Nook nooit meedenkt (bundle-ID → naam), op jouw verzoek.
    @Published private(set) var mutedApps: [String: String]

    private var focusKey = ""
    private var focusSince = Date()
    private var lastLook = Date.distantPast
    private var lastOffer = Date.distantPast
    private var looked: [String: (date: Date, print: UInt64)] = [:]
    private var offered: [(date: Date, text: String)] = []
    private var declines = 0

    /// Zo lang moet je met hetzelfde venster bezig zijn voor Nook meekijkt.
    private let settle: TimeInterval = 25
    private let minLookGap: TimeInterval = 120
    private let sameWindowGap: TimeInterval = 240
    private let baseOfferGap: TimeInterval = 180

    init() {
        mutedApps = (UserDefaults.standard.dictionary(forKey: "thinkAlongMuted") as? [String: String]) ?? [:]
    }

    /// Hoe lang Nook na een aanbod wacht: langer na elk nee, tot hooguit een half uur.
    private var offerGap: TimeInterval {
        min(1800, baseOfferGap * pow(2, Double(min(declines, 4))))
    }

    /// Moet Nook nu meekijken? `bundleID` en `window` beschrijven het voorste venster, `print` de inhoud ervan.
    func shouldLook(bundleID: String, window: String, print: UInt64, now: Date = Date()) -> Bool {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier, mutedApps[bundleID] == nil,
              !ScreenReader.excludedBundles.contains(bundleID) else { return false }
        // Even weg van je Mac: dan valt er niets mee te denken.
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

    /// Bood Nook dit (of iets vrijwel gelijks) de afgelopen uren al aan?
    func alreadyOffered(_ text: String) -> Bool {
        let key = Self.normalize(text)
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        return offered.contains { $0.date > cutoff && $0.text == key }
    }

    /// Wat Nook onlangs aanbood, zodat het brein zichzelf niet herhaalt.
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
