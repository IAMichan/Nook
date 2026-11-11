import SwiftUI

/// The items of every snooze menu (a row's hover menu, its right-click menu, VoiceOver's actions): the snooze options of
/// Settings › Sessions soonest first (a today one hides once its time has passed), "until the usage limit resets" while a
/// limit holds the session, and "Custom…" for a moment or a duration of your own.
struct SnoozeMenuItems: View {
    /// The moment the menu is drawn for: the rows pass their clock, so a passed option leaves with the next tick.
    var now = Date()
    var limitResetsAt: Date?
    let onUntil: (Date) -> Void
    var onCustom: (() -> Void)?

    var body: some View {
        ForEach(SnoozeOption.menu(InboxStore.shared.snoozeOptions, now: now), id: \.option.id) { item in
            // A duration counts from the click, not from when the menu was drawn.
            Button(SnoozeText.title(item.option)) { onUntil(item.option.end(from: Date()) ?? item.end) }
        }
        if let reset = limitResetsAt {
            Button(SnoozeText.untilReset(reset)) { onUntil(reset) }
        }
        if let onCustom {
            Divider()
            Button(tr("automation.snooze.custom")) { onCustom() }
        }
    }
}

enum SnoozeText {
    /// An option as the menu says it: "1 hour", "30 minutes", "Today at 18:00", "Monday at 09:00".
    static func title(_ option: SnoozeOption) -> String {
        switch option.kind {
        case .duration:
            let minutes = option.minutes
            if minutes % 1440 == 0 { return count(minutes / 1440, one: "snooze.option.day", many: "snooze.option.days") }
            if minutes % 60 == 0 { return count(minutes / 60, one: "snooze.option.hour", many: "snooze.option.hours") }
            return count(minutes, one: "snooze.option.minute", many: "snooze.option.minutes")
        case .time:
            return tr("snooze.option.at", dayName(option.day), clock(hour: option.hour, minute: option.minute))
        }
    }

    static func dayName(_ day: SnoozeOption.Day) -> String { tr("snooze.day." + day.rawValue) }

    /// "09:00" or "9:00 AM", as the Mac writes times.
    static func clock(hour: Int, minute: Int) -> String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func count(_ n: Int, one: String, many: String) -> String {
        n == 1 ? tr(one) : tr(many, n)
    }

    /// "Until the usage limit resets (14:30)", with the date when it is not today.
    static func untilReset(_ reset: Date) -> String {
        let clock = Calendar.current.isDateInToday(reset)
            ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(date: .abbreviated, time: .shortened)
        return tr("automation.snooze.limitReset", clock)
    }
}

/// "Custom…": snooze until a date and time, or for a while.
struct CustomSnoozeSheet: View {
    let title: String
    let onSnooze: (Date) -> Void
    let onCancel: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case moment, duration
        var id: String { rawValue }
    }

    @State private var mode = Mode.moment
    @State private var moment = Date().addingTimeInterval(2 * 3600)
    @State private var amount = 2
    @State private var unit = SnoozePolicy.DurationUnit.hours

    private var end: Date? {
        switch mode {
        case .moment: return SnoozePolicy.customEnd(moment)
        case .duration: return SnoozePolicy.customEnd(amount: amount, unit: unit)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(tr("automation.snooze.custom.title"))
                    .font(NookTheme.TextStyle.heading)
                    .foregroundStyle(NookTheme.paper)
                Text(title)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Picker("", selection: $mode) {
                Text(tr("automation.snooze.custom.moment")).tag(Mode.moment)
                Text(tr("automation.snooze.custom.duration")).tag(Mode.duration)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .moment:
                DatePicker("", selection: $moment, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            case .duration:
                HStack(spacing: NookTheme.Spacing.md) {
                    TextField("", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("", value: $amount, in: 1...999).labelsHidden()
                    Picker("", selection: $unit) {
                        Text(tr("automation.snooze.unit.minutes")).tag(SnoozePolicy.DurationUnit.minutes)
                        Text(tr("automation.snooze.unit.hours")).tag(SnoozePolicy.DurationUnit.hours)
                        Text(tr("automation.snooze.unit.days")).tag(SnoozePolicy.DurationUnit.days)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            Text(end.map { tr("automation.snooze.custom.until", $0.formatted(date: .abbreviated, time: .shortened)) }
                 ?? tr("automation.snooze.custom.invalid"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(end == nil ? NookTheme.coralSoft : NookTheme.textTertiary)
            HStack {
                Spacer()
                NookGhostButton(title: tr("button.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                NookPrimaryButton(title: tr("agents.snooze.menu")) { if let end { onSnooze(end) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(end == nil)
            }
        }
        .padding(NookTheme.Spacing.xl)
        .frame(width: 380)
        .background(NookTheme.graphite)
    }
}
