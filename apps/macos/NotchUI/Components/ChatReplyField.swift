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
    /// "@nook …": what was asked ("" for a fitting answer), returning the message Nook wrote. Throws with a sentence
    /// you can act on.
    let draft: (String) async throws -> String
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
    private var offersReplies = false
    private var editLast: (() -> Bool)?

    init(text: Binding<String>, notice: Binding<String?>, focus: FocusState<Bool>.Binding, placeholder: String,
         sendSymbol: String, sendLabel: String, readyNotice: String, outgoing: ChatSending? = nil, recipient: String? = nil,
         quote: BubbleQuote? = nil, cancelQuote: @escaping () -> Void = {}, onEscape: (() -> Void)? = nil,
         draft: @escaping (String) async throws -> String, send: @escaping () -> Void) {
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

    /// One click lets Nook write an answer while the field is empty: "Let Nook answer" and a few ready-made requests sit
    /// above it. For the Chats tab, where there is room; a card in the notch keeps to the field.
    func offersNookReplies(_ on: Bool = true) -> Self {
        var copy = self
        copy.offersReplies = on
        return copy
    }

    /// ↑ in the empty field changes your last message, as in Slack and Telegram: `edit` puts it in the field (false
    /// when there is none to change).
    func editsLastMessage(_ edit: (() -> Bool)?) -> Self {
        var copy = self
        copy.editLast = edit
        return copy
    }

    /// Nothing to send: no text, nothing else waiting, and no "@nook …".
    private var empty: Bool { !asksNook && !hasExtra && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "@nook …" at the start of the field: Nook writes the message instead of sending what is typed.
    private var asksNook: Bool { ChatDraft.instruction(in: text) != nil }

    /// The panel above the field: Nook writing, or its draft in the field.
    private var showsDraft: Bool { drafting || drafted != nil }

    /// A message is on its way: the field and its button wait until it is there or failed.
    private var busy: Bool { outgoing.map { !$0.sent } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if outgoing == nil, showsDraft {
                DraftPanel(writing: drafting, rewriting: drafting && beforeWriting != nil,
                           edited: drafted.map { $0 != text } ?? false, readyNotice: readyNotice,
                           request: request.flatMap { ChatDraft.instruction(in: $0) },
                           version: version, versions: versions.count, showVersion: showVersion,
                           sendSymbol: sendSymbol, sendLabel: sendLabel, canSend: !empty && !busy, send: submit,
                           steer: $steer, steerFocused: $steerFocused,
                           undo: backToRequest, tweak: { rewrite($0.request) },
                           rewrite: { rewrite(steer) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Nook's own progress and a message on its way have their panel; any other notice (a failed rewrite or send)
            // stays a line above.
            if let notice, !drafting, outgoing == nil {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "info.circle")
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
            if offersReplies, text.isEmpty, !showsDraft, outgoing == nil, quote == nil, !menu.isOpen, !hasExtra {
                NookReplyChips(write: letNookWrite)
                    .transition(.opacity)
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
        .animation(NookTheme.reveal, value: text.isEmpty)
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
        HStack(spacing: NookTheme.Spacing.sm) {
            if let leadingAccessory { leadingAccessory }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...6)
                .focused(focus)
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
                    // Emptied (sent) or a new "@nook …": the draft is gone.
                    if !drafting, drafted != nil,
                       new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ChatDraft.instruction(in: new) != nil {
                        drafted = nil
                        versions = []
                        version = 0
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
            if drafting {
                NookIconButton(systemName: "stop.fill", label: tr("chats.draft.stop"), filled: true, size: 28) { stopWriting() }
            } else if empty, !busy, let idleAccessory {
                idleAccessory
            } else {
                NookIconButton(systemName: asksNook ? "sparkles" : sendSymbol, label: buttonLabel, filled: true, size: 28) { submit() }
                    .disabled(busy || empty)
                    .help(buttonLabel + " (↩)")
            }
        }
        .padding(.leading, leadingAccessory == nil ? NookTheme.Spacing.md : NookTheme.Spacing.xs)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        // Nook's draft in the field: the field takes Nook's color, so it is clear whose words are about to go out.
        // The field you type in stands out a little from the rest of the panel.
        .cardBackground(NookTheme.field, stroke: showsDraft && outgoing == nil ? NookTheme.iris.opacity(0.45)
                            : (focus.wrappedValue ? NookTheme.separator : NookTheme.fieldStroke),
                        radius: NookTheme.Radius.sheet)
        .animation(NookTheme.hover, value: focus.wrappedValue)
    }

    private var buttonLabel: String { asksNook ? tr("chats.draft.button") : sendLabel }

    /// The menu for what is typed: "@" offers "@nook" and the ready-made requests, in the user's language.
    private func updateMenu(_ text: String) {
        let presets = ChatDraft.presetKeys.map { tr($0) }
        menu.show(ChatDraft.choices(for: text, presets: presets).map { choice in
            ComposerSuggestion(id: "nook:" + choice.insertion, title: choice.title,
                               detail: tr(choice.isNook ? "chats.nook.detail" : "chats.nook.presetDetail"), symbol: "sparkles",
                               payload: .command(ComposerCommand(name: choice.insertion, insertion: choice.insertion, action: .insert)))
        })
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
    /// With ⌥ or ⇧ it adds a line instead.
    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
            newline()
        } else if menu.isOpen {
            chooseSelected()
        } else {
            submit()
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
            write(instruction)
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
        run(instruction)
    }

    /// One of the ready-made answers above an empty field: the request goes in the field and Nook writes at once.
    private func letNookWrite(_ request: String) {
        guard !busy, !drafting else { return }
        text = request.isEmpty ? "@nook" : "@nook " + request
        submit()
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
        writing = Task { @MainActor in
            // A stopped run was already cleared by Stop, and a newer run may be under way.
            defer {
                if !Task.isCancelled {
                    drafting = false
                    writing = nil
                }
            }
            do {
                let message = try await draft(instruction)
                guard !Task.isCancelled else { return }
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
        steer = ""
        request = nil
    }
}

/// Above the field while Nook writes or its message is in the field: Nook's own panel. It says what you asked, what Nook
/// is doing, lets you go back and forth between its versions, steer the draft (one click, or in your own words), and
/// send it with one click once it reads right.
private struct DraftPanel: View {
    let writing: Bool
    let rewriting: Bool
    /// You changed Nook's message in the field.
    let edited: Bool
    let readyNotice: String
    /// What you asked after "@nook" ("" for a fitting answer); nil when not known.
    let request: String?
    /// Which of Nook's versions of this message is in the field, of how many.
    let version: Int
    let versions: Int
    let showVersion: (Int) -> Void
    let sendSymbol: String
    let sendLabel: String
    let canSend: Bool
    let send: () -> Void
    @Binding var steer: String
    var steerFocused: FocusState<Bool>.Binding
    let undo: () -> Void
    let tweak: (ChatDraft.Tweak) -> Void
    let rewrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            header
            if let request {
                requestLine(request)
            }
            if writing {
                WritingDots()
                    .padding(.vertical, NookTheme.Spacing.xxs)
            } else {
                Text(readyNotice)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tweaks
            HStack(spacing: NookTheme.Spacing.sm) {
                steerField
                sendButton
            }
        }
        .padding(NookTheme.Spacing.lg)
        .cardBackground(NookTheme.iris.opacity(0.07), stroke: NookTheme.iris.opacity(0.22), radius: NookTheme.Radius.panel,
                        style: .continuous)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.iris)
                .symbolEffect(.pulse, options: .repeating, isActive: writing)
                .accessibilityHidden(true)
            if writing {
                ShimmerText(text: tr(rewriting ? "chats.draft.rewriting" : "chats.draft.writing"))
                    .font(NookTheme.TextStyle.label)
                    .lineLimit(1)
            } else {
                Text(tr("chats.draft.title"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                if edited {
                    Text("· " + tr("chats.draft.edited"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if versions > 1 { versionStepper }
            ToolbarIconButton("arrow.uturn.backward", tr("chats.draft.undo"), undo)
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

    /// What you asked Nook, quoted, so the draft can be read against it.
    private func requestLine(_ request: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Capsule()
                .fill(NookTheme.iris.opacity(0.5))
                .frame(width: 3, height: 14)
                .accessibilityHidden(true)
            Text(request.isEmpty ? tr("chats.draft.request.fitting") : request)
                .font(NookTheme.TextStyle.detail)
                .italic(!request.isEmpty)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(2)
        }
        .accessibilityLabel(tr("chats.draft.request") + ": " + (request.isEmpty ? tr("chats.draft.request.fitting") : request))
    }

    /// One click steers the draft; the ones that do not fit wrap to a second line.
    private var tweaks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.xs) { chips }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.xs) { ForEach(ChatDraft.Tweak.allCases.prefix(2)) { chip($0) } }
                HStack(spacing: NookTheme.Spacing.xs) { ForEach(ChatDraft.Tweak.allCases.dropFirst(2)) { chip($0) } }
            }
        }
        .disabled(writing)
    }

    @ViewBuilder private var chips: some View {
        ForEach(ChatDraft.Tweak.allCases) { chip($0) }
    }

    private func chip(_ tweak: ChatDraft.Tweak) -> some View {
        DraftChip(title: tr(tweak.titleKey), symbol: tweak.symbol) { self.tweak(tweak) }
    }

    /// The draft goes as it is in the field, as Return does: one click once it reads right.
    private var sendButton: some View {
        NookPrimaryButton(title: sendLabel, symbol: sendSymbol, action: send)
            .disabled(writing || !canSend)
            .fixedSize()
            .help(sendLabel + " (↩)")
    }

    /// Any other change, in your own words: Return lets Nook rewrite the draft with it.
    private var steerField: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(systemName: "wand.and.stars")
                .font(NookTheme.font(10.5, .medium))
                .foregroundStyle(NookTheme.textTertiary)
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
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.xxs)
        .frame(minHeight: 28)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control, style: .continuous)
        .disabled(writing)
        .animation(NookTheme.hover, value: steer.isEmpty)
    }

    private func submitSteer() {
        guard !writing, !steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rewrite()
    }
}

/// Above an empty answer field: one click lets Nook write the answer ("Let Nook answer"), or a ready-made one (say yes,
/// say no kindly, another moment). Nook writes it into the field, where you read it before it goes.
private struct NookReplyChips: View {
    let write: (String) -> Void

    private static let presets = ["chats.nook.preset.yes", "chats.nook.preset.no", "chats.nook.preset.later",
                                  "chats.nook.preset.thanks"]

    var body: some View {
        // As many as fit on one line, in this order: the open request first.
        ViewThatFits(in: .horizontal) {
            row(Self.presets.count)
            row(3)
            row(2)
            row(0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("chats.draft.suggest"))
    }

    private func row(_ presets: Int) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            DraftChip(title: tr("chats.draft.suggest"), symbol: "sparkles", tint: NookTheme.iris) { write("") }
            ForEach(Self.presets.prefix(presets), id: \.self) { key in
                DraftChip(title: tr(key), symbol: nil) { write(tr(key)) }
            }
        }
        .fixedSize()
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
                    Image(systemName: symbol)
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
            .background(Capsule().fill(tint.map { $0.opacity(hovering ? 0.2 : 0.12) } ?? (hovering ? NookTheme.smoke : NookTheme.graphite)))
            .overlay(Capsule().stroke(tint.map { $0.opacity(0.3) } ?? NookTheme.line2, lineWidth: 1))
            .hoverLift(hovering, scale: 1.02)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                    Image(systemName: "checkmark.circle.fill")
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
        let rate = energy.plan.frameRate(energy.plan.ambientFrameRate, attended: attended)
        // perf: flies only for the second or two a message takes to send.
        TimelineView(.nookFrames(fps: rate, paused: reduceMotion || energy.plan.pace == .paused)) { context in
            let phase = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            // Out to the top right while it fades, then in again from the bottom left.
            let travel = (phase - 0.35) * 14
            let fade = 1 - pow(abs(phase - 0.35) / 0.65, 2)
            Image(systemName: "paperplane.fill")
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
        let rate = energy.plan.frameRate(energy.plan.ambientFrameRate, attended: attended)
        GeometryReader { proxy in
            // perf: runs only for the second or two a message takes to send.
            TimelineView(.nookFrames(fps: rate, paused: reduceMotion || energy.plan.pace == .paused)) { context in
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
        let rate = energy.plan.frameRate(energy.plan.ambientFrameRate, attended: attended)
        // In a graph of its own (`SeparateGraph`), so its frames do not update the conversation around it for as long as
        // Nook writes.
        SeparateGraph {
            TimelineView(.nookFrames(fps: rate, paused: reduceMotion || energy.plan.pace == .paused)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: NookTheme.Spacing.xs) {
                    ForEach(0..<3) { index in
                        let wave = reduceMotion ? 0 : (sin(t * 5 - Double(index) * 0.7) + 1) / 2
                        Circle()
                            .fill(NookTheme.iris.opacity(0.35 + 0.55 * wave))
                            .frame(width: 6, height: 6)
                            .offset(y: -2.5 * wave)
                    }
                }
            }
        }
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
            Image(systemName: "arrowshape.turn.up.left.fill")
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.smoke))
        .accessibilityElement(children: .contain)
    }
}
