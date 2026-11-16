import Foundation

/// A saved prompt: a title, a body that may hold `{{variables}}`, and an optional trigger typed in the composer
/// (`/summarize`) or the command palette. `{{name}}` is asked for when the prompt is used; `{{name|default}}` starts with a
/// default. The same name used twice is asked once.
struct SavedPrompt: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var body: String
    /// Lowercase letters, digits, `-` and `_`, without the slash; empty for a prompt that has no trigger.
    var trigger = ""
    var updatedAt = Date()

    struct Variable: Equatable, Sendable {
        var name: String
        var defaultValue: String
    }

    /// The variables in the body, in the order they first appear.
    var variables: [Variable] {
        var seen = Set<String>()
        var result: [Variable] = []
        for match in Self.pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let parsed = Self.parse(body, match) else { continue }
            if seen.insert(parsed.name).inserted { result.append(parsed) }
        }
        return result
    }

    /// The body with each variable replaced by its value; one without a value gets its default, else stays empty.
    func render(_ values: [String: String]) -> String {
        var output = body
        let matches = Self.pattern.matches(in: body, range: NSRange(body.startIndex..., in: body))
        // From the end, so the earlier ranges stay valid.
        for match in matches.reversed() {
            guard let parsed = Self.parse(body, match), let range = Range(match.range, in: output) else { continue }
            let value = values[parsed.name].flatMap { $0.isEmpty ? nil : $0 } ?? parsed.defaultValue
            output.replaceSubrange(range, with: value)
        }
        return output
    }

    private static let pattern = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?:\\|([^}]*))?\\}\\}")

    private static func parse(_ text: String, _ match: NSTextCheckingResult) -> Variable? {
        guard let name = Range(match.range(at: 1), in: text) else { return nil }
        let fallback = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        return Variable(name: String(text[name]), defaultValue: fallback)
    }

    /// A trigger as typed: the slash and anything but letters, digits, `-` and `_` taken out, lowercased.
    static func cleanTrigger(_ raw: String) -> String {
        String(raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    init(id: UUID = UUID(), title: String, body: String, trigger: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.trigger = trigger
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, title, body, trigger, updatedAt }

    /// Fields with a default may be missing (a file from an older version): they get the default instead of failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// The prompts the user saved, newest edit first. Foundation only; the app keeps it in `prompts.json` in Nook's folder.
struct PromptLibrary: Codable, Equatable, Sendable {
    var prompts: [SavedPrompt] = []

    /// Adds or replaces a prompt. A trigger another prompt already has is dropped from the new one (a trigger names one
    /// prompt); a prompt with no words in it is not saved. Returns whether it was kept.
    @discardableResult
    mutating func save(_ prompt: SavedPrompt) -> Bool {
        var prompt = prompt
        prompt.title = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.body = prompt.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.title.isEmpty, !prompt.body.isEmpty else { return false }
        prompt.trigger = SavedPrompt.cleanTrigger(prompt.trigger)
        if !prompt.trigger.isEmpty, prompts.contains(where: { $0.trigger == prompt.trigger && $0.id != prompt.id }) {
            prompt.trigger = ""
        }
        prompt.updatedAt = Date()
        prompts.removeAll { $0.id == prompt.id }
        prompts.insert(prompt, at: 0)
        return true
    }

    mutating func remove(_ id: UUID) { prompts.removeAll { $0.id == id } }

    func prompt(trigger: String) -> SavedPrompt? {
        let wanted = SavedPrompt.cleanTrigger(trigger)
        return wanted.isEmpty ? nil : prompts.first { $0.trigger == wanted }
    }

    /// The prompts a typed word offers: a trigger that starts with it first, then a title or body that contains it.
    func matches(_ query: String) -> [SavedPrompt] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return prompts }
        let bare = SavedPrompt.cleanTrigger(q)
        let byTrigger = prompts.filter { !$0.trigger.isEmpty && $0.trigger.hasPrefix(bare) }
        let rest = prompts.filter { prompt in
            !byTrigger.contains(prompt) && (prompt.title.lowercased().contains(q) || prompt.body.lowercased().contains(q))
        }
        return byTrigger + rest
    }

    /// Prompt by prompt: one that cannot be read is left out, and the original file is kept aside first (`SafeStorage`),
    /// so the next save never takes the user's prompts with it.
    static func load(_ url: URL) -> PromptLibrary {
        SafeStorage.load(Stored.self, from: url, skipped: { $0.prompts.skipped }).value.map { PromptLibrary(prompts: $0.prompts.elements) }
            ?? PromptLibrary()
    }

    private struct Stored: Decodable {
        var prompts: LossyArray<SavedPrompt>
        private enum CodingKeys: String, CodingKey { case prompts }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompts = try container.decodeIfPresent(LossyArray<SavedPrompt>.self, forKey: .prompts) ?? LossyArray([])
        }
    }

    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? SafeStorage.write(data, to: url)
    }
}
