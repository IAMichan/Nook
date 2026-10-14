import Foundation

/// Een grafiek die Nook in de chat tekent.
struct ChatChart: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case bar, line, area, pie, point }

    struct Point: Equatable {
        var label: String
        var value: Double
    }

    struct Series: Equatable {
        var name: String
        var points: [Point]
    }

    let id = UUID()
    var title: String
    var kind: Kind
    var unit: String
    var series: [Series]

    /// Maakt een grafiek uit de invoer van het model. Accepteert `series` met `points` (of `data`), of één losse `data`-lijst.
    static func parse(_ input: [String: Any]) -> ChatChart? {
        let title = (input["title"] as? String) ?? ""
        let kind = Kind(rawValue: ((input["type"] as? String) ?? "bar").lowercased()) ?? .bar
        let unit = (input["unit"] as? String) ?? ""

        func points(_ raw: Any?) -> [Point] {
            ((raw as? [Any]) ?? []).compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                let label = (object["label"] as? String) ?? (object["x"].map { "\($0)" }) ?? ""
                guard let value = number(object["value"] ?? object["y"]) else { return nil }
                return Point(label: label, value: value)
            }
        }

        var series: [Series] = ((input["series"] as? [Any]) ?? []).compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let list = points(object["points"] ?? object["data"])
            return list.isEmpty ? nil : Series(name: (object["name"] as? String) ?? "", points: list)
        }
        if series.isEmpty {
            let list = points(input["data"] ?? input["points"])
            if !list.isEmpty { series = [Series(name: title, points: list)] }
        }
        guard !series.isEmpty else { return nil }
        return ChatChart(title: title, kind: kind, unit: unit, series: Array(series.prefix(8)))
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String:
            let cleaned = value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
            return Double(cleaned)
        default: return nil
        }
    }
}

/// Een mail die Nook schreef. Je past hem aan in de chat en verstuurt hem zelf met één klik.
struct MailDraft: Identifiable, Equatable {
    enum State: Equatable { case draft, sending, sent, opened, failed(String) }

    let id = UUID()
    var to: String
    var cc: String
    var subject: String
    var body: String
    var state: State = .draft
}

/// Eén bericht in het gesprek met Nook.
struct ChatMessage: Identifiable {
    enum Role { case user, nook }
    enum PlanState: Equatable { case pending, running, done(String), cancelled, failed(String) }

    let id = UUID()
    var role: Role
    var text: String
    var date = Date()
    /// Wat Nook nu doet ("Ik kijk even mee…"), zolang er nog geen tekst is.
    var status = ""
    var streaming = false
    var isError = false
    /// Context die meeging zonder tool: het scherm, een bestand uit de Shelf.
    var sources: [String] = []
    /// Waar Nook voor dit antwoord echt in keek, met de uitkomst per bron.
    var retrieval: [RetrievalStep] = []
    /// Genummerde bronnen uit wat Nook ophaalde; het antwoord verwijst ernaar met [1], [2].
    var references: [SourceReference] = []
    /// Bronnen waarvan de samenvatting volledig meeging (de rest alleen als één regel).
    var contextSources: [String] = []
    /// Welke bronnen mochten, als de gebruiker dat beperkte ("Alleen Agenda en Mail").
    var scopeLabel = ""
    /// Wat de gebruiker moet weten over dit antwoord, zoals een bron die niet gelezen kon worden.
    var notices: [String] = []
    var charts: [ChatChart] = []
    var mails: [MailDraft] = []
    /// Acties die Nook voorstelt; pas na "Uitvoeren" gebeuren ze echt.
    var actions: [PlannedAction] = []
    var planState: PlanState = .pending
    /// Per stap van het plan: hoe het ging, of hij aan staat en wat er mis is met de invoer.
    var actionStates: [ActionStepState] = []
    var actionIncluded: [Bool] = []
    var actionProblems: [[String]] = []
    /// Wat Nook hierna kan doen ("Zet het in mijn agenda"), als knoppen onder het antwoord.
    var offers: [String] = []

    /// Hoe dit bericht in de geschiedenis voor het brein staat: tekst plus wat er verder gebeurde.
    var historyText: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        for chart in charts { parts.append("[grafiek getoond: \(chart.title)]") }
        for mail in mails {
            let state: String
            switch mail.state {
            case .sent: state = "verstuurd"
            case .opened: state = "geopend in Mail"
            default: state = "nog niet verstuurd"
            }
            parts.append("[mailconcept aan \(mail.to.isEmpty ? "?" : mail.to), onderwerp \"\(mail.subject)\", \(state)]")
        }
        if !retrieval.isEmpty {
            let searched = retrieval.map { step -> String in
                switch step.outcome {
                case .failed(let error): return "\(step.sourceTitle) (fout: \(error))"
                case .empty: return "\(step.sourceTitle) (niets gevonden)"
                default: return step.sourceTitle + (step.query.isEmpty ? "" : " \"\(step.query)\"")
                }
            }
            parts.append("[doorzocht: \(searched.joined(separator: ", "))]")
        }
        if !references.isEmpty {
            // Zodat een vervolgvraag ("stuur dat naar dezelfde persoon") weet waar het over ging.
            let list = references.prefix(8).map { "[\($0.number)] \($0.title)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") }
            parts.append("[bronnen bij dit antwoord: \(list.joined(separator: "; "))]")
        }
        if !actions.isEmpty {
            let state: String
            switch planState {
            case .pending, .running: state = "wacht op goedkeuring"
            case .done: state = "uitgevoerd"
            case .cancelled: state = "geannuleerd door de gebruiker"
            case .failed(let error): state = "niet helemaal gelukt: \(error)"
            }
            var steps: [String] = []
            for (index, action) in actions.enumerated() {
                let outcome: String
                switch index < actionStates.count ? actionStates[index] : .pending {
                case .done(let result): outcome = "gelukt: \(result)"
                case .failed(let error): outcome = "mislukt: \(error)"
                case .notRun: outcome = "niet uitgevoerd"
                case .skipped: outcome = "overgeslagen door de gebruiker"
                case .duplicate(let when): outcome = "niet opnieuw gedaan, al uitgevoerd op \(when)"
                case .running: outcome = "bezig"
                case .pending: outcome = planState == .cancelled ? "geannuleerd" : "wacht"
                }
                steps.append("\(index + 1). \(action.tool) \(Self.compactInput(action.input)) → \(outcome)")
            }
            parts.append("[voorgestelde acties — \(state)]\n" + steps.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    /// De invoer van een actie, kort, voor de geschiedenis van het brein.
    static func compactInput(_ input: [String: Any]) -> String {
        let pairs = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
            return "\(key)=\(text.count > 120 ? String(text.prefix(119)) + "…" : text)"
        }
        return "(" + pairs.joined(separator: ", ") + ")"
    }
}

/// Eén Nook: een gesprek over één onderwerp, met zijn eigen geschiedenis. Meerdere Nooks kunnen tegelijk werken.
struct Conversation: Identifiable {
    enum Status { case working, waiting, unread, idle }

    let id: UUID
    var title: String
    var created: Date
    var updated: Date
    var messages: [ChatMessage] = []
    var busy = false
    /// Klaar terwijl je naar iets anders keek.
    var unread = false
    /// Welke bronnen deze Nook mag gebruiken (de bronkiezer naast het invoerveld).
    var scope = SourceScope.automatic

    var isEmpty: Bool { messages.isEmpty }

    /// Wat de Nook nu doet, voor het stipje in de lijst.
    var status: Status {
        if busy { return .working }
        let waiting = messages.contains { message in
            (!message.actions.isEmpty && message.planState == .pending)
                || message.mails.contains { $0.state == .draft }
        }
        if waiting { return .waiting }
        return unread ? .unread : .idle
    }

    /// Eén regel onder de titel: wat Nook het laatst zei.
    var preview: String {
        guard let last = messages.last(where: { $0.role == .nook && !$0.text.isEmpty }) else { return "" }
        let flat = last.text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[#*_`>|]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(80))
    }

    /// Een titel uit de eerste vraag: kort, zonder vraagteken.
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

/// Alle Nooks. De geschiedenis blijft bewaard (lokaal, in je eigen map), ook als je Nook opnieuw start.
@MainActor
final class NookChat: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var activeID: UUID?
    private(set) var lastActivity = Date.distantPast
    private var saveTask: Task<Void, Never>?

    private let maxConversations = 40
    private let maxMessages = 80

    init() {
        load()
    }

    // MARK: Lezen

    var active: Conversation? { activeID.flatMap { conversation($0) } }
    var messages: [ChatMessage] { active?.messages ?? [] }
    var isEmpty: Bool { messages.isEmpty }
    /// Werkt de Nook die je nu ziet?
    var busy: Bool { active?.busy ?? false }
    /// Werkt er ergens een Nook?
    var anyBusy: Bool { conversations.contains { $0.busy } }

    /// Nooks met inhoud, laatst gebruikte eerst.
    var history: [Conversation] {
        conversations.filter { !$0.isEmpty || $0.busy }.sorted { $0.updated > $1.updated }
    }

    /// Kort geleden nog gepraat? Dan klapt het paneel niet vanzelf dicht.
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

    /// In welke Nook staat dit bericht?
    func conversationID(of messageID: UUID) -> UUID? {
        conversations.first { $0.messages.contains { $0.id == messageID } }?.id
    }

    // MARK: Nooks

    /// De Nook waar je nu in praat; is er geen, dan een nieuwe.
    @discardableResult
    func ensureActive() -> UUID {
        if let activeID, conversation(activeID) != nil { return activeID }
        return startNew()
    }

    /// Een nieuwe Nook. Is de huidige nog leeg, dan wordt die gewoon hergebruikt.
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
        // Een lege Nook die je achterlaat, hoeft niet bewaard te worden.
        conversations.removeAll { $0.isEmpty && !$0.busy && $0.id != id }
        scheduleSave()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeID == id { activeID = history.first?.id }
        scheduleSave()
    }

    func markUnread(_ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].unread = true
        scheduleSave()
    }

    // MARK: Berichten

    func append(_ message: ChatMessage, to id: UUID? = nil) {
        let target = id ?? ensureActive()
        guard let index = index(of: target) else { return }
        // De eerste vraag geeft de Nook zijn naam.
        if message.role == .user, !conversations[index].messages.contains(where: { $0.role == .user }) {
            conversations[index].title = Conversation.title(from: message.text)
        }
        conversations[index].messages.append(message)
        // Niet eindeloos groeien: de oudste berichten vallen eraf.
        if conversations[index].messages.count > maxMessages {
            conversations[index].messages.removeFirst(conversations[index].messages.count - maxMessages)
        }
        touch(index)
    }

    func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        for index in conversations.indices {
            if let message = conversations[index].messages.firstIndex(where: { $0.id == id }) {
                change(&conversations[index].messages[message])
                touch(index, save: !conversations[index].messages[message].streaming)
                return
            }
        }
    }

    func updateMail(_ mailID: UUID, _ change: (inout MailDraft) -> Void) {
        for index in conversations.indices {
            for message in conversations[index].messages.indices {
                if let mail = conversations[index].messages[message].mails.firstIndex(where: { $0.id == mailID }) {
                    change(&conversations[index].messages[message].mails[mail])
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

    /// De laatste vraag van de gebruiker in een Nook, voor Opnieuw proberen.
    func lastQuestion(in id: UUID) -> String? {
        conversation(id)?.messages.last(where: { $0.role == .user })?.text
    }

    func setBusy(_ value: Bool, conversation id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].busy = value
        touch(index)
    }

    /// De laatste beurten voor het brein, zonder het bericht dat nu beantwoord wordt.
    func history(before id: UUID, limit: Int = 16) -> [ChatTurn] {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == id } }) else { return [] }
        let earlier = conversation.messages.prefix { $0.id != id }
        return earlier.suffix(limit).compactMap { message in
            let text = message.isError ? "" : message.historyText
            guard !text.isEmpty else { return nil }
            return ChatTurn(fromUser: message.role == .user, text: String(text.prefix(4000)))
        }
    }

    // MARK: Intern

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    private func touch(_ index: Int, save: Bool = true) {
        conversations[index].updated = Date()
        lastActivity = Date()
        if save { scheduleSave() }
    }

    private func trim() {
        let keep = conversations.sorted { $0.updated > $1.updated }.prefix(maxConversations).map(\.id)
        conversations.removeAll { !keep.contains($0.id) }
    }

    // MARK: Bewaren

    private static var fileURL: URL { NookPaths.supportDirectory.appendingPathComponent("nooks.json") }

    /// Even wachten, zodat een stroom aan wijzigingen één keer schrijven is.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    private func save() {
        let stored = StoredChats(
            active: activeID,
            conversations: conversations.filter { !$0.isEmpty }.map { StoredConversation($0) }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(StoredChats.self, from: data) else { return }
        conversations = stored.conversations.map { $0.restored() }.filter { !$0.isEmpty }
        activeID = stored.active.flatMap { id in conversations.contains { $0.id == id } ? id : nil }
            ?? history.first?.id
    }
}

// MARK: Opslag op schijf

/// Wat er van een gesprek bewaard wordt. Acties die nog wachtten worden niet bewaard (die voer je niet uit na een herstart);
/// ze blijven als regel in de tekst staan, zodat het gesprek begrijpelijk blijft.
private struct StoredChats: Codable {
    var active: UUID?
    var conversations: [StoredConversation]
}

private struct StoredConversation: Codable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var unread: Bool
    var messages: [StoredMessage]
    /// Later toegevoegd: optioneel, zodat oudere nooks.json gewoon blijft laden.
    var scope: SourceScope?

    @MainActor
    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        created = conversation.created
        updated = conversation.updated
        unread = conversation.unread
        messages = conversation.messages.compactMap { StoredMessage($0) }
        scope = conversation.scope == .automatic ? nil : conversation.scope
    }

    func restored() -> Conversation {
        var conversation = Conversation(id: id, title: title, created: created, updated: updated)
        conversation.unread = unread
        conversation.scope = scope ?? .automatic
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
    // Later toegevoegd: optioneel, zodat oudere nooks.json gewoon blijft laden.
    var retrieval: [RetrievalStep]?
    var references: [SourceReference]?
    var contextSources: [String]?
    var scopeLabel: String?
    var notices: [String]?

    @MainActor
    init?(_ message: ChatMessage) {
        var text = message.text
        if !message.actions.isEmpty {
            // Een plan staat als regels in de tekst: wat er was voorgesteld en hoe elke stap afliep.
            // De acties zelf worden niet bewaard: na een herstart voert Nook niets meer uit.
            let steps = AppModel.shared.planSteps(message.actions)
            var lines: [String] = []
            for (index, step) in steps.enumerated() {
                let state: String
                switch index < message.actionStates.count ? message.actionStates[index] : .pending {
                case .done(let result): state = "✓ " + result
                case .failed(let error): state = "✗ mislukt: \(error)"
                case .duplicate(let when): state = "al gedaan op \(when)"
                case .skipped: state = "overgeslagen"
                case .notRun, .running: state = "niet uitgevoerd"
                case .pending: state = message.planState == .cancelled ? "geannuleerd" : "niet uitgevoerd"
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

/// Bij welk antwoord de tools van deze taak horen (grafieken, mailconcepten). Zo komen ze bij de juiste Nook,
/// ook als er meerdere tegelijk werken.
enum ReplyContext {
    @TaskLocal static var messageID: UUID?
}
