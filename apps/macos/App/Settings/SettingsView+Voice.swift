import SwiftUI
import AppKit

/// Settings › Dictation and voice: dictating anywhere, speech recognition, reading aloud and "Hey Nook".
/// Settings › Notifications and sound: agent sounds and what the iPhone is told.
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
                Toggle(tr("settings.voice.agentSound"), isOn: $settings.sounds)
                LabeledContent(tr("settings.voice.customSounds")) {
                    Button(tr("button.openFolder")) { NookSound.openFolder() }
                }
            } header: {
                Text(tr("settings.voice.sounds"))
            } footer: {
                Text(tr("settings.voice.customSoundsHint"))
            }
            Section {
                Button { app.settingsSection = .devices } label: {
                    HStack(spacing: 12) {
                        SettingsTile(.devices, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("companion.push.enable")).foregroundStyle(.primary)
                            Text(tr("settings.notifications.iphoneDetail"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(tr("settings.notifications.iphone"))
            }
        }
    }
}
