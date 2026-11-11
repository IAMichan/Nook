import SwiftUI

/// Settings › Sessions › Snooze options: the choices of every snooze menu (a row's hover and right-click menu, the command
/// palette). Each is a duration ("3 hours") or a time on a day ("21:00 tomorrow"); the menus list them
/// soonest first and hide a today option once its time has passed.
struct SnoozeOptionsSection: View {
    @ObservedObject private var inbox = InboxStore.shared

    private enum Unit: String, CaseIterable, Identifiable {
        case minutes, hours, days
        var id: String { rawValue }
        var minutes: Int {
            switch self {
            case .minutes: return 1
            case .hours: return 60
            case .days: return 1440
            }
        }
    }

    @State private var kind = SnoozeOption.Kind.duration
    @State private var amount = 3
    @State private var unit = Unit.hours
    @State private var day = SnoozeOption.Day.tomorrow
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    /// The option the add row describes now.
    private var draft: SnoozeOption {
        switch kind {
        case .duration:
            return .duration(minutes: max(1, amount) * unit.minutes)
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .time(day, hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        }
    }

    private var canAdd: Bool {
        let option = draft
        return inbox.snoozeOptions.count < SnoozeOption.maxCount && !inbox.snoozeOptions.contains(option)
            && (option.kind == .time || option.minutes <= SnoozeOption.maxMinutes)
    }

    var body: some View {
        Section {
            ForEach(inbox.snoozeOptions) { option in
                HStack {
                    Text(SnoozeText.title(option))
                    Spacer()
                    ToolbarIconButton("minus.circle", tr("snooze.settings.remove"), enabled: inbox.snoozeOptions.count > 1) {
                        inbox.snoozeOptions.removeAll { $0 == option }
                    }
                }
            }
            addRow
            HStack {
                Spacer()
                Button(tr("snooze.settings.reset")) { inbox.snoozeOptions = SnoozeOption.defaults }
                    .disabled(inbox.snoozeOptions == SnoozeOption.defaults)
            }
        } header: {
            SettingsSectionTitle(tr("snooze.settings.title"), info: tr("snooze.settings.info"))
        }
    }

    private var addRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Picker("", selection: $kind) {
                Text(tr("snooze.settings.duration")).tag(SnoozeOption.Kind.duration)
                Text(tr("snooze.settings.time")).tag(SnoozeOption.Kind.time)
            }
            .labelsHidden()
            .fixedSize()
            switch kind {
            case .duration:
                TextField("", value: $amount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .accessibilityLabel(tr("snooze.settings.amount"))
                Stepper("", value: $amount, in: 1...999).labelsHidden()
                Picker("", selection: $unit) {
                    Text(tr("automation.snooze.unit.minutes")).tag(Unit.minutes)
                    Text(tr("automation.snooze.unit.hours")).tag(Unit.hours)
                    Text(tr("automation.snooze.unit.days")).tag(Unit.days)
                }
                .labelsHidden()
                .fixedSize()
            case .time:
                Picker("", selection: $day) {
                    ForEach(SnoozeOption.Day.allCases, id: \.self) { day in
                        Text(SnoozeText.dayName(day)).tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel(tr("snooze.settings.time"))
            }
            Spacer(minLength: 0)
            Button(tr("snooze.settings.add")) { inbox.snoozeOptions.append(draft) }
                .disabled(!canAdd)
        }
    }
}
