// Which connector is broken, why in plain words, and what "Fix it" does, the same for every connector (calendar, mail, the
// forges, Stripe, custom sources). A connector only tells its `ConnectorErrorKind`; the sorting, the wording keys and the
// fix come from here. Also the gallery's search, so one fold decides what matches. Foundation only, so it is tested
// anywhere.
import Foundation

/// What "Fix it" does for a broken connector.
enum ConnectorFix: String, Equatable, Sendable {
    /// Open the account in Settings: sign in again, or correct the address or the permission.
    case reconnect
    /// Read it again now: the service was only unreachable or asked Nook to wait.
    case retry
    /// Nothing Nook can do for this one: it names the problem and links the service.
    case inspect

    /// The key of the button's title (`tr`).
    var titleKey: String { "connectors.health.fix." + rawValue }
}

/// One connector's health, as the Health page lists it.
struct ConnectorHealthEntry: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: ConnectorErrorKind
    /// What the service itself said, shown under the plain reason; may be empty.
    var detail: String
    var fix: ConnectorFix

    /// The key of the plain-language reason (`tr`): never the raw error alone.
    var reasonKey: String { "connectors.health.reason." + kind.rawValue }
}

enum ConnectorHealth {
    /// The fix that belongs to a kind of failure: reconnecting beats retrying when the credentials are the problem.
    static func fix(for kind: ConnectorErrorKind) -> ConnectorFix {
        if kind.needsReconnect { return .reconnect }
        if kind.canRetry { return .retry }
        return .inspect
    }

    /// The broken connectors among `reports` (id, title, failure kind, what it said; nil kind = healthy), the ones that
    /// need you first (a sign-in, a setting), then the ones that mend themselves, each group by title.
    static func entries(_ reports: [(id: String, title: String, kind: ConnectorErrorKind?, detail: String)]) -> [ConnectorHealthEntry] {
        reports.compactMap { report in
            guard let kind = report.kind else { return nil }
            return ConnectorHealthEntry(id: report.id, title: report.title, kind: kind, detail: report.detail, fix: fix(for: kind))
        }.sorted {
            let lhs = $0.fix == .reconnect ? 0 : 1, rhs = $1.fix == .reconnect ? 0 : 1
            if lhs != rhs { return lhs < rhs }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

/// The gallery's search: name, category and aliases, case and accents ignored, every word of the query must match.
enum ConnectorGallerySearch {
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = fold(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = fields.map(fold).joined(separator: " ")
        return words.allSatisfy { haystack.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

/// What a connector may do, as one plain sentence key per level: scopes are shown by what they let Nook do, never by
/// their technical names.
enum ConnectorAccessLevel: String, CaseIterable, Sendable {
    /// Reads only (a calendar, a list of pull requests).
    case read
    /// Reads, and writes after your yes on an approval card.
    case readWrite

    var summaryKey: String { "connectors.access." + rawValue }
}
