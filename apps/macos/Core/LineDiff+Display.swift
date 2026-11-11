import Foundation

// The part of `LineDiff` that draws: it needs `DiffLine` (AgentSession.swift), which the Foundation-only core tests leave out.

extension LineDiff {
    /// Only the changed lines with surrounding context, formatted for display.
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
