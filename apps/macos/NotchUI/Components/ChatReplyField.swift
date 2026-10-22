import SwiftUI

/// The answer field under a chat, the same in the Chats tab and on a message card in the notch. What is typed goes to
/// the chat through `send`; "@" opens the menu with "@nook" and ready-made requests above the field, and "@nook …" lets
/// Nook write the message into this field first, through `draft`, for you to read before it goes anywhere.
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
    /// "@nook …": what was asked ("" for a fitting answer), returning the message Nook wrote. Throws with a sentence
    /// you can act on.
    let draft: (String) async throws -> String
    /// Return or the button with ordinary text: the host sends it (the text is still in `text`).
    let send: () -> Void

    @State private var drafting = false
    /// The menu "@" opens above the field, as in Nook's own chat.
    @StateObject private var menu = ComposerModel()

    /// "@nook …" at the start of the field: Nook writes the message instead of sending what is typed.
    private var asksNook: Bool { ChatDraft.instruction(in: text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let notice {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                    if drafting || busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "info.circle")
                            .font(NookTheme.font(10.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    Text(notice)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                .transition(.opacity)
            }
            if menu.isOpen {
                ComposerSuggestionList(model: menu, tint: NookTheme.iris) { choose($0) }
            }
            field
        }
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
                    guard menu.isOpen else { return .ignored }
                    menu.close()
                    return .handled
                }
                .onChange(of: text) { _, new in
                    updateMenu(new)
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
            NookIconButton(systemName: asksNook ? "sparkles" : sendSymbol, label: buttonLabel, filled: true, size: 28) { submit() }
                .disabled(busy || drafting || (!asksNook && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .help(buttonLabel)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
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
            send()
        }
    }

    /// Nook writes the message from the chat and what you asked, and puts it in the field; sending stays your own click.
    private func write(_ instruction: String) {
        drafting = true
        notice = tr("chats.draft.writing")
        Task { @MainActor in
            defer { drafting = false }
            do {
                text = try await draft(instruction)
                notice = readyNotice
                focus.wrappedValue = true
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
