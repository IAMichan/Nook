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
                .onChange(of: flowStore.key) { _, _ in FlowDictation.shared.refresh(); DoubleTap.shared.refresh() }
            } header: {
                Text(tr("flow.settings.title"))
            } footer: {
                Text(tr("flow.settings.enableDetail", flowStore.key.symbol))
            }
            Section {
                Toggle(tr("doubletap.settings.enable"), isOn: $doubleTap.enabled)
                Picker(tr("doubletap.settings.key"), selection: $doubleTap.key) {
                    ForEach(FlowKey.allCases) { key in
                        Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                    }
                }
                .disabled(!doubleTap.enabled)
                Picker(tr("doubletap.settings.action"), selection: $doubleTap.fillsOnDoubleTap) {
                    Text(tr("doubletap.settings.action.ask")).tag(false)
                    Text(tr("doubletap.settings.action.fill")).tag(true)
                }
                .disabled(!doubleTap.enabled)
                Toggle(tr("takeover.settings.onTap"), isOn: $doubleTap.taskOnTap)
                    .disabled(!doubleTap.enabled)
            } header: {
                Text(tr("doubletap.settings.title"))
            } footer: {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(tr(doubleTap.fillsOnDoubleTap ? "doubletap.settings.detail" : "doubletap.settings.askDetail",
                            doubleTap.key.symbol))
                    if doubleTap.taskOnTap {
                        Text(tr("takeover.settings.onTapDetail", doubleTap.key.symbol))
                    }
                    if doubleTap.enabled && doubleTap.conflictsWithFlow {
                        Text(tr("doubletap.settings.conflict")).foregroundStyle(NookTheme.amber)
                    }
                }
            }
            AutocompleteKeysSection()
        }
    }
}
