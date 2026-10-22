import SwiftUI

/// The answer field under a chat, the same in the Chats tab and on a message card in the notch. What is typed goes to
/// the chat through `send`; "@" opens the menu with "@nook" and ready-made requests above the field, and "@nook …" lets
/// Nook write the message into this field first, through `draft`, for you to read before it goes anywhere. While Nook
/// writes, and once its message is in the field, a panel above the field shows it as Nook's draft: stop it, go back to
/// your request, or steer it (shorter, friendlier, more formal, other words, or a change you type) before you send it.
struct ChatReplyField: View {
    @Binding var text: String
    /// The status line above the field: Nook writing, the draft ready, or why something failed. The host may set it too
    /// (sending, a file opening).
    @Binding var notice: String?
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    /// The button for what is typed: its symbol ("arrow.up", "doc.on.doc") and what it does ("Send", "Copy for Telegram").
    let sendSymbol: String
    let sendLabel: String
    /// What the status line says once Nook's message is in the field.
    let readyNotice: String
    /// The host is busy with the text (sending it): the field and its button wait.
    var busy = false
    /// The message what is typed answers, quoted above the field; nil for an ordinary message.
    var quote: BubbleQuote? = nil
    /// The cross on the quote, or Escape in the field: the message goes as an ordinary one.
    var cancelQuote: () -> Void = {}
    /// "@nook …": what was asked ("" for a fitting answer), returning the message Nook wrote. Throws with a sentence
    /// you can act on.
    let draft: (String) async throws -> String
    /// Return or the button with ordinary text: the host sends it (the text is still in `text`).
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
    /// The menu "@" opens above the field, as in Nook's own chat.
    @StateObject private var menu = ComposerModel()

    /// "@nook …" at the start of the field: Nook writes the message instead of sending what is typed.
    private var asksNook: Bool { ChatDraft.instruction(in: text) != nil }

    /// The panel above the field: Nook writing, or its draft in the field.
    private var showsDraft: Bool { drafting || drafted != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if showsDraft {
                DraftPanel(writing: drafting, rewriting: drafting && beforeWriting != nil,
                           edited: drafted.map { $0 != text } ?? false, readyNotice: readyNotice,
                           steer: $steer, steerFocused: $steerFocused,
                           undo: backToRequest, tweak: { rewrite($0.request) },
                           rewrite: { rewrite(steer) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Nook's own progress is in its panel; any other notice (a failed rewrite, sending) stays a line above.
            if let notice, !drafting {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "info.circle")
                            .font(NookTheme.font(10.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
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
            field
        }
        .animation(NookTheme.reveal, value: showsDraft)
        .animation(NookTheme.reveal, value: drafting)
    }

    private var field: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...6)
                .focused(focus)
                .onSubmit { menu.isOpen ? chooseSelected() : submit() }
                .onKeyPress(.upArrow) { () -> KeyPress.Result in moveInMenu(-1) }
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
                    guard quote != nil else { return .ignored }
                    cancelQuote()
                    return .handled
                }
                .onChange(of: text) { _, new in
                    updateMenu(new)
                    // Emptied (sent) or a new "@nook …": the draft is gone.
                    if !drafting, drafted != nil,
                       new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ChatDraft.instruction(in: new) != nil {
                        drafted = nil
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
                .opacity(drafting ? 0.55 : 1)
            if drafting {
                NookIconButton(systemName: "stop.fill", label: tr("chats.draft.stop"), filled: true, size: 28) { stopWriting() }
            } else {
                NookIconButton(systemName: asksNook ? "sparkles" : sendSymbol, label: buttonLabel, filled: true, size: 28) { submit() }
                    .disabled(busy || (!asksNook && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        // Nook's draft in the field: the field takes Nook's color, so it is clear whose words are about to go out.
        .cardBackground(NookTheme.field, stroke: showsDraft ? NookTheme.iris.opacity(0.45) : NookTheme.fieldStroke,
                        radius: NookTheme.Radius.sheet)
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

    private func moveInMenu(_ delta: Int) -> KeyPress.Result {
        guard menu.isOpen else { return .ignored }
        menu.move(delta)
        return .handled
    }

    /// Return or the button: Nook writes for "@nook …"; anything else goes to the host to send.
    private func submit() {
        guard !busy, !drafting else { return }
        if let instruction = ChatDraft.instruction(in: text) {
            write(instruction)
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notice = nil
            drafted = nil
            send()
        }
    }

    /// Nook writes the message from the chat and what you asked, and puts it in the field; sending stays your own click.
    private func write(_ instruction: String) {
        request = text
        beforeWriting = nil
        run(instruction)
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
                text = message
                drafted = message
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
        if let before = beforeWriting { text = before }
        beforeWriting = nil
        notice = nil
        focus.wrappedValue = true
    }

    /// The draft goes; your "@nook …" request is back in the field, to change it and let Nook write again.
    private func backToRequest() {
        stopWriting()
        text = request ?? ""
        drafted = nil
        steer = ""
        request = nil
    }
}

/// Above the field while Nook writes or its message is in the field: Nook's own panel, with what it is doing and the
/// ways to steer the draft before you send it.
private struct DraftPanel: View {
    let writing: Bool
    let rewriting: Bool
    /// You changed Nook's message in the field.
    let edited: Bool
    let readyNotice: String
    @Binding var steer: String
    var steerFocused: FocusState<Bool>.Binding
    let undo: () -> Void
    let tweak: (ChatDraft.Tweak) -> Void
    let rewrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header
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
            steerField
        }
        .padding(NookTheme.Spacing.md)
        .cardBackground(NookTheme.iris.opacity(0.07), stroke: NookTheme.iris.opacity(0.2), radius: NookTheme.Radius.panel,
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
            ToolbarIconButton("arrow.uturn.backward", tr("chats.draft.undo"), undo)
        }
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

/// A one-click change under Nook's draft: a small capsule with a symbol, lit under the pointer.
private struct DraftChip: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: symbol)
                    .font(NookTheme.font(9.5, .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(NookTheme.TextStyle.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.graphite))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
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

/// Three dots that rise in turn while Nook writes; still with Reduce Motion.
private struct WritingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
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
        .frame(height: 10)
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
