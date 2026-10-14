import Foundation

/// Een eenvoudige regel-diff (langste gemeenschappelijke deelreeks). Genoeg voor bewerkingen van agents
/// en voor het voorbeeld van een instellingenbestand; heel grote stukken vallen terug op "alles weg, alles nieuw".
enum LineDiff {
    enum Op: Equatable {
        case same(String)
        case add(String)
        case remove(String)
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    static func diff(_ old: [String], _ new: [String]) -> [Op] {
        // Gemeenschappelijk begin en einde eerst, dan blijft er meestal weinig over.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        var ops = old[0..<prefix].map { Op.same($0) }

        if a.count * b.count > 250_000 {
            ops += a.map { Op.remove($0) } + b.map { Op.add($0) }
        } else {
            ops += middle(a, b)
        }
        ops += old[(old.count - suffix)...].map { Op.same($0) }
        return ops
    }

    private static func middle(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return b.map { .add($0) } }
        if m == 0 { return a.map { .remove($0) } }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.same(a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.remove(a[i])); i += 1
            } else {
                ops.append(.add(b[j])); j += 1
            }
        }
        while i < n { ops.append(.remove(a[i])); i += 1 }
        while j < m { ops.append(.add(b[j])); j += 1 }
        return ops
    }

    static func counts(_ ops: [Op]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for op in ops {
            switch op {
            case .add: added += 1
            case .remove: removed += 1
            case .same: break
            }
        }
        return (added, removed)
    }

    /// Alleen de gewijzigde regels met wat context eromheen, klaar om te tonen.
    static func display(_ ops: [Op], context: Int = 1, limit: Int = 40, width: Int = 110) -> [DiffLine] {
        var keep = Set<Int>()
        for (index, op) in ops.enumerated() {
            if case .same = op { continue }
            for k in max(0, index - context)...min(ops.count - 1, index + context) { keep.insert(k) }
        }
        var result: [DiffLine] = []
        var last = -1
        for index in keep.sorted() {
            if last >= 0, index > last + 1 { result.append(DiffLine(kind: .context, text: "  …")) }
            last = index
            switch ops[index] {
            case .same(let text): result.append(DiffLine(kind: .context, text: "  " + String(text.prefix(width))))
            case .add(let text): result.append(DiffLine(kind: .add, text: "+ " + String(text.prefix(width))))
            case .remove(let text): result.append(DiffLine(kind: .remove, text: "- " + String(text.prefix(width))))
            }
            if result.count >= limit {
                result.append(DiffLine(kind: .context, text: "  …"))
                break
            }
        }
        return result
    }
}
