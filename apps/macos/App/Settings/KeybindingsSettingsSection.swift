import SwiftUI
import AppKit

/// Settings › Shortcuts › Panel keys: the keys of the panel (send, find, the command palette…) as the key monitor uses
/// them, the user's `~/.nook/keybindings.json` with what it could not use, and the keys that claim the same chord.
struct KeybindingsSettingsSection: View {
    @ObservedObject private var center = KeyCommandCenter.shared

    var body: some View {
        Group {
            Section {
                ForEach(Keybindings.commandIDs, id: \.self) { command in row(command) }
            } header: {
                Text(tr("keys.title"))
            } footer: {
                Text(tr("keys.detail"))
            }
            Section {
                LabeledContent(tr("keys.file")) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Button(tr("keys.file.open")) { openFile() }
                        Button(tr("keys.file.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([Keybindings.userFileURL]) }
                            .disabled(center.file.state == .missing)
                        Button(tr("keys.file.reload")) { center.reload() }
                    }
                }
                ForEach(notes.indices, id: \.self) { index in SettingNote(notes[index].text, tone: notes[index].tone) }
            } header: {
                Text(tr("keys.file.title"))
            } footer: {
                Text(tr("keys.file.detail", Self.displayPath))
            }
        }
        .onAppear { center.reload() }
    }

    private func row(_ command: String) -> some View {
        let chords = Keybindings.chords(for: command, rules: center.rules)
        return LabeledContent {
            HStack(spacing: NookTheme.Spacing.xs) {
                if chords.isEmpty {
                    Text(tr("keys.unbound")).foregroundStyle(NookTheme.textTertiary)
                } else {
                    ForEach(chords, id: \.self) { Keycap(label: $0.symbols) }
                }
            }
        } label: {
            if KeyCommandCenter.wiredCommands.contains(command) {
                Text(Self.title(command))
            } else {
                SettingLabel(Self.title(command), detail: tr("keys.notYet"))
            }
        }
    }

    /// What the file says about itself, then the keys that compete for the same chord.
    private var notes: [(text: String, tone: SettingNote.Tone)] {
        var out: [(text: String, tone: SettingNote.Tone)] = []
        switch center.file.state {
        case .missing: out.append((tr("keys.state.missing"), .info))
        case .empty: out.append((tr("keys.state.empty"), .info))
        case .unparseable: out.append((tr("keys.state.unparseable"), .error))
        case .ok: out.append((tr("keys.state.ok", center.file.rules.count), .success))
        }
        for problem in center.file.problems {
            out.append((tr("keys.problem.\(problem.reason.rawValue)", problem.index + 1), .warning))
        }
        for rule in Keybindings.unknownCommands(center.file.rules) {
            out.append((tr("keys.problem.unknownCommand", rule.command), .warning))
        }
        for conflict in Keybindings.conflicts(center.rules) {
            out.append((tr("keys.conflict", conflict.chord.symbols, Self.title(center.rules[conflict.first].command),
                           Self.title(center.rules[conflict.winner].command)), .warning))
        }
        return out
    }

    /// The command's name in the user's language; a command Nook does not know keeps its id.
    private static func title(_ command: String) -> String {
        Keybindings.commandIDs.contains(command) ? tr("keys.command.\(command)") : command
    }

    private static var displayPath: String {
        (Keybindings.userFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the file in the user's editor, writing an empty list first when there is none yet.
    private func openFile() {
        let url = Keybindings.userFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("[]\n".utf8).write(to: url)
            center.reload()
        }
        NSWorkspace.shared.open(url)
    }
}
