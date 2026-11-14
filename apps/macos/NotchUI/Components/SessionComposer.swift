import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The box you write to an agent or to Nook in. Starting a session, answering one and chatting look and work the same:
/// the text on top, underneath the choices for the turn (agent, mode, permissions… or model and sources) passed in as
/// `controls`, and the send button on the right in Nook's own color, which turns into a stop button while work runs.
struct SessionComposer<Controls: View>: View {
    @Binding var text: String
    let prompt: String
    /// Room for the text before you type: a few lines when starting a session, one line when answering.
    var minHeight: CGFloat = 20
    var lines: ClosedRange<Int> = 1...6
    /// Anything besides an empty text that keeps the message from going out (no folder chosen, agent busy…).
    var canSend = true
    var sending = false
    /// The agent is working: the button stops it instead of sending (when `onStop` is given).
    var busy = false
    var onStop: (() -> Void)? = nil
    var sendLabel: String? = nil
    var focus: FocusState<Bool>.Binding? = nil
    let onSend: () -> Void
    @ViewBuilder var controls: () -> Controls

    /// An extra round button next to send (the microphone), kept on the right instead of among the choices.
    private var trailingAccessory: AnyView?
    /// A status at the right end of the tray of choices (the account's usage limits), outside the fitting.
    private var trayAccessory: AnyView?
    /// While busy: puts the text in line for after the current turn (or steers the turn) instead of sending it.
    private var queueAction: (() -> Void)?
    private var queueLabel = ""
    private var queueSymbol = "text.append"
    /// Cmd+Return while busy: the other way to deliver the text (steer instead of queue, or the reverse).
    private var flipAction: (() -> Void)?
    /// Cmd+Return while not busy: send right away, past messages still waiting in line (without it Cmd+Return sends as Return).
    private var sendNowAction: (() -> Void)?
    /// The list under the text, history and references (see `ComposerRich`); nil keeps the plain box.
    private var extras: (model: ComposerModel, config: ComposerConfig)?
    /// The choices sit in a tray under the box, tucked behind it, and the box holds the text with send on its row.
    private var choicesBelow = false
    /// The message you will likely send next (`NextPromptSuggestion`), shown in place of the placeholder while the box is
    /// empty; Tab takes it, typing or Escape dismisses it.
    private var suggestion: (text: String, accept: () -> Void, dismiss: () -> Void)?
    /// The composer's own color: the send button, the focus ring and a trace in the surface.
    private var tint: Color = NookTheme.iris

    /// Pictures added by dragging or pasting. Optional: a composer without it does not take pictures.
    private var imagesBinding: Binding<[ImageAttachment]>?
    /// Agents read pictures from disk: on send their paths go below the text. Without it the caller sends the pictures itself.
    private var imagesAsPaths = true
    /// What happens to another file that is dropped (default: its path goes into the text, which agents read).
    private var fileDropped: ((URL) -> Void)?

    /// The microphone next to send dictates into the draft (`dictating()`).
    private var dictates = false

    @FocusState private var ownFocus: Bool
    @StateObject private var dictator = ComposerDictator()
    @State private var editorLock = ComposerEditorLock()
    /// Undo, redo, copy and cut over the draft while the field has the keyboard (`ComposerFieldSession`).
    @State private var fieldSession = ComposerFieldSession()
    @State private var drop = ComposerDrop()
    @State private var pasteMonitor = PasteMonitor()
    /// Pasted pictures still being encoded: sending waits for them, or the message would go without the picture and the
    /// picture land in the next one.
    @State private var encodingPictures = 0

    /// The same composer that, while busy, queues what you type (Return or the queue button) for after the turn.
    func queueing(_ action: (() -> Void)?, alternate: (() -> Void)? = nil, label: String = tr("compose.queue"),
                  symbol: String = "text.append") -> Self {
        var copy = self
        copy.queueAction = action
        copy.flipAction = alternate
        copy.queueLabel = label
        copy.queueSymbol = symbol
        return copy
    }

    /// The same composer with a suggested next message as ghost text: Tab puts it in the box (and calls `onAccept`),
    /// Escape calls `onDismiss`. Typing hides it until the box is empty again. Nil shows the placeholder as before.
    func suggesting(_ text: String?, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) -> Self {
        var copy = self
        copy.suggestion = text.map { ($0, onAccept, onDismiss) }
        return copy
    }

    /// The same composer whose Cmd+Return sends right away, ahead of anything waiting in line, when it is not busy.
    func sendingNow(_ action: (() -> Void)?) -> Self {
        var copy = self
        copy.sendNowAction = action
        return copy
    }

    /// The same composer with rich workspace behaviour: `/`, `@` and `#` lists, ArrowUp for earlier messages, references, and the
    /// composer's own tint. The model belongs to the call site, which sends through `model.outgoing(_:)`.
    func rich(_ model: ComposerModel, _ config: ComposerConfig) -> Self {
        var copy = self
        copy.extras = (model, config)
        copy.tint = config.tint
        return copy
    }

    /// The same composer that takes pictures (drag, drop and paste) and shows them above the text.
    func images(_ images: Binding<[ImageAttachment]>, asPaths: Bool = true, onFile: ((URL) -> Void)? = nil) -> Self {
        var copy = self
        copy.imagesBinding = images
        copy.imagesAsPaths = asPaths
        copy.fileDropped = onFile
        return copy
    }

    /// The same composer with its choices (agent, model, mode…) in a tray under the box instead of inside it: a
    /// one-line box that reads the same when the agent works, when you scroll back and when you start a session.
    func choicesBelowBox() -> Self {
        var copy = self
        copy.choicesBelow = true
        return copy
    }

    /// The same composer with a small view placed right before the send button.
    func trailing<Accessory: View>(@ViewBuilder _ accessory: () -> Accessory) -> Self {
        var copy = self
        copy.trailingAccessory = AnyView(accessory())
        return copy
    }

    /// The same composer with a microphone next to send that dictates into the draft: the box shows that it listens and
    /// stays read-only until the words are in, Send while it listens sends once they have landed, and Escape throws the
    /// recording away (see `ComposerDictator`).
    func dictating() -> Self {
        var copy = self
        copy.dictates = true
        return copy
    }

    /// The same composer with a small view at the right end of the tray of choices under the box (`choicesBelowBox`).
    func trayTrailing<Accessory: View>(@ViewBuilder _ accessory: () -> Accessory) -> Self {
        var copy = self
        copy.trayAccessory = AnyView(accessory())
        return copy
    }

    init(
        text: Binding<String>,
        prompt: String,
        minHeight: CGFloat = 20,
        lines: ClosedRange<Int> = 1...6,
        canSend: Bool = true,
        sending: Bool = false,
        busy: Bool = false,
        onStop: (() -> Void)? = nil,
        sendLabel: String? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onSend: @escaping () -> Void,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self._text = text
        self.prompt = prompt
        self.minHeight = minHeight
        self.lines = lines
        self.canSend = canSend
        self.sending = sending
        self.busy = busy
        self.onStop = onStop
        self.sendLabel = sendLabel
        self.focus = focus
        self.onSend = onSend
        self.controls = controls
    }

    /// Convenience initializer where `focus` precedes `busy`, preventing argument-order compiler errors.
    init(
        text: Binding<String>,
        prompt: String,
        minHeight: CGFloat = 20,
        lines: ClosedRange<Int> = 1...6,
        canSend: Bool = true,
        sending: Bool = false,
        focus: FocusState<Bool>.Binding?,
        busy: Bool = false,
        onStop: (() -> Void)? = nil,
        sendLabel: String? = nil,
        onSend: @escaping () -> Void,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self._text = text
        self.prompt = prompt
        self.minHeight = minHeight
        self.lines = lines
        self.canSend = canSend
        self.sending = sending
        self.busy = busy
        self.onStop = onStop
        self.sendLabel = sendLabel
        self.focus = focus
        self.onSend = onSend
        self.controls = controls
    }

    static var surface: Color { NookTheme.composer }

    private var hasImages: Bool { !(imagesBinding?.wrappedValue.isEmpty ?? true) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasImages }
    /// While dictating, Send may be pressed before any word is in: it sends once they have landed (and only if there are).
    private var enabled: Bool {
        canSend && !sending && (!isEmpty || dictator.isActive) && encodingPictures == 0 && overLimit == nil
    }
    /// Characters past `PasteRule.messageLimit`: the draft stays in the box, with a notice, until it fits.
    private var overLimit: Int? { PasteRule.overLimit(typedText) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            // The list watches the model itself: the panel around the composer does not, so a key that changes the
            // list redraws the list and not the conversation above it.
            if let extras {
                ComposerSuggestionSlot(model: extras.model, tint: tint) { choose($0) }
                if let scope = extras.config.secretScope {
                    ComposerSecretOfferSlot(model: extras.model) { keepSecrets(scope: scope) }
                }
            }
            if let over = overLimit {
                PanelNoticeBar(title: tr("compose.limit.title"),
                               detail: tr("compose.limit.detail", PasteRule.messageLimit.formatted(), over.formatted()),
                               symbol: "text.badge.xmark", tone: NookTheme.amber) { EmptyView() }
            }
            if choicesBelow {
                // The box comes first in z-order so the tray runs on behind it (see ComposerTray).
                VStack(spacing: 0) {
                    box.zIndex(1)
                    ComposerTray(edge: .bottom) { choicesRow }
                }
            } else {
                box
            }
        }
        // What each control does, above it on hover (`composerTip`): the system tooltip did not show in this row.
        .composerTips()
        // The composer keeps to the conversation's reading column on its own, so a wide window never stretches it
        // from edge to edge, wherever it is placed.
        .chatColumn()
        // A page the session's agent opened floats just above it (SessionBrowserCorner).
        .anchorPreference(key: SessionComposerBounds.self, value: .bounds) { $0 }
        // F6 steps to the composer as a part of its own.
        .focusArea(.composer)
    }

    private func assign(_ value: String) {
        if let extras, value != text { extras.model.applying = true }
        text = value
    }

    /// The words in the box; files attached at the end of the draft show as tiles above it (see `ComposerAttachments`).
    private var typedText: String { ComposerAttachments.split(text).body }

    private var isFocused: Bool { (focus ?? $ownFocus).wrappedValue }

    /// The words as the field shows them (see `ComposerChips`): with the keyboard each reference is one chip where it was
    /// put, without it each reads as its short name. The draft keeps the links.
    private var shownText: String {
        isFocused ? ComposerChips.display(typedText) : ComposerChips.resting(typedText)
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { shownText }, set: { setShown($0) })
    }

    /// The field's words back into the draft: the chips that stay keep their links, a chip deleted takes its link along.
    private func setShown(_ value: String) {
        let body = typedText
        // Dictation owns the box until its words are in; the field writes back what it was given (on focus changes too).
        guard !dictator.isActive, value != ComposerChips.display(body) else { return }
        let hasChips = !ContextRefs.find(in: body).isEmpty
        if hasChips, !isFocused || value == ComposerChips.resting(body) { return }
        guard hasChips || value.contains(ComposerChips.mark) else {
            text = ComposerAttachments.replacingBody(of: text, with: value)
            return
        }
        let edit = ComposerChips.applying(display: value, to: body, caret: ComposerFieldStyle.focusedCaret(),
                                          spares: ComposerChipSpares.links)
        ComposerChipSpares.update(edit)
        text = ComposerAttachments.replacingBody(of: text, with: edit.text)
    }

    private func choose(_ suggestion: ComposerSuggestion) {
        guard let extras else { return }
        // What you chose goes where its `@`, `#` or `/` was typed, also in the middle of the text; the caret after it.
        let (value, caret) = extras.model.accepting(suggestion, in: typedText, extras.config)
        assign(ComposerAttachments.replacingBody(of: text, with: value))
        if let caret { placeCaret(caret, inWords: value) }
        // A line that fills the box can lead to a list of its own ("@chat " lists the chats): show it straight away.
        if case .command(let command) = suggestion.payload, command.action == .insert {
            extras.model.update(for: value, caret: caret, extras.config)
        }
        (focus ?? $ownFocus).wrappedValue = true
    }

    /// Where the caret is in `words` (the draft's words, UTF-16) while the field shows them; nil without the keyboard.
    private func caret(in words: String) -> Int? {
        guard isFocused, let selection = ComposerFieldStyle.focusedSelection(expecting: ComposerChips.display(words)) else { return nil }
        return ComposerChips.draftOffset(display: NSMaxRange(selection), in: words)
    }

    /// Puts the caret at `offset` (UTF-16 in `words`, the draft's words) once the field shows them.
    private func placeCaret(_ offset: Int, inWords words: String) {
        guard isFocused else { return }
        let clamped = min(offset, words.utf16.count)
        ComposerFieldStyle.placeCaret(ComposerChips.displayOffset(draft: clamped, in: words), expecting: ComposerChips.display(words))
    }

    /// Hands the field's undo, redo, copy and cut to `fieldSession` while it has the keyboard.
    private func wireFieldSession() {
        fieldSession.draft = { text }
        fieldSession.words = { typedText }
        fieldSession.restore = { value, caret in
            assign(value)
            placeCaret(caret, inWords: ComposerAttachments.split(value).body)
        }
        fieldSession.editable = { !dictator.isActive }
    }

    private func textChanged(_ oldText: String, _ newText: String) {
        NookPresence.shared.typed(count: newText.count)
        fieldSession.record(old: oldText, new: newText, separate: extras?.model.applying ?? false)
        // Typing only hides the suggestion (it is drawn while the box is empty): clear the box again and it is back, so
        // a key pressed by accident does not cost it. Escape dismisses it; taking it with Tab has already called `accept`.
        styleMarkdown()
        guard let extras else { return }
        // Only typing proposes a name (`ComposerInlineName`) or asks for the rest of the sentence (`ComposerCompleter`):
        // every other change (a paste, a chip, history) hides the grey text, unless it put in the start of the sentence.
        var typedName: ComposerInlineName.Match?
        var typedAt: Int?
        defer { updateGhost(words: ComposerAttachments.split(newText).body, name: typedName, typedAt: typedAt) }
        // ⇧⌘V asked for this change to stay text; it holds for this one change only.
        let pastedAsText = extras.model.pastesAsText
        extras.model.pastesAsText = false
        // The list, list items and big pastes look at the words in the box, not at the files attached after them.
        let old = ComposerAttachments.split(oldText).body, new = ComposerAttachments.split(newText).body
        if extras.model.applying {
            extras.model.applying = false
            return
        }
        extras.model.history.stopWalking()
        // Text with chips copied from a composer comes in as readable Markdown: it gets its chips back.
        if new.utf16.count > old.utf16.count, let at = caret(in: new),
           let restored = ComposerFieldSession.restoringPaste(in: new, caret: at) {
            assign(ComposerAttachments.replacingBody(of: newText, with: restored.text))
            placeCaret(restored.caret, inWords: restored.text)
            extras.model.close()
            return
        }
        // A session link pasted or dropped into the text ("Copy session link", a dragged row) becomes its chip.
        if let linked = SessionLink.replacingPasted(old: old, new: new) {
            assign(ComposerAttachments.replacingBody(of: newText, with: linked))
            extras.model.close()
            return
        }
        if imagesBinding != nil, let found = PastedPaths.attaching(old: old, new: new) {
            assign(ComposerAttachments.replacingBody(of: newText, with: found.body))
            extras.model.close()
            found.urls.forEach(receive)
            return
        }
        // A line break after a list item starts the next item (or ends the list after an empty one).
        if let continued = ComposerLists.continued(old: old, new: new) {
            assign(ComposerAttachments.replacingBody(of: newText, with: continued))
            return
        }
        // A pasted secret is offered to be kept out of the message first; the paste then stays in the box until you decide.
        if extras.config.secretScope != nil, extras.model.noticeSecrets(old: old, new: new) {
            extras.model.update(for: new, caret: caret(in: new), extras.config)
            return
        }
        if extras.config.keepsBigPastes, let kept = extras.model.keepPaste(old: old, new: new, asText: pastedAsText) {
            assign(ComposerAttachments.replacingBody(of: newText, with: kept))
            extras.model.close()
            return
        }
        let at = caret(in: new)
        extras.model.update(for: new, caret: at, extras.config)
        // A word or two more than before, typed at the caret: perhaps the start of a model's name.
        if let at, new.utf16.count > old.utf16.count {
            typedName = extras.model.inlineName(in: new, caret: at, extras.config)
        }
        typedAt = at
    }

    /// The grey text after the caret (`ComposerInlineGhost`) once the field shows `words`: a name typed without `@`, the
    /// sentence on screen carried on (typed through, or a word taken), or after a pause in typing a new suggestion for the
    /// rest of the sentence. Anything else hides it straight away, so Tab never takes what is no longer on screen.
    private func updateGhost(words: String, name: ComposerInlineName.Match?, typedAt: Int?) {
        let ghost = ComposerInlineGhost.shared
        let completer = ComposerCompleter.shared
        let editor = { ComposerFieldStyle.focusedEditor(expecting: ComposerChips.display(words)) }
        if let name {
            completer.cancel()
            DispatchQueue.main.async { ghost.show(name, in: editor()) }
            return
        }
        if let carried = ghost.carried(into: words) {
            completer.cancel()
            DispatchQueue.main.async { ghost.show(carried, in: editor()) }
            return
        }
        ghost.hide()
        // Autocomplete may have started or stopped since the focus came: the sentence is its own or the composer's, never both.
        if isFocused, extras != nil { AutocompleteController.shared.standAside(completer.suggestsItself, for: "composer") }
        guard let typedAt, let extras, isFocused, !extras.model.isOpen, completer.suggestsItself,
              let caretIndex = String.Index(exactUTF16: typedAt, in: words) else { return completer.cancel() }
        let before = String(words[..<caretIndex]), after = String(words[caretIndex...])
        completer.suggest(before: before, after: after, situation: extras.config.situation(), hint: prompt) { suggestion in
            // Still the same words and the keyboard here: a suggestion for older text is not shown.
            guard let suggestion, isFocused, typedText == words, !(self.extras?.model.isOpen ?? false) else { return }
            ghost.show(.text(suggestion, words: words, caret: typedAt), in: editor())
        }
    }

    /// Tab (one word) or ⇧Tab (all of it) on the sentence on screen: the words go in at the caret; what is left stays grey.
    private func acceptGhostText(all: Bool) -> Bool {
        let words = typedText
        guard case .text(var suggestion, let shownWords, let caret)? = ComposerInlineGhost.shared.shown(
                  for: ComposerFieldStyle.focusedEditor(expecting: ComposerChips.display(words))),
              shownWords == words, let index = String.Index(exactUTF16: caret, in: words) else { return false }
        let prefs = AutocompleteStore.shared.prefs
        let piece = all ? suggestion.remaining
            : suggestion.acceptNextChunk(.init(trailingSpace: prefs.trailingSpace, attachedPunctuation: prefs.punctuationWithWord))
        guard !piece.isEmpty else { return false }
        let value = String(words[..<index]) + piece + String(words[index...])
        assign(ComposerAttachments.replacingBody(of: text, with: value))
        placeCaret(caret + piece.utf16.count, inWords: value)
        return true
    }

    /// Tab on a name typed without `@`: the typed words become its chip, as if chosen from the `@` list.
    private func acceptInlineName() -> Bool {
        let words = typedText
        guard let match = ComposerInlineGhost.shared.match(for: ComposerFieldStyle.focusedEditor(expecting: ComposerChips.display(words))) else {
            return false
        }
        ComposerInlineGhost.shared.hide()
        let (value, caret) = match.accepting(in: words)
        guard let caret else { return false }
        assign(ComposerAttachments.replacingBody(of: text, with: value))
        placeCaret(caret, inWords: value)
        return true
    }

    /// The pasted secrets go to private files and the box keeps references to them.
    private func keepSecrets(scope: String) {
        guard let extras else { return }
        let kept = extras.model.keepSecretsPrivate(in: typedText, scope: scope)
        assign(ComposerAttachments.replacingBody(of: text, with: kept))
        WorkspaceBridge.shared.scheduleSecretSweep()
    }

    /// Up and Down move in the list, or walk through earlier messages: plain arrows only from the edge of the text (see
    /// `ComposerKeys`), the history commands (⌥↑ ⌥↓) from anywhere.
    private func arrow(_ delta: Int, walkAnywhere: Bool = false) -> KeyPress.Result {
        guard let extras else { return .ignored }
        if extras.model.isOpen {
            extras.model.move(delta)
            return .handled
        }
        if delta < 0 {
            guard walkAnywhere || ComposerKeys.arrowWalksHistory(text: typedText, walking: extras.model.history.isWalking),
                  let previous = extras.model.history.previous(current: text) else { return .ignored }
            assign(previous)
            return .handled
        }
        guard extras.model.history.isWalking, let next = extras.model.history.next() else { return .ignored }
        assign(next)
        return .handled
    }

    /// Return with the list open takes the chosen line; a plain Return otherwise sends. Sending here, instead of leaving
    /// it to `onSubmit`, keeps the field from committing the edit, which selected the whole text while it was still there.
    /// SwiftUI handles key presses while it updates its views, and sending changes the session and the draft, so the send
    /// itself runs right after.
    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        if chooseSelected() { return .handled }
        guard press.modifiers.isEmpty else { return .ignored }
        DispatchQueue.main.async { submit() }
        return .handled
    }

    private func chooseSelected() -> Bool {
        guard let extras, extras.model.isOpen, extras.model.suggestions.indices.contains(extras.model.selection) else { return false }
        choose(extras.model.suggestions[extras.model.selection])
        return true
    }

    /// The composer's commands for the panel's key monitor (see `Keybindings`); they run while the box has the keyboard.
    private var keyHandlers: [String: () -> Bool] {
        var handlers = baseKeyHandlers
        if dictates {
            handlers["composer.dictate"] = {
                toggleDictation()
                return true
            }
        }
        return handlers
    }

    private var baseKeyHandlers: [String: () -> Bool] {
        [
            // ⌘Return: send, or while the agent works deliver the other way (steer instead of queue, or the reverse).
            "composer.send": { sendKey(alternate: false) },
            "composer.sendAlternate": { sendKey(alternate: true) },
            "composer.newline": {
                if chooseSelected() { return true }
                return NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            },
            "composer.stash": stashKey,
            "composer.historyPrevious": { walkHistory(-1) },
            "composer.historyNext": { walkHistory(1) },
            // Undo and redo the draft itself, so a chip comes back whole; the field's own undo is off meanwhile.
            "composer.undo": { fieldSession.isAttached ? fieldSession.undo() : false },
            "composer.redo": { fieldSession.isAttached ? fieldSession.redo() : false },
            "composer.pasteAsText": pasteAsText,
        ]
    }

    /// ⇧⌘V: pastes the clipboard's text into the box as text, also when it is big enough to become an attachment with ⌘V.
    /// A paste that would push the message past `PasteRule.messageLimit` still goes aside.
    private func pasteAsText() -> Bool {
        guard !dictator.isActive, NSPasteboard.general.string(forType: .string) != nil else { return false }
        extras?.model.pastesAsText = true
        let pasted = NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
        if !pasted { extras?.model.pastesAsText = false }
        return pasted
    }

    private func walkHistory(_ delta: Int) -> Bool {
        if case .handled = arrow(delta, walkAnywhere: true) { return true }
        return false
    }

    private var keyContext: [String: Bool] {
        ["composerFocus": true, "composerDraft": !isEmpty, "turnRunning": busy]
    }

    private func sendKey(alternate: Bool) -> Bool {
        if chooseSelected() { return true }
        if alternate {
            if busy, !isEmpty, encodingPictures == 0, overLimit == nil, let flipAction { fire(flipAction) }
        } else if !busy, let sendNowAction, !isEmpty, encodingPictures == 0, overLimit == nil {
            fire(sendNowAction)
        } else if !busy, enabled {
            fire(onSend)
        }
        return true
    }

    /// ⌘S: set the draft aside, bring one back, or choose from several.
    private func stashKey() -> Bool {
        guard let extras else { return true }
        // Another composer may have changed the set-aside drafts since this one last looked.
        if extras.model.onStashChanged != nil { extras.model.stash = ComposerDraftStore.shared.stash }
        guard let result = extras.model.stashKey(composerText: text) else { return true }
        assign(result)
        extras.model.onStashChanged?()
        return true
    }

    private func tabKey(_ press: KeyPress) -> KeyPress.Result {
        let outdent = press.modifiers.contains(.shift) || press.key.character == "\u{19}"
        if extras != nil, let shown = ComposerInlineGhost.shared.shown(for: ComposerFieldStyle.focusedEditor(expecting: shownText)) {
            switch shown {
            case .name: if !outdent, acceptInlineName() { return .handled }
            case .text: if acceptGhostText(all: outdent) { return .handled }
            }
        }
        if !outdent, let suggestion, typedText.isEmpty, !(extras?.model.isOpen ?? false) {
            bodyBinding.wrappedValue = suggestion.text
            suggestion.accept()
            Self.placeCaretAtEnd()
            return .handled
        }
        if !outdent, let extras, extras.model.isOpen, extras.model.suggestions.indices.contains(extras.model.selection) {
            choose(extras.model.suggestions[extras.model.selection])
            return .handled
        }
        return nestListItem(outdent: outdent) ? .handled : .ignored
    }

    /// Tab and Shift+Tab on a list item move it in under the one above, or back out (`ComposerLists.nest`); the caret
    /// moves along. False anywhere else, so Tab keeps its usual meaning.
    private func nestListItem(outdent: Bool) -> Bool {
        let body = shownText
        guard let editor = ComposerFieldStyle.focusedEditor(expecting: body),
              let nested = ComposerLists.nest(body, selection: editor.selectedRange(), outdent: outdent) else { return false }
        guard nested.text != body else { return true }
        bodyBinding.wrappedValue = nested.text
        DispatchQueue.main.async {
            guard let editor = ComposerFieldStyle.focusedEditor(expecting: nested.text) else { return }
            editor.setSelectedRange(nested.selection)
        }
        return true
    }

    /// The draft's Markdown styled in the field (Settings › Appearance › Style Markdown as you type), right after the
    /// field took the change.
    /// The references are drawn as chips on their marks either way (`ComposerChips`).
    private func styleMarkdown() {
        let markdown = AppSettings.shared.richComposer
        let chips = ContextRefs.find(in: typedText).map { ContextRef(kind: $0.kind, id: $0.id, label: $0.label) }
        guard markdown || !chips.isEmpty else { return }
        DispatchQueue.main.async { [shown = ComposerChips.display(typedText)] in
            ComposerFieldStyle.restyleFocusedEditor(expecting: shown, chips: chips, markdown: markdown)
        }
    }

    // MARK: Dictation

    /// The microphone or ⌘⇧D: start listening, or finish while it listens.
    private func toggleDictation() {
        if dictator.isActive {
            dictator.finish()
            return
        }
        // The words go where the caret is, in place of what is selected.
        let words = typedText
        let selection = isFocused ? ComposerFieldStyle.focusedSelection(expecting: ComposerChips.display(words)) : nil
        (focus ?? $ownFocus).wrappedValue = true
        dictator.start(body: words, selection: selection.map {
            ComposerChips.draftRange(display: $0.location..<NSMaxRange($0), in: words)
        }, folder: extras?.config.fileRoot) { spoken, caret in
            assign(ComposerAttachments.replacingBody(of: text, with: spoken))
            placeCaret(caret, inWords: spoken)
        }
    }

    /// Escape or the cross: the recording goes, the draft is as it was before it.
    private func discardDictation() {
        dictator.discard { before in assign(ComposerAttachments.replacingBody(of: text, with: before)) }
    }

    /// The box is read-only while the microphone has it, and editable again once the words are in.
    private func dictationChanged(_ active: Bool) {
        if active {
            editorLock.lock(expecting: shownText)
        } else {
            editorLock.unlock()
            styleMarkdown()
        }
    }

    private func escapeKey() -> KeyPress.Result {
        if dictator.isActive {
            discardDictation()
            return .handled
        }
        if ComposerInlineGhost.shared.shown(for: ComposerFieldStyle.focusedEditor(expecting: shownText)) != nil {
            ComposerInlineGhost.shared.dismiss()
            return .handled
        }
        if let suggestion, typedText.isEmpty, !(extras?.model.isOpen ?? false) {
            suggestion.dismiss()
            return .handled
        }
        guard let extras, extras.model.isOpen else { return .ignored }
        extras.model.close()
        return .handled
    }

    // The text field and its keys are built in separate steps: as one chain the compiler cannot type-check it in time.
    // The placeholder is drawn here, not as the field's prompt: a vertical field takes its prompt's width on one line as
    // its narrowest, so a long one ("Describe what the agent should do. Return starts the session.") pushed the box past
    // a narrow column and under the tab beside it in split view. Drawn behind the field it wraps within the box instead
    // (as `ChatReplyField` does).
    private func field(focused: FocusState<Bool>.Binding) -> some View {
        TextField("", text: bodyBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .lineLimit(lines)
            .background(alignment: .topLeading) {
                if typedText.isEmpty, let suggestion {
                    // The suggestion in the ghost text's quiet grey, with the key that takes it.
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                        Text(suggestion.text)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(lines.upperBound)
                        NookKeyHint(text: tr("textgen.next.tab"))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else if typedText.isEmpty {
                    Text(prompt)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(lines.lowerBound)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(prompt)
            .accessibilityHint(suggestion.map { tr("textgen.next.accessibility", $0.text) } ?? "")
            .focused(focused)
            .onChange(of: focused.wrappedValue) { _, now in
                if now {
                    // The composer suggests in its own field: autocomplete leaves it alone meanwhile. With autocomplete's own
                    // model while autocomplete runs here, the sentence is autocomplete's (`ComposerCompleter.handsOver`).
                    if extras != nil, ComposerCompleter.shared.suggestsItself { AutocompleteController.shared.standAside(true, for: "composer") }
                    Self.placeCaretAtEnd()
                    styleMarkdown()
                    wireFieldSession()
                    DispatchQueue.main.async { if isFocused { fieldSession.attach() } }
                    // With the keyboard the references turn from short names into chips: the field takes that text
                    // after this update, so draw the chips once more right after it.
                    if text.contains("nook-context:") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { styleMarkdown() }
                    }
                } else {
                    fieldSession.detach()
                    ComposerInlineGhost.shared.hide()
                    ComposerCompleter.shared.cancel()
                    AutocompleteController.shared.standAside(false, for: "composer")
                }
            }
            .onChange(of: dictator.isActive) { _, active in dictationChanged(active) }
            // A composer that goes while it has the keyboard (another session opened) takes its grey text along.
            .onDisappear {
                guard focused.wrappedValue else { return }
                ComposerInlineGhost.shared.hide()
                ComposerCompleter.shared.cancel()
                AutocompleteController.shared.standAside(false, for: "composer")
            }
            .onSubmit(submit)
            .onChange(of: text) { old, new in textChanged(old, new) }
            // In the non-activating notch and ask panels the binding can lag behind the field until Return commits it,
            // which left the send arrow looking disabled; take every keystroke straight from the field itself, through
            // `bodyBinding` so files attached to the draft stay.
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                guard focused.wrappedValue, let field = note.object as? NSTextField,
                      field.window is NotchPanel || field.window is SelectionAskPanel,
                      field.stringValue != shownText else { return }
                bodyBinding.wrappedValue = field.stringValue
            }
    }

    // The keys that belong to the text field itself (moving in the list, taking a line); ⌘Return, ⌘S, ⇧Return and the
    // history keys are keybinding commands, offered to the panel's key monitor while the box has the keyboard.
    private func withKeys(_ view: some View, focused: Bool) -> some View {
        view
            .onKeyPress(.upArrow) { () -> KeyPress.Result in arrow(-1) }
            .onKeyPress(.downArrow) { () -> KeyPress.Result in arrow(1) }
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { (press: KeyPress) -> KeyPress.Result in tabKey(press) }
            .onKeyPress(.escape) { () -> KeyPress.Result in escapeKey() }
            .onKeyPress(.return, phases: .down) { (press: KeyPress) -> KeyPress.Result in returnKey(press) }
            .keyCommands(keyHandlers, context: keyContext, enabled: focused)
    }

    private func submit() {
        if busy, let queueAction, !isEmpty, encodingPictures == 0, overLimit == nil {
            fire(queueAction)
        } else if !(busy && onStop != nil), enabled {
            // While busy with a stop button showing, Return must not send: the button is for stopping.
            fire(onSend)
        }
    }

    private var box: some View {
        let focused = focus ?? $ownFocus
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            let images = imagesBinding?.wrappedValue ?? []
            let files = ComposerAttachments.split(text).files
            if !images.isEmpty || !files.isEmpty || drop.open {
                ImageAttachmentStrip(images: images, files: files, fileRoot: extras?.config.fileRoot,
                                     dropSlot: drop.hovering ? tint : nil) { gone in
                    imagesBinding?.wrappedValue.removeAll { $0.id == gone.id }
                } removeFile: { index in
                    text = ComposerAttachments.removing(at: index, from: text)
                }
                .transition(.opacity)
            }
            if dictates, dictator.isActive {
                ComposerDictationBar(dictator: dictator, tint: tint, discard: discardDictation, finish: { dictator.finish() })
            }
            if choicesBelow {
                // The text gets 4 pt of its own above and below, so lines that wrap keep 12 pt from the edges while the
                // send button stays 8 pt in; one line still fits beside the button, so the 48 pt capsule does not grow.
                HStack(alignment: .center, spacing: NookTheme.Spacing.lg) {
                    withKeys(field(focused: focused), focused: focused.wrappedValue)
                        .padding(.vertical, NookTheme.Spacing.xs)
                        .frame(minHeight: minHeight, alignment: .center)
                    sendCluster
                }
            } else {
                withKeys(field(focused: focused), focused: focused.wrappedValue)
                    .frame(minHeight: minHeight, alignment: .topLeading)
            }
            // When the box gets narrow (the chat beside an open app), the choices give up their words step by step,
            // so the row shrinks with the box instead of running out of it while keeping as much text as fits.
            if !choicesBelow {
                controlRow
            }
        }
        // The send button sits 8 pt from the bottom and trailing edges, so with `Radius.composer` its circle runs
        // parallel to the corner; the text starts 16 pt in.
        .padding(.leading, NookTheme.Spacing.xl)
        .padding(.trailing, NookTheme.Spacing.md)
        .padding(.top, choicesBelow ? NookTheme.Spacing.md : NookTheme.Spacing.xl)
        .padding(.bottom, NookTheme.Spacing.md)
        // One quiet surface with a hairline outline and a faint light along its top edge, so it lifts off the canvas;
        // focus only brightens the outline a little, so the box does not flash while you type.
        .background(shape.fill(Self.surface))
        .overlay(shape.strokeBorder(focused.wrappedValue ? tint.opacity(0.28) : NookTheme.fieldStroke, lineWidth: 1))
        .overlay(edgeLight)
        .overlay {
            if drop.hovering {
                shape
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .animation(NookTheme.reveal, value: focused.wrappedValue)
        .animation(NookTheme.reveal, value: drop)
        .composerDrop(of: (imagesBinding == nil ? [] : [UTType.fileURL, UTType.image]) + (extras == nil ? [] : SessionLinkDrag.types),
                      $drop) { providers in
            // A session row from the Agents list: its chip, like picking it after `@`.
            if extras != nil, SessionLinkDrag.receive(providers, add: { link in
                assign(SessionLink.inserting(link, into: text))
            }) { return true }
            guard let imagesBinding else { return false }
            return ImageAttachment.receive(providers, images: { imagesBinding.wrappedValue += $0 }, file: { url in
                dropFile(url)
            })
        }
        .onAppear {
            startPasteMonitor(focused: focused)
            extras?.model.connectStash()
        }
        .onDisappear {
            pasteMonitor.stop()
            fieldSession.detach()
            // Leaving the box stops listening; the words that came in so far stay in the draft.
            dictator.discard { _ in }
        }
        .animation(NookTheme.reveal, value: dictator.isActive)
    }

    private var shape: RoundedRectangle {
        NookTheme.shape(NookTheme.Radius.composer)
    }

    /// The faint light along the top edge of the box, fading out before its middle.
    private var edgeLight: some View {
        let light = LinearGradient(colors: [NookTheme.paper.opacity(0.06), NookTheme.paper.opacity(0)],
                                   startPoint: .top, endPoint: .center)
        return shape.strokeBorder(light, lineWidth: 1).allowsHitTesting(false)
    }

    /// The choices for the turn, then the extra button and send (or stop) on the right. The row starts a pill's own
    /// padding further out, so the first choice's words line up with the text above it. Send stays outside the fitting:
    /// the choices get the width it leaves, which picks the same density as fitting the whole row did.
    private var controlRow: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ComposerDensityFit(content: controls(), minGap: NookTheme.Spacing.md)
            if let trayAccessory { trayAccessory }
            sendCluster
        }
        .padding(.leading, -NookTheme.Spacing.md)
    }

    /// The choices in the tray under the box, and its accessory at the right end; the choices give up their words step
    /// by step like the row in the box, in the width the accessory leaves them.
    private var choicesRow: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ComposerDensityFit(content: controls(), minGap: trayAccessory == nil ? 0 : NookTheme.Spacing.md)
            if let trayAccessory { trayAccessory }
        }
    }

    /// The extra button, then send, or stop and queue while the agent works.
    private var sendCluster: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if let trailingAccessory { trailingAccessory }
            if dictates { ComposerDictationButton(dictator: dictator, toggle: toggleDictation) }
            if busy, let onStop {
                if let queueAction, !isEmpty, overLimit == nil {
                    roundButton(symbol: queueSymbol, label: queueLabel, active: encodingPictures == 0) { fire(queueAction) }
                        .disabled(encodingPictures > 0)
                }
                roundButton(symbol: "stop.fill", label: tr("button.stop"), active: true, action: onStop)
            } else {
                roundButton(symbol: "arrow.up", label: sendLabel ?? tr("button.send"), active: enabled) { fire(onSend) }
                    .disabled(!enabled)
            }
        }
    }

    /// Sends. For agents the pictures go out as paths below the text. A rich composer hands them to its model, whose
    /// `outgoing` adds the paths to what is sent: the box never shows them, and keeps your words and the pictures while a
    /// session starts in the background. The caller clears the pictures once the message went out. A plain composer has no
    /// model, so the paths go into the text for the moment of the send.
    private func fire(_ action: @escaping () -> Void) {
        // Send while dictating finishes the recording and sends once its words are in (and only when there are any).
        if dictates, dictator.send({ [self] in if !isEmpty { deliver(action) } }) { return }
        deliver(action)
    }

    private func deliver(_ action: () -> Void) {
        guard imagesAsPaths, let imagesBinding, !imagesBinding.wrappedValue.isEmpty else { return action() }
        if let extras {
            extras.model.pictures = imagesBinding.wrappedValue
            action()
            extras.model.pictures = []
            return
        }
        let typed = text
        let pictures = imagesBinding.wrappedValue
        let outgoing = ImageAttachment.appendingPaths(of: pictures, to: typed)
        text = outgoing
        imagesBinding.wrappedValue = []
        action()
        if text == outgoing {
            text = typed
            imagesBinding.wrappedValue = pictures
        }
    }

    /// A file or folder named as a path: the same as dropping it.
    private func receive(_ url: URL) {
        ImageAttachment.take(url, images: { imagesBinding?.wrappedValue += $0 }, file: dropFile)
    }

    /// Another file that is dropped or pasted: handed to the caller, or a tile for a rich composer, or its path in the text.
    private func dropFile(_ url: URL) {
        if let fileDropped { fileDropped(url) } else if extras != nil { attach(url) } else { insertPath(url) }
    }

    /// A file dropped on a composer for an agent: a tile above the box, a reference the agent reads itself.
    private func attach(_ url: URL) {
        let path = url.standardizedFileURL.path
        let base = extras?.config.fileRoot.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        let id = base.flatMap { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : nil } ?? path
        text = ComposerAttachments.appending(ContextRef(kind: .file, id: id, label: url.lastPathComponent), to: text)
    }

    private func insertPath(_ url: URL) {
        let path = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + path + " "
    }

    /// AppKit selects a text field's whole text when it gets the keyboard, so coming back to a draft would leave it
    /// selected and the next key would replace it. A full selection becomes a caret at the end; a click keeps its spot.
    /// Coming back from a dropdown (the model picker) its popover is still the key window for a moment and the field
    /// takes the keyboard a little later, so this looks in the main window too and tries again a few times, until it
    /// finds the field with its text.
    static func placeCaretAtEnd() {
        placeCaretAtEnd(retries: [0.05, 0.15, 0.3])
    }

    private static func placeCaretAtEnd(retries: [TimeInterval]) {
        DispatchQueue.main.async {
            if caretPlaced() { return }
            guard let delay = retries.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { placeCaretAtEnd(retries: Array(retries.dropFirst())) }
        }
    }

    /// True once a field editor with text has the keyboard (in the key or the main window), after its full selection
    /// became a caret at the end.
    private static func caretPlaced() -> Bool {
        // A dropdown's own search field is in its popover window, not the composer's.
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .filter { !String(describing: type(of: $0)).contains("Popover") }
        for window in windows {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { continue }
            let length = (editor.string as NSString).length
            guard length > 0 else { continue }
            let selected = editor.selectedRange()
            if selected.location == 0, selected.length == length {
                editor.setSelectedRange(NSRange(location: length, length: 0))
            }
            return true
        }
        return false
    }

    /// Cmd-V with a picture on the clipboard adds it here; with text it pastes as always.
    private func startPasteMonitor(focused: FocusState<Bool>.Binding) {
        guard let imagesBinding else { return }
        pasteMonitor.start {
            guard focused.wrappedValue else { return false }
            // Copied files that are not pictures attach like a drop.
            let others = ImageAttachment.nonImageFiles()
            let claimed = ImageAttachment.fromPasteboard { pictures in
                encodingPictures = max(encodingPictures - 1, 0)
                imagesBinding.wrappedValue += pictures
            }
            if claimed { encodingPictures += 1 }
            others.forEach(dropFile)
            return claimed || !others.isEmpty
        }
    }

    private func roundButton(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(icon: symbol).font(NookTheme.font(12, .bold))
                }
            }
            .foregroundStyle(active ? NookTheme.onIris : NookTheme.textTertiary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(active ? tint : NookTheme.smoke))
            .contentShape(Circle())
        }
        .buttonStyle(.nookPlain)
        .composerTip(label)
        .accessibilityLabel(label)
    }
}

/// Watches for Cmd-V while a composer is on screen and lets it claim a paste that holds a picture.
final class PasteMonitor {
    private var monitor: Any?

    func start(handle: @escaping () -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v" else { return event }
            return handle() ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

/// A quiet choice inside or under the composer: an agent logo, a symbol or a colored dot, and a short text.
struct ComposerPill: View {
    var symbol: String? = nil
    var dot: Color? = nil
    /// Shows this agent's logo (with the account badge) in front of the text.
    var agent: String? = nil
    var account: AccountTag? = nil
    /// Shows this brand's mark in front of the text (a model's maker).
    var brand: BrandLogo? = nil
    let text: String
    /// A shorter text for a narrower composer (the model alone instead of agent, account and model).
    var short: String? = nil
    /// A word after the text in full white ("High", the model's effort), kept down to the narrow density.
    var detail: String? = nil
    /// A small state icon after the text (Main thread on), with what it means for its tooltip.
    var badge: (symbol: String, help: String)? = nil
    var tint: Color? = nil
    var showsChevron = true
    /// A toggle that is on: drawn filled in Nook's color, so its state reads at a glance and not only by its tint.
    var selected = false
    @Environment(\.composerDensity) private var density
    @State private var hovering = false

    private var hasMark: Bool { agent != nil || brand != nil }

    /// Only a pill with an icon ever drops its text; one without keeps its words. A logo already says who, so those go
    /// first; a symbol alone says too little, so those keep their words until nothing else fits.
    private var iconOnly: Bool {
        switch density {
        case .full, .short: return false
        case .marks: return hasMark
        case .icons: return hasMark || dot != nil || symbol != nil
        }
    }

    private var shown: String { density == .full ? text : short ?? text }

    var body: some View {
        HStack(spacing: 0) {
            content
            // A logo pill that gave up its words still shows them when the row has room left for them.
            if iconOnly && hasMark {
                RoomyText(text: shown)
            }
        }
        .font(NookTheme.TextStyle.control)
        .foregroundStyle(selected ? NookTheme.onIris : tint ?? (hovering ? NookTheme.paper : NookTheme.textSecondary))
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 28)
        .roundedBackground(selected ? (hovering ? NookTheme.primaryHover : NookTheme.iris)
                                    : hovering ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let agent {
                AgentMark(agent: agent, account: account, size: 15, ring: SessionComposer<EmptyView>.surface)
                    .padding(.trailing, account == nil ? 0 : 3)
            } else if let brand {
                BrandMark(logo: brand, size: 14)
            } else if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            } else if let symbol {
                Image(icon: symbol).font(NookTheme.font(13, .medium))
            }
            if !iconOnly {
                Text(shown).lineLimit(1)
                if let detail {
                    Text(detail).lineLimit(1).foregroundStyle(selected ? NookTheme.onIris : NookTheme.paper)
                }
            }
            if let badge, density != .icons {
                Image(icon: badge.symbol).font(NookTheme.font(12, .medium))
                    .padding(.leading, 2)
                    .help(badge.help)
                    .accessibilityLabel(badge.help)
            }
            if showsChevron && density == .full {
                Image(icon: "chevron.down").font(NookTheme.font(8, .bold)).opacity(0.6)
            }
        }
    }
}

/// How a model reads on the composer's model pill: its name without the maker the agent's logo beside it already shows
/// ("Sonnet 5.5" for "Claude Sonnet 5.5" under Claude Code's logo). A name whose rest would not start with a word
/// ("Gemini 3 Pro") keeps its maker.
enum ComposerModelLabel {
    static func compact(_ name: String, agent: String) -> String {
        guard let maker = agent.split(separator: " ").first, name.hasPrefix(maker + " ") else { return name }
        let rest = name.dropFirst(maker.count + 1)
        return rest.first?.isLetter == true ? String(rest) : name
    }
}

/// A text that asks for no width of its own: it shows whole when the room it is given holds it, and not at all
/// otherwise. The composer's row still picks its density as if the text were not there.
private struct RoomyText: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).lineLimit(1).padding(.leading, 6)
            Color.clear.frame(width: 0, height: 0)
        }
        .frame(minWidth: 0, idealWidth: 0, alignment: .leading)
    }
}

/// The composer's choices at the widest density that fits. The choices are built once and measured four times: building
/// them (menus and all) and the send button once per density cost four times that on every key.
private struct ComposerDensityFit<Content: View>: View {
    let content: Content
    /// The least room after the last choice (before send).
    let minGap: CGFloat

    var body: some View {
        // `ViewThatFits` builds every density it tries again each time it is measured, and the box is measured again on
        // every key as the text grows: in the new session's box that was several builds of every menu per key.
        MeasuredOnce { fits }
    }

    private var fits: some View {
        ViewThatFits(in: .horizontal) {
            row.environment(\.composerDensity, .full)
            row.environment(\.composerDensity, .short)
            row.environment(\.composerDensity, .marks)
            // The last step takes whatever width it is given: when even the icons do not fit (a very narrow chat beside
            // an open side panel), `ViewThatFits` would otherwise lay this row out at its full width and push the box,
            // and the tray on it, past the column's edge. The icons that do not fit are cut off at the end instead.
            row.environment(\.composerDensity, .icons)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }

    private var row: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            content
            Spacer(minLength: minGap)
        }
    }
}

/// Lays out its one view as is, but asks its size only once per proposal until the view changes: SwiftUI resets the
/// cache (`updateCache`) whenever something inside it needs a new layout, such as a menu showing another model.
private struct MeasuredOnce: Layout {
    struct Cache {
        var sizes: [ProposalKey: CGSize] = [:]
    }

    struct ProposalKey: Hashable {
        let width: CGFloat?
        let height: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let key = ProposalKey(width: proposal.width, height: proposal.height)
        if let size = cache.sizes[key] { return size }
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        cache.sizes[key] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// How much of each choice the composer's row has room for, from everything down to icons only.
enum ComposerDensity {
    /// Every word and the chevrons.
    case full
    /// Short texts (the model alone), no chevrons.
    case short
    /// Pills with a logo show only it; pills with a symbol keep their short text.
    case marks
    /// Only icons.
    case icons

    /// Logo pills dropped their words here, so they take what room the row has left to show them anyway.
    var logosTakeRoom: Bool { self == .marks || self == .icons }
}

private struct ComposerDensityKey: EnvironmentKey {
    static let defaultValue = ComposerDensity.full
}

extension EnvironmentValues {
    /// How much room the composer's row of choices has.
    var composerDensity: ComposerDensity {
        get { self[ComposerDensityKey.self] }
        set { self[ComposerDensityKey.self] = newValue }
    }
}

/// A choice in the composer that is only a symbol (the plus menu): the same size and hover as `ComposerPill`.
struct ComposerIcon: View {
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Image(icon: symbol)
            .font(NookTheme.font(12, .semibold))
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: 26)
            .roundedBackground(hovering ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The room between two groups of choices in the composer: a gap, not a line, so the row stays quiet.
struct ComposerDivider: View {
    var body: some View {
        Color.clear.frame(width: NookTheme.Spacing.xs, height: 16)
    }
}

extension View {
    /// A menu that looks like its label only: no button chrome, no arrow.
    func composerMenu() -> some View {
        self.menuStyle(.nookButton)
            .buttonStyle(.nookPlain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: Composer tips

/// What a control in the composer does, shown above it once the pointer rests on it a moment. Drawn by the composer
/// itself (`composerTips()`) instead of the system tooltip, which the composer's row (redrawn while the agent works,
/// measured at several widths and clipped when narrow) did not show reliably, and which took a second or more to come.
struct ComposerTip {
    let text: String
    let anchor: Anchor<CGRect>
}

struct ComposerTipKey: PreferenceKey {
    static var defaultValue: ComposerTip? { nil }
    static func reduce(value: inout ComposerTip?, nextValue: () -> ComposerTip?) {
        value = value ?? nextValue()
    }
}

private struct ComposerTipsHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a composer that draws its controls' tips (`composerTips()`); outside one `composerTip` is a tooltip.
    var composerTipsHosted: Bool {
        get { self[ComposerTipsHostedKey.self] }
        set { self[ComposerTipsHostedKey.self] = newValue }
    }
}

private struct ComposerTipModifier: ViewModifier {
    let text: String
    @Environment(\.composerTipsHosted) private var hosted
    @State private var shown = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        if hosted, !text.isEmpty {
            content
                .onHover { inside in
                    delay?.cancel()
                    guard inside else { shown = false; return }
                    delay = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if !Task.isCancelled { shown = true }
                    }
                }
                // A click opens the control's own panel or does what it says: the tip makes way.
                .simultaneousGesture(TapGesture().onEnded {
                    delay?.cancel()
                    shown = false
                })
                .onDisappear {
                    delay?.cancel()
                    shown = false
                }
                .anchorPreference(key: ComposerTipKey.self, value: .bounds) { shown ? ComposerTip(text: text, anchor: $0) : nil }
                .accessibilityHint(text)
        } else {
            content.help(text)
        }
    }
}

extension View {
    /// What this composer control does, shown above it on hover by the composer around it; a plain tooltip elsewhere.
    func composerTip(_ text: String) -> some View {
        modifier(ComposerTipModifier(text: text))
    }

    /// `composerTip` for a shared button that sits under a composer only sometimes; a plain tooltip otherwise.
    @ViewBuilder
    func composerTip(_ text: String, inComposer: Bool) -> some View {
        if inComposer { composerTip(text) } else { help(text) }
    }

    /// Draws the tips of the controls inside (`composerTip`) above the control the pointer rests on.
    func composerTips() -> some View {
        environment(\.composerTipsHosted, true)
            .overlayPreferenceValue(ComposerTipKey.self) { tip in
                if let tip {
                    GeometryReader { proxy in
                        ComposerTipPlacement(target: proxy[tip.anchor]) {
                            ComposerTipLabel(text: tip.text)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            // Drawn here, so a host around this one (the new session's box and its tray) does not draw it again.
            .transformPreference(ComposerTipKey.self) { $0 = nil }
    }
}

/// The tip itself: a small dark label, wrapped when long.
private struct ComposerTipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.paper)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .cardBackground(DropdownStyle.panel, stroke: NookTheme.line2, radius: NookTheme.Radius.control)
            .accessibilityHidden(true)
    }
}

/// Places the tip centered above `target`, kept inside the composer's width, at most `maxWidth` wide.
private struct ComposerTipPlacement: Layout {
    let target: CGRect
    var gap: CGFloat = NookTheme.Spacing.sm
    var maxWidth: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let width = min(maxWidth, bounds.width)
        let size = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let centered = bounds.minX + target.midX - size.width / 2
        let x = min(max(bounds.minX, centered), bounds.maxX - size.width)
        let y = bounds.minY + target.minY - gap - size.height
        label.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
