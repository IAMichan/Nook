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
    /// The composer's own color: the send button, the focus ring and a trace in the surface.
    private var tint: Color = NookTheme.iris

    /// Pictures added by dragging or pasting. Optional: a composer without it does not take pictures.
    private var imagesBinding: Binding<[ImageAttachment]>?
    /// Agents read pictures from disk: on send their paths go below the text. Without it the caller sends the pictures itself.
    private var imagesAsPaths = true
    /// What happens to another file that is dropped (default: its path goes into the text, which agents read).
    private var fileDropped: ((URL) -> Void)?

    @FocusState private var ownFocus: Bool
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

    static var surface: Color { NookTheme.surface }

    private var hasImages: Bool { !(imagesBinding?.wrappedValue.isEmpty ?? true) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasImages }
    private var enabled: Bool { canSend && !sending && !isEmpty && encodingPictures == 0 }

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

    private var bodyBinding: Binding<String> {
        Binding(get: { ComposerAttachments.split(text).body },
                set: { text = ComposerAttachments.replacingBody(of: text, with: $0) })
    }

    private func choose(_ suggestion: ComposerSuggestion) {
        guard let extras else { return }
        let value = extras.model.accept(suggestion, in: typedText, extras.config)
        assign(ComposerAttachments.replacingBody(of: text, with: value))
        // A line that fills the box can lead to a list of its own ("@chat " lists the chats): show it straight away.
        if case .command(let command) = suggestion.payload, command.action == .insert {
            extras.model.update(for: value, extras.config)
        }
        (focus ?? $ownFocus).wrappedValue = true
    }

    private func textChanged(_ oldText: String, _ newText: String) {
        NookPresence.shared.typed(count: newText.count)
        guard let extras else { return }
        // The list, list items and big pastes look at the words in the box, not at the files attached after them.
        let old = ComposerAttachments.split(oldText).body, new = ComposerAttachments.split(newText).body
        if extras.model.applying {
            extras.model.applying = false
            return
        }
        extras.model.history.stopWalking()
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
            extras.model.update(for: new, extras.config)
            return
        }
        if extras.config.keepsBigPastes, let kept = extras.model.keepPaste(old: old, new: new) {
            assign(ComposerAttachments.replacingBody(of: newText, with: kept))
            extras.model.close()
            return
        }
        extras.model.update(for: new, extras.config)
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
        ]
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
            if busy, !isEmpty, encodingPictures == 0, let flipAction { fire(flipAction) }
        } else if !busy, let sendNowAction, !isEmpty, encodingPictures == 0 {
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

    private func tabKey() -> KeyPress.Result {
        guard let extras, extras.model.isOpen, extras.model.suggestions.indices.contains(extras.model.selection) else { return .ignored }
        choose(extras.model.suggestions[extras.model.selection])
        return .handled
    }

    private func escapeKey() -> KeyPress.Result {
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
                if typedText.isEmpty {
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
            .focused(focused)
            .onChange(of: focused.wrappedValue) { _, now in if now { Self.placeCaretAtEnd() } }
            .onSubmit(submit)
            .onChange(of: text) { old, new in textChanged(old, new) }
            // In the non-activating notch and ask panels the binding can lag behind the field until Return commits it,
            // which left the send arrow looking disabled; take every keystroke straight from the field itself, through
            // `bodyBinding` so files attached to the draft stay.
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                guard focused.wrappedValue, let field = note.object as? NSTextField,
                      field.window is NotchPanel || field.window is SelectionAskPanel,
                      field.stringValue != typedText else { return }
                bodyBinding.wrappedValue = field.stringValue
            }
    }

    // The keys that belong to the text field itself (moving in the list, taking a line); ⌘Return, ⌘S, ⇧Return and the
    // history keys are keybinding commands, offered to the panel's key monitor while the box has the keyboard.
    private func withKeys(_ view: some View, focused: Bool) -> some View {
        view
            .onKeyPress(.upArrow) { () -> KeyPress.Result in arrow(-1) }
            .onKeyPress(.downArrow) { () -> KeyPress.Result in arrow(1) }
            .onKeyPress(.tab) { () -> KeyPress.Result in tabKey() }
            .onKeyPress(.escape) { () -> KeyPress.Result in escapeKey() }
            .onKeyPress(.return, phases: .down) { (press: KeyPress) -> KeyPress.Result in returnKey(press) }
            .keyCommands(keyHandlers, context: keyContext, enabled: focused)
    }

    private func submit() {
        if busy, let queueAction, !isEmpty, encodingPictures == 0 {
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
        .composerDrop(of: imagesBinding == nil ? [] : [UTType.fileURL, UTType.image], $drop) { providers in
            guard let imagesBinding else { return false }
            return ImageAttachment.receive(providers, images: { imagesBinding.wrappedValue += $0 }, file: { url in
                dropFile(url)
            })
        }
        .onAppear {
            startPasteMonitor(focused: focused)
            extras?.model.connectStash()
        }
        .onDisappear { pasteMonitor.stop() }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NookTheme.Radius.composer, style: .continuous)
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
            if busy, let onStop {
                if let queueAction, !isEmpty {
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
    private func fire(_ action: () -> Void) {
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
    static func placeCaretAtEnd() {
        DispatchQueue.main.async {
            guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView else { return }
            let length = (editor.string as NSString).length
            let selected = editor.selectedRange()
            guard length > 0, selected.location == 0, selected.length == length else { return }
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
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
                    Image(systemName: symbol).font(NookTheme.font(12, .bold))
                }
            }
            .foregroundStyle(active ? NookTheme.onIris : NookTheme.textTertiary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(active ? tint : NookTheme.smoke))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
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
    var tint: Color? = nil
    var showsChevron = true
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
        .foregroundStyle(tint ?? (hovering ? NookTheme.paper : NookTheme.textSecondary))
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering ? NookTheme.smoke : Color.clear))
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
                Image(systemName: symbol).font(NookTheme.font(13, .medium))
            }
            if !iconOnly {
                Text(shown).lineLimit(1)
            }
            if showsChevron && density == .full {
                Image(systemName: "chevron.down").font(NookTheme.font(8, .bold)).opacity(0.6)
            }
        }
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
        Image(systemName: symbol)
            .font(NookTheme.font(12, .semibold))
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(hovering ? NookTheme.smoke : Color.clear))
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
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
