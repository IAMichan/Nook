import AppKit
import Carbon
import SwiftUI

/// ⇧⌘K in the Agents tab (⌘K searches everything): one field to jump to a session or run an action, in groups: the
/// sessions you open often and lately, what you can do with the open session (pin, settle, snooze, rename, fork, copy,
/// the diff, stop), getting around (new session, a new session in a project, back and forward, the pages and panels) and
/// Settings. Each command shows its key (`Keybindings`, your own keys too). Typing filters, `>` first leaves only the
/// actions; ↑/↓ move, Return runs, Esc closes (or goes back from the list of projects).
struct AgentCommandPalette: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var viewModel: NotchViewModel
    /// The rows of the Agents list, running and earlier.
    let sessions: [AgentListItem]
    /// The session that is open, if one is.
    let current: AgentListItem?
    let close: () -> Void

    @State private var query = ""
    @State private var index = 0
    /// "New session in…" lists the projects in place of the commands.
    @State private var choosingProject = false
    @FocusState private var focused: Bool

    private enum Group: String, CaseIterable {
        case recent, session, navigation, settings, projects

        var title: String { tr("palette.group." + rawValue) }
    }

    private struct Entry: Identifiable {
        let id: String
        let group: Group
        let symbol: String
        let title: String
        var detail = ""
        /// The keybinding command it stands for, whose key it shows.
        var command: String? = nil
        /// Runs it; true keeps the palette open (a step into a list).
        let run: () -> Bool
    }

    // MARK: Entries

    private var entries: [Entry] {
        let parsed = PaletteQuery(query)
        if choosingProject { return filtered(projectEntries, parsed) }
        var out: [Entry] = []
        if !parsed.actionsOnly { out += recentEntries(parsed) }
        out += filtered(sessionEntries, parsed)
        out += filtered(navigationEntries, parsed)
        out += filtered(settingsEntries, parsed)
        return out
    }

    /// Keeps the entries that match every word, the best match first, in their order otherwise.
    private func filtered(_ list: [Entry], _ parsed: PaletteQuery) -> [Entry] {
        guard !parsed.isEmpty else { return list }
        return list.enumerated()
            .compactMap { offset, entry in parsed.match(title: entry.title, detail: entry.detail).map { (entry, $0, offset) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    /// The sessions you open often and lately (from `SessionHistory`), the open one left out.
    private func recentEntries(_ parsed: PaletteQuery) -> [Entry] {
        let candidates = sessions.filter { $0.id != current?.id }.map { item in
            PaletteRanking.Candidate(id: item.id, title: item.title, detail: Self.detail(item), updated: item.started ?? .distantPast)
        }
        let ranked = PaletteRanking.sessions(candidates, query: parsed, usage: SessionHistory.shared.usage,
                                             limit: parsed.isEmpty ? 6 : 12)
        return ranked.map { candidate in
            Entry(id: candidate.id, group: .recent, symbol: "bubble.left.and.text.bubble.right", title: candidate.title,
                  detail: candidate.detail) {
                viewModel.selectedAgentID = candidate.id
                return false
            }
        }
    }

    private static func detail(_ item: AgentListItem) -> String {
        [item.agent, item.folder, item.branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What can be done with the open session.
    private var sessionEntries: [Entry] {
        guard let current else { return [] }
        let actions = OpenSessionActions(item: current, app: app)
        var out: [Entry] = [
            Entry(id: "s:pin", group: .session, symbol: actions.pinned ? "pin.slash" : "pin",
                  title: actions.pinned ? tr("inbox.unpin") : tr("inbox.pin"), command: "session.pin") { _ = actions.togglePin(); return false },
        ]
        if !(actions.settled && current.id.hasPrefix("past:")) {
            out.append(Entry(id: "s:settle", group: .session, symbol: actions.settled ? "arrow.uturn.backward" : "checkmark",
                             title: actions.settled ? tr("inbox.reopen") : tr("inbox.settle"), command: "session.settle") {
                _ = actions.toggleSettled(); return false
            })
        }
        if actions.canSnooze {
            for choice in SnoozePolicy.Choice.allCases {
                out.append(Entry(id: "s:snooze:" + choice.rawValue, group: .session, symbol: "clock",
                                 title: tr("agents.snooze.menu") + ": " + tr("agents.snooze." + choice.rawValue)) {
                    actions.snooze(choice); return false
                })
            }
            if let reset = actions.limitResetsAt {
                out.append(Entry(id: "s:snooze:limitReset", group: .session, symbol: "clock",
                                 title: tr("agents.snooze.menu") + ": " + SnoozeText.untilReset(reset)) {
                    actions.snooze(until: reset); return false
                })
            }
        }
        if actions.canRename {
            out.append(Entry(id: "s:rename", group: .session, symbol: "pencil", title: tr("palette.rename"),
                             command: "session.rename") { _ = actions.rename(); return false })
        }
        if actions.canFork {
            out.append(Entry(id: "s:fork", group: .session, symbol: "arrow.triangle.branch", title: tr("agents.fork")) {
                if let id = actions.fork() { viewModel.selectedAgentID = id }
                return false
            })
        }
        if offers("diff.toggle") {
            out.append(Entry(id: "s:diff", group: .session, symbol: "plus.forwardslash.minus", title: tr("palette.diff"),
                             command: "diff.toggle") { run("diff.toggle") })
        }
        if actions.localFolder != nil {
            out.append(Entry(id: "s:editor", group: .session, symbol: "chevron.left.forwardslash.chevron.right",
                             title: tr("palette.openInEditor"), detail: current.folder, command: "session.openInEditor") {
                _ = actions.openInEditor(); return false
            })
        }
        if let branch = current.branch, !branch.isEmpty {
            out.append(Entry(id: "s:branch", group: .session, symbol: "arrow.triangle.branch", title: tr("inbox.copy.branch"),
                             detail: branch) { actions.copy(branch); return false })
        }
        if !current.path.isEmpty {
            out.append(Entry(id: "s:path", group: .session, symbol: "doc.on.doc", title: tr("inbox.copy.path"),
                             detail: current.path) { actions.copy(current.path); return false })
        }
        out.append(Entry(id: "s:reference", group: .session, symbol: "link", title: tr("palette.copyReference"),
                         command: "session.copyReference") { _ = actions.copyReference(); return false })
        // The open session's title, written again.
        if current.id.hasPrefix("run:"), let id = UUID(uuidString: String(current.id.dropFirst(4))), app.workspace.run(id) != nil {
            out.append(Entry(id: "s:retitle", group: .session, symbol: "wand.and.stars", title: tr("ws.title.regenerate")) {
                app.workspace.regenerateTitle(id); return false
            })
        }
        // The open session's agent starts again in the same conversation, so new skills, plugins and MCP servers count.
        if current.id.hasPrefix("run:"), let id = UUID(uuidString: String(current.id.dropFirst(4))),
           app.workspace.canRestartAgent(id) {
            out.append(Entry(id: "s:restartAgent", group: .session, symbol: "arrow.clockwise", title: tr("agents.restartAgent")) {
                app.workspace.restartAgent(id); return false
            })
        }
        if actions.canInterrupt {
            out.append(Entry(id: "s:interrupt", group: .session, symbol: "stop.circle", title: tr("palette.interrupt"),
                             command: "session.interrupt") { _ = actions.interrupt(); return false })
        }
        return out
    }

    private var navigationEntries: [Entry] {
        var out: [Entry] = [
            Entry(id: "n:new", group: .navigation, symbol: "square.and.pencil", title: tr("agents.newSession"),
                  command: "session.new") { viewModel.selectedAgentID = "new"; return false },
            Entry(id: "n:newIn", group: .navigation, symbol: "folder.badge.plus", title: tr("palette.newSessionIn")) {
                choosingProject = true
                query = ""
                return true
            },
        ]
        if SessionHistory.shared.trail.canGoBack {
            out.append(Entry(id: "n:back", group: .navigation, symbol: "chevron.left", title: tr("palette.back"),
                             command: "session.back") { run("session.back") })
        }
        if SessionHistory.shared.trail.canGoForward {
            out.append(Entry(id: "n:forward", group: .navigation, symbol: "chevron.right", title: tr("palette.forward"),
                             command: "session.forward") { run("session.forward") })
        }
        out += [
            Entry(id: "n:search", group: .navigation, symbol: "magnifyingglass", title: tr("keys.command.search.toggle"),
                  command: "search.toggle") { run("search.toggle") },
            Entry(id: "n:pulls", group: .navigation, symbol: PullRequestIcon.generic, title: tr("agents.footer.pullRequests")) {
                viewModel.selectedAgentID = AgentsPage.pullRequests; return false
            },
            Entry(id: "n:actions", group: .navigation, symbol: "play.circle", title: tr("actions.title"), detail: tr("actions.footerHint")) {
                viewModel.selectedAgentID = AgentsPage.actions; return false
            },
            Entry(id: "n:terminals", group: .navigation, symbol: "terminal", title: tr("agents.footer.terminals")) {
                viewModel.selectedAgentID = AgentsPage.terminals; return false
            },
            Entry(id: "n:browser", group: .navigation, symbol: "globe", title: tr("agents.footer.browser")) {
                viewModel.selectedAgentID = AgentsPage.browser; return false
            },
            Entry(id: "n:simulator", group: .navigation, symbol: "iphone", title: tr("agents.footer.simulator")) {
                viewModel.selectedAgentID = AgentsPage.simulator; return false
            },
            Entry(id: "n:worktrees", group: .navigation, symbol: "arrow.triangle.branch", title: tr("agents.footer.worktrees")) {
                viewModel.selectedAgentID = AgentsPage.worktrees; return false
            },
        ]
        // The panels, where the open page has them.
        for (command, symbol) in [("sidebar.toggle", "sidebar.left"), ("terminal.toggle", "terminal"),
                                  ("sidePanel.toggle", "sidebar.right"), ("sessionPanel.toggle", "list.bullet.rectangle")] where offers(command) {
            out.append(Entry(id: "n:" + command, group: .navigation, symbol: symbol, title: tr("keys.command." + command),
                             command: command) { run(command) })
        }
        return out
    }

    private var settingsEntries: [Entry] {
        [
            Entry(id: "x:settings", group: .settings, symbol: "gearshape", title: tr("agents.footer.settings")) {
                app.openSettings(); return false
            },
            Entry(id: "x:shortcuts", group: .settings, symbol: "keyboard", title: tr("palette.shortcuts")) {
                app.openSettings(section: .shortcuts); return false
            },
            Entry(id: "x:usage", group: .settings, symbol: "chart.bar", title: tr("agents.footer.usage")) {
                app.usageModalOpen = true; return false
            },
            Entry(id: "x:triage", group: .settings, symbol: "stethoscope", title: tr("palette.triage")) {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                PromptLinkInbox.shared.pending = PromptLink(text: NookTriage.prompt(version: version, supportFolder: NookPaths.supportDirectory.path))
                viewModel.selectedAgentID = "new"
                return false
            },
        ]
    }

    /// "New session in…": your favorite projects, then the recent ones.
    private var projectEntries: [Entry] {
        let settings = app.workspace.settings
        var seen = Set<String>()
        let paths = (settings.favoriteProjects + settings.recentProjects)
            .filter { seen.insert($0).inserted && !settings.isArchivedProject($0) }
        return paths.map { path in
            Entry(id: "p:" + path, group: .projects, symbol: "folder", title: URL(fileURLWithPath: path).lastPathComponent,
                  detail: AgentPathFormat.tilde(path)) {
                PromptLinkInbox.shared.requestProject(path)
                viewModel.selectedAgentID = "new"
                return false
            }
        }
    }

    // MARK: Commands

    private func offers(_ command: String) -> Bool {
        KeyCommandCenter.shared.offers(command, in: NSApp.keyWindow)
    }

    /// Runs a keybinding command as its key would; the palette closes first, so the command acts on the page under it.
    private func run(_ command: String) -> Bool {
        let window = NSApp.keyWindow
        DispatchQueue.main.async { KeyCommandCenter.shared.run(command, in: window) }
        return false
    }

    private func shortcut(_ command: String?) -> String? {
        guard let command else { return nil }
        return Keybindings.chords(for: command, rules: KeyCommandCenter.shared.rules).first?.symbols
    }

    // MARK: View

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            NookSearchField(prompt: choosingProject ? tr("palette.projects.placeholder") : tr("palette.placeholder"),
                            text: $query, style: .large, focus: $focused,
                            onSubmit: { perform(list) }, onEscape: escape)
                .padding(.horizontal, NookTheme.Spacing.xs)
            NookDivider()
            if list.isEmpty {
                ListEmptyNote(choosingProject ? tr("palette.projects.none") : tr("palette.none"), padding: NookTheme.Spacing.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { offset, entry in
                                if offset == 0 || list[offset - 1].group != entry.group {
                                    NookSectionLabel(entry.group.title, inset: NookTheme.Spacing.md)
                                        .padding(.top, offset == 0 ? NookTheme.Spacing.xxs : NookTheme.Spacing.sm)
                                        .padding(.bottom, NookTheme.Spacing.xxs)
                                }
                                row(entry, selected: offset == index)
                                    .id(entry.id)
                                    // The pointer and the arrow keys share one highlighted row.
                                    .onHover { if $0 { index = offset } }
                                    .onTapGesture { index = offset; perform(list) }
                            }
                        }
                        .padding(NookTheme.Spacing.sm)
                    }
                    .frame(maxHeight: 360)
                    // The arrow keys keep the highlighted row in view; a row the pointer moved to is already in view.
                    .onChange(of: index) { _, value in
                        guard list.indices.contains(value) else { return }
                        withAnimation(NookTheme.scroll) { proxy.scrollTo(list[value].id) }
                    }
                }
            }
        }
        // As wide as a narrow tab allows, never wider than the usual 480.
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 480)
        .cardBackground(NookTheme.graphite, stroke: NookTheme.line2, radius: NookTheme.Radius.sheet)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .padding(.horizontal, NookTheme.Spacing.lg)
        .focusOnAppear($focused)
        .onChange(of: query) { _, _ in index = 0 }
        .onChange(of: choosingProject) { _, _ in index = 0 }
        .onWindowKeyDown { event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
            switch Int(event.keyCode) {
            case kVK_DownArrow: index = min(index + 1, max(0, list.count - 1))
            case kVK_UpArrow: index = max(index - 1, 0)
            case kVK_Escape: escape()
            default: return false
            }
            return true
        }
    }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            NookSymbol(entry.symbol, size: 13).font(NookTheme.font(12, .medium)).frame(width: 18)
                .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
            Text(entry.title).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
            if !entry.detail.isEmpty {
                Text(entry.detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let keys = shortcut(entry.command) { NookKeyHint(text: keys) }
            if entry.id == "n:newIn" {
                Image(icon: "chevron.right").font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .roundedBackground(selected ? NookTheme.smoke : .clear, radius: NookTheme.Radius.control)
        .contentShape(Rectangle())
    }

    /// Escape: back from the list of projects, else closes.
    private func escape() {
        if choosingProject {
            choosingProject = false
            query = ""
        } else {
            close()
        }
    }

    private func perform(_ list: [Entry]) {
        guard list.indices.contains(index) else { return }
        if !list[index].run() { close() }
    }
}
