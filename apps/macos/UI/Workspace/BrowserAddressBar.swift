import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// The extensions in the browser's toolbar: the buttons of the pinned ones, then the puzzle piece, always there, whose
/// menu lists every extension (run it, pin it, turn it off, its options, remove it) and adds new ones. A click on a
/// button runs the extension's action or opens its popup under the button; its right-click menu has the same choices.
struct BrowserExtensionButtons: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var extensions = BrowserExtensions.shared

    var body: some View {
        let buttons = extensions.buttons(for: store.page)
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(buttons) { button in
                ExtensionButton(button: button, page: store.page)
            }
            if BrowserExtensions.isSupported {
                BrowserExtensionsMenu(store: store)
            }
        }
    }
}

/// The puzzle piece in the browser's toolbar: every extension you added, and the ways to add one.
private struct BrowserExtensionsMenu: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var extensions = BrowserExtensions.shared
    @State private var anchor = ViewAnchor.Box()
    @State private var hovering = false
    @State private var removing: BrowserExtensions.Installed?

    var body: some View {
        ComposerDropdown(width: 300) {
            Image(icon: "puzzlepiece.extension")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .roundedBackground(hovering ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
                .background(ViewAnchor(box: anchor))
                .onHover { hovering = $0 }
                .nookTip(tr("browser.extensions.menu"))
                .accessibilityLabel(tr("browser.extensions.menu"))
        } content: {
            menu
        }
        .confirmDelete($removing, question: { tr("confirm.remove", $0.name) },
                       confirmTitle: tr("browser.extensions.remove")) { extensions.remove($0.id) }
    }

    @ViewBuilder
    private var menu: some View {
        DropdownHeader(title: tr("browser.extensions.menu"))
        if extensions.installed.isEmpty {
            Text(tr("browser.extensions.none"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.sm)
        } else {
            let buttons = extensions.allButtons(for: store.page)
            ForEach(extensions.installed) { item in
                ExtensionMenuRow(item: item, button: buttons[item.id], page: store.page, anchor: anchor,
                                 remove: { removing = item })
            }
        }
        DropdownDivider()
        DropdownRow(symbol: "bag", title: tr("settings.browser.extensions.openStore")) {
            if let url = URL(string: "https://chromewebstore.google.com") { BrowserStore.show(url) }
        }
        DropdownRow(symbol: "folder", title: tr("settings.browser.extensions.fromFileButton"),
                    disabledReason: extensions.installing == nil ? nil : tr("browser.extensions.adding")) {
            // After the menu closed: the open panel is modal.
            DispatchQueue.main.async { pickExtensionFile() }
        }
        DropdownRow(symbol: "gearshape", title: tr("browser.extensions.manage")) {
            AppModel.shared.openSettings(section: .openIn)
        }
    }
}

/// One extension in the extensions menu: its icon and name (a click runs it), a pin for the toolbar, and a menu with
/// turning it off, its options and removing it.
private struct ExtensionMenuRow: View {
    let item: BrowserExtensions.Installed
    let button: BrowserExtensions.Button?
    let page: BrowserPage
    let anchor: ViewAnchor.Box
    let remove: () -> Void
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Button(action: run) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Group {
                        if let icon = button?.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
                        } else {
                            NookSymbol("puzzlepiece.extension", size: 12).foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .opacity(item.enabled ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: item.name)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(item.enabled ? NookTheme.paper : NookTheme.textTertiary)
                            .lineLimit(1)
                        if !item.enabled {
                            Text(tr("browser.extensions.off"))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    Spacer(minLength: NookTheme.Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .disabled(!item.enabled)
            if item.enabled {
                ToolbarIconButton(item.pinned ? "pin.fill" : "pin",
                                  tr(item.pinned ? "browser.extensions.unpin" : "browser.extensions.pin"),
                                  height: 22, width: 22, selected: item.pinned) {
                    BrowserExtensions.shared.setPinned(item.id, !item.pinned)
                }
            }
            Menu {
                ExtensionActions(id: item.id, enabled: item.enabled, remove: remove)
            } label: {
                Image(icon: "ellipsis").font(NookTheme.font(11, .medium)).frame(width: 22, height: 22)
            }
            .menuStyle(.nookButton)
            .buttonStyle(.nookPlain)
            .menuIndicator(.hidden)
            .fixedSize()
            .nookTip(tr("a11y.more"))
            .accessibilityLabel(tr("a11y.more"))
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .frame(minHeight: 32)
        .roundedBackground(hovering ? DropdownStyle.hover : .clear, radius: NookTheme.Radius.chip)
        .onHover { hovering = $0 }
    }

    /// Runs the extension as its toolbar button would, its popup opening under the puzzle piece once the menu is gone.
    private func run() {
        close()
        let id = item.id, page = page, anchor = anchor
        DispatchQueue.main.async {
            BrowserExtensions.shared.click(id, page: page, anchor: anchor.view)
        }
    }
}

/// What can be done with an extension, in its right-click menu and its row in the extensions menu.
private struct ExtensionActions: View {
    let id: String
    let enabled: Bool
    let remove: () -> Void

    var body: some View {
        if enabled, BrowserExtensions.shared.hasOptions(id) {
            Button { BrowserExtensions.shared.openOptions(id) } label: { Label(tr("browser.extensions.options"), icon: "slider.horizontal.3") }
        }
        Button { BrowserExtensions.shared.setEnabled(id, !enabled) } label: {
            Label(tr(enabled ? "browser.extensions.turnOff" : "browser.extensions.turnOn"), icon: enabled ? "pause.circle" : "play.circle")
        }
        Divider()
        Button(role: .destructive, action: remove) { Label(tr("browser.extensions.remove"), icon: "trash") }
    }
}

/// Lets you pick an extension on disk (a folder with a manifest.json, a .zip or a .crx) and adds it.
@MainActor
func pickExtensionFile() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
    panel.message = tr("settings.browser.extensions.pickMessage")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await BrowserExtensions.shared.installFromFile(url) }
}

private struct ExtensionButton: View {
    let button: BrowserExtensions.Button
    let page: BrowserPage
    @State private var anchor = ViewAnchor.Box()
    @State private var hovering = false
    @State private var removing = false

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
                        .padding(.horizontal, NookTheme.Spacing.xxs)
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
            Button { BrowserExtensions.shared.setPinned(button.id, false) } label: { Label(tr("browser.extensions.unpin"), icon: "pin.slash") }
            ExtensionActions(id: button.id, enabled: true) { removing = true }
        }
        .confirmationDialog(tr("confirm.remove", button.name), isPresented: $removing, titleVisibility: .visible) {
            Button(tr("browser.extensions.remove"), role: .destructive) { BrowserExtensions.shared.remove(button.id) }
            Button(tr("button.cancel"), role: .cancel) {}
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
