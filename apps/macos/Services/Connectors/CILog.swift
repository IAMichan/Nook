import Foundation

/// What a CI check shows when you open it from a watched pull request: the steps of its job and, once GitHub has it,
/// the log. Parsed from GitHub's REST answers by `CILogParser`; Foundation only, so tests can use it.
struct CILog: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let number: Int
        let name: String
        let outcome: PullRequestCheck.Outcome
    }

    var steps: [Step] = []
    /// The end of the log, cleaned up for reading; nil while GitHub has none yet (a job that still runs).
    var text: String?
    /// Lines left out at the top because the log was longer than Nook shows.
    var omittedLines = 0
}

enum CILogParser {
    /// The lines of a log Nook shows: the end, where a failure is.
    static let maxLines = 2_000

    /// The job id of a GitHub Actions check ("…/actions/runs/123/job/456" → 456); nil for a check from another app.
    static func jobID(from url: URL?) -> Int? {
        guard let url, url.host?.hasSuffix("github.com") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "job"), parts.index(after: index) < parts.endIndex,
              parts.contains("actions") else { return nil }
        return Int(parts[parts.index(after: index)])
    }

    /// The steps of `GET /actions/jobs/{id}`, in order.
    static func steps(job: [String: Any]) -> [CILog.Step] {
        ((job["steps"] as? [[String: Any]]) ?? []).map { step in
            let status = (step["status"] as? String) ?? ""
            let conclusion = (step["conclusion"] as? String) ?? ""
            let outcome: PullRequestCheck.Outcome
            if status != "completed" { outcome = .pending }
            else if ["failure", "timed_out", "cancelled"].contains(conclusion) { outcome = .failing }
            else if ["skipped", "neutral"].contains(conclusion) { outcome = .skipped }
            else { outcome = .passing }
            return CILog.Step(number: (step["number"] as? Int) ?? 0, name: (step["name"] as? String) ?? "?", outcome: outcome)
        }
    }

    /// A raw job log as people read it: without the timestamp GitHub puts before every line and without terminal colour
    /// codes, and only its last `limit` lines.
    static func clean(_ raw: String, limit: Int = maxLines) -> (text: String, omitted: Int) {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        let omitted = max(0, lines.count - limit)
        let shown = lines.suffix(limit).map { stripANSI(stripTimestamp($0)) }
        return (shown.joined(separator: "\n"), omitted)
    }

    /// "2026-10-20T12:00:01.1234567Z Run swift test" → "Run swift test".
    static func stripTimestamp(_ line: String) -> String {
        let body = line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
        guard let space = body.firstIndex(of: " "), body.distance(from: body.startIndex, to: space) >= 20 else { return body }
        let stamp = body[..<space]
        guard stamp.hasSuffix("Z"), stamp.dropFirst(10).first == "T", stamp.prefix(4).allSatisfy(\.isNumber) else { return body }
        return String(body[body.index(after: space)...])
    }

    /// Removes ESC [ … letter sequences (colours, cursor moves).
    static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var result = ""
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else { result.append(character); continue }
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            while let code = iterator.next(), !code.isLetter {}
        }
        return result
    }
}
