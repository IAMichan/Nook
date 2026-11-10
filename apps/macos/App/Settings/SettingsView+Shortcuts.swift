import SwiftUI
import AppKit

/// Settings › Shortcuts: Nook's keys that work anywhere on the Mac and the keys inside the panel, with the keybindings
/// file folded away at the end. A feature's own key (dictation, Double Tap, accepting a completion) is set on that
/// feature's page, next to the switch that turns it on.
extension SettingsView {
    // MARK: Shortcuts

    var shortcutsSection: some View {
        Group {
            Section {
                ForEach(ShortcutAction.allCases) { action in ShortcutRecorder(action: action) }
                WindowCaptureTargetPicker()
                LabeledContent(tr("settings.overview.openPanel")) {
                    Text(tr("settings.overview.pointToNotch")).foregroundStyle(NookTheme.textSecondary)
                }
            } header: {
                Text(tr("shortcuts.anywhere"))
            }
            KeybindingsSettingsSection()
        }
    }
}

/// Where the window capture shortcut (and ⌥-dragging Nook onto a window) puts the window: see `WindowCaptureTarget`.
private struct WindowCaptureTargetPicker: View {
    @AppStorage(WindowCaptureTarget.defaultsKey) private var target = WindowCaptureTarget.session.rawValue

    var body: some View {
        Picker(selection: $target) {
            ForEach(WindowCaptureTarget.allCases) { Text(tr("windowCapture.target." + $0.rawValue)).tag($0.rawValue) }
        } label: {
            SettingText("windowCapture.target")
        }
        .help(tr("windowCapture.target.help"))
    }
}
