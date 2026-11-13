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
    /// Who the message goes to and what they said last, for the composer's sentence suggestions (`ComposerCompleter`).
    var situation: () -> ComposerCompletion.Situation = { ComposerCompletion.Situation() }

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
    func connectStash(_ store: ComposerDraftStore? = nil) {
        guard onStashChanged == nil else { return }
        let store = store ?? .shared
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

    // MARK: Names typed without `@`

    private var inlineNames: (names: [ComposerInlineName.Candidate], at: Date)?

    /// The name typed right before `caret` (`ComposerInlineName`), while the list is closed. The names are read from the
    /// agents once every few seconds, not on every key.
    func inlineName(in text: String, caret: Int, _ config: ComposerConfig) -> ComposerInlineName.Match? {
        guard !isOpen, caret >= ComposerInlineName.minimumLetters,
              let index = String.Index(exactUTF16: caret, in: text), index > text.startIndex,
              !text[text.index(before: index)].isWhitespace else { return nil }
        if inlineNames.map({ Date().timeIntervalSince($0.at) > 5 }) ?? true {
            inlineNames = (ComposerInlineName.candidates(models: config.models()), Date())
        }
        return ComposerInlineName.match(in: text, caret: caret, candidates: inlineNames?.names ?? [])
    }

    // MARK: Suggestions

    /// Looks at the text before the caret (UTF-16; nil: the end) and fills the list.
    func update(for text: String, caret: Int? = nil, _ config: ComposerConfig) {
        search?.cancel()
        // "@chat …" and "@open …" read the whole box, so they count with the caret at its end.
        let atEnd = caret.map { $0 >= text.utf16.count } ?? true
        // Each list comes from its source once per key: the chats are every inbox thread, sorted.
        let chatQuery = atEnd ? EmbeddedAppCatalog.chatQuery(in: text) : nil
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
        if atEnd, !config.apps.isEmpty, let query = EmbeddedAppCatalog.openQuery(in: text) {
            trigger = ComposerTrigger(kind: .mention, query: query, token: text)
            return publish(appRows(query, config, chats: chats))
        }
        guard let found = ComposerTrigger.detect(in: text, caret: caret) else { return close() }
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
                    ComposerSuggestion(id: "file:" + path, title: (path as NSString).lastPathComponent, detail: path,
                                       symbol: "doc", payload: .ref(ContextRef(kind: .file, id: path,
                                                                                label: (path as NSString).lastPathComponent)))
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
        accepting(suggestion, in: text, config).text
    }

    /// As `accept`, with where the caret goes (UTF-16): right after what went in where the trigger was typed. Nil leaves
    /// it at the end.
    func accepting(_ suggestion: ComposerSuggestion, in text: String, _ config: ComposerConfig) -> (text: String, caret: Int?) {
        if case .stash(let index) = suggestion.payload {
            defer { close() }
            let restored = stash.restore(at: index) ?? text
            onStashChanged?()
            return (restored, nil)
        }
        guard let trigger else { return (text, nil) }
        defer { close() }
        switch suggestion.payload {
        case .stash:
            return (text, nil)
        case .command(let command):
            if command.action == .insert { return trigger.inserting(command.insertion, in: text) }
            config.onCommand(command)
            return trigger.removing(from: text)
        case .ref(let ref):
            return trigger.inserting(config.plainReferences ? ContextRefs.plainText(ref) : ContextRefs.link(ref), in: text)
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

    /// The next paste stays editable text however big it is (⇧⌘V), unless it would push the message past its limit. The
    /// composer reads and clears it on the next change of the text.
    var pastesAsText = false

    /// A paste that was too big for the box, or that would make the message too long: keep it aside and put a reference
    /// in its place. `asText` (⇧⌘V) keeps a big paste as text. Typing never counts: under 16 characters nothing is kept aside.
    func keepPaste(old: String, new: String, asText: Bool = false) -> String? {
        guard new.utf8.count - old.utf8.count >= 16, let parts = PasteRule.split(old: old, new: new),
              PasteRule.attaches(parts.inserted, result: new, asText: asText) else { return nil }
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
                .buttonStyle(.nookPlain)
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
    /// A picture of the window in front, added to the message: given by every composer that writes to an agent.
    var screenshot: (() -> Void)? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            Button(action: attach) { Label(attachLabel, icon: "paperclip") }
            if let screenshot {
                Button(action: screenshot) { Label(tr("compose.plus.screenshot"), icon: "camera.viewfinder") }
            }
            extra()
        } label: {
            ComposerIcon(symbol: "plus")
        }
        .composerMenu()
        .composerTip(tr("chat.more"))
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

/// What fills the context window, as Claude Code's `/context` says it: a line per part with its size and share, the
/// parts loaded only when needed, and how many tools, memory files, agents and skills there are. For an agent that only
/// reports the conversation's size: that, the room kept for summarizing and what is left. Shown inline under the context
/// bar of the session panel's usage section, opened and closed like an accordion.
struct ContextUsageBreakdown: View {
    let usage: ContextUsage

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                ForEach(usage.inWindow) { row($0) }
            }
            if !usage.deferred.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    ForEach(usage.deferred) { row($0) }
                }
            }
            if !counts.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    ForEach(counts, id: \.0) { name, count in
                        HStack {
                            Text(name)
                            Spacer(minLength: NookTheme.Spacing.md)
                            Text("\(count)").monospacedDigit()
                        }
                        .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                }
            }
            if !usage.detailed {
                Text(tr("compose.context.estimate"))
                    .font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func row(_ category: ContextUsage.Category) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Circle()
                .fill(Self.color(category))
                .frame(width: 8, height: 8)
            Text(Self.name(category)).foregroundStyle(category.kind == .used ? NookTheme.paper : NookTheme.textSecondary)
            Spacer(minLength: NookTheme.Spacing.md)
            Text(TokenTally.format(category.tokens)).monospacedDigit().foregroundStyle(NookTheme.textSecondary)
            Text(category.kind == .deferred ? "—" : ContextMeter.percentText(usage.share(category)))
                .monospacedDigit().foregroundStyle(NookTheme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(NookTheme.TextStyle.detail)
        .lineLimit(1)
    }

    /// "MCP tools 147", "Memory files 1", …: only what the agent counted.
    private var counts: [(String, Int)] {
        [("mcp_tools", usage.mcpTools), ("memory_files", usage.memoryFiles), ("custom_agents", usage.agents), ("skills", usage.skills)]
            .compactMap { id, count in count.flatMap { $0 > 0 ? (Self.name(id: id, fallback: id), $0) : nil } }
    }

    /// The categories Nook knows by name; another keeps the agent's own label.
    static let knownIDs: Set<String> = [
        "messages", "system_prompt", "system_tools", "system_tools_deferred", "mcp_tools", "mcp_tools_deferred",
        "mcp_instructions", "custom_agents", "memory_files", "skills", "autocompact_buffer", "free_space",
        ContextUsage.conversation,
    ]

    static func name(_ category: ContextUsage.Category) -> String { name(id: category.id, fallback: category.name) }

    static func name(id: String, fallback: String) -> String {
        knownIDs.contains(id) ? tr("compose.context.part." + id) : fallback
    }

    static func color(_ category: ContextUsage.Category) -> Color {
        switch category.kind {
        case .buffer: return NookTheme.textTertiary.opacity(0.5)
        case .free: return NookTheme.line2
        case .deferred: return NookTheme.textTertiary.opacity(0.35)
        case .used:
            switch category.id {
            case "messages", ContextUsage.conversation: return NookTheme.blue
            case "mcp_tools": return NookTheme.coral
            case "system_tools": return NookTheme.mint
            case "skills": return NookTheme.amber
            case "custom_agents": return NookTheme.violet
            case "memory_files": return NookTheme.music
            default: return NookTheme.textTertiary
            }
        }
    }
}

/// How much of its subscription the session's account has used, among the choices of the composer, right after the effort:
/// the short window (5 hours) and the long one (week) at once, as two rings in one (outer the short window, inner the long
/// one) beside two small labelled lines ("5h 38%", "W 12%") that stack inside the chip's height, so it hardly grows wider
/// than a single number. Each window takes its own tone: amber from 75 %, coral from 90 %. Click for every window as one
/// line each (`UsageLimitRows`, reset and pace in their tooltips) and "All limits", the usage limits modal with every
/// account (`UsageModal`). Every agent that reports limits gets it.
///
/// Equatable, and without the app model of its own: composers redraw for every change of the workspace, and this one only
/// has to when the limits do.
struct ComposerUsageRing: View, Equatable {
    let limits: [QuotaLimit]
    let account: String
    /// The account whose limits these are: the popover reads them again from the app, so a refresh shows in it at once.
    var profileID: String?
    @State private var open = false
    @State private var hovering = false
    fileprivate static let shownLimits = 6

    static func == (a: ComposerUsageRing, b: ComposerUsageRing) -> Bool {
        a.limits == b.limits && a.account == b.account && a.profileID == b.profileID
    }

    /// The ring for an account, in every session composer and from the first percent, working or not: nothing only for an
    /// agent that reports no limits. Built in the caller's body rather than as a view of its own, so the percentage follows
    /// the caller's updates.
    @ViewBuilder
    static func forAccount(_ profile: AgentProfile?, app: AppModel) -> some View {
        if let profile {
            let limits = app.quota.limits(for: profile)
            if !limits.isEmpty {
                ComposerUsageRing(limits: limits, account: AccountLabel.name(profile, app: app), profileID: profile.id).equatable()
            }
        }
    }

    private typealias Line = UsageLimits.ChipLine

    /// "Limits of Work: 5 hours: 38% used · Week: 12% used".
    private var help: String {
        tr("compose.limits.help", account, limits.map { tr("limits.rowUsed", $0.label, UsageLimitRows.used($0)) }.joined(separator: " · "))
    }

    var body: some View {
        let lines = UsageLimits.chipLines(limits.map { ($0.duration, $0.percent, $0.window) })
        Button { open.toggle() } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                rings(lines)
                HStack(spacing: NookTheme.Spacing.xxs) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index].short)
                                .font(NookTheme.font(9.5, .semibold))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            let used = lines[index].used
                            Text("\(used)%")
                                .font(NookTheme.TextStyle.caption.monospacedDigit())
                                .foregroundStyle(UsageTone.level(used: used) == .calm
                                                 ? (hovering ? NookTheme.paper : NookTheme.textSecondary) : UsageTone.text(used: used))
                        }
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 28)
            .roundedBackground(hovering || open ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.nookPlain)
        .fixedSize()
        .composerTip(help)
        .accessibilityLabel(help)
        .popover(isPresented: $open, arrowEdge: .top) { ComposerUsagePanel(limits: limits, account: account, profileID: profileID, open: $open) }
    }

    /// The short window as the outer ring, the long one inside it, each filled from the top in its own tone. Both
    /// rings have the same stroke and the inner one keeps a real hole, so neither reads heavier than the other.
    private func rings(_ lines: [Line]) -> some View {
        ZStack {
            ForEach(lines.indices, id: \.self) { index in
                let used = lines[index].used
                ProgressRing(fraction: CGFloat(used) / 100,
                             tint: UsageTone.fill(used: used, calm: NookTheme.textSecondary), lineWidth: 1.75)
                    .frame(width: index == 0 ? 17 : 10, height: index == 0 ? 17 : 10)
            }
        }
        .frame(width: 17, height: 17)
    }

}

/// The title with the account, a line per window, the way to every account's limits, and a refresh button.
private struct ComposerUsagePanel: View {
    @EnvironmentObject private var app: AppModel
    /// The limits when the ring was drawn; only used when the account is gone.
    let limits: [QuotaLimit]
    let account: String
    let profileID: String?
    @Binding var open: Bool

    /// Read from the app on every redraw rather than kept from when the popover opened: the ring is equatable and the
    /// popover's content does not always follow it, so after the refresh button the numbers stayed as they were.
    private var current: [QuotaLimit] {
        guard let profile = profileID.flatMap({ app.profiles.profile(id: $0) }) else { return limits }
        return app.quota.limits(for: profile)
    }

    /// The fullest windows when there are many (an agent with a quota per model), in the agent's order.
    private var shown: [QuotaLimit] {
        let limits = current
        guard limits.count > ComposerUsageRing.shownLimits else { return limits }
        let busiest = Set(limits.sorted { $0.percent > $1.percent }.prefix(ComposerUsageRing.shownLimits).map(\.id))
        return limits.filter { busiest.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("limits.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Text(account).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
            }
            TimelineView(.nookTicks(every: 60)) { context in
                UsageLimitRows(limits: shown, now: context.date)
            }
            // "All limits" on the left, and on its far right a way to read the limits again right now.
            HStack(spacing: NookTheme.Spacing.sm) {
                SmallGhostButton(title: tr("limits.all")) {
                    open = false
                    app.openUsageModal(.limits)
                }
                Spacer(minLength: 0)
                UsageRefreshButton()
            }
        }
        .padding(NookTheme.Spacing.md)
        .frame(width: 300)
    }
}
