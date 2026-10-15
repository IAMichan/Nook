import SwiftUI
import AppKit

/// Settings › Assistant: screen reading, thinking along, small things.
extension SettingsView {
    // MARK: Assistant

    var assistantSection: some View {
        Group {
            Section(tr("settings.assistant.whatNookSees")) {
                SettingToggle(tr("settings.assistant.trackAllScreens"), detail: tr("settings.assistant.trackAllScreensDetail"), isOn: $settings.liveScreen)
                SettingToggle(tr("settings.assistant.useScreensEveryQuestion"), detail: tr("settings.assistant.useScreensEveryQuestionDetail"), isOn: $settings.screenWithEveryQuestion)
                LabeledContent(tr("settings.assistant.currentlyOnScreen")) {
                    Text(app.screenContext.windows.isEmpty ? tr("settings.assistant.nothingRead") : "\(app.screenContext.windows.count) vensters op \(max(1, app.screenContext.displayCount)) \(app.screenContext.displayCount == 1 ? "scherm" : "schermen")")
                        .foregroundStyle(.secondary)
                }
                if !CGPreflightScreenCaptureAccess() {
                    Button(tr("settings.assistant.grantScreenPermission")) { CGRequestScreenCaptureAccess(); refreshTick += 1 }
                }
            }
            Section(tr("settings.assistant.thinkAlong")) {
                SettingToggle(tr("settings.assistant.webSearch"), detail: tr("settings.assistant.webSearchDetail"), isOn: $settings.webSearch)
                SettingToggle(tr("settings.assistant.thinkAlongToggle"), detail: tr("settings.assistant.thinkAlongDetail"), isOn: $settings.autoWatch)
                .disabled(settings.useLocal)
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
        }
    }
}
