import Foundation

/// What a CI check shows when you open it from a watched pull request: the steps of its job and, once GitHub has it,
/// the log. Parsed from GitHub's REST answers by `CILogParser`; Foundation only, so tests can use it.
struct CILog: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let number: Int
        let name: String
        let outcome: PullRequestCheck.Outcome
        var started: Date? = nil
        var finished: Date? = nil
        /// Runs right now (a pending step that has not started yet waits).
        var running = false
    }

    /// One line of the log as it is read: what GitHub marked it as (`##[error]`, `##[group]`…) or what its words say.
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case plain, group, command, error, warning, notice }
        let kind: Kind
        let text: String
    }

    var steps: [Step] = []
    /// The end of the log, cleaned up for reading; nil while GitHub has none yet (a job that still runs).
    var text: String?
    /// Lines left out at the top because the log was longer than Nook shows.
    var omittedLines = 0
    /// When the job started and finished, for its clock; nil while it waits or runs.
    var started: Date?
    var finished: Date?

    /// The step that runs now, if any.
    var runningStep: Step? { steps.first(where: \.running) }
    /// Steps that are done (passed, failed or skipped), for "step 8 of 15".
    var doneSteps: Int { steps.filter { $0.outcome != .pending }.count }
}

/// What a check that is not a GitHub Actions job has to say, read in Nook instead of on its own page: the report a check
/// run carries (a title, a summary and details in Markdown, and remarks on lines of code), and what the app behind the
/// check wrote on the pull request (CodeRabbit, a deploy bot…), which is where a commit status puts its words.
struct CICheckReport: Equatable, Sendable {
    /// A remark on a line of code ("Foo.swift:12 · warning · Unused variable").
    struct Annotation: Equatable, Sendable {
        let path: String
        let line: Int?
        let level: CILog.Line.Kind
        let title: String
        let message: String
    }

    /// What the app wrote on the pull request: a comment or a review, newest first.
    struct Note: Equatable, Sendable {
        let author: String
        let date: Date?
        let body: String
        let url: URL?
    }

    var title: String = ""
    var summary: String = ""
    var text: String = ""
    var annotations: [Annotation] = []
    var notes: [Note] = []

    var isEmpty: Bool { title.isEmpty && summary.isEmpty && text.isEmpty && annotations.isEmpty && notes.isEmpty }

    /// Everything as plain text, for the copy button.
    var plainText: String {
        var parts = [title, summary, text].filter { !$0.isEmpty }
        parts += annotations.map { annotation in
            [annotation.path + (annotation.line.map { ":\($0)" } ?? ""), annotation.title, annotation.message]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        parts += notes.map(\.body)
        return parts.joined(separator: "\n\n")
    }
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
            return CILog.Step(number: (step["number"] as? Int) ?? 0, name: (step["name"] as? String) ?? "?", outcome: outcome,
                              started: PullRequestDetailParser.date(step["started_at"]),
                              finished: status == "completed" ? PullRequestDetailParser.date(step["completed_at"]) : nil,
                              running: status == "in_progress")
        }
    }

    /// A job's steps with its own start and end, from `GET /actions/jobs/{id}`.
    static func log(job: [String: Any]) -> CILog {
        var log = CILog(steps: steps(job: job))
        log.started = PullRequestDetailParser.date(job["started_at"])
        if (job["status"] as? String) == "completed" { log.finished = PullRequestDetailParser.date(job["completed_at"]) }
        return log
    }

    /// A duration as a clock that reads the same in every language: "0:42", "3:12", "1:04:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// How long something ran: until it finished, or until `now` while it still runs. Nil before it started.
    static func elapsed(started: Date?, finished: Date?, now: Date = Date()) -> TimeInterval? {
        guard let started else { return nil }
        return (finished ?? now).timeIntervalSince(started)
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

    /// The cleaned log as lines with a kind: GitHub's `##[…]` markers become the kind and leave the text, `##[endgroup]`
    /// and `##[debug]` are dropped, and a plain line that says "error:", "warning:" or that the build failed counts too.
    static func lines(_ text: String) -> [CILog.Line] {
        text.components(separatedBy: "\n").compactMap { line in
            for (marker, kind) in markers where line.hasPrefix(marker) {
                return CILog.Line(kind: kind, text: String(line.dropFirst(marker.count)))
            }
            if line.hasPrefix("##[endgroup]") || line.hasPrefix("##[debug]") { return nil }
            return CILog.Line(kind: plainKind(line), text: line)
        }
    }

    /// Only what went wrong: the error and warning lines, each group's name before its first one so a line keeps its place.
    static func problems(_ lines: [CILog.Line]) -> [CILog.Line] {
        var result: [CILog.Line] = []
        var group: CILog.Line?
        for line in lines {
            switch line.kind {
            case .group: group = line
            case .error, .warning:
                if let heading = group { result.append(heading); group = nil }
                result.append(line)
            default: break
            }
        }
        return result
    }

    // MARK: Reports

    /// The report of `GET /check-runs/{id}` and its `/annotations`.
    static func report(run: [String: Any], annotations: [[String: Any]]) -> CICheckReport {
        let output = (run["output"] as? [String: Any]) ?? [:]
        func text(_ key: String) -> String {
            ((output[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var report = CICheckReport(title: text("title"), summary: GitHubMarkdown.markdown(text("summary")),
                                   text: GitHubMarkdown.markdown(text("text")))
        report.annotations = annotations.map { item in
            let level: CILog.Line.Kind
            switch (item["annotation_level"] as? String) ?? "" {
            case "failure": level = .error
            case "warning": level = .warning
            default: level = .notice
            }
            return CICheckReport.Annotation(path: (item["path"] as? String) ?? "", line: item["start_line"] as? Int,
                                            level: level, title: (item["title"] as? String) ?? "",
                                            message: (item["message"] as? String) ?? "")
        }
        // A title that only repeats the summary's first line says nothing new.
        if !report.title.isEmpty, report.summary.hasPrefix(report.title) { report.title = "" }
        return report
    }

    /// What `reporter` wrote on the pull request, from its comments (`/issues/{n}/comments`) and reviews
    /// (`/pulls/{n}/reviews`), newest first. "coderabbitai[bot]" and "coderabbitai" are the same author.
    static func notes(comments: [[String: Any]], reviews: [[String: Any]], reporter: String, limit: Int = 5) -> [CICheckReport.Note] {
        let wanted = botless(reporter)
        guard !wanted.isEmpty else { return [] }
        func note(_ item: [String: Any], dateKey: String) -> CICheckReport.Note? {
            guard let author = (item["user"] as? [String: Any])?["login"] as? String, botless(author) == wanted else { return nil }
            let body = ((item["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return CICheckReport.Note(author: author, date: PullRequestDetailParser.date(item[dateKey]),
                                      body: GitHubMarkdown.markdown(body),
                                      url: (item["html_url"] as? String).flatMap(URL.init(string:)))
        }
        let found = comments.compactMap { note($0, dateKey: "updated_at") } + reviews.compactMap { note($0, dateKey: "submitted_at") }
        return Array(found.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }

    private static func botless(_ login: String) -> String {
        let lower = login.lowercased()
        return lower.hasSuffix("[bot]") ? String(lower.dropLast(5)) : lower
    }

    private static let markers: [(String, CILog.Line.Kind)] = [
        ("##[group]", .group), ("##[command]", .command), ("##[error]", .error),
        ("##[warning]", .warning), ("##[notice]", .notice),
    ]

    private static func plainKind(_ line: String) -> CILog.Line.Kind {
        let lower = line.lowercased()
        if lower.contains("error:") || lower.contains("build failed") || lower.contains("test failed")
            || lower.hasPrefix("fatal:") { return .error }
        if lower.contains("warning:") { return .warning }
        return .plain
    }
}
