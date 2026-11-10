import Foundation

// Which versions of the Mac and the phone can talk to each other (docs/COMPANION.md, "Versions").
//
// Most differences are handled by `CompanionFeature`: the phone only offers what the Mac lists, so a newer phone works with
// an older Mac and the other way round. The protocol version is for the day that is not enough: when the wire format
// itself changes, each side says the oldest version of the other it still understands, and the phone shows which of the
// two to update instead of failing with an unreadable answer.
//
// Both sides send their protocol version and app version with `hello`, `list` and `subscribe`. A side that sends none is
// version 1, the protocol as it was before versions existed.

enum CompanionProtocol {
    /// The protocol this build speaks. 3: pull requests, files with a message, snoozing to a moment, `limitResetsAt`.
    static let version = 3
    /// The oldest Mac this phone still works with.
    static let oldestMac = 1
    /// The oldest phone this Mac still works with; the Mac sends it as `CompanionResponse.oldestPhone`.
    static let oldestPhone = 1
    /// What a side that sends no version speaks.
    static let unversioned = 1

    /// This build's version as people read it ("1.4.0"), from the app bundle; nil when the bundle has none (tests).
    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// An app version as it may be shown: printable, at most 40 characters; nil when nothing is left.
    static func cleanVersion(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(40))
    }
}

/// Whether this phone and this Mac can work together, and if not, which one to update.
enum CompanionCompatibility: Equatable, Sendable {
    case ok
    /// The Mac speaks an older protocol than this phone still supports: update Nook on the Mac.
    case macTooOld
    /// The Mac no longer supports this phone's protocol: update the app on the phone.
    case phoneTooOld

    /// Features the Mac advertises that this phone build does not recognize. Nil means no feature list was sent.
    static func unknownFeatures(_ advertised: [String]?) -> Set<String>? {
        guard let advertised else { return nil }
        return Set(advertised).subtracting(CompanionFeature.all)
    }

    /// Decides from what the Mac said (`macVersion` and `oldestPhone`, nil from a Mac that predates versions).
    static func check(macVersion: Int?, oldestPhone: Int?, phoneVersion: Int = CompanionProtocol.version,
                      oldestMac: Int = CompanionProtocol.oldestMac) -> CompanionCompatibility {
        let mac = macVersion ?? CompanionProtocol.unversioned
        if mac < oldestMac { return .macTooOld }
        if phoneVersion < (oldestPhone ?? CompanionProtocol.unversioned) { return .phoneTooOld }
        return .ok
    }

    /// The same, from an answer to `hello`, `list` or `subscribe`.
    static func check(_ response: CompanionResponse, phoneVersion: Int = CompanionProtocol.version,
                      oldestMac: Int = CompanionProtocol.oldestMac) -> CompanionCompatibility {
        check(macVersion: response.protocolVersion, oldestPhone: response.oldestPhone, phoneVersion: phoneVersion, oldestMac: oldestMac)
    }

    /// Both work together, but one speaks an older protocol than the other, so some of what the newer one offers is
    /// missing: which one to update for it. Nil when both speak the same, or when they cannot work together at all (that
    /// is `check`'s to say).
    static func notice(macVersion: Int?, oldestPhone: Int? = nil, phoneVersion: Int = CompanionProtocol.version,
                       oldestMac: Int = CompanionProtocol.oldestMac) -> CompanionVersionNotice? {
        guard check(macVersion: macVersion, oldestPhone: oldestPhone, phoneVersion: phoneVersion, oldestMac: oldestMac) == .ok else { return nil }
        let mac = macVersion ?? CompanionProtocol.unversioned
        if mac < phoneVersion { return .macBehind }
        if mac > phoneVersion { return .phoneBehind }
        return nil
    }

    /// The same, from an answer to `hello`, `list` or `subscribe`.
    static func notice(_ response: CompanionResponse, phoneVersion: Int = CompanionProtocol.version) -> CompanionVersionNotice? {
        notice(macVersion: response.protocolVersion, oldestPhone: response.oldestPhone, phoneVersion: phoneVersion)
    }

    /// Seen from the Mac: a phone that works, but speaks an older protocol than this Mac (nil: a phone that predates
    /// versions, which is version 1).
    static func phoneBehind(_ phoneVersion: Int?, macVersion: Int = CompanionProtocol.version) -> Bool {
        phoneSupported(phoneVersion) && (phoneVersion ?? CompanionProtocol.unversioned) < macVersion
    }

    /// The same, seen from the Mac for a phone that sent `phoneVersion` (nil: a phone that predates versions).
    static func phoneSupported(_ phoneVersion: Int?, oldestPhone: Int = CompanionProtocol.oldestPhone) -> Bool {
        (phoneVersion ?? CompanionProtocol.unversioned) >= oldestPhone
    }
}

/// A gentle word when the Mac and the phone work together but one of them is behind (`CompanionCompatibility.notice`).
enum CompanionVersionNotice: Equatable, Sendable {
    /// Update Nook on the Mac to use everything this app offers.
    case macBehind
    /// Update the app to use everything Nook on the Mac offers.
    case phoneBehind
}
