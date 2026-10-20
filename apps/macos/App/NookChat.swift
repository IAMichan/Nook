import Foundation

/// An email drafted by Nook. Can be edited in chat and sent with one click.
struct MailDraft: Identifiable, Equatable {
    enum State: Equatable { case draft, sending, sent, opened, failed(String) }

    let id = UUID()
    var to: String
    var cc: String
    var subject: String
    var body: String
    var state: State = .draft
}

/// A single message in the conversation with Nook.
struct ChatMessage: Identifiable {
    enum Role { case user, nook }
    enum PlanState: Equatable { case pending, running, done(String), cancelled, failed(String) }

    let id = UUID()
    var role: Role
    var text: String
    /// Pictures sent with a question. Kept for this session only: they are not saved with the conversation.
    var images: [ImageAttachment] = []
    var date = Date()
    /// Goes up with every change (`NookChat.update`), so a message view redraws only when its own message changed.
    var revision = 0
    /// What Nook is currently doing (e.g. "Looking at your screen..."), while streaming text.
    var status = ""
    var streaming = false
    var isError = false
    /// Context attached without tools: screen content, a Shelf file.
    var sources: [String] = []
    /// What Nook consulted for this answer, with outcome per source.
    var retrieval: [RetrievalStep] = []
    /// Numbered references retrieved by Nook; answer cites them as [1], [2].
    var references: [SourceReference] = []
    /// Sources whose summary was included in full (others as a single line).
    var contextSources: [String] = []
    /// Allowed sources if restricted by user ("Only Calendar and Mail").
    var scopeLabel = ""
    /// Notices for the user regarding this answer, e.g. unreadable sources.
    var notices: [String] = []
    var charts: [ChatChart] = []
    var mails: [MailDraft] = []
    /// Actions proposed by Nook; only executed after user approval.
    var actions: [PlannedAction] = []
    var planState: PlanState = .pending
    /// Status per step in the plan: outcome, whether included, and validation issues.
    var actionStates: [ActionStepState] = []
    var actionIncluded: [Bool] = []
    var actionProblems: [[String]] = []
    /// Follow-up suggestions ("Add to my calendar"), shown as buttons below answer.
    var offers: [String] = []

    /// Whether this answer was built from one of these sources: looked up, cited, in the context it was written from,
    /// or (for the screen) read from a window.
    func used(anyOf ids: Set<String>) -> Bool {
        if retrieval.contains(where: { step in step.sourceID.map { ids.contains($0) } ?? false }) { return true }
        if references.contains(where: { ids.contains($0.sourceID) }) { return true }
        let titles = Set(ids.map { SourceCatalog.title($0) })
        if contextSources.contains(where: { titles.contains($0) }) { return true }
        return ids.contains(SourceCatalog.screen) && !sources.isEmpty
    }

    /// Representation of this turn for LLM history: text plus actions/outcomes.
    var historyText: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        for chart in charts { parts.append("[chart displayed: \(chart.title)]") }
        for mail in mails {
            let state: String
            switch mail.state {
            case .sent: state = "sent"
            case .opened: state = "opened in Mail"
            default: state = "not yet sent"
            }
            parts.append("[draft email to \(mail.to.isEmpty ? "?" : mail.to), subject \"\(mail.subject)\", \(state)]")
        }
        if !retrieval.isEmpty {
            let searched = retrieval.map { step -> String in
                switch step.outcome {
                case .failed(let error): return "\(step.sourceTitle) (error: \(error))"
                case .empty: return "\(step.sourceTitle) (nothing found)"
                default: return step.sourceTitle + (step.query.isEmpty ? "" : " \"\(step.query)\"")
                }
            }
            parts.append("[searched: \(searched.joined(separator: ", "))]")
        }
        if !references.isEmpty {
            // So follow-up questions ("send that to the same person") retain context.
            let list = references.prefix(8).map { "[\($0.number)] \($0.title)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") }
            parts.append("[sources for this reply: \(list.joined(separator: "; "))]")
        }
        if !actions.isEmpty {
            let state: String
            switch planState {
            case .pending, .running: state = "waiting for approval"
            case .done: state = "completed"
            case .cancelled: state = "cancelled by user"
            case .failed(let error): state = "partially failed: \(error)"
            }
            var steps: [String] = []
            for (index, action) in actions.enumerated() {
                let outcome: String
                switch index < actionStates.count ? actionStates[index] : .pending {
                case .done(let result): outcome = "completed: \(result)"
                case .verified(let result): outcome = "completed and confirmed: \(result)"
                case .approved: outcome = "approved, not yet run"
                case .failed(let error): outcome = "failed: \(error)"
                case .notRun: outcome = "not executed"
                case .skipped: outcome = "skipped by user"
                case .duplicate(let when): outcome = "not repeated, already executed on \(when)"
                case .running: outcome = "running"
                case .pending: outcome = planState == .cancelled ? "cancelled" : "pending"
                }
                steps.append("\(index + 1). \(action.tool) \(Self.compactInput(action.input)) → \(outcome)")
            }
            parts.append("[proposed actions — \(state)]\n" + steps.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    /// Compact action input representation for model history.
    static func compactInput(_ input: [String: Any]) -> String {
        let pairs = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
            return "\(key)=\(text.count > 120 ? String(text.prefix(119)) + "…" : text)"
        }
        return "(" + pairs.joined(separator: ", ") + ")"
    }
}

/// A single Nook conversation with its own history. Multiple conversations can run concurrently.
struct Conversation: Identifiable, ConversationListItem {
    enum Status { case working, waiting, unread, idle }

    let id: UUID
    var title: String
    var created: Date
    var updated: Date
    var messages: [ChatMessage] = []
    var busy = false
    /// Finished in background while looking elsewhere.
    var unread = false
    /// Scope of sources this conversation can use (picker next to input field).
    var scope = SourceScope.automatic
    /// Kept at the top of the list.
    var pinned = false
    /// Out of the active list but kept; found again through the archive.
    var archived = false

    var isEmpty: Bool { messages.isEmpty }

    /// While Nook answers: when you asked, so the list and the header can show how long it has been going.
    var turnStarted: Date? { busy ? messages.last(where: { $0.role == .user })?.date : nil }

    /// Conversation status indicator.
    var status: Status {
        if busy { return .working }
        // Only what Nook proposed since your last message: a plan or draft you moved past is not waiting for you anymore.
        let lastAsked = messages.lastIndex { $0.role == .user } ?? -1
        let waiting = messages[(lastAsked + 1)...].contains { message in
            (!message.actions.isEmpty && message.planState == .pending)
                || message.mails.contains { $0.state == .draft }
        }
        if waiting { return .waiting }
        return unread ? .unread : .idle
    }

    private static let markdownStripSet = CharacterSet(charactersIn: "#*_`>|")

    /// Single-line preview: last message from Nook.
    var preview: String {
        guard let last = messages.last(where: { $0.role == .nook && !$0.text.isEmpty }) else { return "" }
        let sample = String(last.text.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        let cleaned = String(sample.unicodeScalars.filter { !Self.markdownStripSet.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80))
    }

    /// Extracts a concise title from the initial user prompt.
    static func title(from question: String) -> String {
        var text = question.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        guard text.count > 40 else { return text.prefix(1).uppercased() + text.dropFirst() }
        let cut = text.prefix(40)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        let short = String(cut[..<end])
        return short.prefix(1).uppercased() + short.dropFirst() + "…"
    }
}

/// Manages all conversations, persisted locally to disk.
@MainActor
final class NookChat: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var activeID: UUID?
    private(set) var lastActivity = Date.distantPast
    private var saveTask: Task<Void, Never>?
    private static let saveQueue = DispatchQueue(label: "nl.imdigital.nook.chatsave", qos: .utility)

    private let maxMessages = 80
    /// The saved conversations have been read. Until then nothing is written, so an early save can never replace the file.
    private var loaded = false

    init() {
        load()
    }

    // MARK: Read

    var active: Conversation? { activeID.flatMap { conversation($0) } }
    var messages: [ChatMessage] { active?.messages ?? [] }
    var isEmpty: Bool { messages.isEmpty }
    /// Whether active conversation is busy.
    var busy: Bool { active?.busy ?? false }
    /// Whether any conversation is busy.
    var anyBusy: Bool { conversations.contains { $0.busy } }

    /// Non-empty, not archived conversations: pinned first, then newest first.
    var history: [Conversation] {
        ConversationList.visible(conversations.filter { !$0.isEmpty || $0.busy }, query: "", showArchived: false)
    }

    /// The list as shown: with a search, and optionally the archive instead.
    func list(query: String, showArchived: Bool) -> [Conversation] {
        ConversationList.visible(conversations.filter { !$0.isEmpty || $0.busy }, query: query, showArchived: showArchived)
    }

    var hasArchived: Bool { conversations.contains { $0.archived && !$0.isEmpty } }

    /// Active recently? Prevents panel from closing automatically.
    var isRecentlyActive: Bool { anyBusy || Date().timeIntervalSince(lastActivity) < 180 }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func isBusy(_ id: UUID) -> Bool { conversation(id)?.busy ?? false }

    func message(_ id: UUID) -> ChatMessage? {
        for conversation in conversations {
            if let message = conversation.messages.first(where: { $0.id == id }) { return message }
        }
        return nil
    }

    /// Finds the conversation ID containing the given message.
    func conversationID(of messageID: UUID) -> UUID? {
        conversations.first { $0.messages.contains { $0.id == messageID } }?.id
    }

    // MARK: Conversations

    /// Returns active conversation, creating one if needed.
    @discardableResult
    func ensureActive() -> UUID {
        if let activeID, conversation(activeID) != nil { return activeID }
        return startNew()
    }

    /// Starts a new conversation, reusing current if empty.
    @discardableResult
    func startNew() -> UUID {
        if let current = active, current.isEmpty, !current.busy { return current.id }
        conversations.removeAll { $0.isEmpty && !$0.busy }
        let conversation = Conversation(id: UUID(), title: tr("nooks.new"), created: Date(), updated: Date())
        conversations.append(conversation)
        activeID = conversation.id
        trim()
        scheduleSave()
        return conversation.id
    }

    func select(_ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].unread = false
        activeID = id
        // Empty abandoned conversations do not need to be retained.
        conversations.removeAll { $0.isEmpty && !$0.busy && $0.id != id }
        scheduleSave()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeID == id { activeID = history.first?.id }
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(of: id), !trimmed.isEmpty else { return }
        conversations[index].title = String(trimmed.prefix(80))
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].pinned.toggle()
        if conversations[index].pinned { conversations[index].archived = false }
        scheduleSave()
    }

    func setArchived(_ archived: Bool, _ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].archived = archived
        if archived { conversations[index].pinned = false }
        if archived, activeID == id { activeID = history.first?.id }
        scheduleSave()
    }

    func markUnread(_ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].unread = true
        scheduleSave()
    }

    // MARK: Several at once

    func setUnread(_ unread: Bool, _ ids: Set<UUID>) {
        for index in conversations.indices where ids.contains(conversations[index].id) {
            conversations[index].unread = unread
        }
        scheduleSave()
    }

    /// Pins or unpins; a pinned conversation leaves the archive, as with one.
    func setPinned(_ pinned: Bool, _ ids: Set<UUID>) {
        for index in conversations.indices where ids.contains(conversations[index].id) {
            conversations[index].pinned = pinned
            if pinned { conversations[index].archived = false }
        }
        scheduleSave()
    }

    /// Archives or brings back; a conversation Nook is still answering stays where it is.
    func setArchived(_ archived: Bool, _ ids: Set<UUID>) {
        for index in conversations.indices where ids.contains(conversations[index].id) && !conversations[index].busy {
            conversations[index].archived = archived
            if archived { conversations[index].pinned = false }
        }
        if archived, let activeID, ids.contains(activeID), active?.archived == true { self.activeID = history.first?.id }
        scheduleSave()
    }

    /// Deletes all but the conversations Nook is still answering.
    func delete(_ ids: Set<UUID>) {
        conversations.removeAll { ids.contains($0.id) && !$0.busy }
        if let activeID, conversation(activeID) == nil { self.activeID = history.first?.id }
        scheduleSave()
    }

    // MARK: Messages

    func append(_ message: ChatMessage, to id: UUID? = nil) {
        let target = id ?? ensureActive()
        guard let index = index(of: target) else { return }
        // First user prompt sets conversation title.
        if message.role == .user, !conversations[index].messages.contains(where: { $0.role == .user }) {
            conversations[index].title = Conversation.title(from: message.text)
        }
        conversations[index].messages.append(message)
        // Trim oldest messages beyond limit.
        if conversations[index].messages.count > maxMessages {
            conversations[index].messages.removeFirst(conversations[index].messages.count - maxMessages)
        }
        touch(index)
    }

    func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        for index in conversations.indices {
            if let message = conversations[index].messages.firstIndex(where: { $0.id == id }) {
                change(&conversations[index].messages[message])
                conversations[index].messages[message].revision &+= 1
                let streaming = conversations[index].messages[message].streaming
                // While an answer streams in, only the message changes: the conversation's place in the list stays put,
                // and the list of Nooks is not re-sorted for every few words.
                if streaming { lastActivity = Date() } else { touch(index) }
                return
            }
        }
    }

    func updateMail(_ mailID: UUID, _ change: (inout MailDraft) -> Void) {
        for index in conversations.indices {
            for message in conversations[index].messages.indices {
                if let mail = conversations[index].messages[message].mails.firstIndex(where: { $0.id == mailID }) {
                    change(&conversations[index].messages[message].mails[mail])
                    conversations[index].messages[message].revision &+= 1
                    touch(index)
                    return
                }
            }
        }
    }

    func setScope(_ scope: SourceScope, conversation id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].scope = scope
        scheduleSave()
    }

    /// Last user prompt in conversation, for retry.
    func lastQuestion(in id: UUID) -> String? {
        conversation(id)?.messages.last(where: { $0.role == .user })?.text
    }

    func setBusy(_ value: Bool, conversation id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].busy = value
        touch(index)
    }

    /// Chat history turns formatted for model context, excluding current turn.
    /// `hiding`: sources an external brain may not see; answers built from them are left out, with the question that led to them.
    func history(before id: UUID, limit: Int = 16, hiding hidden: Set<String> = []) -> [ChatTurn] {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == id } }) else { return [] }
        let earlier = Self.withoutPrivate(Array(conversation.messages.prefix { $0.id != id }), hiding: hidden)
        return earlier.suffix(limit).compactMap { message in
            let text = message.isError ? "" : message.historyText
            guard !text.isEmpty else { return nil }
            return ChatTurn(fromUser: message.role == .user, text: String(text.prefix(4000)))
        }
    }

    /// Drops the answers that were built from a hidden source and the question right before each of them.
    nonisolated static func withoutPrivate(_ messages: [ChatMessage], hiding hidden: Set<String>) -> [ChatMessage] {
        guard !hidden.isEmpty else { return messages }
        var kept: [ChatMessage] = []
        for message in messages {
            if message.role == .nook, message.used(anyOf: hidden) {
                if kept.last?.role == .user { kept.removeLast() }
                continue
            }
            kept.append(message)
        }
        return kept
    }

    // MARK: Internal

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    private func touch(_ index: Int, save: Bool = true) {
        conversations[index].updated = Date()
        lastActivity = Date()
        if save { scheduleSave() }
    }

    /// Too many conversations: the oldest are archived (still searchable), only a very old archive is cleared.
    private func trim() {
        for id in ConversationList.toArchive(conversations) {
            if let index = index(of: id) { conversations[index].archived = true }
        }
        let drop = Set(ConversationList.toDelete(conversations))
        conversations.removeAll { drop.contains($0.id) }
    }

    // MARK: Persistence

    private nonisolated static var fileURL: URL { NookPaths.supportDirectory.appendingPathComponent("nooks.json") }

    /// Debounces saves so bursts of edits coalesce into a single disk write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    private func save() {
        guard loaded else { return }
        let stored = StoredChats(
            active: activeID,
            conversations: conversations.filter { !$0.isEmpty }.map { StoredConversation($0) }
        )
        let url = Self.fileURL
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? SafeStorage.write(data, to: url)
        }
    }

    /// Reads and decodes the file off the main thread (it can hold hundreds of conversations), so launching Nook does
    /// not wait for it. Conversations started in the meantime are kept next to the loaded ones.
    private func load() {
        let url = Self.fileURL
        Task.detached(priority: .userInitiated) { [weak self] in
            // Conversation by conversation, and an unreadable file is kept aside: the next save must never wipe your history.
            let stored = SafeStorage.load(StoredChats.self, from: url, skipped: { $0.skipped }).value
            await self?.finishLoading(stored)
        }
    }

    private func finishLoading(_ stored: StoredChats?) {
        loaded = true
        guard let stored else {
            if !conversations.isEmpty { scheduleSave() }
            return
        }
        let started = conversations
        let known = Set(started.map(\.id))
        let restored = stored.conversations.map { $0.restored() }.filter { !$0.isEmpty && !known.contains($0.id) }
        conversations = started + restored
        if activeID == nil {
            activeID = stored.active.flatMap { id in conversations.contains { $0.id == id } ? id : nil }
                ?? history.first?.id
        }
        if !started.isEmpty { scheduleSave() }
    }
}

// MARK: Disk Storage

/// Persisted conversation representation. Pending actions are serialized as text lines rather than executable actions.
private struct StoredChats: Codable, Sendable {
    /// Format version, written since version 2. Files without it are version 1 and read the same way.
    var version: Int? = 2
    var active: UUID?
    var conversations: [StoredConversation]
    /// Conversations in the file that could not be read (kept in the backup copy).
    var skipped = 0

    init(active: UUID?, conversations: [StoredConversation]) {
        self.active = active
        self.conversations = conversations
    }

    private enum CodingKeys: String, CodingKey { case version, active, conversations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        active = try? container.decodeIfPresent(UUID.self, forKey: .active)
        let list = try container.decode(LossyArray<StoredConversation>.self, forKey: .conversations)
        conversations = list.elements
        skipped = list.skipped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encodeIfPresent(active, forKey: .active)
        try container.encode(conversations, forKey: .conversations)
    }
}

private struct StoredConversation: Codable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var unread: Bool
    var messages: [StoredMessage]
    /// Added later: optional to remain backwards compatible with older nooks.json.
    var scope: SourceScope?
    var pinned: Bool?
    var archived: Bool?

    @MainActor
    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        created = conversation.created
        updated = conversation.updated
        unread = conversation.unread
        messages = conversation.messages.compactMap { StoredMessage($0) }
        scope = conversation.scope == .automatic ? nil : conversation.scope
        pinned = conversation.pinned ? true : nil
        archived = conversation.archived ? true : nil
    }

    func restored() -> Conversation {
        var conversation = Conversation(id: id, title: title, created: created, updated: updated)
        conversation.unread = unread
        conversation.scope = scope ?? .automatic
        conversation.pinned = pinned ?? false
        conversation.archived = archived ?? false
        conversation.messages = messages.map { $0.restored() }
        return conversation
    }
}

private struct StoredMessage: Codable {
    var user: Bool
    var text: String
    var date: Date
    var isError: Bool
    var sources: [String]
    var charts: [StoredChart]
    var mails: [StoredMail]
    var offers: [String]
    // Added later: optional to remain backwards compatible with older nooks.json.
    var retrieval: [RetrievalStep]?
    var references: [SourceReference]?
    var contextSources: [String]?
    var scopeLabel: String?
    var notices: [String]?

    @MainActor
    init?(_ message: ChatMessage) {
        var text = message.text
        if !message.actions.isEmpty {
            // The plan is formatted into the text: what was proposed and each step's outcome.
            // Executable actions are not restored after restart.
            let steps = AppModel.shared.planSteps(message.actions)
            var lines: [String] = []
            for (index, step) in steps.enumerated() {
                let state: String
                switch index < message.actionStates.count ? message.actionStates[index] : .pending {
                case .done(let result): state = "✓ " + result
                case .verified(let result): state = "✓✓ " + result
                case .approved: state = "not executed"
                case .failed(let error): state = "✗ failed: \(error)"
                case .duplicate(let when): state = "already completed on \(when)"
                case .skipped: state = "skipped"
                case .notRun, .running: state = "not executed"
                case .pending: state = message.planState == .cancelled ? "cancelled" : "not executed"
                }
                lines.append("\(index + 1). \(step.text) · \(state)")
            }
            text += (text.isEmpty ? "" : "\n\n") + "_Plan:_\n" + lines.map { "_\($0)_" }.joined(separator: "\n")
        }
        guard !text.isEmpty || !message.charts.isEmpty || !message.mails.isEmpty else { return nil }
        user = message.role == .user
        self.text = text
        date = message.date
        isError = message.isError
        sources = message.sources
        charts = message.charts.map(StoredChart.init)
        mails = message.mails.map(StoredMail.init)
        offers = message.offers
        retrieval = message.retrieval.isEmpty ? nil : message.retrieval
        references = message.references.isEmpty ? nil : message.references
        contextSources = message.contextSources.isEmpty ? nil : message.contextSources
        scopeLabel = message.scopeLabel.isEmpty ? nil : message.scopeLabel
        notices = message.notices.isEmpty ? nil : message.notices
    }

    func restored() -> ChatMessage {
        var message = ChatMessage(role: user ? .user : .nook, text: text)
        message.date = date
        message.isError = isError
        message.sources = sources
        message.charts = charts.map { $0.restored() }
        message.mails = mails.map { $0.restored() }
        message.offers = offers
        message.retrieval = retrieval ?? []
        message.references = references ?? []
        message.contextSources = contextSources ?? []
        message.scopeLabel = scopeLabel ?? ""
        message.notices = notices ?? []
        return message
    }
}

private struct StoredChart: Codable {
    struct Series: Codable {
        var name: String
        var labels: [String]
        var values: [Double]
    }

    var title: String
    var kind: String
    var unit: String
    var series: [Series]

    init(_ chart: ChatChart) {
        title = chart.title
        kind = chart.kind.rawValue
        unit = chart.unit
        series = chart.series.map { Series(name: $0.name, labels: $0.points.map(\.label), values: $0.points.map(\.value)) }
    }

    func restored() -> ChatChart {
        ChatChart(
            title: title,
            kind: ChatChart.Kind(rawValue: kind) ?? .bar,
            unit: unit,
            series: series.map { item in
                ChatChart.Series(name: item.name, points: zip(item.labels, item.values).map { ChatChart.Point(label: $0, value: $1) })
            }
        )
    }
}

private struct StoredMail: Codable {
    var to: String
    var cc: String
    var subject: String
    var body: String
    var state: String

    init(_ mail: MailDraft) {
        to = mail.to
        cc = mail.cc
        subject = mail.subject
        body = mail.body
        switch mail.state {
        case .sent: state = "sent"
        case .opened: state = "opened"
        default: state = "draft"
        }
    }

    func restored() -> MailDraft {
        var mail = MailDraft(to: to, cc: cc, subject: subject, body: body)
        mail.state = state == "sent" ? .sent : (state == "opened" ? .opened : .draft)
        return mail
    }
}

/// Associates tool outputs (charts, mail drafts) with the correct reply and conversation.
enum ReplyContext {
    @TaskLocal static var messageID: UUID?
    /// The pictures sent with the question being answered; the brain adds them to the last message.
    @TaskLocal static var images: [ImageAttachment] = []
    /// Lookups the caller already knows are the answer's material (a WhatsApp card's own chat): the run reads exactly
    /// these instead of searching, so an answer about one chat is never mixed with others.
    @TaskLocal static var focus: [Prefetch.Call] = []
    /// False for a prompt Nook wrote itself (a card's button): there is nothing the user said to reflect on.
    @TaskLocal static var reflects = true
}
