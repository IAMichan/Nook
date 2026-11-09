import SwiftUI
import AppKit

/// Settings › Sound & voice: the sounds Nook makes, speech recognition, reading aloud and "Hey Nook". Dictating has a
/// page of its own (`FlowSettingsSection`); how notices show and which apps may notify is under Notifications
/// (`NoticeRulesSettings`); how Nook behaves in meetings and while you share your screen is under Notch & windows.
extension SettingsView {
    // MARK: Sound and voice

    var soundSection: some View {
        Group {
            Section {
                Toggle(isOn: $settings.sounds) { SettingText("settings.voice.agentSound") }
                LabeledContent {
                    Button(tr("button.openFolder")) { NookSound.openFolder() }
                } label: {
                    SettingText("settings.voice.customSounds")
                }
                .disabled(!settings.sounds)
            } header: {
                SettingsSectionTitle(tr("settings.voice.sounds"), info: tr("settings.voice.customSoundsHint"))
            }
            Section {
                Toggle(isOn: $settings.speakAnswers) { SettingText("settings.voice.speakAnswers") }
                Toggle(isOn: $settings.wakeWord) { SettingText("settings.voice.wakeWord") }
                    .disabled(!WakeWordService.supported)
            } header: {
                SettingsSectionTitle(tr("settings.voice.speaking"), info: tr("settings.voice.wakeWordFooter"))
            } footer: {
                // Why the wake word is greyed out is worth seeing; how it works when it is on sits behind the ⓘ.
                if !WakeWordService.supported {
                    SettingNote(tr("settings.voice.wakeWordUnsupported"), tone: .warning)
                }
            }
            ParakeetSettingsSection()
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
            SettingText("quiet.title")
        }
    }
}
