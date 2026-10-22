import Foundation

/// Finds an app by any name it goes by, whatever language the Mac runs in. On a Dutch Mac System Settings shows as
/// "Systeeminstellingen" and Control Center as "Bedieningspaneel", while the model (and many people) say the English
/// name: an app is known by its shown name, the name of its bundle on disk ("System Settings.app"), the names in its
/// Info.plist, and for Apple's own apps the English names people use for them. Foundation only; tested in AppNamesTests.
enum AppNames {
    /// One app that could be meant.
    struct Candidate: Equatable {
        /// Every name it goes by: shown, on disk, in its Info.plist.
        var names: [String]
        var bundleID: String?
    }

    static let systemSettings = "com.apple.systempreferences"
    static let controlCenter = "com.apple.controlcenter"

    /// Apps that run without a Dock icon but that Nook may still read and control: Control Center holds Focus (Do Not
    /// Disturb), Wi-Fi, Bluetooth, sound and display, all from its menu bar items.
    static let systemAgents: Set<String> = [controlCenter]

    /// Names people use for Apple's apps that are not their name on disk, in the five languages Nook speaks, folded.
    static let aliases: [String: String] = [
        "system settings": systemSettings, "system preferences": systemSettings, "settings": systemSettings,
        "systeeminstellingen": systemSettings, "systeemvoorkeuren": systemSettings, "instellingen": systemSettings,
        "systemeinstellungen": systemSettings, "reglages systeme": systemSettings, "preferences systeme": systemSettings,
        "ajustes del sistema": systemSettings, "preferencias del sistema": systemSettings,
        "control center": controlCenter, "control centre": controlCenter, "controlcenter": controlCenter,
        "bedieningspaneel": controlCenter, "kontrollzentrum": controlCenter, "centre de controle": controlCenter,
        "centro de control": controlCenter
    ]

    /// The bundle identifier an alias stands for, or nil.
    static func aliasBundleID(_ query: String) -> String? {
        aliases[Fuzzy.fold(query)]
    }

    /// The names an app goes by, without empty ones or repeats.
    static func names(shown: String?, bundlePath: String?, plistNames: [String?]) -> [String] {
        let onDisk = bundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        var seen = Set<String>()
        return ([shown, onDisk] + plistNames).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Which candidate is meant: an alias's bundle, a bundle identifier, the same name in any form, then the closest name.
    /// Nil when nothing is close or two apps are equally close.
    static func index(of query: String, in candidates: [Candidate]) -> Int? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let bundle = aliasBundleID(clean), let found = candidates.firstIndex(where: { $0.bundleID == bundle }) {
            return found
        }
        if let found = candidates.firstIndex(where: { $0.bundleID?.caseInsensitiveCompare(clean) == .orderedSame }) {
            return found
        }
        let wanted = Fuzzy.fold(clean)
        let exact = candidates.indices.filter { candidates[$0].names.contains { Fuzzy.fold($0) == wanted } }
        if let first = exact.first { return first }
        guard let match = Fuzzy.best(clean, in: candidates.flatMap(\.names)) else { return nil }
        let owners = candidates.indices.filter { candidates[$0].names.contains(match) }
        return owners.count == 1 ? owners[0] : nil
    }
}
