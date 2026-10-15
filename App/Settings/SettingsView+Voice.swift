import SwiftUI
import AppKit

/// Settings › Voice & sound.
extension SettingsView {
    // MARK: Voice and Sound

    var voiceSection: some View {
        Group {
            Section {
                Toggle(tr("settings.voice.speakAnswers"), isOn: $settings.speakAnswers)
                Toggle(tr("settings.voice.wakeWord"), isOn: $settings.wakeWord)
                    .disabled(!WakeWordService.supported)
            } header: {
                Text(tr("settings.voice.speaking"))
            } footer: {
                Text(WakeWordService.supported
                     ? "With wake word enabled, Nook continuously listens on-device. Audio is never stored or transmitted. The orange microphone indicator will be visible."
                     : "This Mac cannot recognize speech on-device, so wake word cannot be enabled. Use ⌥ Space to talk anytime.")
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
        }
    }
}
