import AppKit
import SwiftUI

/// Your history (⌘Y) and bookmarks (⌥⌘B) in Nook's browser, over the page as Safari and Chrome show them in a tab: a
/// search field, then the pages newest first under Today, Yesterday and so on, or the bookmarks with their folders.
/// A click opens the page here, ⌘-click in a tab behind it; Escape or the cross goes back to the page.
struct BrowserLibraryView: View {
    enum Section: Hashable { case history, bookmarks }

    @ObservedObject var store: BrowserStore
    @Binding var section: Section?
    @State private var query = ""
    @State private var history: [BrowserHistoryEntry] = []
    @State private var bookmarks: [BrowserBookmarks.Bookmark] = []
    @State private var folders: [String] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                NookTabBar(items: [.init(value: Section.history, title: tr("browser.history.title"), symbol: "clock"),
                                   .init(value: Section.bookmarks, title: tr("browser.bookmarks.title"), symbol: "star")],
                           selected: section ?? .history, onSelect: { section = $0 }, segmented: true)
                    .fixedSize()
                NookSearchField(prompt: tr(section == .bookmarks ? "browser.bookmarks.search" : "browser.history.search"),
                                text: $query, style: .inline, focus: $searchFocused, onEscape: { section = nil })
                if section == .bookmarks {
                    ToolbarIconButton("folder.badge.plus", tr("browser.bookmarks.newFolder")) { newFolder() }
                }
                SidePanelCloseButton(help: tr("button.close")) { section = nil }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: SidePanelMetrics.toolbar + NookTheme.Spacing.sm)
            NookDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if section == .bookmarks { bookmarkRows } else { historyRows }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, NookTheme.Spacing.md)
                .padding(.horizontal, NookTheme.Spacing.lg)
            }
        }
        .background(NookTheme.canvas)
        .onAppear {
            searchFocused = true
            reload()
        }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: section) { _, _ in
            query = ""
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserBookmarks.changed)) { _ in reload() }
        .onKeyPress(.escape) {
            section = nil
            return .handled
        }
    }

    private func reload() {
        history = section == .history ? BrowserHistory.shared.recent(matching: query) : []
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        bookmarks = BrowserBookmarks.shared.all.filter { bookmark in
            words.allSatisfy { bookmark.url.lowercased().contains($0) || bookmark.title.lowercased().contains($0) }
        }
        folders = BrowserBookmarks.shared.folders
    }

    // MARK: History

    @ViewBuilder
    private var historyRows: some View {
        if history.isEmpty {
            ListEmptyNote(tr(query.isEmpty ? (BrowserHistory.isEnabled() ? "browser.history.empty" : "browser.history.off")
                                           : "browser.library.noMatch"), padding: NookTheme.Spacing.xl)
        } else {
            ForEach(DayBucket.group(history, date: \.lastVisit), id: \.bucket) { group in
                NookSectionLabel(tr(group.bucket.titleKey), inset: 0)
                    .padding(.top, NookTheme.Spacing.md)
                ForEach(group.items, id: \.url) { entry in
                    BrowserLibraryRow(url: entry.url, title: entry.title, trailing: NookDates.clockOrDay(entry.lastVisit),
                                      fallback: "clock", open: { open(entry.url, newTab: $0) }) {
                        Button { open(entry.url, newTab: true) } label: { Label(tr("browser.library.openInNewTab"), icon: "plus.square.on.square") }
                        Button { copy(entry.url) } label: { Label(tr("browser.library.copyAddress"), icon: "doc.on.doc") }
                        Divider()
                        Button(role: .destructive) {
                            BrowserHistory.shared.remove(url: entry.url)
                            reload()
                        } label: { Label(tr("browser.history.forgetPage"), icon: "trash") }
                    }
                }
            }
            if query.isEmpty {
                HStack {
                    Spacer()
                    ConfirmedButton(tr("settings.browser.history.clear"), question: tr("confirm.clearBrowserHistory"),
                                    detail: tr("confirm.clearBrowserHistory.detail")) {
                        BrowserHistory.shared.clear()
                        reload()
                    }
                    .buttonStyle(.nookPlain)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                }
                .padding(.top, NookTheme.Spacing.lg)
            }
        }
    }

    // MARK: Bookmarks

    @ViewBuilder
    private var bookmarkRows: some View {
        let top = bookmarks.filter { $0.folder == nil }
        if bookmarks.isEmpty && (folders.isEmpty || !query.isEmpty) {
            ListEmptyNote(tr(query.isEmpty ? "browser.bookmarks.empty" : "browser.library.noMatch"), padding: NookTheme.Spacing.xl)
        }
        ForEach(top) { bookmarkRow($0) }
        ForEach(folders, id: \.self) { folder in
            let inFolder = bookmarks.filter { $0.folder == folder }
            if query.isEmpty || !inFolder.isEmpty {
                BrowserFolderHeader(name: folder, count: inFolder.count)
                ForEach(inFolder) { bookmarkRow($0).padding(.leading, NookTheme.Spacing.lg) }
            }
        }
    }

    private func bookmarkRow(_ bookmark: BrowserBookmarks.Bookmark) -> some View {
        BrowserLibraryRow(url: bookmark.url, title: bookmark.title, trailing: nil, fallback: "star",
                          open: { open(bookmark.url, newTab: $0) }) {
            Button { open(bookmark.url, newTab: true) } label: { Label(tr("browser.library.openInNewTab"), icon: "plus.square.on.square") }
            Button { copy(bookmark.url) } label: { Label(tr("browser.library.copyAddress"), icon: "doc.on.doc") }
            Button {
                Task {
                    if let name = await BrowserPageDialogs.askName(tr("browser.bookmarks.rename"), value: bookmark.title) {
                        BrowserBookmarks.shared.rename(url: bookmark.url, to: name)
                    }
                }
            } label: { Label(tr("browser.bookmarks.rename"), icon: "pencil") }
            Menu {
                Button(tr("browser.bookmarks.topLevel")) { BrowserBookmarks.shared.move(url: bookmark.url, to: nil) }
                    .disabled(bookmark.folder == nil)
                ForEach(folders, id: \.self) { folder in
                    Button(folder) { BrowserBookmarks.shared.move(url: bookmark.url, to: folder) }
                        .disabled(bookmark.folder == folder)
                }
            } label: { Label(tr("browser.bookmarks.moveTo"), icon: "folder") }
            Divider()
            Button(role: .destructive) { BrowserBookmarks.shared.remove(url: bookmark.url) } label: {
                Label(tr("browser.bookmarks.remove"), icon: "star.slash")
            }
        }
    }

    private func newFolder() {
        Task {
            if let name = await BrowserPageDialogs.askName(tr("browser.bookmarks.newFolder"), value: tr("browser.bookmarks.folder")) {
                BrowserBookmarks.shared.addFolder(name)
            }
        }
    }

    // MARK: Opening

    /// Opens the page here and goes back to it, or with ⌘ (or from the menu) in a tab behind the library.
    private func open(_ address: String, newTab: Bool) {
        guard let url = URL(string: address) else { return }
        if newTab || NSEvent.modifierFlags.contains(.command) {
            store.newBackgroundTab().open(url)
        } else {
            section = nil
            store.open(url)
        }
    }

    private func copy(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }
}

/// One page in the library: its icon, title and address, and a time for history. Its right-click menu and the "…" at
/// the end, shown under the pointer, hold what can be done with it.
private struct BrowserLibraryRow<Actions: View>: View {
    let url: String
    let title: String
    let trailing: String?
    let fallback: String
    let open: (_ newTab: Bool) -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button { open(false) } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    SiteIcon(domain: URL(string: url)?.host ?? "", fallback: fallback, tint: NookTheme.textTertiary, size: 14)
                    Text(verbatim: title.isEmpty ? BrowserHistory.bare(url) : title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !title.isEmpty {
                        Text(verbatim: BrowserHistory.bare(url))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let trailing {
                        Text(verbatim: trailing)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            Menu { actions() } label: {
                Image(icon: "ellipsis").font(NookTheme.font(11, .medium)).frame(width: 22, height: 22)
            }
            .menuStyle(.nookButton)
            .buttonStyle(.nookPlain)
            .menuIndicator(.hidden)
            .fixedSize()
            .revealOnHover(hovering)
            .nookTip(tr("a11y.more"))
            .accessibilityLabel(tr("a11y.more"))
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(height: 30)
        .roundedBackground(hovering ? DropdownStyle.hover : .clear, radius: NookTheme.Radius.control)
        .onHover { hovering = $0 }
        .contextMenu { actions() }
    }
}

/// A bookmark folder in the library: its name and how many it holds, with renaming and removing in its menu.
private struct BrowserFolderHeader: View {
    let name: String
    let count: Int
    @State private var removing = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: "folder").font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            Text(verbatim: name).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
            NookCountBadge(count: count)
            Spacer()
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.top, NookTheme.Spacing.md)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                Task {
                    if let new = await BrowserPageDialogs.askName(tr("browser.bookmarks.renameFolder"), value: name) {
                        BrowserBookmarks.shared.renameFolder(name, to: new)
                    }
                }
            } label: { Label(tr("browser.bookmarks.renameFolder"), icon: "pencil") }
            Button(role: .destructive) { removing = true } label: { Label(tr("browser.bookmarks.removeFolder"), icon: "trash") }
        }
        .confirmationDialog(tr("confirm.remove", name), isPresented: $removing, titleVisibility: .visible) {
            Button(tr("browser.bookmarks.removeFolder"), role: .destructive) { BrowserBookmarks.shared.removeFolder(name) }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("browser.bookmarks.removeFolderDetail"))
        }
    }
}

/// History and bookmarks in the browser's toolbar: the book opens a menu with your newest bookmarks, and the way to all
/// of your history (⌘Y) and bookmarks (⌥⌘B).
struct BrowserLibraryButton: View {
    @ObservedObject var store: BrowserStore
    let show: (BrowserLibraryView.Section) -> Void
    @State private var hovering = false
    @State private var bookmarks: [BrowserBookmarks.Bookmark] = []

    var body: some View {
        ComposerDropdown(width: 300) {
            Image(icon: "book")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .roundedBackground(hovering ? WS.subtle : Color.clear, radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .nookTip(tr("browser.library.title"))
                .accessibilityLabel(tr("browser.library.title"))
                .onAppear { bookmarks = BrowserBookmarks.shared.all }
                .onReceive(NotificationCenter.default.publisher(for: BrowserBookmarks.changed)) { _ in
                    bookmarks = BrowserBookmarks.shared.all
                }
        } content: {
            DropdownRow(symbol: "clock", title: tr("browser.history.title"), trailing: "⌘Y") { show(.history) }
            DropdownRow(symbol: "star", title: tr("browser.bookmarks.all"), trailing: "⌥⌘B") { show(.bookmarks) }
            if !bookmarks.isEmpty {
                DropdownDivider()
                DropdownHeader(title: tr("browser.bookmarks.title"))
                ForEach(bookmarks.prefix(10)) { bookmark in
                    DropdownRow(symbol: "star", site: URL(string: bookmark.url)?.host,
                                title: bookmark.title.isEmpty ? BrowserHistory.bare(bookmark.url) : bookmark.title,
                                detail: bookmark.folder) {
                        if let url = URL(string: bookmark.url) { store.open(url) }
                    }
                }
            }
        }
    }
}
