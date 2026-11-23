import SwiftUI

/// What a session's header needs to draw the session tabs: the open tabs with their rows from the Agents list, which
/// one is open, and what a click does. Set by `AgentsTab`; without it the header shows "folder / title" as before.
struct SessionTabsContext {
    struct Tab: Identifiable {
        let id: String
        /// Its row in the Agents list; nil for the open session when the list has no row for it (yet).
        let item: AgentListItem?
    }

    let tabs: [Tab]
    /// The id of the session that is open.
    let current: String
    let select: (String) -> Void
    let close: (String) -> Void
    let closeOthers: (String) -> Void
    let closeRight: (String) -> Void
    let closeAll: () -> Void
    let move: (String, String) -> Void
    let newSession: () -> Void
}

extension EnvironmentValues {
    @Entry var sessionTabs: SessionTabsContext? = nil
}

/// The sessions you opened, as tabs in the session's header where the folder and title of the open one used to be: each
/// the agent's logo and the session's name, with the folder in its tooltip. The open tab shows `title` (the header's
/// own, so a rename shows at once) and the controls the header gives it after its name (`accessory`, the session's
/// menu). Click a tab to switch, its cross (under the pointer) or its right-click menu to close it; drag to reorder. The
/// folder the old header named is still a click away: the menu starts a new session in it.
struct SessionTabStrip<Accessory: View>: View {
    @EnvironmentObject private var app: AppModel
    let context: SessionTabsContext
    /// The open session's folder and title, as its header knows them.
    let folder: String
    let title: String
    /// The open session's folder on disk, for "New session in …" in its menu; empty when it has none here.
    let directory: String
    /// Double-click on the open tab, to rename it; nil when it cannot be renamed.
    var rename: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory
    @State private var dragging: String?
    /// How wide the tabs are together: the row takes no more than that, so the header's controls after it stay beside
    /// the last tab and the tabs scroll only when they do not fit.
    @State private var contentWidth: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    ForEach(context.tabs) { tab in
                        let active = tab.id == context.current
                        HStack(spacing: 0) {
                            SessionTabButton(tab: tab, active: active, folder: active ? folder : nil,
                                             title: active ? title : nil, select: { context.select(tab.id) },
                                             close: { context.close(tab.id) }, rename: active ? rename : nil)
                            if active { accessory() }
                        }
                        .id(tab.id)
                        .contextMenu { menu(for: tab) }
                        .onDrag {
                            dragging = tab.id
                            return NSItemProvider(object: "nook.session.tab" as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: SessionTabDrop(target: tab.id, dragging: $dragging,
                                                                           move: context.move))
                    }
                    Button(action: context.newSession) {
                        Image(icon: "plus")
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.nookPlain)
                    .nookTip(tr("agents.newSession"))
                    .accessibilityLabel(tr("agents.newSession"))
                }
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.width) } action: { contentWidth = $0 }
            }
            .frame(maxWidth: contentWidth ?? .infinity, alignment: .leading)
            .onChange(of: context.current) { _, id in
                withAnimation(NookTheme.scroll) { proxy.scrollTo(id) }
            }
            .onAppear { proxy.scrollTo(context.current) }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func menu(for tab: SessionTabsContext.Tab) -> some View {
        let ids = context.tabs.map(\.id)
        let index = ids.firstIndex(of: tab.id) ?? 0
        let folder = tab.id == context.current ? self.folder : (tab.item?.folder ?? "")
        let directory = tab.id == context.current ? self.directory : (tab.item?.path ?? "")
        if !folder.isEmpty, !directory.isEmpty, !app.demoMode {
            Button(tr("inbox.project.newSession", folder)) {
                FolderCrumb.startNewSession(app: app, project: folder, directory: directory)
            }
            Divider()
        }
        Button(tr("agents.pulls.tabs.close")) { context.close(tab.id) }
        Button(tr("agents.pulls.tabs.closeOthers")) { context.closeOthers(tab.id) }
            .disabled(ids.count < 2)
        Button(tr("agents.pulls.tabs.closeRight")) { context.closeRight(tab.id) }
            .disabled(index >= ids.count - 1)
        Divider()
        Button(tr("agents.pulls.tabs.closeAll")) { context.closeAll() }
    }
}

/// One session tab: the agent's logo (the cross under the pointer) and the session's name, on a soft fill while open.
private struct SessionTabButton: View {
    let tab: SessionTabsContext.Tab
    let active: Bool
    /// The open tab's folder and title from its header; the list row's otherwise.
    let folder: String?
    let title: String?
    let select: () -> Void
    let close: () -> Void
    let rename: (() -> Void)?
    @State private var hovering = false

    private var name: String { title ?? tab.item?.title ?? "" }
    private var project: String { folder ?? tab.item?.folder ?? "" }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ZStack {
                if let item = tab.item {
                    AgentMark(agent: item.agent, size: 14, quiet: !active && !hovering)
                        .overlay(alignment: .topTrailing) {
                            if let dot = Self.dot(item.status) {
                                Circle().fill(dot).frame(width: 5, height: 5).offset(x: 2, y: -2)
                            }
                        }
                        .opacity(hovering ? 0 : 1)
                        .accessibilityHidden(true)
                }
                TabCloseButton(tr("agents.pulls.tabs.close"), spoken: tr("agents.pulls.tabs.close") + " " + name,
                               tint: nil, action: close)
                    .revealOnHover(hovering || tab.item == nil)
            }
            .frame(width: 16, height: 16)
            Text(name)
                .font(active ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: active ? 260 : 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.leading, NookTheme.Spacing.xs)
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(height: 24)
        .roundedBackground(NookTheme.rowFill(selected: active, hovering: hovering, rest: .clear), radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .nookClickable()
        .onTapGesture(count: 2) { if let rename { rename() } else { select() } }
        .onTapGesture(perform: select)
        .trackedHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .nookTip(project.isEmpty ? name : project + " / " + name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.isEmpty ? name : project + ", " + name)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select() }
    }

    /// A small dot for a session that works or waits for you; none for one at rest.
    private static func dot(_ status: AgentListItem.Status) -> Color? {
        switch status {
        case .working: return NookTheme.blue
        case .waiting, .input: return NookTheme.amber
        case .failed, .limited: return NookTheme.coral
        case .idle, .finished: return nil
        }
    }
}

private struct SessionTabDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(NookTheme.swap) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
