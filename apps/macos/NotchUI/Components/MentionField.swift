import SwiftUI

// `@` in any text field, in two parts: `.mentions(_:text:config:)` on the field itself listens to what is typed and to
// the keys (ArrowUp and ArrowDown move, Return or Tab chooses, Escape closes), and `MentionSuggestions` shows the list,
// placed by the call site right above the field's box. Both share a `ComposerModel` the call site owns with
// `@StateObject`. The composers (`SessionComposer`, `ChatReplyField`) build the same list into themselves; every other
// field where you write words uses this.

extension View {
    /// `@` on this text field: what you type after it fills `model`'s list, and the keys choose from it. Put it on the
    /// field itself, not on its box, so Return chooses a line before the field's own `onSubmit` sees it.
    func mentions(_ model: ComposerModel, text: Binding<String>, config: ComposerConfig) -> some View {
        modifier(MentionKeys(model: model, text: text, config: config))
    }
}

extension ComposerConfig {
    /// What `@` offers in a field outside the composers: the people from your chats by name, and the files of `folder`
    /// when the field belongs to a project. Everything goes in as plain words, since people read these fields.
    @MainActor
    static func mentions(folder: String? = nil) -> ComposerConfig {
        var config = ComposerConfig()
        config.people = { AppModel.shared.chatChoices() }
        config.fileRoot = folder.flatMap { $0.isEmpty ? nil : $0 }
        config.plainReferences = true
        return config
    }
}

extension ComposerModel {
    /// Puts the chosen line in the text. A line that fills the text with something that has a list of its own ("@chat ")
    /// shows that list straight away.
    func choose(_ suggestion: ComposerSuggestion, text: Binding<String>, config: ComposerConfig) {
        let value = accept(suggestion, in: text.wrappedValue, config)
        if value != text.wrappedValue {
            applying = true
            text.wrappedValue = value
        }
        if case .command(let command) = suggestion.payload, command.action == .insert {
            update(for: value, config)
        }
    }
}

private struct MentionKeys: ViewModifier {
    @ObservedObject var model: ComposerModel
    @Binding var text: String
    let config: ComposerConfig

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, new in changed(new) }
            .onKeyPress(.upArrow) { () -> KeyPress.Result in move(-1) }
            .onKeyPress(.downArrow) { () -> KeyPress.Result in move(1) }
            .onKeyPress(.tab) { () -> KeyPress.Result in chooseSelected() }
            .onKeyPress(.return) { () -> KeyPress.Result in chooseSelected() }
            .onKeyPress(.escape) { () -> KeyPress.Result in
                guard model.isOpen else { return .ignored }
                model.close()
                return .handled
            }
            .onDisappear { model.close() }
    }

    private func changed(_ new: String) {
        if model.applying {
            model.applying = false
            return
        }
        model.update(for: new, config)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard model.isOpen else { return .ignored }
        model.move(delta)
        return .handled
    }

    private func chooseSelected() -> KeyPress.Result {
        guard model.isOpen, model.suggestions.indices.contains(model.selection) else { return .ignored }
        model.choose(model.suggestions[model.selection], text: $text, config: config)
        return .handled
    }
}

/// The list `@` opens, above a field that has `.mentions(_:text:config:)`. Shows nothing while the list is closed.
struct MentionSuggestions: View {
    @ObservedObject var model: ComposerModel
    @Binding var text: String
    let config: ComposerConfig
    /// The field to give the keyboard back to after a click on a line.
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        if model.isOpen {
            ComposerSuggestionList(model: model, tint: config.tint) { row in
                model.choose(row, text: $text, config: config)
                focus?.wrappedValue = true
            }
            .transition(.opacity)
        }
    }
}
