import Foundation

// The Agents tab on the phone does what the Mac's Agents tab does (`CompanionFeature.agentsTab`): the row and header
// menus (pin, settle, mark unread, fork, retry, restart the agent, a new title, delete), the list's shelves (Pinned,
// Working, Snoozed, Settled), "Always allow", several questions at once with multi-select, the composer's effort, mode
// and model, the messages in line, and a new session with its effort, access, title, base branch and files. Everything
// goes through the Mac's own functions; the Mac lists per session what applies (`SessionDigest.actions`), so the phone
// offers exactly what works and an older phone ignores what it does not know. Foundation only, so the rules are tested
// on Linux.

/// One question of an agent's ask, as the Mac's question card shows it (`RunQuestionPanel`).
struct SessionQuestion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// The short label over it ("Approach"); empty when the agent gave none.
    var header: String
    var question: String
    var options: [String]
    /// A preview per option (a mock-up or code), empty for one without; nil when no option has one.
    var previews: [String]? = nil
    /// Several options may be picked.
    var multiSelect: Bool
    /// Your own words are taken besides the options.
    var allowsOther: Bool
}

/// The composer's choices for the next turns of a session, as the Mac's model picker offers them. Each list holds the
/// choice's id and its name as the Mac shows it; an empty list (or nil) means there is nothing to change.
struct SessionControls: Codable, Equatable, Sendable {
    /// The reasoning effort chosen now ("" the agent's default) and the levels its model offers, "" first.
    var effort: String? = nil
    var efforts: [LaunchOptions.Model]? = nil
    /// "agent" or "plan"; nil when the agent has no plan mode.
    var mode: String? = nil
    /// The model chosen now and the ones it can switch to (only the session's own agent and account: another agent
    /// moves the session, which is done on the Mac).
    var model: String? = nil
    var models: [LaunchOptions.Model]? = nil
}

/// A message that waits in line for after the turn (`MessageQueue` on the Mac).
struct QueuedDigest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String

    /// How much of one queued message travels: enough to recognise it.
    static let limit = 240
}

/// What a decision on an approval can be besides allow and deny (`CompanionRequest.decision`).
enum ApprovalChoice: String, Codable, Sendable {
    /// Allow it and remember it: the agent (or Nook) stops asking for what is like it.
    case always
}

/// The shelves of the Mac's Agents list (`InboxLayout.sections`), as the phone puts a session on one. What needs you is
/// never folded away: it stays on top, as on the Mac ("What waits for you is never hidden").
enum SessionShelf: String, CaseIterable, Sendable {
    case needsYou, pinned, working, active, snoozed, settled

    /// The shelf of `session`. `showWorking`: sessions that work and need nothing from you get a shelf of their own, as
    /// the Mac's "Show working" does; off, they stay among the others.
    static func of(_ session: SessionDigest, showWorking: Bool, now: Double = Date().timeIntervalSince1970) -> SessionShelf {
        let needs = needsYou(session)
        if needs { return .needsYou }
        if session.pinned == true { return .pinned }
        if session.settled == true { return .settled }
        if let until = session.snoozedUntil, until > now { return .snoozed }
        if showWorking, session.attention == "working" { return .working }
        return .active
    }

    /// An approval or a question waits, or the session stopped on something only you can resolve.
    static func needsYou(_ session: SessionDigest) -> Bool {
        !session.items.isEmpty || ["approval", "input", "failed", "limited"].contains(session.attention)
    }

    /// The sessions on each shelf, newest first within it.
    static func place(_ sessions: [SessionDigest], showWorking: Bool,
                      now: Double = Date().timeIntervalSince1970) -> [SessionShelf: [SessionDigest]] {
        var shelves: [SessionShelf: [SessionDigest]] = [:]
        for session in sessions.sorted(by: { $0.updated > $1.updated }) {
            shelves[of(session, showWorking: showWorking, now: now), default: []].append(session)
        }
        return shelves
    }
}

/// The row and header menus of a session, in the Mac's order (`AgentInboxList.contextMenu`,
/// `AgentRunPanel.sessionActions`), from the actions the Mac lists for it. One place, so the iPhone and the Tauri
/// companion show the same menu.
enum SessionMenu {
    /// A row's long press, as the Mac's row menu: rename, pin, settle, snooze, then fork, restart and mark unread, then
    /// archive and delete. Snooze shows as one submenu (`snoozeHour` stands for it).
    static let row: [SessionAction] = [.rename, .pin, .unpin, .settle, .reopen, .unsnooze, .snoozeHour,
                                       .fork, .restartAgent, .markUnread, .mainThreadOn, .mainThreadOff,
                                       .archive, .delete, .end]

    /// The session's own header, as the Mac's: retry and settle first, then rename, a new title, fork and restart, then
    /// pin, snooze and mark unread, then archive and delete.
    static let header: [SessionAction] = [.retry, .settle, .reopen, .rename, .regenerateTitle, .fork, .restartAgent,
                                          .mainThreadOn, .mainThreadOff, .pin, .unpin, .unsnooze, .snoozeHour, .markUnread,
                                          .archive, .delete, .end]

    /// The actions of `order` the session offers, in that order. `deleteWithWorktree` rides with `delete` (a choice in
    /// its confirmation), the snooze moments with `snoozeHour`.
    static func items(_ order: [SessionAction], offered names: [String]?) -> [SessionAction] {
        let offered = Set((names ?? []).compactMap(SessionAction.init(rawValue:)))
        return order.filter(offered.contains)
    }

    /// Whether the action changes nothing you cannot get back: archive and delete ask first.
    static func confirms(_ action: SessionAction) -> Bool {
        action == .delete || action == .deleteWithWorktree || action == .end
    }
}

/// The answers to an ask with several questions, as the phone collects them and the Mac checks them
/// (`CompanionRequest.answers`).
enum SessionAnswers {
    /// The most one answer may hold, as a message.
    static let limit = 2_000

    /// The answers as the Mac takes them: one entry per question, each answer one of its options or (where it takes
    /// them) your own words, a single answer where only one may be picked. Nil when one is missing or not allowed.
    static func validated(_ answers: [String: [String]]?, for questions: [SessionQuestion]) -> [String: [String]]? {
        guard let answers, !questions.isEmpty else { return nil }
        var result: [String: [String]] = [:]
        for question in questions {
            let picked = (answers[question.id] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !picked.isEmpty, picked.count == Set(picked).count else { return nil }
            if !question.multiSelect, picked.count > 1 { return nil }
            for answer in picked {
                guard answer.count <= limit else { return nil }
                if !question.options.contains(answer), !question.allowsOther { return nil }
            }
            result[question.id] = picked
        }
        return result
    }

    /// Toggles `option` in what is picked for a question: added or taken out where several may be picked, the only
    /// answer otherwise.
    static func toggle(_ option: String, in picked: [String], multiSelect: Bool) -> [String] {
        guard multiSelect else { return [option] }
        return picked.contains(option) ? picked.filter { $0 != option } : picked + [option]
    }
}

/// A session related to another one (`SessionDigest.lineage`), as one row of the Mac's Lineage control.
struct LineageDigest: Codable, Equatable, Identifiable, Sendable {
    /// How it relates to the session that lists it.
    enum Role: String, Codable, Sendable {
        /// The session that delegated this one, or that this one was forked or compared from.
        case parentAgent, parentThread
        case fork, comparison, subThread, sideChat
    }

    /// Where it is in its work, as the control's rows say it.
    enum Status: String, Codable, Sendable {
        case working, approval, question, done, failed, stopped

        /// It still works or waits for you.
        var isLive: Bool { self == .working || self == .approval || self == .question }
        /// It waits for you: the amber of every list.
        var needsYou: Bool { self == .approval || self == .question }
    }

    var id: String
    var title: String
    var role: Role
    var status: Status
    /// A delegated task that ended: under "Previous agents", folded, on the Mac.
    var previous: Bool? = nil

    /// At most this many travel with one session; the newest are kept.
    static let limit = 20
}

extension QueuedDigest {
    /// A queued message as it travels: its words cut at `limit`.
    static func clipped(id: String, text: String) -> QueuedDigest {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return QueuedDigest(id: id, text: clean.count > limit ? String(clean.prefix(limit)) + "…" : clean)
    }
}

extension SessionAction {
    /// The actions that came with the Agents tab (`CompanionFeature.agentsTab`): a Mac lists them only with that feature.
    static let agentsTab: Set<SessionAction> = [.pin, .unpin, .settle, .reopen, .markUnread, .fork, .retry, .restartAgent,
                                                 .regenerateTitle, .delete, .deleteWithWorktree, .setEffort, .setMode,
                                                 .setModel, .unqueue, .editQueued, .moveQueued, .sendQueuedNow]
}
