import SwiftUI
import AppKit

/// Settings › Dictation and voice: dictating anywhere, speech recognition, reading aloud and "Hey Nook".
/// Settings › Notifications and sound: agent sounds, how Nook behaves in meetings and while you share your screen, and
/// what the iPhone is told.
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
                Text(tr("settings.voice.speaking"))
            } footer: {
                Text(WakeWordService.supported ? tr("settings.voice.wakeWordFooter") : tr("settings.voice.wakeWordUnsupported"))
            }
        }
    }

    // MARK: Notifications and sound

    var notificationsSection: some View {
        Group {
            Section {
                NoticeDeliveryPicker(settings: settings)
                Picker(selection: $settings.agentNotice) {
                    ForEach(AgentNoticeStyle.allCases) { Text(tr($0.titleKey)).tag($0) }
                } label: {
                    SettingLabel(tr("agentNotice.style"), detail: tr("agentNotice.styleDetail"))
                }
                .disabled(settings.noticeDelivery == .system)
            } header: {
                Text(tr("agentNotice.title"))
            } footer: {
                Text(tr("agentNotice.footer"))
            }
            Section {
                Toggle(tr("settings.voice.agentSound"), isOn: $settings.sounds)
                LabeledContent(tr("settings.voice.customSounds")) {
                    Button(tr("button.openFolder")) { NookSound.openFolder() }
                }
            } header: {
                Text(tr("settings.voice.sounds"))
            } footer: {
                Text(tr("settings.voice.customSoundsHint"))
            }
            quietSection
            Section {
                Button { app.settingsSection = .devices } label: {
                    HStack(spacing: 12) {
                        SettingsTile(.devices, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("companion.push.enable")).foregroundStyle(.primary)
                            Text(tr("settings.notifications.iphoneDetail"))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(NookTheme.font(11, .semibold)).foregroundStyle(NookTheme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                SettingLabel(tr("quiet.sharing"), detail: tr("quiet.sharingDetail"))
            }
            Picker(selection: $settings.quietInMeetings) {
                ForEach(QuietBehavior.meetingChoices) { Text(tr($0.titleKey)).tag($0) }
            } label: {
                SettingLabel(tr("quiet.meeting"), detail: tr("quiet.meetingDetail"))
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
        } footer: {
            Text(tr("quiet.footer"))
        }
    }
}

/// Settings › Notifications: notch cards or macOS notifications, with a way to System Settings when macOS blocks Nook's.
private struct NoticeDeliveryPicker: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var notifier = SystemNotifier.shared

    var body: some View {
        Picker(selection: $settings.noticeDelivery) {
            ForEach(NoticeDelivery.allCases) { Text(tr($0.titleKey)).tag($0) }
        } label: {
            SettingLabel(tr("noticeDelivery.title"), detail: tr("noticeDelivery.detail"))
        }
        .onChange(of: settings.noticeDelivery) { _, delivery in
            if delivery == .system { notifier.requestAccess() }
        }
        .onAppear {
            if settings.noticeDelivery == .system { notifier.requestAccess() }
        }
        if notifier.blocked, settings.noticeDelivery == .system {
            LabeledContent(tr("noticeDelivery.blocked")) {
                Button(tr("noticeDelivery.openSettings")) { SystemNotifier.openSystemSettings() }
            }
        }
    }
}
