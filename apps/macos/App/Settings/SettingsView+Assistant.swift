import SwiftUI
import AppKit

/// Settings › Assistant: what Nook sees and how it thinks along.
extension SettingsView {
    // MARK: Assistant

    var assistantSection: some View {
        Group {
            Section(tr("settings.assistant.whatNookSees")) {
                SettingToggle(tr("settings.assistant.trackAllScreens"), detail: tr("settings.assistant.trackAllScreensDetail"), isOn: $settings.liveScreen)
                SettingToggle(tr("settings.assistant.useScreensEveryQuestion"), detail: tr("settings.assistant.useScreensEveryQuestionDetail"), isOn: $settings.screenWithEveryQuestion)
                LabeledContent(tr("settings.assistant.currentlyOnScreen")) {
                    ScreenStatusText(screenContext: app.screenContext, enabled: settings.liveScreen)
                }
                if !permissions.isGranted(.screen) {
                    Button(tr("settings.assistant.managePermissions")) { app.settingsSection = .privacy }
                        .buttonStyle(.link)
                }
            }
            Section(tr("settings.assistant.thinkAlong")) {
                SettingToggle(tr("settings.assistant.webSearch"), detail: tr("settings.assistant.webSearchDetail"), isOn: $settings.webSearch)
                SettingToggle(tr("settings.assistant.thinkAlongToggle"), detail: tr("settings.assistant.thinkAlongDetail"), isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
                // A switch that is greyed out without a word leaves you guessing: say why, and where to change it.
                if settings.useLocal {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(tr("settings.assistant.thinkAlongLocal"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(tr("settings.section.brain")) { app.settingsSection = .brain }
                            .buttonStyle(.link)
                    }
                }
                if !app.thinkAlong.mutedApps.isEmpty {
                    LabeledContent(tr("settings.assistant.mutedIn")) {
                        HStack {
                            Text(app.thinkAlong.mutedApps.values.sorted().joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button(tr("button.clear")) { app.thinkAlong.unmuteAll() }
                        }
                    }
                }
                SettingToggle(tr("settings.assistant.autoRunSafe"), detail: tr("settings.assistant.autoRunSafeDetail"), isOn: $settings.autoRunSafe)
            }
            buddySection
        }
    }

    // MARK: Buddy

    /// Nook as a friend: the small moments he shares by himself, how playful he sounds, and your birthday.
    private var buddySection: some View {
        Section {
            SettingToggle(tr("settings.buddy.moments"), detail: tr("settings.buddy.momentsDetail"), isOn: $settings.buddyMoments)
            Picker(tr("settings.buddy.tone"), selection: $settings.buddyTone) {
                ForEach(BuddyTone.allCases) { tone in
                    Text(tr("settings.buddy.tone.\(tone.rawValue)")).tag(tone)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.buddyMoments)
            // How he sounds in the chosen tone: the morning greeting on a day with three events.
            HStack(alignment: .top, spacing: 10) {
                NookOrb(mood: .cozy, size: 26, animated: false, glow: false)
                    .frame(width: 30, height: 30)
                Text(tr(BuddyPlanner.lineKey(BuddyMoment(kind: .morning, id: "preview", count: 3), tone: settings.buddyTone), 3))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(settings.buddyMoments ? 1 : 0.5)
            LabeledContent(tr("settings.buddy.birthday")) {
                HStack(spacing: 6) {
                    Picker(tr("settings.buddy.birthdayDay"), selection: birthdayPart(\.day)) {
                        Text(verbatim: "–").tag(0)
                        ForEach(1...31, id: \.self) { day in Text(verbatim: "\(day)").tag(day) }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                    Picker(tr("settings.buddy.birthdayMonth"), selection: birthdayPart(\.month)) {
                        Text(verbatim: "–").tag(0)
                        ForEach(1...12, id: \.self) { month in Text(Self.monthName(month)).tag(month) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            HStack {
                Button(tr("settings.buddy.breatheNow")) { app.breatheAlong() }
                Spacer()
            }
        } header: {
            Text(tr("settings.buddy.title"))
        } footer: {
            Text(tr("settings.buddy.footer"))
        }
    }

    /// The day or the month of your birthday, 0 when not set. Stored together as "MM-dd"; a half-filled date is kept
    /// (so you can pick the day first) but only counts once both are set.
    private func birthdayPart(_ part: WritableKeyPath<BirthdayParts, Int>) -> Binding<Int> {
        Binding(
            get: { BirthdayParts(settings.birthday)[keyPath: part] },
            set: { value in
                var parts = BirthdayParts(settings.birthday)
                parts[keyPath: part] = value
                settings.birthday = parts.month == 0 && parts.day == 0 ? "" : String(format: "%02d-%02d", parts.month, parts.day)
            }
        )
    }

    /// The month's name in the app's language.
    private static func monthName(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: I18n.shared.currentLanguage.rawValue)
        let names = calendar.standaloneMonthSymbols
        return names.indices.contains(month - 1) ? names[month - 1].capitalized : "\(month)"
    }
}

/// What the screen reading does right now: off, how many windows it holds, or paused and why (the battery, a hot or busy
/// Mac, you are away), so an empty line never looks like something is broken. Observes the screen reader itself: its
/// `shown` is published, the app model is not told about it.
private struct ScreenStatusText: View {
    @ObservedObject var screenContext: ScreenContext
    @ObservedObject var energy = EnergyMonitor.shared
    let enabled: Bool

    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }

    private var text: String {
        guard enabled else { return tr("settings.assistant.screenOff") }
        let shown = screenContext.shown
        if shown.count > 0 {
            return shown.displays > 1
                ? tr("settings.assistant.windowsOnScreens", shown.count, shown.displays)
                : tr("settings.assistant.windowsOneScreen", shown.count)
        }
        if !energy.plan.readsScreen, let reason = energy.plan.mainReason {
            return tr("settings.assistant.screenPaused", tr(reason.textKey))
        }
        return tr("settings.assistant.nothingRead")
    }
}

/// The two halves of the stored birthday, "MM-dd", each 0 when missing.
struct BirthdayParts {
    var month = 0
    var day = 0

    init(_ stored: String) {
        let parts = stored.split(separator: "-").map { Int($0) ?? 0 }
        if parts.count == 2 {
            month = parts[0]
            day = parts[1]
        }
    }
}
