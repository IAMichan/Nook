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
    /// The composer's own tint: the send button, the focus ring and the list. Nook's quiet iris everywhere; an agent's color
    /// stays in its logo.
    var tint: Color = NookTheme.iris
    /// The folder `@` searches for files; nil turns `@` off.
    var fileRoot: String?
    /// "owner/repo": lets `#12` become a pull request reference.
    var repository: String?
    /// Other sessions `@` can point at (id and title).
    var sessions: () -> [(id: String, title: String)] = { [] }
    /// The models `@` can name for the agent (`ModelMention`): every connected agent's.
    var models: () -> [ModelMention.Candidate] = { [] }
    var commands: [ComposerCommand] = []
    var onCommand: (ComposerCommand) -> Void = { _ in }
    /// The agent's skills for `$` (named in the text; the agent loads them itself).
    var skills: [Skill] = []
    /// Open pull requests of the repository, for `#` (asked on demand).
    var pullRequests: ((String) async -> [(number: Int, title: String)])? = nil
    /// Apps that open inside Nook, for `@` in the chat ("@open WhatsApp"): id, title and symbol.
    var apps: [(id: String, title: String, symbol: String)] = []
    /// The chats of every chat app for "@chat …", newest first: name and a short line about it ("Telegram · 2 new").
    var chats: () -> [(name: String, detail: String)] = { [] }
    /// People `@` names in plain text ("@Arjan"): the chats of every chat app, name and a short line about it.
    var people: () -> [(name: String, detail: String)] = { [] }
    /// A file or session chosen under `@` goes in as plain words (its path or title) instead of a link only an agent
    /// reads: for a mail, a commit message, or anything else people read.
    var plainReferences = false
    /// The app open next to the chat, if any: "@close" is offered only then.
    var openApp: () -> String? = { nil }
    /// Big pastes become a reference instead of filling the box.
    var keepsBigPastes = false
    /// Where a pasted secret goes when you keep it out of the message (`SecretFiles` scope: the session's id, or
    /// "composer" before there is one). Nil: no offer, as in a chat with people or a session on another machine.
    var secretScope: String? = nil

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

    /// Keeps the drafts set aside (Cmd+S) in `ComposerDraftStore`, so every composer shares them across launches. A
    /// call site that wired `onStashChanged` itself (the session panel) is left alone.
    func connectStash(_ store: ComposerDraftStore = .shared) {
        guard onStashChanged == nil else { return }
        stash = store.stash
        onStashChanged = { [weak self] in
            guard let self else { return }
            store.setStash(self.stash)
        }
    }
    private(set) var excerpts: [String: String] = [:]
    private var search: Task<Void, Never>?
    private var trigger: ComposerTrigger?
    /// The text was just set by the composer itself (history, a chosen line): the change is not typing.
    var applying = false
    /// The pictures going out with this send, set by `SessionComposer` only while the caller's send runs. `outgoing`
    /// puts their paths below the text, so the box keeps showing your words and the pictures instead of the paths.
    var pictures: [ImageAttachment] = []

    /// Whether there is anything to send: words, or pictures alone.
    func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.isEmpty
    }

    struct Outgoing: Equatable {
        /// What the agent receives: references as short markers plus the context envelope. The timeline and the queue show
        /// `ContextRefs.visible(send)`.
        var send: String
    }

    var isOpen: Bool { !suggestions.isEmpty }

    /// Takes the text you send: remembers it for ArrowUp, turns references into what the agent receives and puts the
    /// paths of the pictures below it (agents read pictures from disk).
    func outgoing(_ text: String) -> Outgoing {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        history.record(clean)
        let projected = ContextRefs.project(ComposerAttachments.spaced(clean), excerpts: excerpts)
        let sent = pictures.isEmpty ? projected : ImageAttachment.appendingPaths(of: pictures, to: projected)
        excerpts = [:]
        pictures = []
        dismissSecretOffer()
        close()
        return Outgoing(send: sent)
    }

    func close() {
        search?.cancel()
        trigger = nil
        // Only publish a real change: close() also runs while SwiftUI updates the view (a disappearing field, a
        // keystroke that opens no list), and publishing there is undefined behavior.
        if !suggestions.isEmpty { suggestions = [] }
        if selection != 0 { selection = 0 }
    }

    func keep(_ id: String, text: String) { excerpts[id] = text }

    // MARK: Suggestions

    /// Looks at the end of the text and fills the list.
    func update(for text: String, _ config: ComposerConfig) {
        search?.cancel()
        // Each list comes from its source once per key: the chats are every inbox thread, sorted.
        let chatQuery = EmbeddedAppCatalog.chatQuery(in: text)
        let chats: [(name: String, detail: String)]? = chatQuery == nil ? nil : config.chats()
        // "@chat Ja…": the chats whose name fits, so you choose the right one; choosing fills in its whole name.
        if let query = chatQuery, let all = chats, !all.isEmpty {
            let names = EmbeddedAppCatalog.chatMatches(query, in: all.map(\.name))
            guard !names.isEmpty else { return close() }
            let details = Dictionary(all.map { ($0.name, $0.detail) }, uniquingKeysWith: { first, _ in first })
            trigger = ComposerTrigger(kind: .mention, query: query, token: text)
            return publish(names.map { name in
                let insertion = "@chat " + name
                return ComposerSuggestion(id: "chat:" + name, title: name, detail: details[name],
                                          symbol: "bubble.left.and.bubble.right.fill",
                                          payload: .command(ComposerCommand(name: "chat:" + name, insertion: insertion, action: .insert)))
            })
        }
        // "@open whats": the app list stays open past the space after "@open" and filters by the name typed after it.
        if !config.apps.isEmpty, let query = EmbeddedAppCatalog.openQuery(in: text) {
            trigger = ComposerTrigger(kind: .mention, query: query, token: text)
            return publish(appRows(query, config, chats: chats))
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
            let query = found.query
            let people = personRows(query, config)
            let known = config.sessions()
            let models = ModelMention.matches(query, in: config.models()).map { candidate in
                ComposerSuggestion(id: "model:" + ModelMention.id(agent: candidate.agent, model: candidate.model),
                                   title: candidate.name, detail: tr("compose.ref.model", candidate.agentName), symbol: "cpu",
                                   payload: .ref(ModelMention.ref(candidate)))
            }
            guard config.fileRoot != nil || !known.isEmpty || !people.isEmpty || !models.isEmpty else { return close() }
            let sessions = known.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(3).map { session in
                ComposerSuggestion(id: "session:" + session.id, title: session.title, detail: tr("compose.ref.session"),
                                   symbol: "bubble.left.and.text.bubble.right",
                                   payload: .ref(ContextRef(kind: .session, id: session.id, label: session.title)))
            }
            guard let root = config.fileRoot else { return publish(people + models + sessions) }
            search = Task { [weak self] in
                // A short pause first, so a word typed after `@` reads the folder once and not once per letter.
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                let all = await FileIndex.shared.paths(root: root)
                guard !Task.isCancelled else { return }
                let files = await Task.detached(priority: .userInitiated) { FileSearch.rank(all, query: query) }.value
                guard !Task.isCancelled, let self else { return }
                let rows = files.map { path in
                    ComposerSuggestion(id: "file:" + path, title: URL(fileURLWithPath: path).lastPathComponent, detail: path,
                                       symbol: "doc", payload: .ref(ContextRef(kind: .file, id: path,
                                                                                label: URL(fileURLWithPath: path).lastPathComponent)))
                }
                self.publish(people + models + rows + sessions)
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

    /// The `@` list: "@close" while an app is open, "@chat" when there are chats, then "@open WhatsApp" for each app.
    /// Once a name is typed, a Mac app shows each way as its own line ("@open WhatsApp mac", "… web", "… venster"),
    /// each saying what it is. Return puts a line in the box, Return again runs it.
    private func appRows(_ query: String, _ config: ComposerConfig,
                         chats: [(name: String, detail: String)]? = nil) -> [ComposerSuggestion] {
        let rows = EmbeddedAppCatalog.openSuggestions(for: query).filter { match in config.apps.contains { $0.id == match.app.id } }
        let typed = query.lowercased()
        var commands: [ComposerSuggestion] = []
        if let open = config.openApp(), typed.isEmpty || "close".hasPrefix(typed) {
            commands.append(ComposerSuggestion(id: "close", title: "@close", detail: tr("embedded.close.mentionDetail", open),
                                               symbol: "xmark.circle",
                                               payload: .command(ComposerCommand(name: "close", insertion: "@close", action: .insert))))
        }
        // "@chat": choosing it lists the chats straight away.
        if typed.isEmpty || "chat".hasPrefix(typed), !(chats ?? config.chats()).isEmpty {
            commands.append(ComposerSuggestion(id: "chat", title: "@chat", detail: tr("whatsapp.open.mentionDetail"),
                                               symbol: "bubble.left.and.bubble.right.fill",
                                               payload: .command(ComposerCommand(name: "chat", insertion: "@chat", action: .insert))))
        }
        return commands + rows.prefix(10).map { row -> ComposerSuggestion in
            let insertion = "@open " + row.app.title + (row.mode.map { " " + $0.word } ?? "")
            // Without a way named, the line opens the way the app opened last time (else its own way): say which.
            let way = row.mode ?? EmbeddedAppCatalog.resolve(row.app, mode: row.app.isMacApp ? EmbeddedAppPreference.mode(for: row.app) : nil).mode
            let symbol = row.mode == .web ? "globe" : row.mode == .window ? "macwindow" : row.app.symbol
            return ComposerSuggestion(id: "app:" + row.app.id + (row.mode.map { ":" + $0.rawValue } ?? ""), title: insertion,
                                      detail: tr("embedded.mode.detail." + way.rawValue), symbol: symbol,
                                      payload: .command(ComposerCommand(name: row.app.id, insertion: insertion, action: .insert)))
        }
    }

    /// The people whose name fits what is typed after `@`, each once; choosing one puts "@Name" in the text.
    private func personRows(_ query: String, _ config: ComposerConfig) -> [ComposerSuggestion] {
        var seen = Set<String>()
        return config.people()
            .filter { (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) && seen.insert($0.name).inserted }
            .prefix(5)
            .map { person in
                ComposerSuggestion(id: "person:" + person.name, title: person.name, detail: person.detail.isEmpty ? nil : person.detail,
                                   symbol: "person.crop.circle",
                                   payload: .command(ComposerCommand(name: "person:" + person.name, insertion: "@" + person.name, action: .insert)))
            }
    }

    private func commandDetail(_ command: ComposerCommand) -> String? {
        // An agent's own command says what it does in its own words, or nothing.
        if let detail = command.detail { return detail.isEmpty ? nil : detail }
        return tr(AgentCommands.descriptionKey(for: command))
    }

    private func pullRequestRow(repo: String, number: Int, title: String?) -> ComposerSuggestion {
        ComposerSuggestion(id: "pr:\(number)", title: "#\(number)" + (title.map { " " + $0 } ?? ""), detail: repo, symbol: PullRequestIcon.generic,
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

    /// Shows lines a call site made itself (the "@nook" menu in a chat's answer field); none closes the list.
    func show(_ rows: [ComposerSuggestion]) {
        search?.cancel()
        trigger = nil
        if rows.map(\.id) != suggestions.map(\.id) { publish(rows) }
    }

    /// Publishes only a real change: every key passes through here, and each write redraws whoever watches the list.
    private func publish(_ rows: [ComposerSuggestion]) {
        if rows != suggestions { suggestions = rows }
        if selection != 0 { selection = 0 }
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
            return trigger.replacing(in: text, with: config.plainReferences ? ContextRefs.plainText(ref) : ContextRefs.link(ref))
        }
    }

    // MARK: Pasted secrets

    /// What looked like secrets in your last paste, until you keep them out of the message or leave them. The values stay
    /// in memory only, here, and go when you decide.
    struct SecretOffer: Equatable {
        struct Item: Equatable {
            var name: String
            var value: String
        }
        var items: [Item]
        var names: [String] { items.map(\.name) }
    }

    @Published private(set) var secretOffer: SecretOffer?

    /// Looks at what a paste added (never at typing: under 16 characters nothing is checked) and offers to keep what looks
    /// like a secret out of the message. True when it offered.
    @discardableResult
    func noticeSecrets(old: String, new: String) -> Bool {
        guard new.utf8.count - old.utf8.count >= 16, let parts = PasteRule.split(old: old, new: new) else { return false }
        let found = SecretPasteDetector.matches(in: parts.inserted)
        guard !found.isEmpty else { return false }
        var taken = Set(ContextRefs.find(in: old).filter { $0.kind == .secret }.map(\.label))
        let items = found.map { match -> SecretOffer.Item in
            let name = SecretPasteDetector.uniqueName(match.name, taken: taken)
            taken.insert(name)
            return SecretOffer.Item(name: name, value: String(parts.inserted[match.range]))
        }
        secretOffer = SecretOffer(items: items)
        return true
    }

    /// Keeps the offered secrets out of `text`: each value goes to a private file (`SecretFiles`) and the message gets a
    /// reference to it instead, so only the path reaches the agent. A value you edited away meanwhile is left alone.
    func keepSecretsPrivate(in text: String, scope: String, files: SecretFiles = .standard) -> String {
        guard let offer = secretOffer else { return text }
        secretOffer = nil
        var result = text
        for item in offer.items {
            guard let range = result.range(of: item.value),
                  let url = try? files.write(item.value, name: item.name, scope: scope) else { continue }
            result.replaceSubrange(range, with: ContextRefs.link(ContextRef(kind: .secret, id: url.path, label: item.name)))
        }
        return result
    }

    /// Leaves the paste as it is.
    func dismissSecretOffer() {
        if secretOffer != nil { secretOffer = nil }
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

/// Above the box after you pasted what looks like a secret: keep it out of the message (it goes to a private file and the
/// agent gets only the path) or leave it. Observes the model itself, so only this redraws.
struct ComposerSecretOfferSlot: View {
    @ObservedObject var model: ComposerModel
    let keep: () -> Void

    var body: some View {
        if let offer = model.secretOffer {
            PanelNoticeBar(title: tr("secrets.paste.title", offer.names.joined(separator: ", ")),
                           detail: tr("secrets.paste.detail"), symbol: "key.fill", tone: NookTheme.amber) {
                NookNoticeActions(primary: NookNoticeAction(tr("secrets.paste.keep")) { keep() },
                                  secondary: NookNoticeAction(tr("secrets.paste.leave")) { model.dismissSecretOffer() })
            }
        }
    }
}

/// The list under the text while it has lines, and nothing otherwise. The one view that observes the model, so only it
/// redraws as the list changes.
struct ComposerSuggestionSlot: View {
    @ObservedObject var model: ComposerModel
    let tint: Color
    let accept: (ComposerSuggestion) -> Void

    var body: some View {
        if model.isOpen { ComposerSuggestionList(model: model, tint: tint, accept: accept) }
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
                        NookSymbol(row.symbol, size: 12)
                            .font(NookTheme.font(11, .medium))
                            .foregroundStyle(index == model.selection ? tint : NookTheme.textTertiary)
                            .frame(width: 16)
                        Text(row.title)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                    .frame(height: 30)
                    .roundedBackground(index == model.selection ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(NookTheme.Spacing.sm)
        .cardBackground(SessionComposer<EmptyView>.surface, stroke: NookTheme.line2, radius: NookTheme.Radius.sheet)
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

/// A file or folder you pick for a message to an agent: it becomes a reference in the text, the agent reads it itself.
@MainActor
enum ComposerFilePicker {
    static func pick(startingIn folder: String) -> ContextRef? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return nil }
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

/// How full the agent's context window is: a small ring that starts at the top, amber above 80 % and coral above 90 %.
/// Hover says how much, and once it fills up suggests `/compact`; a button asks the agent to summarize when it can.
struct ComposerContextRing: View {
    let used: Int
    let window: Int
    var onCompact: (() -> Void)? = nil
    @State private var open = false

    private var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }

    /// "Context window 84% · 168k/200k", and past the warning line the suggestion to summarize.
    private var help: String {
        let base = tr("compose.context.help", ContextMeter.percentText(fraction), ContextMeter.tokensText(used: used, window: window))
        guard ContextMeter.suggestsCompact(fraction), onCompact != nil else { return base }
        return base + "\n" + tr("compose.context.nearlyFull")
    }

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
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("compose.context.title")).font(NookTheme.TextStyle.strong)
                ProgressView(value: fraction).tint(tint)
                Text(tr("compose.context.detail", ContextMeter.percentText(fraction), ContextMeter.tokensText(used: used, window: window)))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                if ContextMeter.suggestsCompact(fraction), onCompact != nil {
                    Text(tr("compose.context.nearlyFull"))
                        .font(NookTheme.TextStyle.detail).foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onCompact {
                    Button(tr("compose.context.compact")) { open = false; onCompact() }
                } else {
                    Text(tr("compose.context.noCompact")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(12)
            .frame(width: 240)
        }
    }
}

/// How much of its subscription the session's account has used, among the choices of the composer, right after the effort: a
/// small ring filled to the window that runs out first, with its percentage beside it, amber from 75 % and coral from 90 %. Click for every window as one line each (`UsageLimitRows`, reset and pace in their tooltips) and "All limits",
/// the usage limits modal with every account (`UsageModal`). Every agent that reports limits gets it.
///
/// Equatable, and without the app model of its own: composers redraw for every change of the workspace, and this one only
/// has to when the limits do.
struct ComposerUsageRing: View, Equatable {
    let limits: [QuotaLimit]
    let account: String
    @State private var open = false
    @State private var hovering = false
    private static let shownLimits = 6

    static func == (a: ComposerUsageRing, b: ComposerUsageRing) -> Bool {
        a.limits == b.limits && a.account == b.account
    }

    /// The ring for an account, in every session composer and from the first percent, working or not: nothing only for an
    /// agent that reports no limits. Built in the caller's body rather than as a view of its own, so the percentage follows
    /// the caller's updates.
    @ViewBuilder
    static func forAccount(_ profile: AgentProfile?, app: AppModel) -> some View {
        if let profile {
            let limits = app.quota.limits(for: profile)
            if !limits.isEmpty {
                ComposerUsageRing(limits: limits, account: AccountLabel.name(profile, app: app)).equatable()
            }
        }
    }

    /// The fullest window: only shows 100 % once every window is full; otherwise the fullest one that is not (at most 99 %).
    private var used: Int {
        100 - LimitPool.left(UsageLimits.effectiveHighestPercent(limits.map(\.percent)))
    }

    /// "Limits of Work: 5 hours: 38% used · Week: 12% used".
    private var help: String {
        tr("compose.limits.help", account, limits.map { tr("limits.rowUsed", $0.label, UsageLimitRows.used($0)) }.joined(separator: " · "))
    }

    /// The fullest windows when there are many (an agent with a quota per model), in the agent's order.
    private var shown: [QuotaLimit] {
        guard limits.count > Self.shownLimits else { return limits }
        let busiest = Set(limits.sorted { $0.percent > $1.percent }.prefix(Self.shownLimits).map(\.id))
        return limits.filter { busiest.contains($0.id) }
    }

    var body: some View {
        let tint = UsageTone.fill(used: used, calm: NookTheme.textSecondary)
        Button { open.toggle() } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                ring(tint: tint)
                Text("\(used)%")
                    .font(NookTheme.TextStyle.label.monospacedDigit())
                    .foregroundStyle(UsageTone.level(used: used) == .calm ? (hovering ? NookTheme.paper : NookTheme.textSecondary) : UsageTone.text(used: used))
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 28)
            .roundedBackground(hovering || open ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $open, arrowEdge: .top) { ComposerUsagePanel(limits: shown, account: account, open: $open) }
    }

    private func ring(tint: Color) -> some View {
        ZStack {
            Circle().stroke(NookTheme.line2, lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(used) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }

}

/// The title with the account, a line per window, and the way to every account's limits.
private struct ComposerUsagePanel: View {
    @EnvironmentObject private var app: AppModel
    let limits: [QuotaLimit]
    let account: String
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("limits.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Text(account).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            TimelineView(.nookTicks(every: 60)) { context in
                UsageLimitRows(limits: limits, now: context.date)
            }
            SmallGhostButton(title: tr("limits.all")) {
                open = false
                app.openUsageModal(.limits)
            }
        }
        .padding(NookTheme.Spacing.md)
        .frame(width: 300)
    }
}
