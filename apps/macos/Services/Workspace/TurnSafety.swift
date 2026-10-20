import Foundation

// MARK: - Settling open work

/// Why a turn ended; decides how work that is still open gets closed.
enum SettleReason: Equatable, Sendable {
    case completed, stopped, failed, processExited
}

struct EventSettlement: Equatable, Sendable {
    var eventID: UUID
    var state: RunEvent.State
}

/// Every path that ends a turn (done, Stop, failure, process exit) must leave no event spinning or awaiting an
/// answer.
enum OpenWork {
    static func settle(events: [RunEvent], reason: SettleReason) -> [EventSettlement] {
        events.compactMap { event in
            guard let state = event.state else { return nil }
            switch (event.kind, state) {
            case (.tool, .running), (.fileChange, .running):
                return EventSettlement(eventID: event.id, state: reason == .completed ? .done : .failed)
            case (.assistant, .running), (.thinking, .running):
                return EventSettlement(eventID: event.id, state: .done)
            case (.approval, .pending):
                return EventSettlement(eventID: event.id, state: .expired)
            default:
                // Finished events keep their outcome; that also makes a second settle a no-op.
                return nil
            }
        }
    }

    static func apply(_ settlements: [EventSettlement], to events: inout [RunEvent]) {
        let byID = Dictionary(settlements.map { ($0.eventID, $0.state) }, uniquingKeysWith: { _, last in last })
        for index in events.indices {
            if let state = byID[events[index].id] { events[index].state = state }
        }
    }

    /// Approvals still waiting for an answer: the ones that need the user (or expire at the end of the turn).
    static func unresolvedRequests(events: [RunEvent]) -> [RunEvent] {
        events.filter { $0.kind == .approval && $0.state == .pending }
    }
}

// MARK: - Stop

enum StopAction: Equatable, Sendable {
    /// Ask the agent to interrupt its turn (t = 0).
    case sendInterrupt
    /// Close the agent's input so a stuck process notices (after 2.5 s).
    case closeInput
    /// The agent never answered: settle all open work and mark the session stopped (after 10 s).
    case forceFinalize
    /// Stop was pressed before the turn had a provider turn id:
    /// there is nothing to interrupt yet, so the manager cancels the pending launch/send; the interrupt follows
    /// as soon as `markTurnStarted()` is called, and the 10 s deadline finishes it anyway.
    case cancelPending
}

/// The Stop sequence as a value-type state machine. No timers: the manager asks `actions(now:)` whenever it wakes
/// up and schedules one timer for `nextCheck(now:)`.
struct StopCoordinator: Equatable, Sendable {
    static let closeInputDelay: TimeInterval = 2.5
    static let forceFinalizeDelay: TimeInterval = 10

    private(set) var startedAt: Date?
    private(set) var turnStarted: Bool
    private(set) var isFinished = false
    private var sentInterrupt = false
    private var sentCancelPending = false
    private var sentCloseInput = false
    private var sentForceFinalize = false

    init(turnStarted: Bool = true) { self.turnStarted = turnStarted }

    var isActive: Bool { startedAt != nil && !isFinished }

    /// A second Stop while one is running changes nothing.
    mutating func begin(now: Date, turnStarted: Bool? = nil) {
        if let turnStarted { self.turnStarted = turnStarted }
        guard startedAt == nil, !isFinished else { return }
        startedAt = now
    }

    mutating func markTurnStarted() { turnStarted = true }

    mutating func processExited(now: Date) {
        isFinished = true
    }

    /// What is newly due; each action is returned once. Late calls return everything that is due, in order.
    mutating func actions(now: Date) -> [StopAction] {
        guard let startedAt, !isFinished else { return [] }
        let elapsed = now.timeIntervalSince(startedAt)
        var due: [StopAction] = []
        if turnStarted {
            if !sentInterrupt { sentInterrupt = true; due.append(.sendInterrupt) }
        } else if !sentCancelPending {
            sentCancelPending = true
            due.append(.cancelPending)
        }
        if elapsed >= Self.closeInputDelay, !sentCloseInput {
            sentCloseInput = true
            due.append(.closeInput)
        }
        if elapsed >= Self.forceFinalizeDelay, !sentForceFinalize {
            sentForceFinalize = true
            isFinished = true
            due.append(.forceFinalize)
        }
        return due
    }

    /// When to call `actions(now:)` again; nil once finished or when nothing is left. A date in the past means
    /// "right now".
    func nextCheck(now: Date) -> Date? {
        guard let startedAt, !isFinished else { return nil }
        if (turnStarted && !sentInterrupt) || (!turnStarted && !sentCancelPending) { return now }
        if !sentCloseInput { return startedAt.addingTimeInterval(Self.closeInputDelay) }
        if !sentForceFinalize { return startedAt.addingTimeInterval(Self.forceFinalizeDelay) }
        return nil
    }
}

// MARK: - Session approvals

/// What an approval asked for. Codex's own "accept for session" only covers the exact command, so Nook keeps its
/// own grants per run.
enum ApprovalKind: Hashable, Codable, Sendable {
    case command, fileChange, permission
    case other(String)
}

/// Granted request kinds of one run, valid for the permission mode they were granted in.
struct SessionApprovals: Equatable, Sendable {
    private(set) var mode: PermissionPolicy?
    private var granted: Set<ApprovalKind> = []

    init() {}

    var kinds: Set<ApprovalKind> { granted }

    /// A grant under another mode first drops the old ones: switching modes never carries trust over.
    mutating func grant(kind: ApprovalKind, mode: PermissionPolicy) {
        modeChanged(to: mode)
        granted.insert(kind)
    }

    func isGranted(kind: ApprovalKind, mode: PermissionPolicy) -> Bool {
        self.mode == mode && granted.contains(kind)
    }

    mutating func modeChanged(to mode: PermissionPolicy) {
        if self.mode != mode { granted.removeAll() }
        self.mode = mode
    }

    mutating func reset() {
        granted.removeAll()
        mode = nil
    }
}

// MARK: - Live rights

/// What a session's current rights let through without asking. An agent keeps the rights it was started with (a flag,
/// or Codex's policy for the turn), so after you change them Nook answers the requests they now cover itself: the
/// change counts at once, not from the next turn. Plan mode, questions and MCP confirmations always ask.
enum LiveRights {
    static let claudeEditTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    static func coversClaude(tool: String, permission: PermissionPolicy, mode: ExecutionMode) -> Bool {
        guard mode != .plan, tool != "AskUserQuestion", tool != "ExitPlanMode" else { return false }
        switch permission {
        case .bypass: return true
        case .acceptEdits: return claudeEditTools.contains(tool)
        case .ask: return false
        }
    }

    static func coversCodex(_ kind: CodexApprovalRequest.Kind, permission: PermissionPolicy, mode: ExecutionMode) -> Bool {
        guard mode != .plan else { return false }
        switch kind {
        case .fileChange, .legacyPatch: return permission != .ask
        case .command, .legacyCommand: return permission == .bypass
        case .mcpTool: return false
        }
    }
}

// MARK: - Background work

/// Background work of one session (sub-agents, monitors, background commands). While any is running the session
/// is neither "done" nor idle-released.
struct BackgroundRoster: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case subagent, monitor, command, other }
    enum CancelReason: String, Codable, Sendable { case stopped, processExited, sessionClosed }

    private(set) var pending: [(id: String, kind: Kind)] = []
    private(set) var lastCancelReason: CancelReason?

    init() {}

    static func == (a: BackgroundRoster, b: BackgroundRoster) -> Bool {
        a.lastCancelReason == b.lastCancelReason && a.pending.map(\.id) == b.pending.map(\.id)
            && a.pending.map(\.kind) == b.pending.map(\.kind)
    }

    var hasPending: Bool { !pending.isEmpty }
    var pendingCount: Int { pending.count }
    func pendingCount(of kind: Kind) -> Int { pending.filter { $0.kind == kind }.count }
    func contains(_ id: String) -> Bool { pending.contains { $0.id == id } }

    /// A command that runs in the foreground blocks its own turn, so it is not background work.
    mutating func start(_ id: String, kind: Kind, background: Bool = true) {
        guard background, !id.isEmpty, !contains(id) else { return }
        pending.append((id, kind))
        lastCancelReason = nil
    }

    mutating func finish(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Returns the ids that were still running, in start order.
    @discardableResult
    mutating func cancelAll(reason: CancelReason) -> [String] {
        let ids = pending.map(\.id)
        pending.removeAll()
        if !ids.isEmpty { lastCancelReason = reason }
        return ids
    }
}
