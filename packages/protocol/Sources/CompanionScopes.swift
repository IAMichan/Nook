import Foundation

// What a paired phone may do (docs/COMPANION.md, "What a phone may do"). Chosen on the Mac when it pairs and editable
// later in Settings › Devices; a phone paired before scopes existed may do everything, as before.
//
// Every request needs one scope or none (`CompanionScopes.table`, one entry per op; a test fails when an op has none).
// The Mac refuses a request outside the phone's scopes, leaves out of every answer what the phone may not see, and lists
// only the features the phone may use, so the phone hides the rest. Scopes are stored by name: a name this build does
// not know (from a newer Nook) is ignored.

enum CompanionScope: String, Codable, CaseIterable, Sendable {
    /// See the sessions, their conversations, the home and the usage.
    case read
    /// Allow or deny approvals and answer questions.
    case approve
    /// Start sessions, send them messages, stop and manage them.
    case operate
    /// The Chats tab: read chats, answer the ones Nook can answer, mark them read or unread.
    case chats
    /// Play, pause and skip what plays on the Mac.
    case music
    /// Chat with Nook itself.
    case nookChat
}

enum CompanionScopes {
    /// What one op needs.
    enum Requirement: Equatable, Sendable {
        /// Keeping the connection and the phone's own registrations: always allowed, or nothing works at all.
        case always
        case scope(CompanionScope)
    }

    /// The one table of what each op needs. Every `CompanionOp` has an entry (`CompanionScopesTests`).
    static let table: [CompanionOp: Requirement] = [
        .hello: .always, .list: .always, .subscribe: .always, .ping: .always,
        .register: .always, .unregister: .always, .liveActivity: .always, .requestUpdate: .always,
        .timeline: .scope(.read), .home: .scope(.read), .usage: .scope(.read), .watch: .scope(.read), .diff: .scope(.read),
        .decide: .scope(.approve), .answer: .scope(.approve),
        .send: .scope(.operate), .stop: .scope(.operate), .options: .scope(.operate), .start: .scope(.operate),
        .manage: .scope(.operate),
        .inbox: .scope(.chats), .inboxChat: .scope(.chats), .inboxSend: .scope(.chats), .inboxMark: .scope(.chats),
        .music: .scope(.music),
        .chats: .scope(.nookChat), .chat: .scope(.nookChat), .ask: .scope(.nookChat), .chatStop: .scope(.nookChat),
    ]

    /// The scope each `CompanionFeature` belongs to; a feature not listed is about the connection and always offered.
    static let featureScopes: [String: CompanionScope] = [
        CompanionFeature.start: .operate, CompanionFeature.manage: .operate, CompanionFeature.steer: .operate,
        CompanionFeature.images: .operate, CompanionFeature.liveTimeline: .read, CompanionFeature.diff: .read,
        CompanionFeature.timeline: .read, CompanionFeature.home: .read, CompanionFeature.usage: .read,
        CompanionFeature.liveActivity: .read,
        CompanionFeature.chat: .nookChat, CompanionFeature.music: .music, CompanionFeature.inbox: .chats,
    ]

    /// Whether `granted` allows `op`. An op missing from the table is refused: a new op must be given its scope.
    static func allows(_ op: CompanionOp, granted: Set<CompanionScope>) -> Bool {
        switch table[op] {
        case .always?: return true
        case .scope(let scope)?: return granted.contains(scope)
        case nil: return false
        }
    }

    /// Scopes from stored names; names this build does not know are dropped. Nil (a device paired before scopes) is all.
    static func parse(_ names: [String]?) -> Set<CompanionScope> {
        guard let names else { return Set(CompanionScope.allCases) }
        return Set(names.compactMap(CompanionScope.init(rawValue:)))
    }

    /// Names to store or send, in a stable order.
    static func names(_ scopes: Set<CompanionScope>) -> [String] {
        CompanionScope.allCases.filter(scopes.contains).map(\.rawValue)
    }

    /// An answer as a phone with `granted` may see it: what it may not see left out, only the features it may use, and
    /// its scopes added to answers that list features (so the phone knows what to hide).
    static func redact(_ response: CompanionResponse, granted: Set<CompanionScope>) -> CompanionResponse {
        var response = response
        if !granted.contains(.read) {
            response.sessions = response.sessions.map { _ in [] }
            response.timeline = nil
            response.home = nil
            response.usage = nil
        }
        if !granted.contains(.operate) { response.launch = nil }
        if !granted.contains(.chats) {
            response.inbox = nil
            response.inboxLines = nil
            response.inboxTyping = nil
        }
        if !granted.contains(.nookChat) {
            response.conversations = nil
            response.messages = nil
        }
        if let features = response.features {
            response.features = features.filter { featureScopes[$0].map(granted.contains) ?? true }
            response.scopes = names(granted)
        }
        return response
    }
}

extension PairedDevice {
    /// What this phone may do; everything for a phone paired before scopes existed.
    var grantedScopes: Set<CompanionScope> { CompanionScopes.parse(scopes) }
}
