import SwiftUI
import AppKit

/// Settings › Shortcuts: every key of Nook, from the ones that work anywhere on the Mac to the keys inside the panel.
/// The keybindings file is folded away at the end.
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
            Section {
                Picker(tr("flow.settings.key"), selection: $flowStore.key) {
                    ForEach(FlowKey.allCases) { key in
                        Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                    }
                }
                .onChange(of: flowStore.key) { _, _ in FlowDictation.shared.refresh(); DoubleTap.shared.refresh() }
            } header: {
                Text(tr("flow.settings.title"))
            }
            Section {
                // What a double tap can do takes four paragraphs; they show on hover, so the page stays a list of keys.
                Toggle(tr("doubletap.settings.enable"), isOn: $doubleTap.enabled)
                    .help(doubleTapHelp)
                Picker(tr("doubletap.settings.key"), selection: $doubleTap.key) {
                    ForEach(FlowKey.allCases) { key in
                        Text(key == .fn ? "fn" : tr("flow.settings.keyRight", key.symbol)).tag(key)
                    }
                }
                .disabled(!doubleTap.enabled)
                Toggle(tr("takeover.settings.onTap"), isOn: $doubleTap.taskOnTap)
                    .disabled(!doubleTap.enabled)
                    .help(tr("takeover.settings.onTapDetail", doubleTap.key.symbol))
            } header: {
                Text(tr("doubletap.settings.title"))
            } footer: {
                // Only a conflict is worth reading here.
                if doubleTap.enabled && doubleTap.conflictsWithFlow {
                    SettingNote(tr("doubletap.settings.conflict"), tone: .warning)
                }
            }
            AutocompleteKeysSection()
            KeybindingsSettingsSection()
        }
    }

    /// Everything a double tap can do, as one tooltip.
    private var doubleTapHelp: String {
        [tr("doubletap.settings.askDetail", doubleTap.key.symbol), tr("doubletap.settings.writeDetail"),
         tr("doubletap.settings.editDetail"), tr("doubletap.settings.detail")].joined(separator: "\n\n")
    }
}
