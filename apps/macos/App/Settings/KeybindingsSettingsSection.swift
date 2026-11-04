import SwiftUI
import AppKit

/// Settings › Shortcuts › Panel keys: the keys of the panel (send, find, the command palette…) as the key monitor uses
/// them, with a search, a Record button per command that takes the next key you press and writes it to
/// `~/.nook/keybindings.json` (`KeybindingEdits`), Reset for the ones you changed, the keys that claim the same chord,
/// and what your file could not use.
struct KeybindingsSettingsSection: View {
    @ObservedObject private var center = KeyCommandCenter.shared
    @State private var search = ""
    /// The command waiting for its new key.
    @State private var recording: String?
    /// The one-shot key monitor of a recording; only there while one waits.
    @State private var monitor: Any?
    /// What the last recording said, under its row.
    @State private var recordNote: (command: String, text: String, tone: SettingNote.Tone)?

    var body: some View {
        Group {
            Section {
                NookSearchField(prompt: tr("keys.search"), text: $search, style: .inline)
                let shown = shownCommands
                if shown.isEmpty {
                    SettingNote(tr("keys.search.none"))
                }
                ForEach(shown, id: \.self) { command in row(command) }
            } header: {
                SettingsSectionTitle(tr("keys.title"), info: tr("keys.detail"))
            }
            .onAppear { center.reload() }
            .onDisappear { stopRecording() }
            // Editing the file by hand is rarely needed: folded away, unless it has something to say.
            Section {
                DisclosureGroup(tr("keys.file.title")) {
                    LabeledContent(tr("keys.file")) {
                        // Side by side while they fit; under each other in a narrow window or a longer language.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: NookTheme.Spacing.sm) { fileButtons }
                            VStack(alignment: .trailing, spacing: NookTheme.Spacing.sm) { fileButtons }
                        }
                    }
                    SettingNote(tr("keys.file.detail", Self.displayPath))
                }
                ForEach(notes.indices, id: \.self) { index in SettingNote(notes[index].text, tone: notes[index].tone) }
            }
        }
    }

    /// The commands whose name, id or key holds every word of the search.
    private var shownCommands: [String] {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return Keybindings.commandIDs }
        return Keybindings.commandIDs.filter { command in
            let keys = Keybindings.chords(for: command, rules: center.rules).map(\.symbols).joined(separator: " ")
            let text = [Self.title(command), command, keys].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func row(_ command: String) -> some View {
        let chords = Keybindings.chords(for: command, rules: center.rules)
        let customized = KeybindingEdits.isCustomized(command, user: center.file.rules)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            LabeledContent {
                HStack(spacing: NookTheme.Spacing.xs) {
                    if recording == command {
                        Text(tr("keys.record.waiting")).foregroundStyle(NookTheme.iris)
                    } else if chords.isEmpty {
                        Text(tr("keys.unbound")).foregroundStyle(NookTheme.textTertiary)
                    } else {
                        ForEach(chords, id: \.self) { Keycap(label: $0.symbols) }
                    }
                    if recording == command {
                        Button(tr("button.cancel")) { stopRecording() }
                    } else {
                        Button(tr("keys.record")) { beginRecording(command) }
                            .help(tr("keys.record.help"))
                    }
                    if customized && recording != command {
                        Button(tr("keys.reset")) { reset(command) }
                            .help(tr("keys.reset.help"))
                    }
                }
                .controlSize(.small)
            } label: {
                label(command)
            }
            if let recordNote, recordNote.command == command {
                SettingNote(recordNote.text, tone: recordNote.tone)
            }
        }
    }

    @ViewBuilder
    private func label(_ command: String) -> some View {
        if !KeyCommandCenter.wiredCommands.contains(command) {
            SettingLabel(Self.title(command), detail: tr("keys.notYet"))
        } else if let other = conflicting(command).first {
            SettingLabel(Self.title(command), detail: tr("keys.row.conflict", Self.title(other)))
        } else {
            Text(Self.title(command))
        }
    }

    /// The commands that share a key with this one where both can hold (`Keybindings.conflicts`).
    private func conflicting(_ command: String) -> [String] {
        var out: [String] = []
        for conflict in Keybindings.conflicts(center.rules) {
            let pair = [center.rules[conflict.first].command, center.rules[conflict.winner].command]
            guard pair.contains(command) else { continue }
            for other in pair where other != command && !out.contains(other) { out.append(other) }
        }
        return out
    }

    // MARK: Recording

    /// Waits for the next key pressed in Nook (a one-shot monitor, gone again after it): Escape cancels, a key without ⌘,
    /// ⌃ or ⌥ is not taken (it types), any other becomes the command's key.
    private func beginRecording(_ command: String) {
        stopRecording()
        recording = command
        recordNote = nil
        center.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { capture(event, for: command) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        center.recording = false
    }

    private func capture(_ event: NSEvent, for command: String) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chord = KeyChord.pressed(characters: event.characters(byApplyingModifiers: []), keyCode: event.keyCode,
                                           command: flags.contains(.command), control: flags.contains(.control),
                                           option: flags.contains(.option), shift: flags.contains(.shift)) else { return }
        if chord.key == "escape" && chord.modifiers.isEmpty {
            stopRecording()
            return
        }
        guard KeybindingEdits.isRecordable(chord) else {
            recordNote = (command, tr("keys.record.needsModifier"), .info)
            return
        }
        let others = KeybindingEdits.conflicts(recording: chord, for: command, user: center.file.rules)
        let rules = KeybindingEdits.recordedRules(chord, for: command)
        stopRecording()
        guard write(command: command, rules: rules) else { return }
        if others.isEmpty {
            recordNote = (command, tr("keys.record.saved", chord.symbols), .success)
        } else {
            recordNote = (command, tr("keys.record.conflict", chord.symbols, others.map(Self.title).joined(separator: ", ")),
                          .warning)
        }
    }

    private func reset(_ command: String) {
        stopRecording()
        if write(command: command, rules: []) { recordNote = (command, tr("keys.reset.done"), .success) }
    }

    /// Replaces the command's rules in your file and reads it again; a file Nook cannot read is left as it is.
    private func write(command: String, rules: [KeybindingRule]) -> Bool {
        let url = Keybindings.userFileURL
        do {
            let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let data = try KeybindingEdits.apply(current, command: command, rules: rules)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            center.reload()
            return true
        } catch {
            recordNote = (command, tr("keys.record.failed"), .error)
            return false
        }
    }

    // MARK: The file

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

    /// The command's name in the user's language; a command Nook does not know keeps its id. ⌘1–⌘9 share one text.
    private static func title(_ command: String) -> String {
        if let number = SessionJump.number(of: command) { return tr("keys.command.session.jump", number) }
        return Keybindings.commandIDs.contains(command) ? tr("keys.command.\(command)") : command
    }

    private static var displayPath: String {
        (Keybindings.userFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the file in the user's editor, writing an empty list first when there is none yet.
    @ViewBuilder
    private var fileButtons: some View {
        Button(tr("keys.file.open")) { openFile() }
        Button(tr("keys.file.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([Keybindings.userFileURL]) }
            .disabled(center.file.state == .missing)
        Button(tr("keys.file.reload")) { center.reload() }
    }

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
