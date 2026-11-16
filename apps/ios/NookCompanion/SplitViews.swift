import SwiftUI
import UIKit

// The iPad (docs/COMPANION.md › iPad): at a regular width the phone's tabs become one split view, the list of a section
// on the left and what you opened from it on the right. Every screen is the phone's own: the list views, the session,
// the chats and the pull requests are the same views, only where a row opens differs (`OpenLink`, `openInDetail`). At a
// compact width (Slide Over, a narrow Split View or Stage Manager window) `RootView` shows the phone's tabs instead, on
// the same state, so what you had open stays open when the window changes size.

// MARK: Where a row opens

/// Opens a row's value beside the list instead of pushing it: set by the split view on its sidebar only.
struct OpenInDetail {
    let open: (AnyHashable) -> Void
    func callAsFunction(_ value: some Hashable) { open(AnyHashable(value)) }
}

private struct OpenInDetailKey: EnvironmentKey { static let defaultValue: OpenInDetail? = nil }
private struct DetailSelectionKey: EnvironmentKey { static let defaultValue: AnyHashable? = nil }
private struct SearchFocusRequestKey: EnvironmentKey { static let defaultValue = SearchRequest() }
private struct SidebarRoomKey: EnvironmentKey { static let defaultValue: SidebarRoom? = nil }

/// Lets what opens beside the conversation (the session's inspector) fold the split view's list away while it needs the
/// room, and bring it back after. Nil outside the split view.
struct SidebarRoom {
    let fold: () -> Void
    let unfold: () -> Void
}

/// Search asked for from the keyboard (⌘F, ⌘K): how often, and when last.
struct SearchRequest: Equatable {
    private(set) var count = 0
    private(set) var at = Date.distantPast

    /// Asked at least once: a list shows its search field from then on, also while it is short.
    var asked: Bool { count > 0 }
    /// Just asked: a field that appears now came for it and takes the keys.
    var isFresh: Bool { Date().timeIntervalSince(at) < 1 }

    mutating func ask() {
        count += 1
        at = Date()
    }
}

extension EnvironmentValues {
    /// Where a row opens: nil pushes it (the phone), set fills the detail column (`CompanionSplitView`).
    var openInDetail: OpenInDetail? {
        get { self[OpenInDetailKey.self] }
        set { self[OpenInDetailKey.self] = newValue }
    }

    /// What the detail column shows, so its row in the list reads as chosen (`detailSelected`).
    var detailSelection: AnyHashable? {
        get { self[DetailSelectionKey.self] }
        set { self[DetailSelectionKey.self] = newValue }
    }

    /// The split view's list, to fold away while an inspector beside the conversation needs the room.
    var sidebarRoom: SidebarRoom? {
        get { self[SidebarRoomKey.self] }
        set { self[SidebarRoomKey.self] = newValue }
    }

    /// ⌘F or ⌘K asked for search: the list on screen shows its search field and puts the keys in it.
    var searchFocusRequest: SearchRequest {
        get { self[SearchFocusRequestKey.self] }
        set { self[SearchFocusRequestKey.self] = newValue }
    }
}

/// A row that opens `value`: a navigation link on the phone, a button that fills the detail column on the iPad.
struct OpenLink<Value: Hashable, Label: View>: View {
    @Environment(\.openInDetail) private var openInDetail
    let value: Value
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let openInDetail {
            Button { openInDetail(value) } label: { label().detailSelected(value) }
        } else {
            NavigationLink(value: value, label: label)
        }
    }
}

extension View {
    /// Lights the row whose value the detail column shows, as the Mac lights the chosen row (`rowSelected`).
    func detailSelected(_ value: some Hashable, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(DetailSelected(value: AnyHashable(value), radius: radius))
    }

    /// Text that reads at a comfortable measure in a wide window (an iPad in landscape, a large Stage Manager window):
    /// at most `CompanionLayout.readingWidth`, centered. On the phone it changes nothing.
    func readingColumn() -> some View {
        frame(maxWidth: CompanionLayout.readingWidth).frame(maxWidth: .infinity)
    }
}

private struct DetailSelected: ViewModifier {
    @Environment(\.detailSelection) private var selection
    let value: AnyHashable
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.roundedBackground(selection == value ? Theme.rowSelected : Color.clear, radius: radius)
    }
}

/// The sizes the iPad layout keeps to.
enum CompanionLayout {
    /// About `NookTheme.readingMeasure` characters of body text, plus the room of the transcript's own margins.
    static let readingWidth: CGFloat = 760
    /// The list beside what is open.
    static let sidebarMin: CGFloat = 320
    static let sidebarIdeal: CGFloat = 360
    static let sidebarMax: CGFloat = 440
    /// The narrowest the conversation gets beside an inspector before the list folds away.
    static let conversationMin: CGFloat = 440
    /// Files, terminals and pull requests next to a session (`SessionWorkspaceMenu`).
    static let inspectorMin: CGFloat = 300
    static let inspectorIdeal: CGFloat = 360
    static let inspectorMax: CGFloat = 520
    /// The smallest window Stage Manager may make: the phone's layout still fits.
    static let minimumWindow = CGSize(width: 375, height: 500)
}

// MARK: The split view

/// The iPad at a regular width: the chosen section's list on the left (the phone's tab, with its sections in a bar under
/// it), and on the right what was opened from it, as the phone would push it. Files, terminals and pull requests of a
/// session open in an inspector next to it (`SessionWorkspaceMenu`).
struct CompanionSplitView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter
    @Binding var sessionPath: [String]
    @Binding var chatPath: [ChatRoute]
    @Binding var inboxPath: [String]
    @Binding var pullPath: [PullRoute]
    @Binding var newSessionRequested: Bool
    @State private var columns = NavigationSplitViewVisibility.all
    /// The list the detail column follows; Settings, which opens nothing, leaves it where it was.
    @State private var detailTab = CompanionTab.agents

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: CompanionLayout.sidebarMin, ideal: CompanionLayout.sidebarIdeal,
                                                max: CompanionLayout.sidebarMax)
        } detail: {
            detail
                .environment(\.sidebarRoom, SidebarRoom(fold: { withAnimation(Theme.reveal) { columns = .detailOnly } },
                                                         unfold: { withAnimation(Theme.reveal) { columns = .all } }))
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.tab, initial: true) { _, tab in
            if tab != .settings { detailTab = tab }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Group {
            switch router.tab {
            case .nook: ChatListView(path: opener($chatPath))
            case .agents: SessionListView(path: opener($sessionPath), newSessionRequested: $newSessionRequested)
            case .chats: InboxListView(path: opener($inboxPath))
            case .pulls: PullRequestListView()
            case .settings: SettingsView()
            }
        }
        .environment(\.openInDetail, OpenInDetail { open($0) })
        .environment(\.detailSelection, selection)
        .safeAreaInset(edge: .bottom, spacing: 0) { SplitSectionBar() }
    }

    /// A list's path as the split view takes it: what the list pushes opens beside it, and the list itself stays.
    private func opener<Value: Hashable>(_ path: Binding<[Value]>) -> Binding<[Value]> {
        Binding(get: { [] }, set: { pushed in
            if let last = pushed.last { path.wrappedValue = [last] }
        })
    }

    /// A row of the sidebar was opened: it shows on the right.
    private func open(_ value: AnyHashable) {
        switch value.base {
        case let route as ChatRoute: chatPath = [route]
        case let route as PullRoute: pullPath = [route]
        case let id as String:
            if router.tab == .chats { inboxPath = [id] } else { sessionPath = [id] }
        default: break
        }
    }

    private var selection: AnyHashable? {
        switch router.tab {
        case .nook: return chatPath.first.map { AnyHashable($0) }
        case .agents: return sessionPath.first.map { AnyHashable($0) }
        case .chats: return inboxPath.first.map { AnyHashable($0) }
        case .pulls: return pullPath.first.map { AnyHashable($0) }
        case .settings: return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch detailTab {
        case .nook:
            if let route = chatPath.first {
                page(route) { ChatDestination(route: route) }
            } else {
                placeholder(symbol: "sparkles", message: String(localized: "Choose a chat with Nook on the left, or ask him something."))
            }
        case .chats:
            if let id = inboxPath.first {
                page(id) { InboxChatView(chatID: id) }
            } else {
                placeholder(symbol: "bubble.left.and.bubble.right", message: String(localized: "Choose a chat on the left to read it here."))
            }
        case .pulls:
            if let route = pullPath.first {
                page(route) { PullRequestDetailView(url: route.url) }
            } else {
                placeholder(symbol: "arrow.triangle.pull", message: String(localized: "Choose a pull request on the left to read it here."))
            }
        case .agents, .settings:
            if let id = sessionPath.first {
                page(id) { SessionDetailView(sessionID: id) }
            } else {
                placeholder(symbol: "square.stack.3d.up", message: String(localized: "Choose a session on the left, or start one with ⌘N."))
            }
        }
    }

    /// One opened thing with a navigation stack of its own, so what it opens (its changes, a file) pushes there; a new
    /// choice starts a new stack.
    private func page<ID: Hashable, Content: View>(_ id: ID, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content() }.id(AnyHashable(id))
    }

    private func placeholder(symbol: String, message: String) -> some View {
        NavigationStack {
            WSEmptyState(symbol: symbol, title: String(localized: "Nothing open"), message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screen()
        }
    }
}

/// The sections under the sidebar's list, the phone's tab bar: each with its symbol, its name and what waits there.
private struct SplitSectionBar: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(router.available(client), id: \.self) { tab in
                let selected = router.tab == tab
                Button {
                    Haptics.tap()
                    router.tab = tab
                } label: {
                    VStack(spacing: Theme.Spacing.xxs) {
                        Image(icon: tab.symbol(selected: selected))
                            .font(Theme.font(17, .medium))
                            .frame(height: 22)
                            .overlay(alignment: .topTrailing) {
                                NookCountBadge(count: router.count(tab, client)).offset(x: 12, y: -6)
                            }
                        Text(tab.title).font(Theme.TextStyle.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Theme.paper : Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .roundedBackground(selected ? Theme.rowSelected : Color.clear, radius: Theme.Radius.control)
                    .contentShape(.hoverEffect, Theme.shape(Theme.Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                .hoverEffect(.highlight)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { NookDivider(tint: Theme.hairline) }
    }
}

// MARK: Keyboard

/// What the keyboard shortcuts of a hardware keyboard do in the window that has the keys (`CompanionMenuCommands`).
struct CompanionCommands {
    let newSession: () -> Void
    let previousSession: () -> Void
    let nextSession: () -> Void
    let search: () -> Void
    let findSession: () -> Void
    let section: (CompanionTab) -> Void
    let sections: [CompanionTab]
}

private struct CompanionCommandsKey: FocusedValueKey { typealias Value = CompanionCommands }

extension FocusedValues {
    var companionCommands: CompanionCommands? {
        get { self[CompanionCommandsKey.self] }
        set { self[CompanionCommandsKey.self] = newValue }
    }
}

/// The app's keyboard shortcuts, listed when you hold ⌘ on an iPad: ⌘N a new session, ⌘[ and ⌘] the session above or
/// below in the Agents list, ⌘F search in the list, ⌘K find a session, ⌘1… a section. ⌘↩ sends from any composer
/// (`SessionComposer`).
struct CompanionMenuCommands: Commands {
    @FocusedValue(\.companionCommands) private var commands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New session") { commands?.newSession() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(commands == nil)
        }
        CommandMenu("Go") {
            Button("Previous session") { commands?.previousSession() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next session") { commands?.nextSession() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Search") { commands?.search() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find a session") { commands?.findSession() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            ForEach(Array((commands?.sections ?? []).enumerated()), id: \.element) { index, tab in
                Button(tab.title) { commands?.section(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
