import SwiftUI
import WidgetKit

/// Plan limits on the Home Screen (docs/COMPANION.md, "Usage widget"): how much of each agent account's limits is used,
/// and when each resets, as the Mac last told the app (`UsageSnapshot` in the app group). The timeline has an entry at
/// every reset (`UsageWidgetTimeline`), so a limit reads reset on time without the app or the Mac; numbers older than a
/// few hours say how old they are. A tap opens the app.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UsageWidgetKind.kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(Theme.canvas, for: .widget)
                .widgetURL(URL(string: "nook://usage"))
        }
        .configurationDisplayName(Text("Plan limits"))
        .description(Text("How much of each agent's limits you used, and when they reset."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let timeline: UsageWidgetTimeline.Entry
}

struct UsageProvider: TimelineProvider {
    private static func snapshot() -> UsageSnapshot? { AppGroup.read(UsageSnapshot.fileName, as: UsageSnapshot.self) }

    func placeholder(in context: Context) -> UsageEntry {
        let now = Date()
        let sample = UsageSnapshot(macName: "Mac", accounts: [
            .init(id: "claude", agent: "Claude", account: "", limits: [.init(label: "5 hours", percent: 42, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970)]),
            .init(id: "codex", agent: "Codex", account: "", limits: [.init(label: "Week", percent: 18, resetsAt: nil)]),
        ], taken: now.timeIntervalSince1970)
        return UsageEntry(date: now, timeline: UsageWidgetTimeline.entries(sample, now: now)[0])
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview, Self.snapshot() == nil { return completion(placeholder(in: context)) }
        let now = Date()
        completion(UsageEntry(date: now, timeline: UsageWidgetTimeline.entries(Self.snapshot(), now: now)[0]))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let entries = UsageWidgetTimeline.entries(Self.snapshot(), now: now).map { UsageEntry(date: $0.date, timeline: $0) }
        // After the last entry WidgetKit asks again; the app also asks it to whenever the Mac reports new numbers.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(UsageWidgetTimeline.horizon))))
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var rows: [UsageWidgetTimeline.Row] {
        let all = entry.timeline.rows
        return family == .systemSmall ? UsageWidgetTimeline.headline(all, count: 3) : Array(all.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("Limits")
                Spacer(minLength: 0)
                if let taken = entry.timeline.taken, entry.timeline.stale {
                    Text(taken, style: .relative).monospacedDigit().lineLimit(1)
                }
            }
            .font(Theme.font(11, .semibold))
            .foregroundStyle(Theme.textSecondary)
            if rows.isEmpty {
                Spacer(minLength: 0)
                Text(entry.timeline.taken == nil ? "Open Nook Companion to see your limits." : "Your Mac reports no plan limits.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                ForEach(rows) { row in UsageRowView(row: row, compact: family == .systemSmall) }
                Spacer(minLength: 0)
            }
        }
        .opacity(entry.timeline.stale ? 0.7 : 1)
    }
}

private struct UsageRowView: View {
    let row: UsageWidgetTimeline.Row
    let compact: Bool

    private var tint: Color {
        if row.reset { return Theme.mint }
        return row.percent >= 90 ? Theme.coral : row.percent >= 70 ? Theme.amber : Theme.iris
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(compact ? row.agent : [row.agent, row.account, row.label].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(row.reset ? String(localized: "Reset") : "\(Int(row.percent.rounded()))%")
                    .font(Theme.font(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.smoke)
                    Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(row.percent / 100))
                }
            }
            .frame(height: 4)
            if !compact, let reset = row.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}
