import SwiftUI

/// The line at the end of a conversation the auto-settle rules settled: since how long, and an Unsettle that brings it
/// back to the open sessions. Nothing when it is open, or when you settled it yourself (you know you did).
/// Shown above the composer of every session view: a session Nook runs (`AgentRunPanel`), one it sees through hooks and
/// an earlier one (`AgentSessionDetail`).
struct AutoSettledLine: View {
    let finishKey: String
    @ObservedObject private var finished = FinishedSessions.shared

    var body: some View {
        if let at = finished.autoSettledAt(finishKey) {
            // Ticks by the minute, so "2 minutes ago" does not stand still while the session is open.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "checkmark.circle")
                    Text(tr("agents.autoSettled.line", Self.elapsed(since: at, now: context.date)))
                        .help(at.formatted(date: .abbreviated, time: .shortened))
                    Text(verbatim: "·")
                    Button(tr("agents.autoSettled.unsettle")) {
                        withAnimation(NookTheme.reveal) { InboxStore.shared.unsettle(keys: [finishKey]) }
                    }
                    .buttonStyle(.nookLink)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(maxWidth: .infinity)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "3 hours ago", in the app's language.
    static func elapsed(since date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return tr("agents.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
