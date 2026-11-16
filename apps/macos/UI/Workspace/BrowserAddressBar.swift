import AppKit
import SwiftUI

/// What the address bar suggests while you type: pages you visited before (`BrowserHistory`). The arrow keys move
/// through them and Enter opens the one lit; when the best one starts with what you typed (`git` → github.com) it is lit
/// at once, so Enter opens it as in other browsers. Escape closes the list.
@MainActor
final class AddressSuggestions: ObservableObject {
    @Published private(set) var items: [BrowserSuggestion] = []
    /// The line the arrow keys are on; nil opens what you typed.
    @Published var highlighted: Int?
    private var lastText = ""

    var isOpen: Bool { !items.isEmpty }

    /// You typed in the address bar.
    func update(for text: String) {
        defer { lastText = text }
        guard BrowserHistory.isEnabled(), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return close() }
        let found = BrowserHistory.shared.suggestions(for: text)
        items = found
        // Lit at once only while you add letters: after a backspace, Enter opens what you typed.
        let growing = text.count > lastText.count && text.hasPrefix(lastText)
        highlighted = growing && BrowserHistory.completion(for: text, best: found.first) != nil ? 0 : nil
    }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        let next = (highlighted ?? (step > 0 ? -1 : items.count)) + step
        highlighted = next < 0 || next >= items.count ? nil : next
    }

    /// The suggestion Enter opens, if one is lit.
    var chosen: BrowserSuggestion? {
        highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func close() {
        items = []
        highlighted = nil
    }

    func forget(_ item: BrowserSuggestion) {
        BrowserHistory.shared.remove(url: item.url)
        items.removeAll { $0 == item }
        if let index = highlighted, index >= items.count { highlighted = items.isEmpty ? nil : items.count - 1 }
    }
}

/// The list under the address bar.
struct AddressSuggestionList: View {
    @ObservedObject var model: AddressSuggestions
    let open: (BrowserSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                AddressSuggestionRow(item: item, highlighted: model.highlighted == index,
                                     open: { open(item) }, forget: { model.forget(item) })
            }
        }
        .padding(NookTheme.Spacing.xs)
        .cardBackground(DropdownStyle.panel, stroke: NookTheme.line2, radius: NookTheme.Radius.sheet)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }
}

private struct AddressSuggestionRow: View {
    let item: BrowserSuggestion
    let highlighted: Bool
    let open: () -> Void
    let forget: () -> Void
    @State private var hovering = false

    private var host: String { URL(string: item.url)?.host ?? "" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: NookTheme.Spacing.sm) {
                SiteIcon(domain: host, fallback: "clock", tint: NookTheme.textTertiary, size: 14)
                Text(item.title.isEmpty ? item.shortAddress : item.title)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                if !item.title.isEmpty {
                    Text(item.shortAddress)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 28)
            .roundedBackground(highlighted || hovering ? DropdownStyle.hover : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .overlay(alignment: .trailing) {
            if hovering {
                ToolbarIconButton("xmark", tr("browser.history.forgetPage"), height: 20, width: 20, symbolSize: 9, forget)
                    .padding(.trailing, NookTheme.Spacing.xs)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// The buttons of the extensions in the browser's toolbar: a click runs the extension's action or opens its popup
/// under the button; the right-click menu has its options and removing it.
struct BrowserExtensionButtons: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var extensions = BrowserExtensions.shared

    var body: some View {
        let buttons = extensions.buttons(for: store.page)
        if !buttons.isEmpty {
            HStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(buttons) { button in
                    ExtensionButton(button: button, page: store.page)
                }
            }
        }
    }
}

private struct ExtensionButton: View {
    let button: BrowserExtensions.Button
    let page: BrowserPage
    @State private var anchor = ViewAnchor.Box()
    @State private var hovering = false

    var body: some View {
        Button {
            BrowserExtensions.shared.click(button.id, page: page, anchor: anchor.view)
        } label: {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
                } else {
                    NookSymbol("puzzlepiece.extension", size: 12).foregroundStyle(NookTheme.textSecondary)
                }
            }
            .frame(width: 24, height: 24)
            .roundedBackground(hovering ? WS.subtle : Color.clear, radius: NookTheme.Radius.control)
            .overlay(alignment: .bottomTrailing) {
                if !button.badge.isEmpty {
                    Text(verbatim: button.badge)
                        .font(NookTheme.font(7.5, .bold))
                        .foregroundStyle(NookTheme.paper)
                        .padding(.horizontal, 2)
                        .roundedBackground(NookTheme.coral, radius: NookTheme.Radius.chip)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .background(ViewAnchor(box: anchor))
        .onHover { hovering = $0 }
        .nookTip(button.name)
        .contextMenu {
            if BrowserExtensions.shared.hasOptions(button.id) {
                Button(tr("browser.extensions.options")) { BrowserExtensions.shared.openOptions(button.id) }
            }
            Button(tr("browser.extensions.remove"), role: .destructive) { BrowserExtensions.shared.remove(button.id) }
        }
    }
}

/// The AppKit view behind a SwiftUI view, for a popover to open beside it.
struct ViewAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
