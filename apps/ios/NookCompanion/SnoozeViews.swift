import SwiftUI

// Snoozing a session to a moment you pick, or until the usage limit that stopped it resets: the phone's form of the
// Mac's custom snooze (`SessionAction.snoozeUntil`, `.snoozeLimitReset`). Both only show where the Mac offers them.

/// The extra snooze choices in a session's snooze menu.
struct SnoozeCustomItems: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let actions: [SessionAction]
    let run: (SessionAction) -> Void

    var body: some View {
        if actions.contains(.snoozeLimitReset) {
            Button { run(.snoozeLimitReset) } label: {
                if let reset = session.limitResetsAt.map(Date.init(timeIntervalSince1970:)) {
                    Label("Until the limit resets (\(reset.formatted(date: .omitted, time: .shortened)))", systemImage: "gauge.with.dots.needle.33percent")
                } else {
                    Label("Until the limit resets", systemImage: "gauge.with.dots.needle.33percent")
                }
            }
        }
        if actions.contains(.snoozeUntil) {
            Button { client.snoozing = session } label: { Label("Pick a time…", systemImage: "calendar.badge.clock") }
        }
    }
}

/// Picks the moment a session wakes: at least a minute ahead, at most a month.
struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    @State private var date = Date().addingTimeInterval(3600)

    private var range: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(CompanionSnooze.minAhead + 30)...now.addingTimeInterval(CompanionSnooze.maxAhead)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                DatePicker("Wake at", selection: $date, in: range, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .tint(Theme.amber)
                NookPrimaryButton(title: String(localized: "Snooze")) {
                    Haptics.tap()
                    let session = session, date = date
                    Task { await client.snooze(session, until: date) }
                    dismiss()
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.xl)
            .screen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Snooze"), subtitle: session.title) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.paper) }
            }
        }
        .presentationDetents([.large])
    }
}
