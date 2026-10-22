import SwiftUI
import AppKit

/// Settings › Shortcuts: every key of Nook in one list, for talking, dictating and completing.
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
                Text(tr("settings.group.nook"))
            }
            Section {
                Picker(tr("flow.settings.key"), selection: $flowStore.key) {
                    ForEach(FlowKey.allCases) { key in
                        Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                    }
                }
                .onChange(of: flowStore.key) { _, _ in FlowDictation.shared.refresh() }
            } header: {
                Text(tr("flow.settings.title"))
            } footer: {
                Text(tr("flow.settings.enableDetail", flowStore.key.symbol))
            }
            AutocompleteKeysSection()
        }
    }
}
