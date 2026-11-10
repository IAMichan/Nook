import SwiftUI
import AppKit

/// The repositories on top of the Actions page, as tabs: one click goes from one repository's runs to another's, and
/// each tab says how its repository stands (turning while something runs, coral when a workflow's newest run failed;
/// nothing when all is well). The tabs keep their order; the "+" at the end searches every repository you pushed to,
/// those of your pull requests and the ones you watch, and opens one typed as "owner/repo" or pasted as a link.
struct ActionsRepoBar: View {
    @ObservedObject var store: ActionsStore
    /// What the picker offers besides the tabs.
    let candidates: [String]

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        ForEach(store.recent, id: \.self) { repo in
                            ActionsRepoTab(repo: repo, title: title(repo), status: store.status(of: repo),
                                           selected: repo.caseInsensitiveCompare(store.repo ?? "") == .orderedSame,
                                           closable: store.recent.count > 1,
                                           onSelect: { store.select(repo) },
                                           onClose: { withAnimation(NookTheme.swap) { store.close(repo) } })
                                .id(repo)
                        }
                    }
                }
                .onChange(of: store.repo) { _, repo in
                    guard let repo else { return }
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(repo) }
                }
            }
            ActionsRepoPicker(store: store, candidates: candidates)
        }
        .frame(height: 32)
    }

    /// A tab names the repository alone, unless another tab has a repository of the same name.
    private func title(_ repo: String) -> String {
        let name = Self.name(repo)
        let twins = store.recent.filter { Self.name($0).caseInsensitiveCompare(name) == .orderedSame }
        return twins.count > 1 ? repo : name
    }

    static func owner(_ repo: String) -> String { String(repo.split(separator: "/").first ?? "") }
    static func name(_ repo: String) -> String { String(repo.split(separator: "/").last ?? "") }
}

/// One repository on the tab bar: its owner's picture, its name, how it stands, and under the pointer an "×" that takes
/// it off the bar.
struct ActionsRepoTab: View {
    let repo: String
    let title: String
    let status: WorkflowRepoStatus?
    let selected: Bool
    let closable: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            GitHubAvatar(login: ActionsRepoBar.owner(repo), size: 16)
                .opacity(selected || hovering ? 1 : 0.75)
            Text(title)
                .font(selected ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                .foregroundStyle(selected ? NookTheme.paper : (hovering ? NookTheme.textStrong : NookTheme.textSecondary))
                .lineLimit(1)
                .fixedSize()
            // Calm by default: a mark only when something runs or a workflow is broken.
            if let status, status.active > 0 || status.failing > 0 {
                CheckOutcomeGlyph(outcome: status.outcome, size: 10, running: status.running)
                    .help(statusHelp(status))
            }
            if closable {
                ToolbarIconButton("xmark", tr("actions.repo.close"), height: 16, width: 16, onClose)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, closable ? NookTheme.Spacing.xs : NookTheme.Spacing.md)
        .frame(height: 30)
        .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear), radius: NookTheme.Radius.control)
        .roundedHitShape(NookTheme.Radius.control)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(repo)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repo)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: tr("actions.repo.close")) { if closable { onClose() } }
        .contextMenu {
            if let url = URL(string: "https://github.com/\(repo)/actions") {
                Button(tr("actions.openOnGitHub")) { NSWorkspace.shared.open(url) }
            }
            Button(tr("actions.repo.copyName")) {
                Pasteboard.copy(repo)
                ToastCenter.shared.success(tr("actions.repo.copiedName"))
            }
            if closable {
                Divider()
                Button(tr("actions.repo.close"), action: onClose)
            }
        }
    }

    private func statusHelp(_ status: WorkflowRepoStatus) -> String {
        var parts: [String] = []
        if status.active > 0 { parts.append(tr("actions.repo.running", status.active)) }
        if status.failing > 0 { parts.append(tr("actions.repo.failing", status.failing)) }
        return parts.joined(separator: " · ")
    }
}

/// The "+" at the end of the tab bar: a search over every repository the page knows, the tabs first. Return opens the
/// first match, or the repository typed as "owner/repo" or pasted as a github.com link.
struct ActionsRepoPicker: View {
    @ObservedObject var store: ActionsStore
    let candidates: [String]

    var body: some View {
        ComposerDropdown(width: 320) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "plus")
                    .font(NookTheme.font(12, .semibold))
                // Without tabs yet, the button says what it is for.
                if store.recent.isEmpty {
                    Text(tr("actions.repo.pick")).font(NookTheme.TextStyle.body)
                }
            }
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, store.recent.isEmpty ? NookTheme.Spacing.md : 0)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
            .help(tr("actions.repo.help"))
            .accessibilityLabel(tr("actions.repo.help"))
        } content: {
            ActionsRepoPickerList(store: store, candidates: candidates)
        }
    }
}

private struct ActionsRepoPickerList: View {
    @ObservedObject var store: ActionsStore
    let candidates: [String]
    @State private var query = ""
    @Environment(\.closeDropdown) private var close

    /// The tabs, then the rest, each once.
    private var all: [String] {
        WorkflowRunParser.candidates(selected: nil, pushed: store.recent, pullRequests: candidates, watched: [])
    }

    private var shown: [String] { Array(WorkflowRunParser.matching(query, in: all).prefix(40)) }

    /// A repository typed or pasted that the list does not have yet.
    private var typed: String? {
        guard let repo = WorkflowRunParser.repository(from: query) else { return nil }
        return all.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } ? nil : repo
    }

    var body: some View {
        DropdownSearch(placeholder: tr("actions.repo.placeholder"), text: $query, onSubmit: submit)
        let tabs = shown.filter(isTab)
        let others = shown.filter { !isTab($0) }
        DropdownList(maxHeight: 340, emptyNote: shown.isEmpty && typed == nil ? tr("actions.repo.noMatch") : nil) {
            if let typed {
                DropdownRow(symbol: "plus", title: typed, detail: tr("actions.repo.openTyped")) { _ = store.add(typed) }
            }
            if !tabs.isEmpty {
                DropdownHeader(title: tr("actions.repo.tabs"))
                ForEach(tabs, id: \.self) { row($0) }
            }
            if !others.isEmpty {
                DropdownHeader(title: tr("actions.repo.more"))
                ForEach(others, id: \.self) { row($0) }
            }
        }
    }

    private func row(_ repo: String) -> some View {
        DropdownRow(symbol: "shippingbox", title: repo,
                    chosen: repo.caseInsensitiveCompare(store.repo ?? "") == .orderedSame) { store.select(repo) }
    }

    private func isTab(_ repo: String) -> Bool {
        store.recent.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
    }

    private func submit() {
        if let typed {
            store.add(typed)
        } else if let first = shown.first {
            store.select(first)
        } else {
            return
        }
        close()
    }
}
