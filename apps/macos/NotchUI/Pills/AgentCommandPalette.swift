import SwiftUI

/// ⌘K in the Agents tab: one field to jump to a session or run an action. Typing filters;
/// ↑/↓ move, Return runs, Esc closes. Sessions match on title, folder and branch.
struct AgentCommandPalette: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var viewModel: NotchViewModel
    let close: () -> Void

    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let run: () -> Void
    }

    private var entries: [Entry] {
        var actions: [Entry] = [
            Entry(id: "act:new", symbol: "square.and.pencil", title: tr("agents.newSession"), detail: "") { viewModel.selectedAgentID = "new" },
            Entry(id: "act:pulls", symbol: "arrow.triangle.pull", title: tr("agents.footer.pullRequests"), detail: "") { viewModel.selectedAgentID = AgentsPage.pullRequests },
            Entry(id: "act:usage", symbol: "chart.bar", title: tr("agents.footer.usage"), detail: "") { viewModel.selectedAgentID = AgentsPage.usage },
            Entry(id: "act:terminals", symbol: "terminal", title: tr("agents.footer.terminals"), detail: "") { viewModel.selectedAgentID = AgentsPage.terminals },
            Entry(id: "act:browser", symbol: "globe", title: tr("agents.footer.browser"), detail: "") { viewModel.selectedAgentID = AgentsPage.browser },
            Entry(id: "act:simulator", symbol: "iphone", title: tr("agents.footer.simulator"), detail: "") { viewModel.selectedAgentID = AgentsPage.simulator },
            Entry(id: "act:worktrees", symbol: "arrow.triangle.branch", title: tr("agents.footer.worktrees"), detail: "") { viewModel.selectedAgentID = AgentsPage.worktrees },
            Entry(id: "act:settings", symbol: "gearshape", title: tr("agents.footer.settings"), detail: "") { app.openSettings() },
        ]
        let sessions = app.workspace.runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(40).map { run in
            Entry(id: "run:" + run.id.uuidString, symbol: "bubble.left.and.text.bubble.right", title: run.title,
                  detail: [run.provider.displayName, URL(fileURLWithPath: run.workingDirectory).lastPathComponent, run.branch ?? ""]
                      .filter { !$0.isEmpty }.joined(separator: " · ")) { viewModel.selectedAgentID = "run:" + run.id.uuidString }
        }
        let all = actions + sessions
        // `>` limits to actions.
        var text = query.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(">") {
            text.removeFirst()
            actions = actions.filter { matches($0, text.trimmingCharacters(in: .whitespaces)) }
            return actions
        }
        return text.isEmpty ? Array(all.prefix(12)) : all.filter { matches($0, text) }.prefix(12).map { $0 }
    }

    private func matches(_ entry: Entry, _ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return text.split(separator: " ").allSatisfy { token in
            entry.title.range(of: token, options: options) != nil || entry.detail.range(of: token, options: options) != nil
        }
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NookTheme.textTertiary)
                TextField(tr("palette.placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(14))
                    .foregroundStyle(NookTheme.paper)
                    .focused($focused)
                    .onSubmit { run(list) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(NookTheme.line2).frame(height: 1)
            if list.isEmpty {
                Text(tr("palette.none")).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary).padding(16)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { offset, entry in
                            row(entry, selected: offset == index)
                                .onTapGesture { index = offset; run(list) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NookTheme.graphite))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NookTheme.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
            Text(entry.title).font(NookTheme.font(13.5, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
            if !entry.detail.isEmpty {
                Text(entry.detail).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? NookTheme.smoke : .clear))
        .contentShape(Rectangle())
    }

    private func run(_ list: [Entry]) {
        guard list.indices.contains(index) else { return }
        list[index].run()
        close()
    }
}
