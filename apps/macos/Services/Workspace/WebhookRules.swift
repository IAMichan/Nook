import Foundation

// What a webhook task does with a verified delivery before it runs: the values its prompt names (`{{body.path}}`,
// `{{headers.name}}`), the filters that decide whether it runs at all, the key that recognises a repeated delivery, the
// window that folds a burst into one run, and the bounded log of what happened to each delivery. Foundation only, so the
// rules are tested on their own; `ScheduledTaskStore` applies them.

/// A delivery as the rules see it: the body and the headers (names in lower case).
struct WebhookRequestData: Sendable {
    var body: Data
    var headers: [String: String]

    init(body: Data, headers: [String: String]) {
        self.body = body
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        parsed = Self.parse(body: body, contentType: self.headers["content-type"])
    }

    /// The body as JSON, or as form fields (`a=1&b=2`) when the sender says it is a form. Nil when it is neither.
    private let parsed: ParsedBody?

    private enum ParsedBody: @unchecked Sendable {
        case json(Any)
        case form([String: String])
    }

    private static func parse(body: Data, contentType: String?) -> ParsedBody? {
        if contentType?.lowercased().contains("application/x-www-form-urlencoded") == true {
            var fields: [String: String] = [:]
            var components = URLComponents()
            components.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
            for item in components.queryItems ?? [] { fields[item.name] = item.value ?? "" }
            return .form(fields)
        }
        guard !body.isEmpty, let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
        return .json(json)
    }

    /// What a name such as `body.pull_request.number`, `body.items.0.id`, `body` or `headers.x-github-event` points at.
    enum Value: Equatable, Sendable {
        case missing
        /// Text, a number or a boolean, as text.
        case text(String)
        /// An object or a list, as compact JSON: only `exists` passes on it.
        case structured(String)

        var text: String? {
            switch self {
            case .missing: return nil
            case .text(let text), .structured(let text): return text
            }
        }
    }

    func value(_ name: String) -> Value {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name == "body" { return body.isEmpty ? .missing : .text(String(decoding: body, as: UTF8.self)) }
        if name.hasPrefix("headers.") {
            let header = String(name.dropFirst("headers.".count)).lowercased()
            return headers[header].map(Value.text) ?? .missing
        }
        guard name.hasPrefix("body.") else { return .missing }
        let path = name.dropFirst("body.".count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.contains(where: \.isEmpty) else { return .missing }
        switch parsed {
        case .form(let fields)?:
            return path.count == 1 ? fields[path[0]].map(Value.text) ?? .missing : .missing
        case .json(let root)?:
            var current: Any = root
            for key in path {
                if let object = current as? [String: Any], let next = object[key] {
                    current = next
                } else if let list = current as? [Any], let index = Int(key), list.indices.contains(index) {
                    current = list[index]
                } else {
                    return .missing
                }
            }
            return Self.describe(current)
        case nil:
            return .missing
        }
    }

    private static func describe(_ value: Any) -> Value {
        switch value {
        case is NSNull: return .missing
        case let text as String: return .text(text)
        case let number as NSNumber:
            // JSON booleans come in as NSNumber too; they read as true/false, not 1/0.
            #if canImport(Darwin)
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            #else
            // swift-corelibs-foundation (the tests on Linux): a JSON boolean is an NSNumber of type "c".
            let isBool = String(cString: number.objCType) == "c"
            #endif
            if isBool { return .text(number.boolValue ? "true" : "false") }
            return .text(number.stringValue)
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return .structured("") }
            return .structured(String(decoding: data, as: UTF8.self))
        }
    }
}

/// `{{body.path}}` and `{{headers.name}}` in a template.
enum WebhookTemplate {
    /// At most this much of one value reaches the prompt.
    static let maxValueCharacters = 4_000

    /// The placeholders in `template`, in order (names without braces), only those that name a request value.
    static func placeholders(in template: String) -> [String] {
        matches(in: template).map(\.name)
    }

    /// The prompt with each placeholder replaced by its value inside an `<untrusted-webhook-value>` tag, so the agent can
    /// tell what came from outside. A value can never close its own tag: `<` and `>` inside it become look-alikes.
    /// A placeholder without a value leaves an empty tag.
    static func renderPrompt(_ template: String, request: WebhookRequestData) -> String {
        replace(template) { name in
            let value = sanitize(request.value(name).text ?? "")
            return "<untrusted-webhook-value field=\"\(name)\">\(value)</untrusted-webhook-value>"
        }
    }

    /// A key such as `{{headers.x-github-delivery}}` or `{{body.pull_request.id}}-{{body.action}}`, filled with the plain
    /// values. Nil when the template names no value, when one of them is missing, or when the result is empty: then the
    /// rule it belongs to does not apply to this delivery.
    static func renderKey(_ template: String, request: WebhookRequestData) -> String? {
        let found = matches(in: template)
        guard !found.isEmpty else { return nil }
        var missing = false
        let key = replace(template) { name in
            guard let text = request.value(name).text, !text.isEmpty else { missing = true; return "" }
            return text
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !missing, !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(512))
    }

    private struct Match { var range: Range<String.Index>; var name: String }

    private static func matches(in template: String) -> [Match] {
        var found: [Match] = []
        var search = template.startIndex..<template.endIndex
        while let open = template.range(of: "{{", range: search),
              let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) {
            let name = template[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if name == "body" || name.hasPrefix("body.") || name.hasPrefix("headers."), !name.contains("{") {
                found.append(Match(range: open.lowerBound..<close.upperBound, name: name))
                search = close.upperBound..<template.endIndex
            } else {
                search = open.upperBound..<template.endIndex
            }
        }
        return found
    }

    private static func replace(_ template: String, with value: (String) -> String) -> String {
        var result = ""
        var cursor = template.startIndex
        for match in matches(in: template) {
            result += template[cursor..<match.range.lowerBound]
            result += value(match.name)
            cursor = match.range.upperBound
        }
        result += template[cursor...]
        return result
    }

    /// No control characters but tab and newline, no way to end the tag, and cut off at `maxValueCharacters`.
    static func sanitize(_ value: String) -> String {
        var text = String(value.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || !CharacterSet.controlCharacters.contains($0) })
        text = text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
        if text.count > maxValueCharacters { text = String(text.prefix(maxValueCharacters)) + "…" }
        return text
    }
}

/// One test on a delivery: a value named like a placeholder (`headers.x-github-event`, `body.action`) equals a text,
/// is one of several, or exists. Values compare as text; an object or a list only passes `exists`.
struct WebhookFilter: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Test: String, Codable, CaseIterable, Sendable {
        case equals, oneOf, exists
    }

    var id = UUID()
    var field: String
    var test: Test
    /// For `oneOf`: the choices, separated by commas.
    var value: String

    init(id: UUID = UUID(), field: String, test: Test, value: String = "") {
        self.id = id; self.field = field; self.test = test; self.value = value
    }

    private enum CodingKeys: String, CodingKey { case field, test, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = (try? c.decode(String.self, forKey: .field)) ?? ""
        // An unknown test never passes as "exists": it is read as equals, which a missing value fails.
        test = (try? c.decode(Test.self, forKey: .test)) ?? .equals
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(test, forKey: .test)
        try c.encode(value, forKey: .value)
    }

    /// The choices of `oneOf`, trimmed, without empty ones.
    var choices: [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func passes(_ request: WebhookRequestData) -> Bool {
        let found = request.value(field)
        switch test {
        case .exists:
            return found != .missing
        case .equals:
            if case .text(let text) = found { return text == value }
            return false
        case .oneOf:
            if case .text(let text) = found { return choices.contains(text) }
            return false
        }
    }

    /// "body.action is one of opened, reopened", for the deliveries log.
    var summary: String {
        switch test {
        case .equals: return "\(field) = \(value)"
        case .oneOf: return "\(field) ∈ \(choices.joined(separator: ", "))"
        case .exists: return "\(field) exists"
        }
    }
}

/// The rules of one webhook task.
struct WebhookRules: Codable, Equatable, Sendable {
    /// Every filter must pass, or the delivery starts nothing.
    var filters: [WebhookFilter] = []
    /// A template such as `{{headers.x-github-delivery}}`: a delivery with a key seen in the last week is skipped.
    var duplicateKey: String = ""
    /// Deliveries within this many seconds of the first become one run, with the latest delivery. 0 is off.
    var coalesceSeconds: Int = 0

    static let coalesceRange = 10...3600
    static let duplicateWindow: TimeInterval = 7 * 24 * 3600

    init(filters: [WebhookFilter] = [], duplicateKey: String = "", coalesceSeconds: Int = 0) {
        self.filters = filters; self.duplicateKey = duplicateKey; self.coalesceSeconds = coalesceSeconds
    }

    private enum CodingKeys: String, CodingKey { case filters, duplicateKey, coalesceSeconds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filters = (try? c.decode([WebhookFilter].self, forKey: .filters)) ?? []
        duplicateKey = (try? c.decode(String.self, forKey: .duplicateKey)) ?? ""
        coalesceSeconds = (try? c.decode(Int.self, forKey: .coalesceSeconds)) ?? 0
    }

    var isEmpty: Bool { filters.isEmpty && duplicateKey.isEmpty && coalesceSeconds == 0 }

    /// The window in seconds, or nil when off. A stored value outside the range is pulled into it.
    var coalesceWindow: TimeInterval? {
        guard coalesceSeconds > 0 else { return nil }
        return TimeInterval(min(max(coalesceSeconds, Self.coalesceRange.lowerBound), Self.coalesceRange.upperBound))
    }

    /// The first filter that fails, or nil when the delivery may run.
    func failingFilter(_ request: WebhookRequestData) -> WebhookFilter? {
        filters.first { !$0.passes(request) }
    }
}

/// Keys of deliveries seen in the last week, per task, so the same event delivered again (a retry with a new delivery
/// id, a second hook for the same thing) runs once. Bounded.
struct WebhookDedupe: Codable, Equatable, Sendable {
    static let capacity = 500
    private(set) var seen: [String: Date] = [:]

    init() {}

    /// True the first time `key` is seen within the window; records it.
    mutating func claim(_ key: String, now: Date, window: TimeInterval = WebhookRules.duplicateWindow) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        if seen[key] != nil { return false }
        seen[key] = now
        if seen.count > Self.capacity, let oldest = seen.min(by: { $0.value < $1.value })?.key { seen[oldest] = nil }
        return true
    }
}

/// A burst of deliveries folded into one run: the window opens with the first delivery and closes `seconds` later
/// (later deliveries do not extend it); the run gets the latest delivery and how many came in.
struct WebhookCoalescer<Delivery: Sendable>: Sendable {
    struct Window: Sendable {
        var closesAt: Date
        var latest: Delivery
        var count: Int
    }

    private(set) var windows: [UUID: Window] = [:]

    enum Outcome: Equatable, Sendable {
        /// A new window: flush it at this time.
        case opened(closesAt: Date)
        /// Folded into the open window; this many deliveries are in it now.
        case merged(count: Int)
    }

    mutating func add(_ delivery: Delivery, task: UUID, seconds: TimeInterval, now: Date) -> Outcome {
        if var window = windows[task], window.closesAt > now {
            window.latest = delivery
            window.count += 1
            windows[task] = window
            return .merged(count: window.count)
        }
        let closes = now.addingTimeInterval(seconds)
        windows[task] = Window(closesAt: closes, latest: delivery, count: 1)
        return .opened(closesAt: closes)
    }

    /// The window of `task` once it closed, removed; nil while it is open or when there is none.
    mutating func flush(_ task: UUID, now: Date) -> Window? {
        guard let window = windows[task], window.closesAt <= now else { return nil }
        windows[task] = nil
        return window
    }

    mutating func forget(_ task: UUID) { windows[task] = nil }

    var isEmpty: Bool { windows.isEmpty }
}

/// What happened to one verified delivery, for the task's Deliveries log.
struct WebhookDeliveryRecord: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        /// It runs (or waits for its turn).
        case accepted
        /// A filter failed: nothing ran.
        case filtered
        /// Its key was seen before: nothing ran.
        case duplicate
        /// Folded into a burst that runs once.
        case coalesced
        /// Too many deliveries waited already.
        case queueFull
    }

    var id = UUID()
    var deliveryID: String
    var receivedAt: Date
    var outcome: Outcome
    /// Why, in plain words for the log: the failing filter, the key, the size of the burst.
    var detail: String?

    static let limit = 50

    /// `log` with `record` first, at most `limit` long.
    static func appending(_ record: WebhookDeliveryRecord, to log: [WebhookDeliveryRecord]) -> [WebhookDeliveryRecord] {
        Array(([record] + log).prefix(limit))
    }
}
