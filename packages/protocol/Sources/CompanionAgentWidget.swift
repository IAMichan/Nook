import Foundation

// The Agent activity widget on the iPhone's Home Screen and Lock Screen (docs/COMPANION.md, "Agent activity widget"): the
// same agents the Live Activity follows (a session that works or waits on you), as the app last heard them from its Mac,
// kept in the app group. The widget refreshes when the app takes in a new list; unfinished work older than
// `staleAfter` reads as out of date, since a closed app hears nothing. Foundation only, next to `CompanionLiveActivity`
// in the widget extension.

/// The agents as the app last heard them from its Mac.
struct AgentActivitySnapshot: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Identifiable, Sendable {
        /// `SessionDigest.id`.
        var id: String
        var title: String
        var project: String
        /// "Claude Code", "Codex".
        var agent: String
        var phase: LiveActivityPhase
        /// When the session last changed on the Mac (seconds since 1970).
        var updated: Double
    }

    var macName: String
    /// Waiting on you first, then working; the newest first in each.
    var agents: [Agent]
    /// When the app took in the list (seconds since 1970).
    var taken: Double

    static let fileName = "agent-activity-widget.json"
    /// No more than the Live Activities the Mac keeps at once.
    static let maxAgents = LiveActivityPlanner.maxActivities
    /// Older than this, unfinished work reads as out of date, as a Live Activity's stale date does.
    static let staleAfter = LiveActivityPlanner.staleAfter

    /// The agents of `snapshots` the Live Activity shows: those that work or wait on you.
    init(macName: String, snapshots: [(snapshot: LiveActivitySnapshot, updated: Double)], taken: Date) {
        self.macName = macName
        self.taken = taken.timeIntervalSince1970
        agents = snapshots.filter { !$0.snapshot.phase.isFinished }
            .map { Agent(id: $0.snapshot.session, title: $0.snapshot.title, project: $0.snapshot.project, agent: $0.snapshot.agent,
                         phase: $0.snapshot.phase, updated: $0.updated) }
            .sorted { ($0.phase == .waiting ? 1 : 0, $0.updated) > ($1.phase == .waiting ? 1 : 0, $1.updated) }
        agents = Array(agents.prefix(Self.maxAgents))
    }

    /// Whether what it says is too old to read as now.
    func stale(now: Date) -> Bool { !agents.isEmpty && now.timeIntervalSince1970 - taken > Self.staleAfter }

    /// How many wait on you.
    var waiting: Int { agents.filter { $0.phase == .waiting }.count }

    /// The same agents, as far as a widget needs to be redrawn for: without the moment it was taken.
    func sameAgents(as other: AgentActivitySnapshot?) -> Bool { other?.agents == agents && other?.macName == macName }
}

/// The widget's kind, for the app to ask WidgetKit to read it again.
enum AgentActivityWidgetKind {
    static let kind = "NookAgentActivity"
}
