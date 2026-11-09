import SwiftUI
import AppKit

/// Settings › Assistant: what Nook sees, how it thinks along, Double Tap, and what Nook may do on its own, in that order.
/// What it remembers has a page of its own (Memory); Nook as a buddy is under Appearance.
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
                    SettingsLinkRow(title: tr("settings.assistant.managePermissions"), section: .privacy, state: .warning) {
                        app.openSettings(section: .permissions)
                    }
                }
            }
            Section(tr("settings.assistant.thinkAlong")) {
                SettingToggle(tr("settings.assistant.selectionAsk"), detail: tr("settings.assistant.selectionAskDetail"), isOn: $settings.selectionAsk)
                SettingToggle(tr("settings.assistant.webSearch"), detail: tr("settings.assistant.webSearchDetail"), isOn: $settings.webSearch)
                SettingToggle(tr("settings.assistant.thinkAlongToggle"), detail: tr("settings.assistant.thinkAlongDetail"), isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
                // A switch that is greyed out without a word leaves you guessing: say why, and where to change it.
                if settings.useLocal {
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                        SettingNote(tr("settings.assistant.thinkAlongLocal"))
                        Spacer(minLength: 0)
                        Button(tr("settings.section.brain")) { app.settingsSection = .brain }
                            .buttonStyle(.link)
                    }
                }
            }
            doubleTapSection
            // The same choice as in the chat's composer and the Double Tap field (⇧Tab there).
            Section {
                Picker(selection: $settings.nookAccess) {
                    ForEach(NookAccess.allCases) { level in Text(level.short).tag(level) }
                } label: {
                    SettingText("nookAccess.title")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SettingNote(settings.nookAccess.detail + " " + tr("nookAccess.always"))
            } header: {
                SettingText("nookAccess.title")
            }
        }
    }

    // MARK: Double Tap

    /// Double Tap: the feature and its key together, so turning it on and choosing its key happen in one place.
    private var doubleTapSection: some View {
        Section {
            // What a double tap can do takes four paragraphs; they show on hover, so the section stays short.
            Toggle(isOn: $doubleTap.enabled) { SettingText("doubletap.settings.enable") }
                .help(doubleTapHelp)
            Picker(tr("doubletap.settings.key"), selection: $doubleTap.key) {
                ForEach(FlowKey.allCases) { key in
                    Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                }
            }
            .disabled(!doubleTap.enabled)
            Toggle(tr("takeover.settings.onTap"), isOn: $doubleTap.taskOnTap)
                .disabled(!doubleTap.enabled)
                .help(tr("takeover.settings.onTapDetail", doubleTap.key.symbol))
        } header: {
            SettingText("doubletap.settings.title")
        } footer: {
            // Only a conflict is worth reading here.
            if doubleTap.enabled && doubleTap.conflictsWithFlow {
                SettingNote(tr("doubletap.settings.conflict"), tone: .warning)
            }
        }
    }

    /// Everything a double tap can do, as one tooltip.
    private var doubleTapHelp: String {
        [tr("doubletap.settings.askDetail", doubleTap.key.symbol), tr("doubletap.settings.writeDetail"),
         tr("doubletap.settings.editDetail"), tr("doubletap.settings.detail")].joined(separator: "\n\n")
    }

    // MARK: Buddy

    /// Nook as a friend: the small moments he shares by himself, how playful he sounds, and your birthday.
    var buddySection: some View {
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
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                NookOrb(mood: .cozy, size: 26, animated: false, glow: false)
                    .frame(width: 30, height: 30)
                Text(tr(BuddyPlanner.lineKey(BuddyMoment(kind: .morning, id: "preview", count: 3), tone: settings.buddyTone), 3))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(settings.buddyMoments ? 1 : 0.5)
            LabeledContent {
                HStack(spacing: NookTheme.Spacing.sm) {
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
            } label: {
                SettingText("settings.buddy.birthday")
            }
            HStack {
                Button(tr("settings.buddy.breatheNow")) { app.breatheAlong() }
                Spacer()
            }
        } header: {
            SettingText("settings.buddy.title")
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

/// What the screen reading does right now: off, paused and why (a hot or busy Mac, Low Power Mode, you are away), or how
/// many windows it holds, so an empty line never looks like something is broken. Observes the screen reader itself: its
/// `shown` is published, the app model is not told about it.
private struct ScreenStatusText: View {
    @ObservedObject var screenContext: ScreenContext
    @ObservedObject var energy = EnergyMonitor.shared
    let enabled: Bool

    var body: some View {
        Text(text).foregroundStyle(NookTheme.textSecondary)
    }

    private var text: String {
        guard enabled else { return tr("settings.assistant.screenOff") }
        // Paused first: the windows read before the pause are still held, and their count would hide that nothing is
        // being read right now.
        if !energy.plan.readsScreen, let reason = energy.plan.mainReason {
            return tr("settings.assistant.screenPaused", tr(reason.textKey))
        }
        let shown = screenContext.shown
        if shown.count > 0 {
            return shown.displays > 1
                ? tr("settings.assistant.windowsOnScreens", shown.count, shown.displays)
                : tr("settings.assistant.windowsOneScreen", shown.count)
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
