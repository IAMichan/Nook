import SwiftUI
import WidgetKit

/// The agents that work or wait on you, on the Home Screen and the Lock Screen (docs/COMPANION.md, "Agent activity
/// widget"): the same sessions the Live Activity follows, as the app last heard them from its Mac (`AgentActivitySnapshot`
/// in the app group). It refreshes when the app takes in a new list; unfinished work older than ten minutes reads as out
/// of date, since a closed app hears nothing. A tap opens the session (or the app).
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AgentActivityWidgetKind.kind, provider: AgentActivityProvider()) { entry in
            AgentActivityWidgetView(entry: entry)
                .containerBackground(Theme.canvas, for: .widget)
        }
        .configurationDisplayName(Text("Agent activity"))
        .description(Text("The agents that work or wait on you on your Mac."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct AgentActivityEntry: TimelineEntry {
    let date: Date
    /// Nil before the app heard from a Mac.
    let snapshot: AgentActivitySnapshot?

    var stale: Bool { snapshot?.stale(now: date) ?? false }
    var agents: [AgentActivitySnapshot.Agent] { snapshot?.agents ?? [] }
}

struct AgentActivityProvider: TimelineProvider {
    private static func snapshot() -> AgentActivitySnapshot? {
        AppGroup.read(AgentActivitySnapshot.fileName, as: AgentActivitySnapshot.self)
    }

    func placeholder(in context: Context) -> AgentActivityEntry {
        let now = Date()
        let sample = AgentActivitySnapshot(macName: "Mac", snapshots: [
            (LiveActivitySnapshot(session: "a", project: "nook", title: "Fix the login form", agent: "Claude Code", model: "",
                                  phase: .waiting), now.timeIntervalSince1970),
            (LiveActivitySnapshot(session: "b", project: "site", title: "Write the release notes", agent: "Codex", model: "",
                                  phase: .working), now.timeIntervalSince1970 - 60),
        ], taken: now)
        return AgentActivityEntry(date: now, snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentActivityEntry) -> Void) {
        if context.isPreview, Self.snapshot() == nil { return completion(placeholder(in: context)) }
        completion(AgentActivityEntry(date: Date(), snapshot: Self.snapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentActivityEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.snapshot()
        var entries = [AgentActivityEntry(date: now, snapshot: snapshot)]
        // One more entry when the work it shows turns out of date; the app asks for a new timeline with every new list.
        if let snapshot, !snapshot.agents.isEmpty {
            let staleAt = Date(timeIntervalSince1970: snapshot.taken + AgentActivitySnapshot.staleAfter)
            if staleAt > now { entries.append(AgentActivityEntry(date: staleAt, snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct AgentActivityWidgetView: View {
    let entry: AgentActivityEntry
    @Environment(\.widgetFamily) private var family

    private var waiting: Int { entry.snapshot?.waiting ?? 0 }
    private var working: Int { entry.agents.count - waiting }
    /// The color of the whole: amber while something waits on you, the agents' blue while they work.
    private var tint: Color {
        if entry.stale { return Theme.textSecondary }
        return waiting > 0 ? LiveActivityPhase.waiting.color : LiveActivityPhase.working.color
    }

    /// "2 working · 1 waits on you", or that nothing runs.
    private var summary: String {
        if entry.snapshot == nil { return String(localized: "Open Nook Companion to see your agents.") }
        if entry.agents.isEmpty { return String(localized: "No agent is working.") }
        var parts: [String] = []
        if working > 0 { parts.append(String(localized: "\(working) working")) }
        if waiting > 0 { parts.append(String(localized: "\(waiting) waiting on you")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(summary, systemImage: entry.agents.isEmpty ? "checkmark.circle" : "sparkles")
                .widgetURL(URL(string: "nook://agents"))
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: waiting > 0 ? LiveActivityPhase.waiting.symbol : "sparkles")
                        .font(Theme.font(12, .semibold))
                    Text("\(entry.agents.count)").font(Theme.font(18, .semibold)).monospacedDigit()
                }
            }
            .widgetAccentable()
            .widgetURL(URL(string: "nook://agents"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.stale ? String(localized: "Out of date") : summary)
                    .font(Theme.font(13, .semibold)).lineLimit(1).widgetAccentable()
                ForEach(entry.agents.prefix(2)) { agent in
                    Label(agent.title.isEmpty ? agent.agent : agent.title, systemImage: agent.phase.symbol)
                        .font(Theme.font(12)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(entry.agents.first.flatMap { ActivityLink.url(session: $0.id) } ?? URL(string: "nook://agents"))
        default:
            homeScreen
        }
    }

    private var homeScreen: some View {
        let rows = Array(entry.agents.prefix(family == .systemSmall ? 3 : 4))
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "sparkles")
                Text("Agents")
                Spacer(minLength: 0)
                if entry.stale, let taken = entry.snapshot?.taken {
                    Text(Date(timeIntervalSince1970: taken), style: .relative).monospacedDigit().lineLimit(1)
                } else if !entry.agents.isEmpty {
                    Text("\(entry.agents.count)").monospacedDigit().foregroundStyle(tint)
                }
            }
            .font(Theme.font(11, .semibold))
            .foregroundStyle(Theme.textSecondary)
            if rows.isEmpty {
                Spacer(minLength: 0)
                Text(summary).font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                ForEach(rows) { agent in
                    Link(destination: ActivityLink.url(session: agent.id) ?? URL(string: "nook://agents")!) {
                        AgentWidgetRow(agent: agent, stale: entry.stale, compact: family == .systemSmall)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .opacity(entry.stale ? 0.7 : 1)
        .widgetURL(URL(string: "nook://agents"))
    }
}

private struct AgentWidgetRow: View {
    let agent: AgentActivitySnapshot.Agent
    let stale: Bool
    let compact: Bool

    private var color: Color { stale ? Theme.textSecondary : agent.phase.color }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: stale ? "clock.arrow.circlepath" : agent.phase.symbol)
                .font(Theme.font(12, .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.title.isEmpty ? agent.agent : agent.title)
                    .font(Theme.font(12, .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                if !compact {
                    Text([agent.agent, agent.project].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.font(10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !compact {
                Text(stale ? String(localized: "Out of date") : agent.phase.word)
                    .font(Theme.font(11, .semibold)).foregroundStyle(color).lineLimit(1)
            }
        }
    }
}
