import AppKit

/// The composer that has the keyboard, seen from its field editor: undo and redo over the draft itself (`ComposerUndo`),
/// so a chip deleted or put in comes back whole, and copy and cut that put the chips on the pasteboard twice: as
/// readable Markdown for other apps and as the draft for Nook's composers (`ComposerClipboard`). A composer attaches its
/// session when its field gets the keyboard and detaches it when the field lets go; the field's own undo is off in
/// between, so there is one history.
@MainActor
final class ComposerFieldSession {
    /// The composer whose field has the keyboard now.
    private static weak var active: ComposerFieldSession?
    private static var menuWatch: [NSObjectProtocol] = []
    /// What a Copy or Cut chosen in a menu took, until the field has written it (`didSendAction`).
    private static var pendingCopy: (fragment: String, changeCount: Int)?

    private weak var editor: NSTextView?
    private weak var field: AnyObject?
    private var keyMonitor: Any?
    private var history = ComposerUndo()
    /// The draft an undo or redo just put in: its change is not a new step.
    private var restoring: String?
    /// The draft before a dictation: what the microphone puts in becomes one step once its words have landed.
    private var beforeDictation: String?

    /// The whole draft (with the files attached at its end).
    var draft: () -> String = { "" }
    /// The words the field shows (`ComposerChips.display` of them while it has the keyboard).
    var words: () -> String = { "" }
    /// Puts a draft back, with the caret (UTF-16 in the draft) after what came back.
    var restore: (String, Int) -> Void = { _, _ in }
    /// False while the draft is not yours to change (dictation).
    var editable: () -> Bool = { true }

    var isAttached: Bool { editor != nil }

    /// Takes over the field editor that has the keyboard now (the composer's field just got it).
    func attach() {
        guard let editor = ComposerFieldStyle.focusedFieldEditor() else { return }
        if self.editor !== editor || field !== editor.delegate {
            history = ComposerUndo()
        }
        self.editor = editor
        field = editor.delegate
        editor.allowsUndo = false
        Self.active = self
        Self.watchMenus()
        startKeys()
    }

    /// Gives the field editor back (the field lost the keyboard, or the composer went away). The history goes with it,
    /// as a Mac text field's does.
    func detach() {
        if let editor, editor.delegate === field || editor.delegate == nil { editor.allowsUndo = true }
        editor = nil
        field = nil
        history = ComposerUndo()
        restoring = nil
        beforeDictation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if Self.active === self { Self.active = nil }
    }

    /// The editor while it still edits this composer's field.
    private var liveEditor: NSTextView? {
        guard let editor, editor.delegate === field, editor.window?.firstResponder === editor else { return nil }
        return editor
    }

    // MARK: Undo

    /// The draft changed. `separate` keeps it out of a run of typing (a chip chosen, a paste, dictation).
    func record(old: String, new: String, separate: Bool) {
        if let restoring {
            self.restoring = nil
            if restoring == new { return }
        }
        guard isAttached else { return }
        if !editable() {
            if beforeDictation == nil { beforeDictation = old }
            return
        }
        if let before = beforeDictation {
            beforeDictation = nil
            history.record(old: before, new: new, separate: true)
            return
        }
        history.record(old: old, new: new, separate: separate)
    }

    func undo() -> Bool {
        guard editable(), let step = history.undo(current: draft()) else { return true }
        restoring = step.text
        restore(step.text, step.caret)
        return true
    }

    func redo() -> Bool {
        guard editable(), let step = history.redo(current: draft()) else { return true }
        restoring = step.text
        restore(step.text, step.caret)
        return true
    }

    // MARK: Copy and paste

    /// ⌘C and ⌘X in the field: done here when the selection holds a chip, else left to the field.
    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(), key == "c" || key == "x" else { return event }
            let used = MainActor.assumeIsolated { self?.copySelection(cut: key == "x") ?? false }
            return used ? nil : event
        }
    }

    /// The selection, when it holds a chip, as the draft's text (with the links).
    private func selectedFragment() -> String? {
        guard let editor = liveEditor else { return nil }
        let range = editor.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length,
              (editor.string as NSString).substring(with: range).contains(ComposerChips.mark) else { return nil }
        let words = words()
        guard ComposerChips.display(words) == editor.string else { return nil }
        return ComposerChips.draftSlice(display: range.location..<NSMaxRange(range), in: words)
    }

    private func copySelection(cut: Bool) -> Bool {
        guard let editor = liveEditor, editor.window?.isKeyWindow == true, !editor.hasMarkedText(),
              let fragment = selectedFragment() else { return false }
        Self.write(fragment)
        // The field deletes the selection as any edit, so the chips' links go along (and undo brings them back).
        if cut, editor.isEditable { editor.delete(nil) }
        return true
    }

    private static func write(_ fragment: String) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(ComposerClipboard.readable(fragment), forType: .string)
        item.setString(fragment, forType: NSPasteboard.PasteboardType(ComposerClipboard.typeIdentifier))
        board.writeObjects([item])
    }

    /// A paste that put what a composer copied before `caret` (UTF-16 in `words`): the words with its chips back, and
    /// the caret after them. Nil for any other change.
    static func restoringPaste(in words: String, caret: Int) -> (text: String, caret: Int)? {
        let board = NSPasteboard.general
        guard board.types?.contains(NSPasteboard.PasteboardType(ComposerClipboard.typeIdentifier)) == true,
              let draft = board.string(forType: NSPasteboard.PasteboardType(ComposerClipboard.typeIdentifier)),
              let readable = board.string(forType: .string) else { return nil }
        return ComposerClipboard.restoringChips(in: words, caret: caret, readable: readable, draft: draft)
    }

    /// Copy and Cut chosen in the Edit menu or the field's context menu: the field writes its own text first (a chip is
    /// only its mark there), then the pasteboard gets both forms.
    private static func watchMenus() {
        guard menuWatch.isEmpty else { return }
        let center = NotificationCenter.default
        menuWatch.append(center.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
            let action = (note.userInfo?["MenuItem"] as? NSMenuItem)?.action
            MainActor.assumeIsolated {
                guard action == #selector(NSText.copy(_:)) || action == #selector(NSText.cut(_:)),
                      let fragment = active?.selectedFragment() else { return }
                pendingCopy = (fragment, NSPasteboard.general.changeCount)
            }
        })
        menuWatch.append(center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                guard let pending = pendingCopy else { return }
                pendingCopy = nil
                if NSPasteboard.general.changeCount != pending.changeCount { write(pending.fragment) }
            }
        })
    }
}
