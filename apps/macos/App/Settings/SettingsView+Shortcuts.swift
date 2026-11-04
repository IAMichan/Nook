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
