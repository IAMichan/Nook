import SwiftUI
import AppKit

// Rich composer behavior: a list under the text for `/`, `@` and `#`, references that sit in the
// message as links, history on the arrow keys, big pastes kept out of the box. The box itself is `SessionComposer`; the
// chat and the agents both use it and differ only in what they put in `ComposerConfig` and in the choices row.

/// A line in the list under the text.
struct ComposerSuggestion: Identifiable, Equatable {
    enum Payload: Equatable {
        case command(ComposerCommand)
        case ref(ContextRef)
        /// A set-aside draft, by position.
        case stash(Int)
    }

    let id: String
    var title: String
    var detail: String?
    var symbol: String
    var payload: Payload
}

/// What a composer can do beyond typing. The chat leaves references off (its question goes to the brain as plain text);
/// an agent gets files, other sessions and pull requests.
struct ComposerConfig {
    /// The composer's own tint: the send button, the focus ring and the list. Nook's iris for the chat, the agent's color.
    var tint: Color = NookTheme.iris
    /// The folder `@` searches for files; nil turns `@` off.
    var fileRoot: String?
    /// "owner/repo": lets `#12` become a pull request reference.
    var repository: String?
    /// Other sessions `@` can point at (id and title).
    var sessions: () -> [(id: String, title: String)] = { [] }
    var commands: [ComposerCommand] = []
    var onCommand: (ComposerCommand) -> Void = { _ in }
    /// The agent's skills for `$` (named in the text; the agent loads them itself).
    var skills: [Skill] = []
    /// Open pull requests of the repository, for `#` (asked on demand).
    var pullRequests: ((String) async -> [(number: Int, title: String)])? = nil
    /// Apps that open inside Nook, for `@` in the chat ("@open WhatsApp"): id, title and symbol.
    var apps: [(id: String, title: String, symbol: String)] = []
    /// WhatsApp chats for "@open chat …", newest first: name and a short line about it ("2 new").
    var chats: () -> [(name: String, detail: String)] = { [] }
    /// Big pastes become a reference instead of filling the box.
    var keepsBigPastes = false

    var referencesEnabled: Bool { fileRoot != nil || repository != nil || !skills.isEmpty }
}

/// The state behind one composer: the list, the history and the text kept out of the box. A call site owns it with
/// `@StateObject` and passes what you send through `outgoing`.
@MainActor
final class ComposerModel: ObservableObject {
    @Published private(set) var suggestions: [ComposerSuggestion] = []
    @Published var selection = 0
    var history = PromptHistory()
    /// Drafts set aside with Cmd+S; the call site keeps them across launches.
    var stash = PromptStash()
    var onStashChanged: (() -> Void)?
    private(set) var excerpts: [String: String] = [:]
    private var search: Task<Void, Never>?
    private var trigger: ComposerTrigger?
    /// The text was just set by the composer itself (history, a chosen line): the change is not typing.
    var applying = false

    struct Outgoing: Equatable {
        /// What the agent receives: references as short markers plus the context envelope. The timeline and the queue show
        /// `ContextRefs.visible(send)`.
        var send: String
    }

    var isOpen: Bool { !suggestions.isEmpty }

    /// Takes the text you send: remembers it for ArrowUp and turns references into what the agent receives.
    func outgoing(_ text: String) -> Outgoing {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        history.record(clean)
        let sent = ContextRefs.project(clean, excerpts: excerpts)
        excerpts = [:]
        close()
        return Outgoing(send: sent)
    }

    func close() {
        search?.cancel()
        suggestions = []
        selection = 0
        trigger = nil
    }

    func keep(_ id: String, text: String) { excerpts[id] = text }

    // MARK: Suggestions

    /// Looks at the end of the text and fills the list.
    func update(for text: String, _ config: ComposerConfig) {
        search?.cancel()
        // "@open chat Ja…": the chats whose name fits, so you choose the right one; choosing fills in its whole name.
        if let query = EmbeddedAppCatalog.chatQuery(in: text), case let chats = config.chats(), !chats.isEmpty {
            let names = EmbeddedAppCatalog.chatMatches(query, in: chats.map(\.name))
            guard !names.isEmpty else { return close() }
            trigger = ComposerTrigger(kind: .mention, query: query, token: text)
            return publish(names.map { name in
                let insertion = "@open chat " + name
                return ComposerSuggestion(id: "chat:" + name, title: name, detail: chats.first { $0.name == name }?.detail,
                                          symbol: "bubble.left.and.bubble.right.fill",
                                          payload: .command(ComposerCommand(name: "chat:" + name, insertion: insertion, action: .insert)))
            })
        }
        // "@open whats": the app list stays open past the space after "@open" and filters by the name typed after it.
        if !config.apps.isEmpty, let query = EmbeddedAppCatalog.openQuery(in: text) {
            trigger = ComposerTrigger(kind: .mention, query: query, token: text)
            return publish(appRows(query, config))
        }
        guard let found = ComposerTrigger.detect(in: text) else { return close() }
        trigger = found
        switch found.kind {
        case .command:
            let matches = ComposerCommand.filter(config.commands, query: found.query)
            publish(matches.map { command in
                ComposerSuggestion(id: "cmd:" + command.name, title: "/" + command.name, detail: commandDetail(command),
                                   symbol: "slash.circle", payload: .command(command))
            })
        case .mention:
            if !config.apps.isEmpty {
                return publish(appRows(EmbeddedAppCatalog.mentionQuery(found.query), config))
            }
            guard config.fileRoot != nil || !config.sessions().isEmpty else { return close() }
            let query = found.query
            let sessions = config.sessions().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(3).map { session in
                ComposerSuggestion(id: "session:" + session.id, title: session.title, detail: tr("compose.ref.session"),
                                   symbol: "bubble.left.and.text.bubble.right",
                                   payload: .ref(ContextRef(kind: .session, id: session.id, label: session.title)))
            }
            guard let root = config.fileRoot else { return publish(Array(sessions)) }
            search = Task { [weak self] in
                let files = await Task.detached(priority: .userInitiated) { FileSearch.search(root: root, query: query) }.value
                guard !Task.isCancelled, let self else { return }
                let rows = files.map { path in
                    ComposerSuggestion(id: "file:" + path, title: URL(fileURLWithPath: path).lastPathComponent, detail: path,
                                       symbol: "doc", payload: .ref(ContextRef(kind: .file, id: path,
                                                                                label: URL(fileURLWithPath: path).lastPathComponent)))
                }
                self.publish(rows + Array(sessions))
            }
        case .pullRequest:
            guard let repo = config.repository else { return close() }
            let query = found.query
            // Typing a number is enough; the open pull requests of the repository are added when GitHub is connected.
            var typed: [ComposerSuggestion] = []
            if let number = Int(query), number > 0 {
                typed = [pullRequestRow(repo: repo, number: number, title: nil)]
            }
            publish(typed)
            guard let load = config.pullRequests else { return }
            search = Task { [weak self] in
                let all = await load(repo)
                guard !Task.isCancelled, let self else { return }
                let rows = PullRequestMatch.filter(all, query: query).map { self.pullRequestRow(repo: repo, number: $0.number, title: $0.title) }
                let known = Set(rows.map(\.id))
                self.publish(rows + typed.filter { !known.contains($0.id) })
            }
        case .skill:
            let rows = SkillIndex.filter(config.skills, query: found.query).map { skill in
                ComposerSuggestion(id: "skill:" + skill.name, title: "$" + skill.name, detail: skill.description.isEmpty ? nil : skill.description,
                                   symbol: "wand.and.stars", payload: .ref(ContextRef(kind: .skill, id: skill.name, label: skill.name)))
            }
            publish(rows)
        }
    }

    /// "@open WhatsApp" as a line to choose, and "@open WhatsApp web" under a Mac app: Return puts it in the box, Return
    /// again opens it.
    private func appRows(_ query: String, _ config: ComposerConfig) -> [ComposerSuggestion] {
        let rows = EmbeddedAppCatalog.openSuggestions(for: query).compactMap { match in
            config.apps.first { $0.id == match.app.id }.map { (app: $0, web: match.mode == .web) }
        }
        // "@open chat" first, when there are chats to open: choosing it lists them.
        let typed = query.lowercased()
        var chat: [ComposerSuggestion] = []
        if typed.isEmpty || "chat".hasPrefix(typed) || "whatsapp".hasPrefix(typed), !config.chats().isEmpty {
            chat = [ComposerSuggestion(id: "chat", title: "@open chat", detail: tr("whatsapp.open.mentionDetail"),
                                       symbol: "bubble.left.and.bubble.right.fill",
                                       payload: .command(ComposerCommand(name: "chat", insertion: "@open chat", action: .insert)))]
        }
        return chat + rows.prefix(10).map { row -> ComposerSuggestion in
            let insertion = "@open " + row.app.title + (row.web ? " web" : "")
            let detail = row.web ? tr("embedded.mode.web") : row.app.id.hasPrefix("mac:") ? tr("embedded.mentionDetailMac") : tr("embedded.mentionDetail")
            return ComposerSuggestion(id: "app:" + row.app.id + (row.web ? ":web" : ""), title: insertion, detail: detail,
                                      symbol: row.web ? "globe" : row.app.symbol,
                                      payload: .command(ComposerCommand(name: row.app.id, insertion: insertion, action: .insert)))
        }
    }

    private func commandDetail(_ command: ComposerCommand) -> String? { tr(AgentCommands.descriptionKey(for: command)) }

    private func pullRequestRow(repo: String, number: Int, title: String?) -> ComposerSuggestion {
        ComposerSuggestion(id: "pr:\(number)", title: "#\(number)" + (title.map { " " + $0 } ?? ""), detail: repo, symbol: "arrow.triangle.pull",
                           payload: .ref(ContextRef(kind: .pullRequest, id: "\(repo)#\(number)", label: "\(number)")))
    }

    // MARK: Stash

    /// Cmd+S: set the draft aside, bring one back, or choose from several. Returns the new text for the box.
    func stashKey(composerText: String) -> String? {
        switch StashAction.decide(composerText: composerText, stashCount: stash.entries.count) {
        case .stash:
            _ = stash.push(composerText)
            return ""
        case .restoreOnly:
            return stash.pop() ?? composerText
        case .openMenu:
            suggestions = stash.entries.enumerated().reversed().map { index, entry in
                ComposerSuggestion(id: "stash:\(index)", title: entry.title, detail: tr("compose.stash.detail"), symbol: "tray.and.arrow.up",
                                   payload: .stash(index))
            }
            selection = 0
            trigger = nil
            return nil
        case .nothing:
            return nil
        }
    }

    private func publish(_ rows: [ComposerSuggestion]) {
        suggestions = rows
        selection = 0
    }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selection = (selection + delta + suggestions.count) % suggestions.count
    }

    /// The text after choosing a line: a command runs or fills the box, a reference becomes a link.
    func accept(_ suggestion: ComposerSuggestion, in text: String, _ config: ComposerConfig) -> String {
        if case .stash(let index) = suggestion.payload {
            defer { close() }
            let restored = stash.restore(at: index) ?? text
            onStashChanged?()
            return restored
        }
        guard let trigger else { return text }
        defer { close() }
        switch suggestion.payload {
        case .stash:
            return text
        case .command(let command):
            if command.action == .insert { return trigger.replacing(in: text, with: command.insertion) }
            config.onCommand(command)
            return String(text.dropLast(trigger.token.count)).trimmingCharacters(in: .whitespaces)
        case .ref(let ref):
            return trigger.replacing(in: text, with: ContextRefs.link(ref))
        }
    }

    /// A paste that was too big for the box: keep it aside and put a reference in its place.
    func keepPaste(old: String, new: String) -> String? {
        guard new.utf8.count - old.utf8.count >= PasteRule.attachThreshold,
              let parts = PasteRule.split(old: old, new: new), PasteRule.shouldAttach(parts.inserted) else { return nil }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        excerpts[id] = parts.inserted
        let ref = ContextRef(kind: .paste, id: id, label: PasteRule.fileName(for: parts.inserted))
        return parts.prefix + ContextRefs.link(ref) + parts.suffix
    }
}

/// The list under the text.
struct ComposerSuggestionList: View {
    @ObservedObject var model: ComposerModel
    let tint: Color
    let accept: (ComposerSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, row in
                Button { accept(row) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol)
                            .font(NookTheme.font(11, .medium))
                            .foregroundStyle(index == model.selection ? tint : NookTheme.textTertiary)
                            .frame(width: 16)
                        Text(row.title)
                            .font(NookTheme.font(12.5, .medium))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(index == model.selection ? tint.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .cardBackground(SessionComposer<EmptyView>.surface, stroke: NookTheme.line2, radius: 14, style: .continuous)
        .accessibilityElement(children: .contain)
    }
}

/// The plus menu, the same in the chat and with an agent: what you add to a message first, the rest of the session after.
struct ComposerPlusMenu<Extra: View>: View {
    var attachLabel = tr("chat.attachShort")
    let attach: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            Button(action: attach) { Label(attachLabel, systemImage: "paperclip") }
            extra()
        } label: {
            ComposerIcon(symbol: "plus")
        }
        .composerMenu()
        .help(tr("chat.more"))
        .accessibilityLabel(tr("chat.more"))
    }
}

/// A file you pick for a message to an agent: it becomes a reference in the text, the agent reads it itself.
@MainActor
enum ComposerFilePicker {
    static func pick(startingIn folder: String) -> ContextRef? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let base = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        return ContextRef(kind: .file, id: relative, label: url.lastPathComponent)
    }
}

/// The microphone of the agents' composer: you speak, the words appear in the box, you send when you are ready. (The chat's
/// microphone asks Nook straight away and speaks the answer back; both sit in the same place.)
struct ComposerMic: View {
    @EnvironmentObject private var app: AppModel
    @Binding var text: String
    @State private var listening = false

    var body: some View {
        NookIconButton(systemName: listening ? "mic.fill" : "mic", label: tr("button.talk"), size: 30) { toggle() }
    }

    private func join(_ base: String, _ spoken: String) -> String {
        let clean = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return clean }
        return clean.isEmpty ? base : base + " " + clean
    }

    private func toggle() {
        if listening {
            app.voice.finishNow()
            return
        }
        Task { @MainActor in
            guard await app.voice.requestPermissions() else { return }
            app.wake.stop()
            app.speech.stop()
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            listening = true
            do {
                try app.voice.start(
                    onPartial: { partial in text = join(base, partial) },
                    onFinish: { final in
                        text = join(base, final)
                        listening = false
                        app.updateWakeWord()
                    }
                )
            } catch {
                listening = false
            }
        }
    }
}

/// How full the agent's context window is: a small ring that starts at the top and turns coral above 90 %.
/// Hover says how much; a button asks the agent to summarize when it can.
struct ComposerContextRing: View {
    let used: Int
    let window: Int
    var onCompact: (() -> Void)? = nil
    @State private var open = false

    private var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }

    var body: some View {
        let level = ContextMeter.level(fraction)
        let tint: Color = level == .critical ? NookTheme.coral : (level == .warning ? NookTheme.amber : NookTheme.textSecondary)
        Button { open.toggle() } label: {
            ZStack {
                Circle().stroke(NookTheme.line2, lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("compose.context.help", ContextMeter.percentText(fraction), ContextMeter.tokensText(used: used, window: window)))
        .accessibilityLabel(tr("compose.context.help", ContextMeter.percentText(fraction), ContextMeter.tokensText(used: used, window: window)))
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("compose.context.title")).font(NookTheme.font(12.5, .semibold))
                ProgressView(value: fraction).tint(tint)
                Text(tr("compose.context.detail", ContextMeter.percentText(fraction), ContextMeter.tokensText(used: used, window: window)))
                    .font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textSecondary)
                if let onCompact {
                    Button(tr("compose.context.compact")) { open = false; onCompact() }
                } else {
                    Text(tr("compose.context.noCompact")).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(12)
            .frame(width: 240)
        }
    }
}
