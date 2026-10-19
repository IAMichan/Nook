import Foundation

/// Uses lightweight handles instead of full bodies: a huge output stays out of the timeline and out of memory; the row shows a
/// preview and the lead's file layer stores the body under `id`.
enum OutputSpill {
    struct Handle: Equatable, Codable, Sendable {
        var id: String
        var byteCount: Int
        var previewHead: String
        /// The preview is shorter than the full output.
        var truncatedHead: Bool
    }

    static func shouldSpill(output: String, limit: Int = 16_000) -> Bool {
        output.utf8.count > limit
    }

    static func makeHandle(id: String, output: String, previewCharacters: Int = 2_000) -> Handle {
        let head = String(output.prefix(previewCharacters))
        return Handle(id: id, byteCount: output.utf8.count, previewHead: head, truncatedHead: head.count < output.count)
    }

    /// Cuts on a character boundary within `limit` UTF-8 bytes.
    static func clipDetail(_ text: String, limit: Int = 32 * 1024) -> String {
        guard text.utf8.count > limit else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text[index].utf8.count
            if bytes + next > limit { break }
            bytes += next
            end = text.index(after: index)
        }
        return String(text[..<end]) + "\n…"
    }
}

enum PlanPreview {
    static func title(from markdown: String) -> String? {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { continue }
            let text = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func needsExpand(_ text: String) -> Bool {
        text.count > 900 || text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > 20
    }

    /// First `lines` non-empty lines; "..." marks that more follows.
    static func preview(_ text: String, lines maxLines: Int = 10) -> String {
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var out: [String] = []
        var visible = 0
        var more = false
        for line in all {
            let isVisible = !line.trimmingCharacters(in: .whitespaces).isEmpty
            if isVisible && visible >= maxLines { more = true; break }
            out.append(line)
            if isVisible { visible += 1 }
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        if out.isEmpty { return title(from: text) ?? "" }
        if more { out += ["", "..."] }
        return out.joined(separator: "\n")
    }

    static func fileName(forTitle title: String) -> String {
        let cleaned = title.lowercased()
            .replacingOccurrences(of: "[`'\".,!?()\\[\\]{}]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (cleaned.isEmpty ? "plan" : cleaned) + ".md"
    }
}

enum ContextMeter {
    enum Level: Equatable, Sendable { case normal, warning, critical }

    static func level(_ fraction: Double) -> Level {
        fraction > 0.9 ? .critical : fraction >= 0.75 ? .warning : .normal
    }

    static func percentText(_ fraction: Double) -> String {
        let pct = min(max(fraction, 0), 1) * 100
        if pct < 10 { return String(format: "%.1f%%", pct) }
        return "\(Int(pct.rounded()))%"
    }

    static func tokensText(used: Int, window: Int) -> String { "\(compact(used))/\(compact(window))" }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return (m.rounded() == m ? String(Int(m)) : String(format: "%.1f", m)) + "m"
        }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return "\(n)"
    }
}
