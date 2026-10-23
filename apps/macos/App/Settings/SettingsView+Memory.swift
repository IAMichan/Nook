import SwiftUI

/// Settings › Memory: what Nook remembers about you, how it learns, and bringing over the old MCP memory server.
/// Memory is built in: nothing to install, nothing leaves the Mac except, with an external brain, the few memories
/// that matter for a question (and never the ones kept on this Mac).
struct MemorySettingsSection: View {
    /// A knowledge graph of the MCP memory server found on this Mac.
    struct ImportFile: Identifiable {
        let url: URL
        let count: Int
        var id: URL { url }
    }

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var servers = MCPServerStore.shared
    @State private var search = ""
    @State private var draft = ""
    @State private var draftProblem: String?
    @State private var editing: String?
    @State private var editText = ""
    /// Why the edited text cannot be kept; the field stays open until it can.
    @State private var editProblem: String?
    @State private var confirmClear = false
    @State private var importable: [ImportFile] = []
    @State private var imported: Int?

    var body: some View {
        Group {
            Section {
                IntroCard(
                    title: tr("memory.hero.title"),
                    text: tr("memory.hero.detail")
                )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))

            Section(tr("memory.settings.how")) {
                SettingToggle(tr("memory.settings.use"), detail: tr("memory.settings.useDetail"), isOn: $settings.useMemory)
                SettingToggle(tr("memory.settings.learn"), detail: tr("memory.settings.learnDetail"), isOn: $settings.learnFromChats)
                    .disabled(!settings.useMemory)
                if settings.localOnlySources.contains(SourceCatalog.memory) {
                    Label(tr("memory.settings.localOnlyAll"), systemImage: "lock.fill")
                        .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !importable.isEmpty || oldServer != nil || imported != nil {
                importSection
            }

            Section {
                HStack {
                    TextField(tr("memory.settings.addPlaceholder"), text: $draft)
                        .onSubmit(add)
                    Button(tr("memory.settings.add"), action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let draftProblem {
                    SettingNote(draftProblem, tone: .warning)
                }
                if app.memory.items.count > 6 {
                    NookSearchField(prompt: tr("memory.settings.search"), text: $search, style: .inline)
                }
                if visible.isEmpty {
                    SettingNote(app.memory.items.isEmpty ? tr("memory.settings.empty") : tr("memory.settings.noMatch"))
                }
                ForEach(MemoryItem.Kind.allCases, id: \.self) { kind in
                    let group = visible.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Text(tr("memory.kind.\(kind.rawValue)"))
                            .font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                            .padding(.top, NookTheme.Spacing.sm)
                        ForEach(group) { item in row(item) }
                    }
                }
            } header: {
                Text(tr("memory.settings.list", app.memory.items.count))
            } footer: {
                Text(tr("memory.settings.listFooter"))
            }

            Section {
                LabeledContent(tr("memory.settings.sources")) {
                    Text(tr("memory.settings.sourcesValue", app.memory.learnedWords)).foregroundStyle(NookTheme.textSecondary)
                }
                Button(tr("memory.settings.clear"), role: .destructive) { confirmClear = true }
                    .disabled(app.memory.items.isEmpty && app.memory.learnedWords == 0)
            } footer: {
                Text(tr("memory.settings.privacyFooter"))
            }
        }
        .onAppear { importable = app.memory.importable().map { ImportFile(url: $0.url, count: $0.count) } }
        .confirmationDialog(tr("memory.settings.clearConfirm"), isPresented: $confirmClear) {
            Button(tr("memory.settings.clear"), role: .destructive) {
                app.memory.clear()
                app.store.audit(tool: "geheugen_gewist", args: "", result: "")
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("memory.settings.clearDetail"))
        }
    }

    // MARK: Parts

    /// The memories that match the search, strongest first.
    private var visible: [MemoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.memory.items
            .filter { query.isEmpty || $0.text.lowercased().contains(query) || $0.subject.lowercased().contains(query) }
            .sorted { ($0.pinned ? 1 : 0, $0.currentStrength()) > ($1.pinned ? 1 : 0, $1.currentStrength()) }
    }

    /// The MCP memory server a user added before memory was built in, if it is still there.
    private var oldServer: MCPServerConfig? {
        servers.servers.first { config in
            if case .stdio(let command, let arguments) = config.transport {
                return ([command] + arguments).joined(separator: " ").contains("server-memory")
            }
            return false
        }
    }

    private var importSection: some View {
        Section {
            ForEach(importable) { file in
                HStack {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(tr("memory.import.found", file.count))
                        Text(file.url.path).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(tr("memory.import.button")) {
                        let count = app.memory.importGraph(file.url)
                        imported = (imported ?? 0) + count
                        importable.removeAll { $0.url == file.url }
                        app.store.audit(tool: "geheugen_geimporteerd", args: file.url.lastPathComponent, result: "\(count)")
                    }
                }
            }
            if let imported {
                SettingNote(tr("memory.import.done", imported), tone: .success)
            }
            if let oldServer {
                HStack {
                    Text(tr("memory.import.oldServer", oldServer.name)).font(NookTheme.TextStyle.body)
                    Spacer()
                    ConfirmedButton(tr("memory.import.removeServer"), question: tr("confirm.remove", oldServer.name)) { servers.remove(oldServer.id) }
                }
            }
        } header: {
            Text(tr("memory.import.title"))
        } footer: {
            Text(tr("memory.import.footer"))
        }
    }

    /// A memory: its text and where it came from; edit, pin, keep on this Mac and delete show under the pointer, with a
    /// pin and a lock at rest when those are on.
    private func row(_ item: MemoryItem) -> some View {
        HoverActionsRow(keepActions: editing == item.id) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                if editing == item.id {
                    TextField("", text: $editText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitEdit(item) }
                        .onExitCommand {
                            editing = nil
                            editProblem = nil
                        }
                    if let editProblem {
                        SettingNote(editProblem, tone: .warning)
                    }
                } else {
                    Text(Self.display(item)).textSelection(.enabled)
                }
                Text(caption(item)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
        } idle: {
            if item.pinned { Image(systemName: "pin.fill").font(NookTheme.font(10)) }
            if item.localOnly { Image(systemName: "lock.fill").font(NookTheme.font(10)) }
        } actions: {
            Button {
                if editing == item.id {
                    commitEdit(item)
                } else {
                    editText = Self.display(item)
                    editProblem = nil
                    editing = item.id
                }
            } label: {
                Image(systemName: editing == item.id ? "checkmark" : "pencil")
            }
            .help(tr("memory.settings.edit"))
            .accessibilityLabel(tr("memory.settings.edit"))
            Button { app.memory.setPinned(item.id, !item.pinned) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .help(tr(item.pinned ? "memory.settings.unpin" : "memory.settings.pin"))
            .accessibilityLabel(tr(item.pinned ? "memory.settings.unpin" : "memory.settings.pin"))
            Button { app.memory.setLocalOnly(item.id, !item.localOnly) } label: {
                Image(systemName: item.localOnly ? "lock.fill" : "lock.open")
            }
            .help(tr(item.localOnly ? "memory.settings.shareable" : "memory.settings.localOnly"))
            .accessibilityLabel(tr(item.localOnly ? "memory.settings.shareable" : "memory.settings.localOnly"))
            ConfirmedButton(symbol: "trash", title: tr("memory.settings.delete"), question: tr("confirm.remove", Self.display(item))) {
                app.memory.delete(item.id)
            }
            .labelled(tr("memory.settings.delete"))
        }
        .buttonStyle(.borderless)
    }

    /// Keeps the edited text, or leaves the field open with the reason when Nook would not keep it.
    private func commitEdit(_ item: MemoryItem) {
        // The same check `NookMemory.edit` makes on the cleaned text, so a rejected edit never closes silently.
        let cleaned = MemoryText.clean(editText)
        if let reason = MemoryText.problem(cleaned) {
            editProblem = tr("memory.rejected." + reason)
            return
        }
        if cleaned.isEmpty { return }
        app.memory.edit(item.id, text: editText)
        editProblem = nil
        editing = nil
    }

    /// A habit reads as a sentence for the user; everything else as Nook stored it.
    static func display(_ item: MemoryItem) -> String {
        if let tool = item.tool, let field = item.field, let value = item.value {
            return tr("memory.habit", value, field, tool)
        }
        return item.text
    }

    private func caption(_ item: MemoryItem) -> String {
        var parts = [tr("memory.origin.\(item.origin.rawValue)"), NookDates.ago(item.updated)]
        if item.isHabit { parts.append(tr("memory.settings.seen", item.evidence)) }
        if item.origin == .learned || item.origin == .observed {
            parts.append(tr("memory.settings.strength", Int((item.currentStrength() * 100).rounded())))
        }
        if item.uses > 0 { parts.append(tr("memory.settings.used", item.uses)) }
        if !item.subject.isEmpty { parts.append(item.subject) }
        return parts.joined(separator: " · ")
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let kind: MemoryItem.Kind = MemoryRequest.asksToRemember(text) || text.lowercased().hasPrefix("voortaan") ? .preference : .fact
        switch app.memory.remember(text, kind: kind, origin: .told) {
        case .rejected(let reason):
            draftProblem = tr("memory.rejected." + reason)
        default:
            draftProblem = nil
            draft = ""
        }
    }
}
