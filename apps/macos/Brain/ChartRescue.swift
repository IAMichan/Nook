import Foundation

/// When you ask for a chart, you want to see a chart, not code. Models sometimes output JSON, Chart.js, Mermaid,
/// Python, or a table instead of calling show_chart. This extracts data from those formats and renders a real chart.
enum ChartRescue {
    /// Does the request ask for a chart?
    static func wantsChart(_ text: String) -> Bool {
        let pattern = #"grafiek|diagram|\bchart|\bplot|visualis|grafisch|staafje|taartje|\bgraph"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Extracts charts from code blocks and returns the text without them. Empty code blocks are also removed.
    static func extract(from text: String, title: String) -> (text: String, charts: [ChatChart]) {
        guard let regex = try? NSRegularExpression(pattern: "```([A-Za-z0-9_+-]*)[^\\n]*\\n([\\s\\S]*?)```", options: []) else {
            return (text, [])
        }
        var result = text
        var charts: [ChatChart] = []
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Reverse order so that indices of preceding blocks remain valid.
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text),
                  let langRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let language = text[langRange].lowercased()
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var remove = body.isEmpty
            if !body.isEmpty, let chart = chart(fromCode: body, language: language, title: title) {
                charts.insert(chart, at: 0)
                remove = true
            }
            if remove, let range = result.range(of: String(text[whole])) {
                result.removeSubrange(range)
            }
        }
        // Bare JSON object without code block (e.g. from a text-protocol brain).
        if charts.isEmpty, let open = result.firstIndex(of: "{"), let close = result.lastIndex(of: "}"), open < close {
            let candidate = String(result[open...close])
            if let object = json(candidate), let chart = chart(fromJSON: object, title: title) {
                charts.append(chart)
                result.removeSubrange(open...close)
            }
        }
        let cleaned = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, charts)
    }

    /// While streaming: hide code blocks that resemble charts (even if incomplete).
    static func hidingChartCode(_ text: String) -> String {
        var visible = text.replacingOccurrences(
            of: "```(json|chart|vega|vega-lite|mermaid|javascript|js|python|py|swift)?[^\\n]*\\n[\\s\\S]*?```",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // An open/incomplete code block: strip everything from the opening fence onward.
        if visible.components(separatedBy: "```").count % 2 == 0, let open = visible.range(of: "```", options: .backwards) {
            visible = String(visible[..<open.lowerBound])
        }
        return visible
    }

    /// Converts a Markdown table with numeric data into a bar chart (or line chart for time series).
    static func chartFromTable(_ text: String, title: String) -> ChatChart? {
        for block in MarkdownBlock.parse(text) {
            guard case .table(let header, let rows) = block, let chart = chart(fromTable: header, rows: rows, title: title) else { continue }
            return chart
        }
        return nil
    }

    /// A table whose first column labels the rows and whose other columns are numbers becomes a chart.
    static func chart(fromTable header: [String], rows: [[String]], title: String) -> ChatChart? {
        do {
            guard rows.count >= 2, header.count >= 2 else { return nil }
            let labels = rows.map { $0.first ?? "" }
            var series: [ChatChart.Series] = []
            for column in 1..<header.count {
                let values = rows.map { $0.count > column ? number($0[column]) : nil }
                guard values.allSatisfy({ $0 != nil }) else { continue }
                let points = zip(labels, values).map { ChatChart.Point(label: $0, value: $1 ?? 0) }
                series.append(ChatChart.Series(name: header[column], points: points))
            }
            guard !series.isEmpty else { return nil }
            let kind: ChatChart.Kind = looksLikeTime(labels) && labels.count > 5 ? .line : .bar
            return ChatChart(title: title, kind: kind, unit: unit(in: rows), series: Array(series.prefix(4)))
        }
    }

    // MARK: From code

    static func chart(fromCode body: String, language: String, title: String) -> ChatChart? {
        if language == "mermaid" || body.hasPrefix("pie") || body.hasPrefix("xychart") {
            return mermaid(body, title: title)
        }
        if let object = json(body), let chart = chart(fromJSON: object, title: title) { return chart }
        // JavaScript objects (Chart.js) are often almost JSON: attempt to extract the object.
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close,
           let object = json(String(body[open...close])), let chart = chart(fromJSON: object, title: title) {
            return chart
        }
        return chart(fromLists: body, title: title)
    }

    private static func json(_ text: String) -> [String: Any]? {
        // Trailing commas before closing brackets and unquoted keys are common; sanitize them first.
        var fixed = text.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let object = (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any] { return object }
        fixed = fixed.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "\"")
        return (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any]
    }

    private static func chart(fromJSON object: [String: Any], title: String) -> ChatChart? {
        // A tool call formatted as raw text: {"name": "show_chart", "parameters": {...}}.
        if let name = (object["name"] as? String) ?? (object["tool"] as? String), name == "show_chart" {
            let input = (object["parameters"] as? [String: Any]) ?? (object["arguments"] as? [String: Any]) ?? (object["input"] as? [String: Any]) ?? [:]
            return ChatChart.parse(input)
        }
        // Chart.js: {"type": "bar", "data": {"labels": [...], "datasets": [{"label": ..., "data": [...]}]}}.
        if let data = object["data"] as? [String: Any], let labels = data["labels"] as? [Any], let sets = data["datasets"] as? [[String: Any]] {
            let names = labels.map { "\($0)" }
            let series: [ChatChart.Series] = sets.compactMap { set in
                let values = ((set["data"] as? [Any]) ?? []).map { number($0) }
                guard !values.isEmpty, values.count == names.count, values.allSatisfy({ $0 != nil }) else { return nil }
                return ChatChart.Series(name: (set["label"] as? String) ?? "", points: zip(names, values).map { ChatChart.Point(label: $0, value: $1 ?? 0) })
            }
            guard !series.isEmpty else { return nil }
            let kind = chartKind((object["type"] as? String) ?? "bar")
            let heading = ((object["options"] as? [String: Any]).flatMap { ($0["plugins"] as? [String: Any])?["title"] as? [String: Any] })?["text"] as? String
            return ChatChart(title: heading ?? title, kind: kind, unit: "", series: Array(series.prefix(4)))
        }
        // Vega-Lite: {"data": {"values": [...]}, "encoding": {"x": {"field": ...}, "y": {"field": ...}}, "mark": "bar"}.
        if let data = object["data"] as? [String: Any], let values = data["values"] as? [[String: Any]],
           let encoding = object["encoding"] as? [String: Any] {
            func field(_ key: String) -> String? { (encoding[key] as? [String: Any])?["field"] as? String }
            if let x = field("x") ?? field("color"), let y = field("y") ?? field("theta") {
                let points = values.compactMap { row -> ChatChart.Point? in
                    guard let value = number(row[y]) else { return nil }
                    return ChatChart.Point(label: row[x].map { "\($0)" } ?? "", value: value)
                }
                if !points.isEmpty {
                    let mark = (object["mark"] as? String) ?? ((object["mark"] as? [String: Any])?["type"] as? String) ?? "bar"
                    return ChatChart(title: (object["title"] as? String) ?? title, kind: chartKind(mark), unit: "", series: [ChatChart.Series(name: y, points: points)])
                }
            }
        }
        // Nook's native format, or similar structures (series/points, data with label/value).
        if var chart = ChatChart.parse(object) {
            if chart.title.isEmpty { chart.title = title }
            return chart
        }
        return nil
    }

    /// Mermaid: `pie` with `"Label" : 42`, or `xychart-beta` with `x-axis [a, b]` and `bar [1, 2]` / `line [...]`.
    private static func mermaid(_ body: String, title: String) -> ChatChart? {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var heading = title
        if let line = lines.first(where: { $0.hasPrefix("title") }) {
            heading = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        } else if let first = lines.first, first.hasPrefix("pie"), first.contains("title") {
            heading = first.components(separatedBy: "title").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? title
        }
        if lines.first?.hasPrefix("pie") == true {
            let points = lines.dropFirst().compactMap { line -> ChatChart.Point? in
                let parts = line.components(separatedBy: ":")
                guard parts.count == 2, let value = number(parts[1]) else { return nil }
                return ChatChart.Point(label: parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"")), value: value)
            }
            guard !points.isEmpty else { return nil }
            return ChatChart(title: heading, kind: .pie, unit: "", series: [ChatChart.Series(name: heading, points: points)])
        }
        guard let axis = lines.first(where: { $0.hasPrefix("x-axis") }) else { return nil }
        let labels = list(in: axis).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        var series: [ChatChart.Series] = []
        var kind: ChatChart.Kind = .bar
        for line in lines where line.hasPrefix("bar") || line.hasPrefix("line") {
            let values = list(in: line).map { number($0) }
            guard values.count == labels.count, values.allSatisfy({ $0 != nil }) else { continue }
            if line.hasPrefix("line") && series.isEmpty { kind = .line }
            series.append(ChatChart.Series(name: "", points: zip(labels, values).map { ChatChart.Point(label: $0, value: $1 ?? 0) }))
        }
        guard !series.isEmpty else { return nil }
        return ChatChart(title: heading, kind: kind, unit: "", series: Array(series.prefix(4)))
    }

    /// Python, JavaScript, or Swift: a list of labels and an equal-length list of numbers.
    private static func chart(fromLists body: String, title: String) -> ChatChart? {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\[\]]+)\]"#) else { return nil }
        let lists = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> [String]? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            return body[range].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let quoted = lists.filter { list in list.count >= 2 && list.allSatisfy { $0.hasPrefix("\"") || $0.hasPrefix("'") } }
        let numeric = lists.filter { list in list.count >= 2 && list.allSatisfy { number($0) != nil } }
        guard let labels = quoted.first else { return nil }
        let names = labels.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        let series = numeric.filter { $0.count == names.count }.prefix(4).map { values in
            ChatChart.Series(name: "", points: zip(names, values).map { ChatChart.Point(label: $0, value: number($1) ?? 0) })
        }
        guard !series.isEmpty else { return nil }
        var heading = title
        if let match = body.range(of: #"title\(\s*["']([^"']+)["']"#, options: .regularExpression) {
            heading = String(body[match]).components(separatedBy: CharacterSet(charactersIn: "\"'")).dropFirst().first ?? title
        }
        let kind: ChatChart.Kind = body.contains("pie(") || body.contains("'pie'") || body.contains("\"pie\"") ? .pie
            : (body.contains("plot(") || body.contains("'line'") || body.contains("\"line\"") ? .line : .bar)
        return ChatChart(title: heading, kind: kind, unit: "", series: Array(series))
    }

    // MARK: Helpers

    private static func list(in line: String) -> [String] {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return [] }
        return line[line.index(after: open)..<close].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func chartKind(_ raw: String) -> ChatChart.Kind {
        switch raw.lowercased() {
        case "line": return .line
        case "area": return .area
        case "pie", "doughnut", "donut", "arc": return .pie
        case "scatter", "point", "bubble": return .point
        default: return .bar
        }
    }

    /// Parses a number from strings like "€ 1,234.50", "12%", "3.5 hours" or simply 42.
    static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        guard var text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
        let negative = text.hasPrefix("-") || text.hasPrefix("−")
        text = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard text.contains(where: \.isNumber) else { return nil }
        if text.contains(",") && text.contains(".") {
            // The last separator is the decimal point: 1.234,50 or 1,234.50.
            if let comma = text.lastIndex(of: ","), let dot = text.lastIndex(of: "."), comma > dot {
                text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        } else if text.contains(",") {
            text = text.replacingOccurrences(of: ",", with: ".")
        } else if text.filter({ $0 == "." }).count > 1 {
            text = text.replacingOccurrences(of: ".", with: "")
        }
        guard let value = Double(text) else { return nil }
        return negative ? -value : value
    }

    private static func unit(in rows: [[String]]) -> String {
        let sample = rows.dropFirst(0).compactMap { $0.count > 1 ? $0[1] : nil }.joined()
        if sample.contains("€") { return "€" }
        if sample.contains("$") { return "$" }
        if sample.contains("%") { return "%" }
        return ""
    }

    private static func looksLikeTime(_ labels: [String]) -> Bool {
        let pattern = #"^(\d{1,2}[-/ ]\w+|\w{2,3}\.?$|\d{4}|(ma|di|wo|do|vr|za|zo|jan|feb|mrt|apr|mei|jun|jul|aug|sep|okt|nov|dec)\w*|\d{1,2}:\d{2}|week|q\d)"#
        return labels.allSatisfy { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
