import Foundation

/// Short pieces of text an agent writes for Nook: a session title, a commit message,
/// a pull request. One headless call to Claude Code (a small model, no tools, no hooks) or Codex (`exec`, read-only,
/// ephemeral), with a JSON schema for the answer.
enum TextGeneration {
    enum Engine: Equatable, Sendable { case claude, codex }

    // MARK: Prompts

    static let titleSchema: [String: Any] = schema(["title": "string", "branch": "string", "needsRefinement": "boolean"])
    static let commitSchema: [String: Any] = schema(["subject": "string", "body": "string"])
    static let pullRequestSchema: [String: Any] = schema(["title": "string", "body": "string"])

    /// `later`: the user's later messages, when a title is written again for a session that went on. `instructions`: the
    /// user's own rules for titles (Settings, or the project's own), after Nook's rules and before the message.
    static func titlePrompt(message: String, later: [String] = [], instructions: String = "") -> String {
        var prompt = baseTitlePrompt(message: message)
        let rules = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty {
            prompt = prompt.replacingOccurrences(of: "\nUser message:\n", with: """

                The user's own rules for titles (follow them; the JSON format above still applies):
                \(limit(rules, 2_000))

                User message:

                """)
        }
        let followUps = later.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(3)
        guard !followUps.isEmpty else { return prompt }
        return prompt + "\n\nThe session went on; the user's latest messages (title what the session is about now):\n"
            + followUps.map { "- " + limit($0, 1_500) }.joined(separator: "\n")
    }

    private static func baseTitlePrompt(message: String) -> String {
        """
        Generate a title that will help the user recognize this Nook session weeks later.
        Also name the git branch the work happens on.
        Return JSON with keys title, branch and needsRefinement.
        Set needsRefinement to true only if the subject is still unknown, such as an unresolved link, "fix this", or an unexplained attachment. Otherwise set it to false.

        Before answering, silently reduce the request to:
        - Subject: What system, feature, or problem is this really about?
        - Outcome: What does the user ultimately want to understand or change?
        - Incidental instructions: What only describes how the agent should do the work?

        Title the subject and outcome. Discard incidental instructions.

        Editorial rules:
        - 3-8 words, fewer than 40 characters.
        - Write the title in the language of the user's message.
        - Use a compact noun phrase or clear action phrase.
        - Capture the umbrella goal when the request lists several symptoms or steps.
        - Name the product change, not the mock, plan, report, branch, or PR used to produce it.
        - Models, subagents, tools, output formats, and monitoring instructions do not belong in the title unless they are themselves the topic.
        - For reviews, name what is being reviewed and the relevant concern.
        - For research, name the question domain rather than the requested research process.
        - Do not claim the work is complete.
        - Do not copy and truncate the user's message.
        - Avoid project names already visible in the UI, quotes, labels, filler, and trailing punctuation.

        Branch rules:
        - Always in English, whatever the language of the message.
        - 2-5 lowercase words joined by hyphens, at most 40 characters, e.g. "fix-safari-login" or "add-archive-button".
        - Start with a verb (add, fix, remove, improve, refactor, investigate…) followed by what it changes.
        - Name the same subject and outcome as the title; no prefix, ticket number, or date.

        User message:
        \(limit(message, 8_000))
        """
    }

    /// `style` holds the extra rules of the commit style you chose (`CommitStyle`).
    static func commitPrompt(branch: String?, files: String, patch: String, style: [String] = []) -> String {
        var lines: [String] = [
            "You write concise git commit messages in English.",
            "Return a JSON object with keys: subject, body.",
            "Rules:",
            "- write subject and body in English",
            "- subject must be imperative, <= 72 chars, and no trailing period",
            "- body can be empty string or short bullet points",
            "- capture the primary user-visible or developer-visible change",
        ]
        lines += style
        lines += [
            "",
            "Branch: \(branch ?? "(detached)")",
            "",
            "Staged files:",
            limit(files, 6_000),
            "",
            "Staged patch:",
            limit(patch, 40_000)
        ]
        return lines.joined(separator: "\n")
    }

    static func pullRequestPrompt(base: String, head: String, commits: String, stat: String, patch: String, template: String?,
                                  guidelines: String? = nil, style: [String] = []) -> String {
        let template = template?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let bodyRules = template == nil ? [
            "- body must be markdown and include headings '## Summary' and '## Testing'",
            "- under Summary, provide short bullet points",
            "- under Testing, include bullet points with concrete checks or 'Not run' where appropriate"
        ] : [
            "- body must be markdown and follow the repository change request template structure",
            "- fill in the template sections appropriately for this change",
            "- drop HTML comments from the template in the generated body",
            "- keep the template's markdown structure and every one of its headings, even when a section has little to say",
            "- under a heading about related or linked issues, list the issues the commits close; when none, write 'None'",
            "- leave checklist boxes unticked unless the commits show that check was done, and under a testing heading add a line "
                + "of its own that says what was run, or 'Not run yet' when nothing in the commits shows it"
        ]
        var lines = ["You write source control change request content in English.", "Return a JSON object with keys: title, body.", "Rules:",
                     "- write title and body in English",
                     "- title should be concise and specific"] + bodyRules + style
        if let guidelines = guidelines?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            lines += ["- the repository's own rules for change requests below come first: where they ask for something else "
                        + "(headings, wording, issue links, checks), follow them"]
            lines += ["", "Repository rules for change requests:", limit(guidelines, 6_000)]
        }
        if let template { lines += ["", "Repository change request template:", limit(template, 8_000)] }
        lines += ["", "Base branch: \(base)", "Head branch: \(head)", "", "Commits:", limit(commits, 12_000), "",
                  "Diff stat:", limit(stat, 12_000), "", "Diff patch:", limit(patch, 40_000)]
        return lines.joined(separator: "\n")
    }

    /// A pull request template without its HTML comments (the hints for whoever fills it in), as the body to start from.
    static func pullRequestTemplateBody(_ template: String) -> String {
        let stripped = template.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The headings (`#`…`######`) of a markdown text, in order, outside code blocks.
    static func markdownHeadings(_ text: String) -> [String] {
        var inFence = false
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle() }
            guard !inFence, line.hasPrefix("#") else { return nil }
            let level = line.prefix { $0 == "#" }.count
            guard level <= 6, line.dropFirst(level).first == " " else { return nil }
            return line
        }
    }

    /// The template's headings the body leaves out.
    static func missingTemplateHeadings(body: String, template: String?) -> [String] {
        guard let template else { return [] }
        let present = Set(markdownHeadings(body).map { $0.lowercased() })
        return markdownHeadings(template).filter { !present.contains($0.lowercased()) }
    }

    /// A generated body that keeps every heading of the template, in the template's order: a section the model left out
    /// comes back with "None", and sections of its own follow the template's.
    static func conformPullRequestBody(_ body: String, template: String?) -> String {
        guard let template else { return body }
        let wanted = markdownHeadings(template)
        guard !wanted.isEmpty else { return body }
        let found = markdownHeadings(body)
        let wantedKeys = wanted.map { $0.lowercased() }
        if found.map({ $0.lowercased() }).filter(wantedKeys.contains) == wantedKeys { return body }
        // The body by section: what comes before the first heading, then each heading with the lines under it.
        var preamble: [String] = []
        var sections: [(heading: String, lines: [String])] = []
        var inFence = false
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, found.contains(line), line.hasPrefix("#") {
                sections.append((line, []))
            } else if sections.isEmpty {
                preamble.append(raw)
            } else {
                sections[sections.count - 1].lines.append(raw)
            }
        }
        func text(_ lines: [String]) -> String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [String] = []
        if !text(preamble).isEmpty { out.append(text(preamble)) }
        var used = Set<Int>()
        for heading in wanted {
            let index = sections.indices.first { !used.contains($0) && sections[$0].heading.lowercased() == heading.lowercased() }
            if let index { used.insert(index) }
            let content = index.map { text(sections[$0].lines) } ?? ""
            out.append(heading + "\n\n" + (content.isEmpty ? "None" : content))
        }
        for index in sections.indices where !used.contains(index) {
            out.append([sections[index].heading, text(sections[index].lines)].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: Commands

    static let system = "You write short texts for a developer tool. Follow the requested format exactly and add nothing else."

    /// `claude -p` that only answers: a small model, a one-line system prompt (instead of the coding agent's 24k-token
    /// prompt), the schema, no user settings or CLAUDE.md (`--setting-sources local`), no tools, no slash commands, no MCP
    /// servers, no hooks and no saved transcript. The prompt goes on stdin. `effort` caps how long a larger model thinks.
    static func claudeArguments(schema: [String: Any], model: String = "haiku", effort: String? = nil) -> [String] {
        ["-p", "--output-format", "json", "--json-schema", json(schema), "--model", model]
            + (effort.map { ["--effort", $0] } ?? [])
            + ["--system-prompt", system, "--setting-sources", "local",
               "--settings", #"{"disableAllHooks":true}"#, "--tools", "", "--disable-slash-commands", "--strict-mcp-config",
               "--permission-mode", "dontAsk", "--no-session-persistence"]
    }

    /// `codex exec` that only answers: none of your config, rules, plugins, apps, MCP servers or built-in tools; read-only,
    /// ephemeral, low effort, the schema and answer in files, prompt on stdin.
    static func codexArguments(schemaPath: String, outputPath: String) -> [String] {
        ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
         "-s", "read-only",
         "--config", "features.plugins=false", "--config", "features.apps=false",
         "--config", "features.shell_tool=false", "--config", "features.unified_exec=false",
         "--config", "features.view_image=false", "--config", "features.multi_agent=false",
         "--config", #"web_search="disabled""#,
         "--config", "developer_instructions=" + AgentTelemetry.tomlString(system),
         "--config", #"model_reasoning_effort="low""#, "--output-schema", schemaPath,
         "--output-last-message", outputPath, "-"]
    }

    /// Claude Code's `--output-format json` reply: the `structured_output` of the result (or a JSON answer as text).
    static func claudeAnswer(_ output: String) -> [String: Any]? {
        let data = Data(output.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let envelopes = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        let result = envelopes.last { ($0["type"] as? String) == "result" || $0["structured_output"] != nil }
        if let structured = result?["structured_output"] as? [String: Any] { return structured }
        return (result?["result"] as? String).flatMap(object)
    }

    /// A JSON object in a model's text answer, also inside a ```json fence.
    static func object(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    // MARK: Cleaning up answers

    /// First line, no quotes or backticks around it, single spaces, at most 120 characters. Nil when nothing is left.
    static func title(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = object(text), let inner = object["title"] as? String { text = inner }
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`").union(.whitespaces))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text != "New thread" else { return nil }
        return text.count > 120 ? String(text.prefix(117)) + "..." : text
    }

    /// "Fix Safari login!" → "fix-safari-login": at most 5 whole words and 40 characters. Nil when nothing is left.
    static func branchSlug(_ raw: String) -> String? {
        let words = WorktreeNaming.slug(raw, limit: 200).split(separator: "-").map(String.init)
        var result: [String] = []
        for word in words where word.count <= 40 {
            if result.count == 5 || (result + [word]).joined(separator: "-").count > 40 { break }
            result.append(word)
        }
        return result.isEmpty || result == ["sessie"] ? nil : result.joined(separator: "-")
    }

    /// First line, no trailing period, at most 72 characters; "Update project files" when empty.
    static func commitSubject(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespaces)
        while line.hasSuffix(".") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return "Update project files" }
        return String(line.prefix(72)).trimmingCharacters(in: .whitespaces)
    }

    /// First line; "Update project changes" when empty.
    static func pullRequestTitle(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Update project changes" : clean
    }

    static func limit(_ text: String, _ maximum: Int) -> String {
        text.count <= maximum ? text : String(text.prefix(maximum)) + "\n\n[truncated]"
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func schema(_ fields: [String: String]) -> [String: Any] {
        ["type": "object", "properties": fields.mapValues { ["type": $0] }, "required": fields.keys.sorted(), "additionalProperties": false]
    }
}

/// One headless call, off the main thread, with a time limit.
enum TextGenerationRunner {
    static let folderPrefix = "nook-text-"

    /// The scratch folder of one of these calls: transcripts Claude Code saved there before `--no-session-persistence`
    /// are Nook's own, not sessions of the user.
    static func isScratchFolder(_ path: String) -> Bool {
        // The name from the text alone: `URL(fileURLWithPath:)` asks the disk whether it is a folder, and the history scan
        // asks this for every session it lists.
        (path as NSString).lastPathComponent.hasPrefix(folderPrefix)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ more: [String]) { lock.withLock { lines += more } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    /// How a call ended: its process exited, could not start, or ran past its time.
    private enum End: Sendable { case exited, failed, timedOut }

    /// Lets only the first of the exit, the start failure and the time limit end the wait.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// Waits for the call without holding a thread: a title or commit message can take up to `timeout` seconds, and a
    /// blocked thread of Swift's shared pool is one fewer for the rest of Nook meanwhile.
    static func run(engine: TextGeneration.Engine, executable: String, environment: [String: String], prompt: String,
                    schema: [String: Any], cwd: String, timeout: TimeInterval = 120, model: String? = nil,
                    effort: String? = nil) async -> [String: Any]? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        let answerFile = temp.appendingPathComponent("answer.txt")
        let arguments: [String]
        switch engine {
        case .claude:
            arguments = TextGeneration.claudeArguments(schema: schema, model: model ?? "haiku", effort: effort)
        case .codex:
            let schemaFile = temp.appendingPathComponent("schema.json")
            guard (try? Data(TextGeneration.json(schema).utf8).write(to: schemaFile)) != nil else { return nil }
            arguments = TextGeneration.codexArguments(schemaPath: schemaFile.path, outputPath: answerFile.path)
        }
        // An empty folder of its own, so neither agent reads project instruction files or leaves a trace in the project.
        let process = AgentProcess(spec: LaunchSpec(executable: executable, arguments: arguments, extraEnvironment: environment,
                                                    workingDirectory: temp.path, initialInput: [prompt], keepsInputOpen: true))
        let output = Output()
        process.onLines = { output.add($0) }
        let once = Once()
        guard !Task.isCancelled else { return nil }
        // Cancelled (a suggestion you started typing over): the process stops, and its exit ends the wait.
        let end: End = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.onExit = { _, _ in if once.claim() { continuation.resume(returning: .exited) } }
                do { try process.start() } catch {
                    if once.claim() { continuation.resume(returning: .failed) }
                    return
                }
                process.closeInput()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if once.claim() { continuation.resume(returning: .timedOut) }
                }
            }
        } onCancel: {
            process.stop(grace: 1)
        }
        guard !Task.isCancelled else { return nil }
        switch end {
        case .exited: break
        case .failed: return nil
        case .timedOut:
            process.stop(grace: 1)
            return nil
        }
        switch engine {
        case .claude: return TextGeneration.claudeAnswer(output.text)
        case .codex: return (try? String(contentsOf: answerFile, encoding: .utf8)).flatMap(TextGeneration.object)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
