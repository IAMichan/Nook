import SwiftUI

/// A destructive button that asks first: a click opens a confirmation dialog, and only its red button runs `action`.
/// Use it for everything that cannot be undone (delete, remove a key, sign out, clear a history), so every such action
/// asks the same way. The title is the button's text; `question` heads the dialog and `detail` says what is lost.
struct ConfirmedButton<Label: View>: View {
    let question: String
    let detail: String?
    /// The text of the dialog's red button.
    let confirmTitle: String
    let action: () -> Void
    let label: () -> Label
    @State private var asking = false

    init(question: String, detail: String? = nil, confirmTitle: String, action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.question = question
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: .destructive, action: { asking = true }, label: label)
            .confirmationDialog(question, isPresented: $asking, titleVisibility: .visible) {
                Button(confirmTitle, role: .destructive, action: action)
                Button(tr("button.cancel"), role: .cancel) {}
            } message: {
                if let detail { Text(detail) }
            }
    }
}

extension ConfirmedButton where Label == Text {
    /// A text button: the title is the button and the dialog's red button.
    init(_ title: String, question: String, detail: String? = nil, action: @escaping () -> Void) {
        self.init(question: question, detail: detail, confirmTitle: title, action: action) { Text(title) }
    }
}

extension ConfirmedButton where Label == Image {
    /// A symbol-only button (a trash can in a row); `title` is its tooltip, what VoiceOver reads, and the red button.
    init(symbol: String, title: String, question: String, detail: String? = nil, action: @escaping () -> Void) {
        self.init(question: question, detail: detail, confirmTitle: title, action: action) { Image(systemName: symbol) }
    }
}

extension ConfirmedButton {
    /// The tooltip and the VoiceOver label of a symbol-only button.
    func labelled(_ title: String) -> some View {
        help(title).accessibilityLabel(title)
    }
}

extension View {
    /// Asks before deleting `item`: set the binding from a menu item (which cannot hold a dialog itself) and the
    /// dialog opens on this view; its red button runs `action` with the item.
    func confirmDelete<Item>(_ item: Binding<Item?>, question: @escaping (Item) -> String, detail: String? = nil,
                             confirmTitle: String, action: @escaping (Item) -> Void) -> some View {
        confirmationDialog(item.wrappedValue.map(question) ?? "",
                           isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: item.wrappedValue) { value in
            Button(confirmTitle, role: .destructive) { action(value) }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: { _ in
            if let detail { Text(detail) }
        }
    }
}
