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
    var sources: [String] = []
    var charts: [ChatChart] = []
    var mails: [MailDraft] = []
    /// Acties die Nook voorstelt; pas na "Uitvoeren" gebeuren ze echt.
    var actions: [PlannedAction] = []
    var planState: PlanState = .pending

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
        if !actions.isEmpty {
            let names = actions.map(\.tool).joined(separator: ", ")
            let state: String
            switch planState {
            case .pending, .running: state = "wacht op goedkeuring"
            case .done: state = "uitgevoerd"
            case .cancelled: state = "geannuleerd door de gebruiker"
            case .failed(let error): state = "mislukt: \(error)"
            }
            parts.append("[voorgestelde acties: \(names) — \(state)]")
        }
        return parts.joined(separator: "\n")
    }
}

/// Het lopende gesprek. Blijft bewaard zolang Nook draait, ook als het paneel dicht gaat.
@MainActor
final class NookChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var busy = false
    private(set) var lastActivity = Date.distantPast

    var isEmpty: Bool { messages.isEmpty }

    /// Kort geleden nog gepraat? Dan klapt het paneel niet vanzelf dicht.
    var isRecentlyActive: Bool { busy || Date().timeIntervalSince(lastActivity) < 180 }

    func append(_ message: ChatMessage) {
        messages.append(message)
        // Niet eindeloos groeien: de oudste berichten vallen eraf.
        if messages.count > 80 { messages.removeFirst(messages.count - 80) }
        lastActivity = Date()
    }

    func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
        lastActivity = Date()
    }

    func message(_ id: UUID) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    func updateMail(_ mailID: UUID, _ change: (inout MailDraft) -> Void) {
        for index in messages.indices {
            if let mail = messages[index].mails.firstIndex(where: { $0.id == mailID }) {
                change(&messages[index].mails[mail])
                lastActivity = Date()
                return
            }
        }
    }

    func setBusy(_ value: Bool) {
        busy = value
        lastActivity = Date()
    }

    func clear() {
        messages.removeAll()
        lastActivity = .distantPast
    }

    /// De laatste beurten voor het brein, zonder het bericht dat nu beantwoord wordt.
    func history(before id: UUID, limit: Int = 16) -> [ChatTurn] {
        let earlier = messages.prefix { $0.id != id }
        return earlier.suffix(limit).compactMap { message in
            let text = message.isError ? "" : message.historyText
            guard !text.isEmpty else { return nil }
            return ChatTurn(fromUser: message.role == .user, text: String(text.prefix(4000)))
        }
    }
}
