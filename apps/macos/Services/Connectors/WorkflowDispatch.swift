import Foundation

/// One input a workflow asks for when you start it by hand (`on: workflow_dispatch: inputs:`), as the Actions page's
/// run form shows it: a text field, a checkbox, a choice, a number, or an environment's name.
struct WorkflowInput: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case string, boolean, choice, number, environment
    }

    let name: String
    var description = ""
    var required = false
    /// The value GitHub uses when none is given; "true"/"false" for a boolean.
    var defaultValue = ""
    var kind: Kind = .string
    /// The values of a choice, in the file's order.
    var options: [String] = []

    var id: String { name }

    /// What the form starts with: the default, the first option of a choice without one, "false" for a boolean.
    var initialValue: String {
        if !defaultValue.isEmpty { return kind == .boolean ? String(WorkflowDispatch.isTrue(defaultValue)) : defaultValue }
        switch kind {
        case .boolean: return "false"
        case .choice: return options.first ?? ""
        default: return ""
        }
    }
}

/// Starting a workflow by hand (`POST /actions/workflows/{id}/dispatches`): whether its file allows it, the inputs it
/// asks for, and the body GitHub expects. Foundation only, so tests can use it.
enum WorkflowDispatch {
    /// The inputs of a workflow that can be started by hand, in the file's order; nil when its `on:` has no
    /// `workflow_dispatch`. Reads only the file's top-level `on:` block, with the YAML a workflow uses there.
    static func inputs(_ file: String) -> [WorkflowInput]? {
        guard let trigger = MiniYAML.topLevel(["on", "true"], in: file) else { return nil }
        switch trigger {
        case .scalar(let event):
            // `on: workflow_dispatch`, or a flow map `on: { workflow_dispatch: … }` written on one line.
            let words = event.components(separatedBy: CharacterSet(charactersIn: "{}[], :")).filter { !$0.isEmpty }
            return words.contains("workflow_dispatch") ? [] : nil
        case .list(let events):
            return events.contains { $0.scalar == "workflow_dispatch" } ? [] : nil
        case .map(let events):
            guard let dispatch = events.first(where: { $0.key == "workflow_dispatch" })?.value else { return nil }
            guard case .map(let fields) = dispatch, let inputs = fields.first(where: { $0.key == "inputs" })?.value,
                  case .map(let list) = inputs else { return [] }
            return list.map { input(name: $0.key, $0.value) }
        case .null:
            return nil
        }
    }

    private static func input(name: String, _ node: MiniYAML.Node) -> WorkflowInput {
        var result = WorkflowInput(name: name)
        guard case .map(let fields) = node else { return result }
        for (key, value) in fields {
            switch key {
            case "description": result.description = value.scalar ?? ""
            case "required": result.required = isTrue(value.scalar ?? "")
            case "default": result.defaultValue = value.scalar ?? ""
            case "type": result.kind = WorkflowInput.Kind(rawValue: (value.scalar ?? "").lowercased()) ?? .string
            case "options":
                if case .list(let items) = value { result.options = items.compactMap(\.scalar) }
                else if let one = value.scalar, !one.isEmpty { result.options = [one] }
            default: break
            }
        }
        return result
    }

    static func isTrue(_ text: String) -> Bool {
        ["true", "yes", "on", "y"].contains(text.lowercased())
    }

    /// The inputs that are required and still empty, by name. A checkbox is never empty.
    static func missing(_ inputs: [WorkflowInput], values: [String: String]) -> [String] {
        inputs.filter { input in
            input.required && input.kind != .boolean
                && (values[input.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.name)
    }

    /// The JSON body of a dispatch: the branch or tag, and the inputs the workflow declares (an empty optional one left
    /// out, so GitHub uses its default). `return_run_details` asks GitHub to answer with the new run's id.
    static func body(ref: String, inputs: [WorkflowInput], values: [String: String]) -> [String: Any] {
        var sent: [String: String] = [:]
        for input in inputs {
            let value = (values[input.name] ?? input.initialValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if input.kind == .boolean {
                sent[input.name] = String(isTrue(value))
            } else if !value.isEmpty {
                sent[input.name] = value
            }
        }
        var body: [String: Any] = ["ref": ref, "return_run_details": true]
        if !sent.isEmpty { body["inputs"] = sent }
        return body
    }

    /// The new run's id in GitHub's answer to a dispatch with `return_run_details`; nil for an empty answer (204).
    static func runID(_ json: Any?) -> Int? {
        let value = (json as? [String: Any])?["workflow_run_id"]
        if let id = value as? Int { return id }
        return (value as? NSNumber)?.intValue
    }

    /// A workflow file's text from `GET /repos/{repo}/contents/{path}`: its base64 `content`.
    static func fileText(_ json: Any?) -> String? {
        guard let content = (json as? [String: Any])?["content"] as? String,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The branch names of `GET /repos/{repo}/branches`, with the default branch first.
    static func branches(_ json: Any?, defaultBranch: String) -> [String] {
        let names = ((json as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        let rest = names.filter { $0 != defaultBranch }
        return defaultBranch.isEmpty ? rest : [defaultBranch] + rest
    }

    /// `GET /repos/{repo}/contents/{path}?ref=…`, the path and ref percent-encoded.
    static func filePath(repo: String, path: String, ref: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let file = path.split(separator: "@", maxSplits: 1).first.map(String.init) ?? path
        let encodedPath = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: allowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? ref
        return "/repos/\(repo)/contents/\(encodedPath)?ref=\(encodedRef)"
    }
}

/// Just enough YAML to read a workflow's `on:` block: block maps and lists by indentation, flow lists of scalars,
/// quoted and plain scalars, `|` and `>` block scalars, and comments. Not a general YAML parser.
enum MiniYAML {
    indirect enum Node: Equatable {
        case null
        case scalar(String)
        case list([Node])
        case map([(key: String, value: Node)])

        var scalar: String? {
            if case .scalar(let text) = self { return text }
            return nil
        }

        static func == (lhs: Node, rhs: Node) -> Bool {
            switch (lhs, rhs) {
            case (.null, .null): return true
            case (.scalar(let a), .scalar(let b)): return a == b
            case (.list(let a), .list(let b)): return a == b
            case (.map(let a), .map(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
            default: return false
            }
        }
    }

    struct Line {
        var indent: Int
        /// The line without its indentation and comment.
        var text: String
        /// The line as written, for block scalars.
        var raw: String
    }

    /// The value of the first top-level key among `keys` (quoted or not: `"on":`), or nil when the file has none of them.
    static func topLevel(_ keys: [String], in file: String) -> Node? {
        let lines = file.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            guard let first = raw.first, first != " ", first != "\t", first != "#" else { continue }
            let text = stripComment(raw)
            guard let (key, value) = split(text), keys.contains(key) else { continue }
            // The block: every following line that is blank or indented, until the next top-level line.
            var block: [Line] = []
            while index < lines.count {
                let next = lines[index]
                if let char = next.first, char != " ", char != "\t", char != "#" { break }
                index += 1
                block.append(line(next))
            }
            if !value.isEmpty, !isBlockScalarMark(value) { return inline(value) }
            let content = block.filter { !$0.text.isEmpty }
            guard let start = content.first else { return .null }
            var cursor = 0
            return parse(content, &cursor, indent: start.indent)
        }
        return nil
    }

    private static func line(_ raw: String) -> Line {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
        let text = stripComment(String(raw.dropFirst(indent))).trimmingCharacters(in: .whitespaces)
        return Line(indent: indent, text: text, raw: raw)
    }

    /// A block (a map or a list) whose lines start at `indent`.
    private static func parse(_ lines: [Line], _ i: inout Int, indent: Int) -> Node {
        guard i < lines.count else { return .null }
        return isListItem(lines[i].text) ? parseList(lines, &i, indent: indent) : parseMap(lines, &i, indent: indent)
    }

    private static func isListItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func parseList(_ lines: [Line], _ i: inout Int, indent: Int) -> Node {
        var items: [Node] = []
        var lines = lines
        while i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
            let rest = String(lines[i].text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                i += 1
                items.append(i < lines.count && lines[i].indent > indent ? parse(lines, &i, indent: lines[i].indent) : .null)
            } else if split(rest) != nil {
                // "- key: value": a map whose first line starts after the dash.
                let offset = lines[i].text.count - rest.count
                lines[i] = Line(indent: indent + offset, text: rest, raw: lines[i].raw)
                items.append(parseMap(lines, &i, indent: indent + offset))
            } else {
                items.append(inline(rest))
                i += 1
            }
        }
        return .list(items)
    }

    private static func parseMap(_ lines: [Line], _ i: inout Int, indent: Int) -> Node {
        var entries: [(key: String, value: Node)] = []
        while i < lines.count {
            let line = lines[i]
            if line.indent < indent { break }
            // A line deeper than its map that nothing took (malformed): skip it.
            if line.indent > indent {
                i += 1
                continue
            }
            if isListItem(line.text) { break }
            guard let (key, value) = split(line.text) else {
                i += 1
                continue
            }
            i += 1
            if isBlockScalarMark(value) {
                entries.append((key, .scalar(blockScalar(lines, &i, parent: indent, folded: value.hasPrefix(">")))))
            } else if !value.isEmpty {
                entries.append((key, inline(value)))
            } else if i < lines.count, lines[i].indent > indent {
                entries.append((key, parse(lines, &i, indent: lines[i].indent)))
            } else if i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
                // A list may sit at its key's own indentation.
                entries.append((key, parseList(lines, &i, indent: indent)))
            } else {
                entries.append((key, .null))
            }
        }
        return .map(entries)
    }

    private static func isBlockScalarMark(_ value: String) -> Bool {
        guard let first = value.first, first == "|" || first == ">" else { return false }
        return value.dropFirst().allSatisfy { "+-0123456789".contains($0) }
    }

    /// The lines of a `|` or `>` block under a key at `parent`, as written (comments included), without their indentation.
    private static func blockScalar(_ lines: [Line], _ i: inout Int, parent: Int, folded: Bool) -> String {
        var parts: [String] = []
        var base: Int?
        while i < lines.count, lines[i].indent > parent {
            let raw = lines[i].raw
            let indent = base ?? lines[i].indent
            base = indent
            parts.append(String(raw.dropFirst(min(indent, raw.prefix { $0 == " " }.count))))
            i += 1
        }
        return parts.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A value written on its key's line: a flow list, or a scalar.
    private static func inline(_ value: String) -> Node {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            return .list(splitFlow(inner).map { .scalar(unquote($0)) })
        }
        if text == "~" || text == "null" { return .null }
        return .scalar(unquote(text))
    }

    /// The items of a flow list, split at commas outside quotes.
    private static func splitFlow(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for char in text {
            if let open = quote {
                if char == open { quote = nil }
                current.append(char)
            } else if char == "\"" || char == "'" {
                quote = char
                current.append(char)
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func unquote(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// "key: value" split at the first colon outside quotes that ends the line or has a space after it.
    static func split(_ text: String) -> (String, String)? {
        var quote: Character?
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            if let open = quote {
                if char == open { quote = nil }
                continue
            }
            if (char == "\"" || char == "'") && index == 0 { quote = char; continue }
            guard char == ":", index + 1 == chars.count || chars[index + 1] == " " || chars[index + 1] == "\t" else { continue }
            let key = String(chars[..<index]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            let value = String(chars[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            return (unquote(key), value)
        }
        return nil
    }

    /// The line without a `# comment` (a `#` at the start or after a space, outside quotes).
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var result = ""
        for char in text {
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'", previous == " " || previous == "[" || previous == "," || previous == ":" {
                quote = char
            } else if char == "#", previous == " " || previous == "\t" {
                break
            }
            result.append(char)
            previous = char
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
