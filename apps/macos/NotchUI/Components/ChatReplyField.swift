import SwiftUI

/// The answer field under a chat, the same in the Chats tab and on a message card in the notch. What is typed goes to
/// the chat through `send`; "@" opens the menu with "@nook" and ready-made requests above the field, and "@nook …" lets
/// Nook write the message into this field first, through `draft`, for you to read before it goes anywhere. While Nook
/// writes, and once its message is in the field, a panel above the field shows it as Nook's draft: stop it, go back to
/// your request, or steer it (shorter, friendlier, more formal, other words, or a change you type) before you send it.
/// While a message is on its way, the same place shows it going out, and briefly that it arrived. With `extras` it takes
/// more than text, as a chat app's field does: files, a poll, a place, a voice message.
struct ChatReplyField: View {
    @Binding var text: String
    /// The status line above the field: Nook writing, the draft ready, or why something failed. The host may set it too
    /// (a file opening).
    @Binding var notice: String?
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    /// The button for what is typed: its symbol ("arrow.up", "doc.on.doc") and what it does ("Send", "Copy for Telegram").
    let sendSymbol: String
    let sendLabel: String
    /// What the status line says once Nook's message is in the field.
    let readyNotice: String
    /// The message the host is sending, or has just sent: a panel above the field shows it, and the field waits.
    var outgoing: ChatSending? = nil
    /// Who the message goes to, named in that panel ("Sending to Arjan…"); nil says "Sending…".
    var recipient: String? = nil
    /// The message what is typed answers, quoted above the field; nil for an ordinary message.
    var quote: BubbleQuote? = nil
    /// The cross on the quote, or Escape in the field: the message goes as an ordinary one.
    var cancelQuote: () -> Void = {}
    /// Escape in the field with no menu or quote to let go of: the host closes what the field is in (the open chat).
    var onEscape: (() -> Void)? = nil
    /// "@nook …": what was asked ("" for a fitting answer), returning the message Nook wrote and what it proposes to do.
    /// What Nook looks up on the way (a mail, another chat) is reported through the second argument. Throws with a
    /// sentence you can act on.
    let draft: Writer
    /// Return, Cmd+Return or the button with ordinary text: the host sends it (the text is still in `text`).
    let send: () -> Void

    @State private var drafting = false
    /// The writing in progress, so Stop can let it go.
    @State private var writing: Task<Void, Never>?
    /// The message Nook last put in the field; nil while the field holds no draft of Nook's.
    @State private var drafted: String?
    /// The "@nook …" the draft was written for, which "back to your request" puts back.
    @State private var request: String?
    /// What was in the field while Nook rewrote it, put back when the rewrite is stopped.
    @State private var beforeWriting: String?
    /// A change typed for Nook under its draft ("say I'll bring wine").
    @State private var steer = ""
    @FocusState private var steerFocused: Bool
    /// Every message Nook wrote for this request, oldest first (the first draft, then each rewrite), and the one in
    /// the field: you can go back to an earlier one when a rewrite came out worse.
    @State private var versions: [String] = []
    /// What Nook looked up for this draft (a mail, another chat), in order: shown in its panel as it happens.
    @State private var lookups: [ChatDraft.Lookup] = []
    /// What Nook proposes to do for this request (a reminder, an event), waiting for your click in its panel.
    @State private var proposed: [ChatDraftAction] = []
    @State private var actionRun = ChatDraftActionRun.waiting
    @State private var version = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The menu "@" opens above the field, as in Nook's own chat.
    @StateObject private var menu = ComposerModel()
    @State private var pasteMonitor = PasteMonitor()

    // What `extras` adds (see there).
    private var leadingAccessory: AnyView?
    private var aboveAccessory: AnyView?
    private var idleAccessory: AnyView?
    private var replacement: AnyView?
    private var trayContent: AnyView?
    private var hasExtra = false
    private var pasted: (() -> Bool)?
    private var editLast: (() -> Bool)?
    /// Left or right in an empty field: the host may take it to walk what waits to go.
    private var walk: ((Int) -> Bool)?
    private var tagPeople: () -> [ChatTagPerson] = { [] }
    /// Runs what Nook proposed, after your click; nil leaves "@nook …" to messages only.
    private var act: (([PlannedAction]) async -> (results: [String], failure: String?))?

    init(text: Binding<String>, notice: Binding<String?>, focus: FocusState<Bool>.Binding, placeholder: String,
         sendSymbol: String, sendLabel: String, readyNotice: String, outgoing: ChatSending? = nil, recipient: String? = nil,
         quote: BubbleQuote? = nil, cancelQuote: @escaping () -> Void = {}, onEscape: (() -> Void)? = nil,
         draft: @escaping Writer, send: @escaping () -> Void) {
        _text = text
        _notice = notice
        self.focus = focus
        self.placeholder = placeholder
        self.sendSymbol = sendSymbol
        self.sendLabel = sendLabel
        self.readyNotice = readyNotice
        self.outgoing = outgoing
        self.recipient = recipient
        self.quote = quote
        self.cancelQuote = cancelQuote
        self.onEscape = onEscape
        self.draft = draft
        self.send = send
    }

    /// The same field for a chat that takes more than text: buttons before the text (add a file, an emoji), what waits
    /// to go above the field (files, a poll's form), a button in place of send while nothing is typed (record a voice
    /// message), a bar that stands in for the whole field (while recording), and Cmd-V for a picture or a file, which
    /// `paste` claims by returning true. `pending`: something besides text waits to go, so send works without text.
    func extras<Leading: View, Above: View, Idle: View>(pending: Bool, replacing: AnyView? = nil, paste: (() -> Bool)? = nil,
                                                       @ViewBuilder leading: () -> Leading, @ViewBuilder above: () -> Above,
                                                       @ViewBuilder idle: () -> Idle) -> Self {
        var copy = self
        copy.hasExtra = pending
        copy.replacement = replacing
        copy.pasted = paste
        copy.leadingAccessory = AnyView(leading())
        copy.aboveAccessory = AnyView(above())
        copy.idleAccessory = AnyView(idle())
        return copy
    }

    /// A line in the tray tucked above the box, the same tray the agents show their queued messages in (see
    /// `ComposerTray`). Nil leaves the box without a tray.
    func tray<Content: View>(_ content: Content?) -> Self {
        var copy = self
        copy.trayContent = content.map { AnyView($0) }
        return copy
    }

    /// "@" also lists the chat's people, to tag one as its app does (`ChatTags`): choosing one writes "@Name", which the
    /// app's bridge turns into its own tag as the message goes. Asked only while a tag is being typed.
    func tags(_ people: @escaping () -> [ChatTagPerson]) -> Self {
        var copy = self
        copy.tagPeople = people
        return copy
    }

    /// What Nook proposes under "@nook …" (a reminder, an event) runs through `run` once you click Do it, as a plan in
    /// Nook Chat does.
    func runsActions(_ run: @escaping ([PlannedAction]) async -> (results: [String], failure: String?)) -> Self {
        var copy = self
        copy.act = run
        return copy
    }

    /// ↑ in the empty field changes your last message, as in Slack and Telegram: `edit` puts it in the field (false
    /// when there is none to change).
    func editsLastMessage(_ edit: (() -> Bool)?) -> Self {
        var copy = self
        copy.editLast = edit
        return copy
    }

    /// ← and → in the empty field walk what waits to go: `walk` gets the direction (false when it has nothing to walk).
    func walksFiles(_ walk: @escaping (Int) -> Bool) -> Self {
        var copy = self
        copy.walk = walk
        return copy
    }

    /// Writes the message for what was asked after "@nook", reporting each lookup on the way.
    typealias Writer = (_ instruction: String, _ onLookup: @escaping @MainActor (ChatDraft.Lookup) -> Void) async throws -> ChatDraftResult

    /// Nothing to send: no text, nothing else waiting, and no "@nook …".
    private var empty: Bool { !asksNook && !hasExtra && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "@nook …" at the start of the field: Nook writes the message instead of sending what is typed.
    private var asksNook: Bool { ChatDraft.instruction(in: text) != nil }

    /// "@nook …" typed over Nook's draft: Nook changes that draft as asked, instead of writing a new message.
    private var steering: Bool { asksNook && !versions.isEmpty }

    /// The draft "@nook …" changes: the version of Nook's that was last in the field.
    private var steered: String? { versions.indices.contains(version) ? versions[version] : nil }

    /// The panel above the field: Nook writing, or its draft in the field.
    private var showsDraft: Bool { drafting || drafted != nil || !proposed.isEmpty }

    /// A message is on its way: the field and its button wait until it is there or failed.
    private var busy: Bool { outgoing.map { !$0.sent } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if outgoing == nil, showsDraft {
                DraftPanel(writing: drafting, rewriting: drafting && beforeWriting != nil,
                           edited: !asksNook && (drafted.map { $0 != text } ?? false), readyNotice: readyNotice,
                           steering: steering && !drafting ? steered : nil,
                           request: request.flatMap { ChatDraft.instruction(in: $0) }, lookups: lookups,
                           version: version, versions: versions.count, showVersion: showVersion,
                           steer: $steer, steerFocused: $steerFocused,
                           hasDraft: drafted != nil,
                           actions: proposed, actionRun: actionRun, runActions: act == nil ? nil : runProposed,
                           dismissActions: dismissProposed,
                           undo: backToRequest, tweak: { rewrite($0.request) },
                           rewrite: { rewrite(steer) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Nook's own progress and a message on its way have their panel; any other notice (a failed rewrite or send)
            // stays a line above.
            if let notice, !drafting, outgoing == nil {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                    Image(icon: "info.circle")
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(notice)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                .transition(.opacity)
            }
            if menu.isOpen {
                ComposerSuggestionList(model: menu, tint: NookTheme.iris) { choose($0) }
            }
            if let quote {
                ReplyingBar(quote: quote, cancel: cancelQuote)
                    .transition(.opacity)
            }
            if let aboveAccessory { aboveAccessory }
            VStack(spacing: 0) {
                // A message on its way takes the tray, where an agent shows its queued messages; the host's line
                // comes back once it is there.
                if let outgoing {
                    ComposerTray(edge: .top) { SendingPanel(message: outgoing.text, sent: outgoing.sent, recipient: recipient) }
                        .transition(.opacity)
                } else if let trayContent {
                    ComposerTray(edge: .top) { trayContent }
                        .transition(.opacity)
                }
                if let replacement {
                    replacement
                        .padding(.horizontal, NookTheme.Spacing.xs)
                        .padding(.vertical, NookTheme.Spacing.xs)
                        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
                } else {
                    field
                }
            }
        }
        .animation(NookTheme.reveal, value: showsDraft)
        .animation(NookTheme.reveal, value: drafting)
        .animation(NookTheme.reveal, value: outgoing)
        // What each button under the field does, above it on hover (`composerTip`).
        .composerTips()
        .onAppear(perform: startPasteMonitor)
        .onDisappear { pasteMonitor.stop() }
    }

    /// Cmd-V in the field with a picture or a file on the pasteboard: the host takes it instead of the text.
    private func startPasteMonitor() {
        guard let pasted else { return }
        let focused = focus
        pasteMonitor.start { focused.wrappedValue && pasted() }
    }

    private var field: some View {
        // The buttons sit at the foot of the field, by the line you type on, as the field grows with a long message.
        HStack(alignment: .bottom, spacing: NookTheme.Spacing.sm) {
            if let leadingAccessory {
                HStack(spacing: NookTheme.Spacing.xxs) { leadingAccessory }
                    .frame(minHeight: Self.buttonSide)
            }
            // The placeholder is drawn on one line here, not as the field's prompt: a vertical field sizes itself to its
            // prompt too, and a long one ("Message to … (LinkedIn) · @nook writes along") wrapped it to two lines high
            // once the field was laid out again (marking the chat read), with the text up top and the buttons below.
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...6)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(placeholder)
                .focused(focus)
                // A restored draft is selected whole when the field gets the keyboard: put the caret at its end.
                .onChange(of: focus.wrappedValue) { _, now in if now { SessionComposer<EmptyView>.placeCaretAtEnd() } }
                // Return sends, as in every chat app; with the `@` menu open Return chooses a line there, and on
                // "@nook …" Return lets Nook write. ⌥Return adds a line; ⌘Return (send) and ⇧Return (a line) are
                // keybinding commands, run by the panel's key monitor while this field has the keyboard.
                .onKeyPress(.return, phases: .down) { (press: KeyPress) -> KeyPress.Result in returnKey(press) }
                .keyCommands(keyHandlers, context: ["composerFocus": true, "composerDraft": !empty], enabled: focus.wrappedValue)
                .onKeyPress(.upArrow) { () -> KeyPress.Result in
                    if !menu.isOpen, text.isEmpty, quote == nil, let editLast, editLast() { return .handled }
                    return moveInMenu(-1)
                }
                .onKeyPress(.downArrow) { () -> KeyPress.Result in moveInMenu(1) }
                .onKeyPress(.leftArrow) { () -> KeyPress.Result in walkFiles(-1) }
                .onKeyPress(.rightArrow) { () -> KeyPress.Result in walkFiles(1) }
                .onKeyPress(.tab) { () -> KeyPress.Result in
                    guard menu.isOpen else { return .ignored }
                    chooseSelected()
                    return .handled
                }
                .onKeyPress(.escape) { () -> KeyPress.Result in
                    if menu.isOpen {
                        menu.close()
                        return .handled
                    }
                    if quote != nil {
                        cancelQuote()
                        return .handled
                    }
                    guard let onEscape else { return .ignored }
                    onEscape()
                    return .handled
                }
                .onChange(of: text) { _, new in
                    updateMenu(new)
                    // Emptied (sent): the draft is gone. A new "@nook …" keeps it, as that steers the draft (see
                    // `steering`).
                    if !drafting, drafted != nil, new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        drafted = nil
                        versions = []
                        version = 0
                        lookups = []
                    }
                    NookPresence.shared.typed(count: new.count)
                }
                // In the non-activating notch panel the binding can lag behind the field until Return commits it,
                // which left the button looking disabled; take every keystroke straight from the field itself.
                .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                    guard focus.wrappedValue, let field = note.object as? NSTextField, field.window is NotchPanel,
                          field.stringValue != text else { return }
                    text = field.stringValue
                }
                .disabled(busy || drafting)
                .opacity(drafting || busy ? 0.55 : 1)
                .padding(.vertical, NookTheme.Spacing.sm)
                .frame(minHeight: Self.buttonSide, alignment: .center)
            if drafting {
                ChatSendButton(symbol: "stop.fill", label: tr("chats.draft.stop"), tint: NookTheme.iris, ready: true) { stopWriting() }
            } else if empty, !busy, let idleAccessory {
                idleAccessory
            } else {
                ChatSendButton(symbol: asksNook ? "sparkles" : sendSymbol, label: buttonLabel + " (↩)",
                               tint: NookTheme.primary, ready: !busy && !empty) { submit() }
            }
        }
        .padding(.leading, leadingAccessory == nil ? NookTheme.Spacing.lg : NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.sm)
        // A soft, round field that stands out a little from the panel, and a little more while you type in it; Nook's
        // draft gives it Nook's color, so it is clear whose words are about to go out.
        .roundedBackground(focus.wrappedValue ? NookTheme.composer : NookTheme.field, radius: NookTheme.Radius.composer)
        .roundedStrokeBorder(showsDraft && outgoing == nil ? NookTheme.iris.opacity(0.45) : (focus.wrappedValue ? NookTheme.separator : NookTheme.fieldStroke),
                             radius: NookTheme.Radius.composer)
        .animation(NookTheme.hover, value: focus.wrappedValue)
    }

    /// The side of the round buttons in and beside the field.
    static let buttonSide: CGFloat = 32

    private var buttonLabel: String {
        if steering { return tr("chats.draft.steer.button") }
        return asksNook ? tr("chats.draft.button") : sendLabel
    }

    /// The menu for what is typed: "@" offers "@nook" and the ready-made requests, in the user's language, and the
    /// chat's people whose name fits what follows the "@".
    private func updateMenu(_ text: String) {
        let presets = ChatDraft.presetKeys.map { tr($0) }
        // "@nook" leads with what it does; the ready-made requests under it read as plain lines ("Say yes"), without
        // repeating "@nook" and the same explanation on every row.
        let nook = ChatDraft.choices(for: text, presets: presets).map { choice in
            let title = choice.isNook ? choice.title : String(choice.insertion.dropFirst("@nook ".count))
            return ComposerSuggestion(id: "nook:" + choice.insertion, title: title,
                                      detail: choice.isNook ? tr("chats.nook.detail") : nil,
                                      symbol: choice.isNook ? "sparkles" : "text.bubble",
                                      payload: .command(ComposerCommand(name: choice.insertion, insertion: choice.insertion, action: .insert)))
        }
        var people: [ComposerSuggestion] = []
        if ChatDraft.instruction(in: text) == nil, let query = ChatTags.typing(in: text) {
            people = ChatTags.matches(query, in: tagPeople()).map { person in
                let insertion = ChatTags.inserting(person, in: text)
                return ComposerSuggestion(id: "tag:" + person.id, title: person.name, detail: tr("chats.tag.detail"),
                                          symbol: "person.crop.circle",
                                          payload: .command(ComposerCommand(name: "tag:" + person.id, insertion: insertion, action: .insert)))
            }
        }
        menu.show(nook + people)
    }

    /// A line of the menu fills the field; Return then lets Nook write.
    private func choose(_ row: ComposerSuggestion) {
        guard case .command(let command) = row.payload else { return }
        text = command.insertion
        menu.close()
        focus.wrappedValue = true
    }

    private func chooseSelected() {
        guard menu.suggestions.indices.contains(menu.selection) else { return }
        choose(menu.suggestions[menu.selection])
    }

    /// Return: takes the menu's line, lets Nook write for "@nook …", else sends what is typed, as a chat app does.
    /// With ⌥ or ⇧ it adds a line instead. SwiftUI handles key presses while it updates its views, and sending changes the
    /// chat, so the send itself runs right after.
    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
            newline()
        } else if menu.isOpen {
            chooseSelected()
        } else {
            DispatchQueue.main.async { submit() }
        }
        return .handled
    }

    private func newline() {
        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
    }

    /// ⌘Return sends (or takes the menu's line); ⇧Return always adds a line. No turn runs in a reply, so the alternate
    /// send never applies here.
    private var keyHandlers: [String: () -> Bool] {
        [
            "composer.send": {
                if menu.isOpen { chooseSelected() } else { submit() }
                return true
            },
            "composer.newline": {
                if menu.isOpen { chooseSelected() } else { newline() }
                return true
            },
        ]
    }

    /// With words in the field these keys move the caret.
    private func walkFiles(_ offset: Int) -> KeyPress.Result {
        guard text.isEmpty, walk?(offset) == true else { return .ignored }
        return .handled
    }

    private func moveInMenu(_ delta: Int) -> KeyPress.Result {
        guard menu.isOpen else { return .ignored }
        menu.move(delta)
        return .handled
    }

    /// Return or Cmd+Return on "@nook …", or the button: Nook writes; anything else (Cmd+Return or the button) goes to
    /// the host to send.
    private func submit() {
        guard !busy, !drafting else { return }
        if let instruction = ChatDraft.instruction(in: text) {
            if steering, let steered {
                steerDraft(steered, with: instruction)
            } else {
                write(instruction)
            }
        } else if !empty {
            notice = nil
            drafted = nil
            send()
        }
    }

    /// Nook writes the message from the chat and what you asked, and puts it in the field; sending stays your own click.
    private func write(_ instruction: String) {
        request = text
        beforeWriting = nil
        versions = []
        version = 0
        lookups = []
        proposed = []
        actionRun = .waiting
        run(instruction)
    }

    /// "@nook …" over Nook's draft: that draft is rewritten as asked and comes in as its next version; Stop puts the draft
    /// back, not your "@nook …".
    private func steerDraft(_ draft: String, with change: String) {
        beforeWriting = draft
        run(ChatDraft.refinement(of: draft, change: change))
    }

    /// Back or forward to another of Nook's versions of this message.
    private func showVersion(_ index: Int) {
        guard versions.indices.contains(index), !drafting else { return }
        version = index
        text = versions[index]
        drafted = versions[index]
        focus.wrappedValue = true
    }

    /// Nook's message comes into the field a few words at a time, as if written there, unless motion is reduced: what
    /// it wrote is easier to follow than a block of text that appears at once.
    private func reveal(_ message: String) async {
        let words = message.split(separator: " ", omittingEmptySubsequences: false)
        guard !reduceMotion, words.count > 3 else {
            text = message
            return
        }
        let step = max(1, words.count / 40)
        var shown = 0
        while shown < words.count {
            shown = min(words.count, shown + step)
            text = words.prefix(shown).joined(separator: " ")
            try? await Task.sleep(for: .milliseconds(18))
            if Task.isCancelled { return }
        }
        text = message
    }

    /// Steers the message in the field (Nook's draft, with your own changes): Nook rewrites it as asked.
    private func rewrite(_ change: String) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !drafting, !busy, !current.isEmpty else { return }
        beforeWriting = text
        run(ChatDraft.refinement(of: current, change: change))
    }

    private func run(_ instruction: String) {
        menu.close()
        drafting = true
        notice = tr(beforeWriting == nil ? "chats.draft.writing" : "chats.draft.rewriting")
        // A rewrite keeps the lookups of the draft before it; its own are numbered after them.
        let offset = lookups.map(\.id).max() ?? 0
        writing = Task { @MainActor in
            // A stopped run was already cleared by Stop, and a newer run may be under way.
            defer {
                if !Task.isCancelled {
                    drafting = false
                    writing = nil
                }
            }
            do {
                let result = try await draft(instruction) { found in
                    // A lookup of a run that was stopped or replaced is not this draft's.
                    guard !Task.isCancelled else { return }
                    var step = ChatDraft.Lookup(id: offset + found.id, source: found.source, query: found.query)
                    step.done = found.done
                    if let index = lookups.firstIndex(where: { $0.id == step.id }) {
                        lookups[index] = step
                    } else {
                        lookups.append(step)
                    }
                }
                guard !Task.isCancelled else { return }
                if !result.actions.isEmpty {
                    proposed = result.actions
                    actionRun = .waiting
                }
                guard let message = result.message else {
                    // Only something to do: the field gets back what it had (the draft a change was asked for), or is
                    // empty for your own words; the request stays quoted in the panel.
                    text = beforeWriting ?? ""
                    steer = ""
                    notice = nil
                    beforeWriting = nil
                    focus.wrappedValue = true
                    return
                }
                await reveal(message)
                guard !Task.isCancelled else { return }
                text = message
                drafted = message
                versions.append(message)
                version = versions.count - 1
                steer = ""
                notice = nil
                beforeWriting = nil
                focus.wrappedValue = true
            } catch {
                guard !Task.isCancelled else { return }
                notice = error.localizedDescription
                if let before = beforeWriting { text = before }
                beforeWriting = nil
                focus.wrappedValue = true
            }
        }
    }

    /// Stop while Nook writes: the field keeps what it had, and whatever Nook answers later is dropped.
    private func stopWriting() {
        writing?.cancel()
        writing = nil
        drafting = false
        if let before = beforeWriting {
            text = before
        } else if drafted == nil, let request {
            // Stopped while the first draft came in: your request is back, not half a message.
            text = request
        }
        beforeWriting = nil
        notice = nil
        focus.wrappedValue = true
    }

    /// The draft goes; your "@nook …" request is back in the field, to change it and let Nook write again.
    private func backToRequest() {
        stopWriting()
        text = request ?? ""
        drafted = nil
        versions = []
        version = 0
        lookups = []
        proposed = []
        actionRun = .waiting
        steer = ""
        request = nil
    }

    /// Do it: what Nook proposed runs, one step after another; the panel shows how it went.
    private func runProposed() {
        guard let act, !proposed.isEmpty, actionRun != .running else { return }
        if case .done = actionRun { return }
        actionRun = .running
        let actions = proposed.map(\.action)
        Task { @MainActor in
            let outcome = await act(actions)
            if let failure = outcome.failure {
                actionRun = .failed(failure)
            } else {
                actionRun = .done(outcome.results.count == 1 ? outcome.results[0] : tr("chat.plan.allDone", outcome.results.count))
            }
        }
    }

    /// The cross on the proposal: it goes without running, or is put away once done.
    private func dismissProposed() {
        guard actionRun != .running else { return }
        proposed = []
        actionRun = .waiting
        if drafted == nil, !drafting {
            request = nil
            lookups = []
        }
    }
}

/// Above the field while Nook writes or its message is in the field: Nook's own panel, in three calm parts. On top what
/// it is (Nook's draft, or what Nook is doing now) with the versions and the way back to your request; under it what you
/// asked, quoted, and the places Nook looked in for it (a mail, another chat), each a chip that turns from searching to
/// done; at the foot, once the draft is in the field, the ways to steer it: one click, or a change in your own words.
/// Sending stays the field's own button, so the panel never shows a second one.
private struct DraftPanel: View {
    let writing: Bool
    let rewriting: Bool
    /// You changed Nook's message in the field.
    let edited: Bool
    /// What sending the draft does ("Read it…; ↩ copies it and opens Telegram"): the panel's tooltip.
    let readyNotice: String
    /// "@nook …" typed over the draft: the draft it will change, shown here as it is no longer in the field.
    let steering: String?
    /// What you asked after "@nook" ("" for a fitting answer); nil when not known.
    let request: String?
    /// What Nook looked up for this draft, in order.
    let lookups: [ChatDraft.Lookup]
    /// Which of Nook's versions of this message is in the field, of how many.
    let version: Int
    let versions: Int
    let showVersion: (Int) -> Void
    @Binding var steer: String
    var steerFocused: FocusState<Bool>.Binding
    /// A message of Nook's is in the field (else Nook only proposes something to do): only a message can be steered.
    let hasDraft: Bool
    /// What Nook proposes to do, and how running it went.
    let actions: [ChatDraftAction]
    let actionRun: ChatDraftActionRun
    /// Do it; nil where this field cannot run actions.
    let runActions: (() -> Void)?
    let dismissActions: () -> Void
    let undo: () -> Void
    let tweak: (ChatDraft.Tweak) -> Void
    let rewrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                header
                if let request { requestLine(request) }
                if !lookups.isEmpty { lookedIn }
                if let steering { steeredDraft(steering) }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.top, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .padding(.bottom, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            if !writing, !actions.isEmpty {
                NookDivider(tint: NookTheme.iris.opacity(0.14))
                    .accessibilityHidden(true)
                DraftActions(actions: actions, run: actionRun, perform: runActions, dismiss: dismissActions)
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.vertical, NookTheme.Spacing.md)
                    .transition(.opacity)
            }
            if !writing, hasDraft {
                NookDivider(tint: NookTheme.iris.opacity(0.14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    tweaks
                    steerField
                }
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.md)
                .transition(.opacity)
            }
        }
        .cardBackground(NookTheme.iris.opacity(0.06), stroke: NookTheme.iris.opacity(0.2), radius: NookTheme.Radius.sheet)
        .help(writing ? "" : readyNotice)
        .animation(NookTheme.reveal, value: lookups)
        .animation(NookTheme.reveal, value: writing)
        .animation(NookTheme.reveal, value: steering)
        .animation(NookTheme.reveal, value: actions)
        .animation(NookTheme.reveal, value: actionRun)
        .accessibilityElement(children: .contain)
    }

    /// The lookup under way, if any: the header names it ("Nook is looking in Mail…").
    private var current: ChatDraft.Lookup? { writing ? lookups.last { !$0.done } : nil }

    private var status: String {
        if let current, !current.title.isEmpty { return tr("chats.draft.looking", current.title) }
        return tr(rewriting ? "chats.draft.rewriting" : "chats.draft.writing")
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            LayerSymbol(name: "sparkles", size: 11, weight: .semibold, color: NookTheme.iris, motion: .pulse, active: writing)
                .frame(width: 22, height: 22)
                .background(Circle().fill(NookTheme.iris.opacity(0.14)))
                .accessibilityHidden(true)
            if writing {
                ShimmerText(text: status)
                    .font(NookTheme.TextStyle.strong)
                    .lineLimit(1)
                    .id(status)
                    .transition(.opacity)
            } else {
                Text(tr(hasDraft ? "chats.draft.title" : "chats.draft.actionsTitle"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                if edited {
                    Text(tr("chats.draft.edited"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                        .padding(.vertical, NookTheme.Spacing.xxs)
                        .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.graphite))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if writing, lookups.isEmpty {
                WritingDots()
            }
            if versions > 1 { versionStepper }
            ToolbarIconButton("arrow.uturn.backward", tr("chats.draft.undo"), undo)
                .disabled(actionRun == .running)
        }
    }

    /// "‹ 2 of 3 ›": back to an earlier version of the message, or on to a later one.
    private var versionStepper: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ToolbarIconButton("chevron.left", tr("chats.draft.previous")) { showVersion(version - 1) }
                .disabled(version == 0 || writing)
            Text(tr("chats.draft.version", version + 1, versions))
                .font(NookTheme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize()
            ToolbarIconButton("chevron.right", tr("chats.draft.next")) { showVersion(version + 1) }
                .disabled(version >= versions - 1 || writing)
        }
    }

    /// What you asked Nook, quoted under the title, so the draft can be read against it.
    private func requestLine(_ request: String) -> some View {
        let shown = request.isEmpty ? tr("chats.draft.request.fitting") : request
        return HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            Capsule()
                .fill(NookTheme.iris.opacity(0.45))
                .frame(width: 2)
                .accessibilityHidden(true)
            Text(shown)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, NookTheme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("chats.draft.request") + ": " + shown)
    }

    /// The draft "@nook …" in the field will change, with what Return does, so it is clear Nook changes this message
    /// and does not write a new one.
    private func steeredDraft(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(draft)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Label(tr("chats.draft.steering"), systemImage: "return")
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.iris)
                .lineLimit(1)
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control)
        .transition(.opacity)
    }

    /// Where Nook looked for this draft: one chip per lookup, searching while it runs and checked once done.
    private var lookedIn: some View {
        ChipFlow(spacing: NookTheme.Spacing.xs) {
            ForEach(lookups) { DraftLookupChip(lookup: $0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("chats.draft.lookedIn") + ": " + lookups.map(\.title).joined(separator: ", "))
    }

    /// One click steers the draft; the ones that do not fit wrap to a second line.
    private var tweaks: some View {
        ChipFlow(spacing: NookTheme.Spacing.xs) {
            ForEach(ChatDraft.Tweak.allCases) { tweak in
                DraftChip(title: tr(tweak.titleKey), symbol: tweak.symbol) { self.tweak(tweak) }
            }
        }
    }

    /// Any other change, in your own words: Return lets Nook rewrite the draft with it.
    private var steerField: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: "wand.and.stars")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.iris)
                .accessibilityHidden(true)
            TextField("", text: $steer, prompt: Text(tr("chats.draft.steer.prompt")).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .focused(steerFocused)
                .onSubmit(submitSteer)
                // The notch panel can lag behind the field until Return commits it, as in the answer field.
                .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { note in
                    guard steerFocused.wrappedValue, let field = note.object as? NSTextField, field.window is NotchPanel,
                          field.stringValue != steer else { return }
                    steer = field.stringValue
                }
            if !steer.trimmingCharacters(in: .whitespaces).isEmpty {
                ToolbarIconButton("return", tr("chats.draft.steer.button"), submitSteer)
                    .transition(.opacity)
            }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xxs)
        .frame(minHeight: 30)
        .cardBackground(NookTheme.field, stroke: steerFocused.wrappedValue ? NookTheme.iris.opacity(0.4) : NookTheme.fieldStroke,
                        radius: NookTheme.Radius.control)
        .animation(NookTheme.hover, value: steer.isEmpty)
        .animation(NookTheme.hover, value: steerFocused.wrappedValue)
    }

    private func submitSteer() {
        guard !writing, !steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rewrite()
    }
}

/// What Nook proposes to do under "@nook …", as a short numbered list with one button: Do it runs the steps, then
/// each line says it is done, or the failure shows under them. The cross lets the proposal go.
private struct DraftActions: View {
    let actions: [ChatDraftAction]
    let run: ChatDraftActionRun
    let perform: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("chats.draft.actions"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer(minLength: NookTheme.Spacing.sm)
                if run != .running {
                    ToolbarIconButton("xmark", tr(isDone ? "button.close" : "chats.draft.actions.dismiss"), dismiss)
                }
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                ForEach(actions) { row($0) }
            }
            footer
        }
        .accessibilityElement(children: .contain)
    }

    private var isDone: Bool {
        if case .done = run { return true }
        return false
    }

    private func row(_ action: ChatDraftAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Group {
                if isDone {
                    Image(icon: "checkmark.circle.fill").foregroundStyle(NookTheme.mint)
                } else {
                    Image(icon: action.symbol).foregroundStyle(NookTheme.iris)
                }
            }
            .font(NookTheme.font(11, .semibold))
            .frame(width: 16)
            .accessibilityHidden(true)
            Text(action.step.text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !action.step.tag.isEmpty {
                Text(action.step.tag)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control)
    }

    @ViewBuilder private var footer: some View {
        switch run {
        case .waiting:
            if let perform {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(tr("chats.draft.actions.hint"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    NookPrimaryButton(title: tr("chats.draft.actions.run"), symbol: "checkmark", action: perform)
                        .fixedSize()
                }
            }
        case .running:
            HStack(spacing: NookTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                ShimmerText(text: tr("chat.plan.running"))
                    .font(NookTheme.TextStyle.label)
            }
        case .done(let summary):
            Label(summary, systemImage: "checkmark")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.mint)
                .lineLimit(2)
        case .failed(let failure):
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coral)
                    .lineLimit(3)
                Spacer(minLength: NookTheme.Spacing.sm)
            }
        }
    }
}

/// What "@nook …" in a chat came back with: the message for the field (nil when only something is to be done), and
/// what Nook proposes to do.
struct ChatDraftResult {
    var message: String?
    var actions: [ChatDraftAction]
}

/// One step Nook proposes under "@nook …": the action as the brain proposed it, and how it reads in a plan.
struct ChatDraftAction: Identifiable, Equatable {
    var id: UUID { action.id }
    let action: PlannedAction
    let step: PlanStep

    /// A symbol for the kind of step: a bell for a reminder, a calendar for an event, an envelope for a mail.
    var symbol: String {
        let tool = action.tool
        if tool.contains("reminder") { return "bell" }
        if tool.contains("event") { return "calendar.badge.plus" }
        if tool.contains("mail") { return "envelope" }
        if tool.contains("note") { return "note.text" }
        if tool.contains("send") || tool.contains("message") { return "paperplane" }
        return "sparkles"
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.step == rhs.step }
}

/// Where running Nook's proposal stands.
enum ChatDraftActionRun: Equatable {
    case waiting, running
    case done(String)
    case failed(String)
}

/// One place Nook looked in while it wrote: the source's symbol and name, what it looked for, and a small spinner that
/// becomes a check once it is read.
private struct DraftLookupChip: View {
    let lookup: ChatDraft.Lookup

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: lookup.symbol)
                .font(NookTheme.font(9.5, .semibold))
                .foregroundStyle(NookTheme.iris)
                .accessibilityHidden(true)
            Text(lookup.title.isEmpty ? tr("chats.draft.lookedIn") : lookup.title)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(1)
            if !lookup.query.isEmpty {
                Text(tr("chats.draft.lookupQuery", lookup.query))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Group {
                if lookup.done {
                    Image(icon: "checkmark")
                        .font(NookTheme.font(8.5, .bold))
                        .foregroundStyle(NookTheme.mint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .transition(.opacity)
                }
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(height: 22)
        .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.graphite))
        .overlay(NookTheme.shape(NookTheme.Radius.control).stroke(NookTheme.line2, lineWidth: 1))
        .animation(NookTheme.reveal, value: lookup.done)
    }
}

/// The round button at the end of the answer field: lit in its color once there is something to send (Nook's color
/// for "@nook …"), a quiet circle while there is not.
private struct ChatSendButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let ready: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(NookTheme.font(13, .bold))
                .foregroundStyle(ready ? NookTheme.onPrimary : NookTheme.textTertiary)
                .frame(width: ChatReplyField.buttonSide, height: ChatReplyField.buttonSide)
                .background(Circle().fill(ready ? tint : NookTheme.smoke))
                .hoverLift(hovering && ready, scale: 1.05)
                .contentShape(Circle())
        }
        .buttonStyle(.nookPlain)
        .disabled(!ready)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: ready)
        .composerTip(label)
        .accessibilityLabel(label)
    }
}

/// A one-click change under Nook's draft: a small capsule with a symbol, lit under the pointer.
private struct DraftChip: View {
    let title: String
    let symbol: String?
    /// Nook's own color for the chip that asks Nook something open; nil for the plain ones.
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if let symbol {
                    Image(icon: symbol)
                        .font(NookTheme.font(9.5, .semibold))
                        .foregroundStyle(tint ?? (hovering ? NookTheme.paper : NookTheme.textStrong))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(NookTheme.TextStyle.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 24)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(tint.map { $0.opacity(hovering ? 0.2 : 0.12) } ?? (hovering ? NookTheme.smoke : NookTheme.graphite)))
            .overlay(NookTheme.shape(NookTheme.Radius.control).stroke(tint.map { $0.opacity(0.3) } ?? NookTheme.line2, lineWidth: 1))
            .hoverLift(hovering, scale: 1.02)
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(title)
    }
}

/// A message on its way to the chat, and briefly once it is there.
struct ChatSending: Equatable {
    let text: String
    /// The chat has it: the panel says so for a moment before the host lets it go.
    var sent = false
}

/// In the tray above the field while a message is sent: a paper plane that glides, who it goes to, and the message itself; once
/// it is there, a check in its place.
private struct SendingPanel: View {
    let message: String
    let sent: Bool
    let recipient: String?

    private var title: String {
        if let recipient, !recipient.isEmpty { return tr(sent ? "whatsapp.sent" : "chats.sending.to", recipient) }
        return tr(sent ? "chats.sent" : "whatsapp.card.sending")
    }

    var body: some View {
        // The same row as the queued messages' header in an agent's tray (see `QueuedMessagesStrip`).
        HStack(spacing: NookTheme.Spacing.sm) {
            Group {
                if sent {
                    Image(icon: "checkmark.circle.fill")
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.mint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    GlidingPlane()
                        .transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Group {
                if sent {
                    Text(title).foregroundStyle(NookTheme.textSecondary)
                } else {
                    ShimmerText(text: title)
                }
            }
            .font(NookTheme.TextStyle.label)
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(message)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            if !sent { SendingSweep().padding(.horizontal, NookTheme.Spacing.md) }
        }
        .animation(NookTheme.reveal, value: sent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ": " + message)
    }
}

/// A paper plane that lifts off, flies out and comes back in, over and over while a message is sent; still with
/// Reduce Motion.
private struct GlidingPlane: View {
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rate = energy.plan.progressFrameRate(attended: attended)
        // perf: flies only for the second or two a message takes to send.
        TimelineView(.nookFrames(fps: rate, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            // Out to the top right while it fades, then in again from the bottom left.
            let travel = (phase - 0.35) * 14
            let fade = 1 - pow(abs(phase - 0.35) / 0.65, 2)
            Image(icon: "paperplane.fill")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.mint)
                .offset(x: travel, y: -travel * 0.6)
                .opacity(max(0, fade))
        }
        .clipped()
    }
}

/// A short light that runs along the bottom of the sending panel, so it reads as under way even for a slow send.
private struct SendingSweep: View {
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rate = energy.plan.progressFrameRate(attended: attended)
        GeometryReader { proxy in
            // perf: runs only for the second or two a message takes to send.
            TimelineView(.nookFrames(fps: rate, paused: reduceMotion)) { context in
                let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let width = proxy.size.width * 0.3
                Capsule()
                    .fill(LinearGradient(colors: [NookTheme.mint.opacity(0), NookTheme.mint.opacity(0.7), NookTheme.mint.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 2)
                    .offset(x: (proxy.size.width + width) * phase - width)
            }
        }
        .frame(height: 2)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Three dots that rise in turn while Nook writes; still with Reduce Motion.
private struct WritingDots: View {
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Run by Core Animation (`LayerLoop`): the main thread draws nothing per frame for as long as Nook writes.
        // A wave that rises every 2π/5 s, each dot 0.14 s after the one before it.
        LayerLoop(shape: .wave(count: 3, diameter: 6, spacing: NookTheme.Spacing.xs, rise: 2.5, low: 0.35, high: 0.9,
                               period: 2 * Double.pi / 5, lag: 0.14),
                  color: NookTheme.iris, fps: reduceMotion ? 0 : energy.plan.progressFrameRate(attended: attended))
        .frame(width: 3 * 6 + 2 * NookTheme.Spacing.xs, height: 10)
        .accessibilityHidden(true)
    }
}

/// Above the field while it answers one message: who wrote that message and its start, with a cross to let it go.
private struct ReplyingBar: View {
    let quote: BubbleQuote
    let cancel: () -> Void

    private var tint: Color { quote.mine ? NookTheme.mint : NookTheme.blue }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "arrowshape.turn.up.left.fill")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.sender.isEmpty ? tr("chat.reply") : tr("chat.replyingTo", quote.sender))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(quote.text)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            ToolbarIconButton("xmark", tr("chat.reply.cancel"), cancel)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.sm)
        .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.card)
        .accessibilityElement(children: .contain)
    }
}
