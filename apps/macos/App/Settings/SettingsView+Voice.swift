import SwiftUI
import AppKit

/// Settings › Typing & dictation and voice: dictating anywhere, speech recognition, reading aloud and "Hey Nook".
/// Settings › Notifications and sound: how each kind of notice shows and which apps may notify (`NoticeRulesSettings`),
/// sounds, how Nook behaves in meetings and while you share your screen, and what the iPhone is told.
extension SettingsView {
    // MARK: Dictation and voice

    var dictationSection: some View {
        Group {
            FlowSettingsSection()
            ParakeetSettingsSection()
            Section {
                Toggle(tr("settings.voice.speakAnswers"), isOn: $settings.speakAnswers)
                Toggle(tr("settings.voice.wakeWord"), isOn: $settings.wakeWord)
                    .disabled(!WakeWordService.supported)
            } header: {
                SettingsSectionTitle(tr("settings.voice.speaking"), info: tr("settings.voice.wakeWordFooter"))
            } footer: {
                // Why the wake word is greyed out is worth seeing; how it works when it is on sits behind the ⓘ.
                if !WakeWordService.supported {
                    SettingNote(tr("settings.voice.wakeWordUnsupported"), tone: .warning)
                }
            }
        }
    }

    // MARK: Notifications and sound

    var notificationsSection: some View {
        Group {
            NoticeRulesSettings(settings: settings, thinkAlong: app.thinkAlong)
            Section {
                Toggle(tr("settings.voice.agentSound"), isOn: $settings.sounds)
                LabeledContent(tr("settings.voice.customSounds")) {
                    Button(tr("button.openFolder")) { NookSound.openFolder() }
                }
                .disabled(!settings.sounds)
            } header: {
                SettingsSectionTitle(tr("settings.voice.sounds"), info: tr("settings.voice.customSoundsHint"))
            }
            quietSection
            Section {
                SettingsLinkRow(title: tr("companion.push.enable"), detail: tr("settings.notifications.iphoneDetail"),
                                section: .connections) { app.settingsSection = .connections }
            } header: {
                Text(tr("settings.notifications.iphone"))
            }
        }
    }

    // MARK: Meetings and screen sharing

    var quietSection: some View {
        Section {
            Picker(selection: $settings.quietWhileSharing) {
                ForEach(QuietBehavior.allCases) { Text(tr($0.titleKey)).tag($0) }
            } label: {
                SettingLabel(tr("quiet.sharing"), hint: tr("quiet.sharingDetail"))
            }
            Picker(selection: $settings.quietInMeetings) {
                ForEach(QuietBehavior.meetingChoices) { Text(tr($0.titleKey)).tag($0) }
            } label: {
                SettingLabel(tr("quiet.meeting"), hint: tr("quiet.meetingDetail"))
            }
            SettingToggle(tr("quiet.useCalendar"), detail: tr("quiet.useCalendarDetail"), isOn: $settings.quietUseCalendar)
            SettingToggle(tr("quiet.hideFromCaptures"), detail: tr("quiet.hideFromCapturesDetail"), isOn: $settings.hideFromCaptures)
            SettingToggle(tr("quiet.showInScreenshots"), detail: tr("quiet.showInScreenshotsDetail"), isOn: $settings.showInScreenshots)
                .disabled(settings.hideFromCaptures)
            LabeledContent(tr("quiet.now")) {
                Text(app.quietStatusText).foregroundStyle(NookTheme.textSecondary)
            }
            // While this line is on screen the situation is read even with "change nothing" for both.
            .onAppear { app.quietViewers += 1; app.quietTick() }
            .onDisappear { app.quietViewers = max(0, app.quietViewers - 1) }
        } header: {
            Text(tr("quiet.title"))
        }
    }
}
