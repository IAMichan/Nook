import Foundation

// What the agent is doing right now, in words rather than a generic "Thinking…": "Running the tests", "Reading
// index.html", "Looking at the results". And which of its commands checked its own work (tests, a build, a linter, a
// type check) and how that went. Both come from the events the agent already sends; nothing here is guessed or made
// up. Everything in this file depends only on Foundation so tests can use it independently.

/// A command the agent ran to check its work, and how it went.
struct VerificationCheck: Equatable, Sendable {
    /// Order is priority: a command that runs the tests also builds, but it is the tests that matter.
    enum Kind: Int, Comparable, Sendable {
        case tests, typecheck, lint, build

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Outcome: Equatable, Sendable { case running, passed, failed }

    var kind: Kind
    var outcome: Outcome
    var command: String
}

enum Verification {
    /// Commands that only run tests.
    private static let testRunners: Set<String> = ["pytest", "jest", "vitest", "rspec", "phpunit", "ctest", "mocha",
                                                   "karma", "playwright", "cypress", "tox", "nox"]
    private static let linters: Set<String> = ["eslint", "swiftlint", "swiftformat", "ruff", "flake8", "pylint", "rubocop",
                                               "golangci-lint", "shellcheck", "stylelint", "ktlint", "biome", "prettier"]
    private static let typecheckers: Set<String> = ["tsc", "mypy", "pyright", "vue-tsc"]
    /// Build tools and package managers whose sub-command says what they do ("swift test", "npm run build").
    private static let runners: Set<String> = ["npm", "npx", "yarn", "pnpm", "bun", "swift", "go", "cargo", "deno", "mix",
                                               "mvn", "gradle", "gradlew", "make", "dotnet", "xcodebuild", "flutter", "dart",
                                               "rake", "bundle", "poetry", "uv", "python", "python3", "pipenv", "turbo", "nx",
                                               "just", "task", "bazel", "sbt", "composer", "zig"]

    /// What kind of check a shell command is, or nil when it is not one. Looks at every part of a chain
    /// ("cd app && npm test") and keeps the most important.
    static func kind(command: String) -> VerificationCheck.Kind? {
        let separators = CharacterSet(charactersIn: ";|&\n")
        return command.components(separatedBy: separators).compactMap(segmentKind).min()
    }

    private static func segmentKind(_ segment: String) -> VerificationCheck.Kind? {
        var words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Leading environment assignments ("CI=1 npm test") and wrappers say nothing about the command.
        while let first = words.first, first.contains("=") && !first.hasPrefix("-") || ["sudo", "env", "time", "exec", "nice"].contains(first) {
            words.removeFirst()
        }
        guard let first = words.first else { return nil }
        let head = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        let rest = words.dropFirst().map { $0.lowercased() }
        // "bash scripts/core-tests.sh": the script is the command.
        if ["bash", "sh", "zsh"].contains(head), let script = rest.first, script.hasSuffix(".sh") {
            return segmentKind(rest.joined(separator: " "))
        }
        if let kind = tool(head) { return head == "prettier" && !rest.contains("--check") ? nil : kind }
        if runners.contains(head) {
            // Only the sub-command (and the script or tool it names) counts, not file arguments: "swift test",
            // "npm run test:unit", "python -m pytest", "npx vitest", "xcodebuild … test".
            // Up to the first file it is given ("python script.py test" runs a script, not the tests); xcodebuild names
            // its action last, after the project and scheme.
            let words = rest.filter { !$0.hasPrefix("-") }
            let verbs = head == "xcodebuild" ? words : Array(words.prefix { !$0.contains("/") && !$0.contains(".") }.prefix(2))
            func has(_ word: String) -> Bool {
                verbs.contains { $0 == word || $0.hasPrefix(word + ":") || $0.hasSuffix(":" + word) }
            }
            if let kind = verbs.compactMap(tool).min() { return kind }
            if has("test") || has("tests") || has("unittest") { return .tests }
            if has("typecheck") || has("type-check") || head == "cargo" && has("check") { return .typecheck }
            if has("lint") || has("clippy") || has("vet") { return .lint }
            if has("build") || head == "xcodebuild" { return .build }
            return nil
        }
        // A project's own script: "./scripts/core-tests.sh", "run_tests.sh", "lint.sh".
        guard head.hasSuffix(".sh") || first.hasPrefix("./") else { return nil }
        let name = head.replacingOccurrences(of: ".sh", with: "")
        if name.range(of: #"(^|[-_.])tests?([-_.]|$)"#, options: .regularExpression) != nil { return .tests }
        if name.range(of: #"(^|[-_.])lint([-_.]|$)"#, options: .regularExpression) != nil { return .lint }
        if name.range(of: #"(^|[-_.])build([-_.]|$)"#, options: .regularExpression) != nil { return .build }
        return nil
    }

    /// A tool that does one kind of check by its name.
    private static func tool(_ name: String) -> VerificationCheck.Kind? {
        if testRunners.contains(name) { return .tests }
        if typecheckers.contains(name) { return .typecheck }
        if linters.contains(name) { return .lint }
        return nil
    }

    static func outcome(_ state: RunEvent.State?) -> VerificationCheck.Outcome {
        switch state {
        case .failed, .denied: return .failed
        case .done, .allowed: return .passed
        default: return .running
        }
    }

    /// A shell command in the timeline that checks the agent's work, and how it went.
    static func check(_ event: RunEvent) -> VerificationCheck? {
        guard event.kind == .tool, ToolCategory.of(tool: event.tool ?? "") == .command,
              let command = AgentActivity.command(event), let kind = kind(command: command) else { return nil }
        return VerificationCheck(kind: kind, outcome: outcome(event.state), command: command)
    }

    /// One check per kind, the latest of each (a test run that failed and then passed passed), most important first.
    static func latest(_ checks: [VerificationCheck]) -> [VerificationCheck] {
        var byKind: [VerificationCheck.Kind: VerificationCheck] = [:]
        for check in checks { byKind[check.kind] = check }
        return byKind.values.sorted { $0.kind < $1.kind }
    }

    static func checks(_ events: [RunEvent]) -> [VerificationCheck] {
        latest(events.compactMap(check))
    }
}

/// What the agent is doing now, as the live line under the timeline says it.
enum AgentActivity: Equatable, Sendable {
    /// Only your message so far.
    case starting
    /// A shell command; its command line or the description the agent gave it.
    case running(String)
    /// A command that checks the work.
    case verifying(VerificationCheck.Kind)
    case reading(String)
    case editing(String)
    case searching(String)
    /// A web search or a page it fetches.
    case browsing(String)
    /// A subagent it started, by what it was asked to do.
    case delegating(String)
    /// It updates its own task list.
    case planning
    /// Any other tool, by name.
    case using(String)
    /// The headline of what it thinks about.
    case thinking(String)
    /// It writes its answer.
    case writing
    /// A step just finished: it looks at what came back.
    case reviewing
    /// The last step failed: it works out what to do about it.
    case recovering

    /// A tool call by name and input.
    static func of(tool: String, input: [String: Any], fallback: String = "") -> AgentActivity {
        let name = tool.lowercased()
        if SessionOutputs.taskTools.contains(tool) || SessionOutputs.taskTools.contains(tool.components(separatedBy: "__").last ?? "") {
            return .planning
        }
        if Subagents.tools.contains(tool) {
            return .delegating((input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        }
        if ["websearch", "webfetch", "web_search", "web_fetch", "google_web_search"].contains(name) {
            let subject = ["query", "url"].lazy.compactMap { input[$0] as? String }.first ?? fallback
            return .browsing(ToolSummary.oneLine(subject, 80))
        }
        switch ToolCategory.of(tool: tool) {
        case .command:
            let command = ToolSummary.command(input) ?? fallback
            if let kind = Verification.kind(command: command) { return .verifying(kind) }
            // The agent's own description of a command ("Run the tests") reads better than the command.
            let described = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .running(ToolSummary.oneLine(described ?? command, 80))
        case .edit:
            return .editing(ToolSummary.path(input).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallback)
        case .read:
            return .reading(ToolSummary.path(input).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallback)
        case .search:
            let subject = ["pattern", "query"].lazy.compactMap { input[$0] as? String }.first ?? fallback
            return .searching(ToolSummary.oneLine(subject, 80))
        case .other:
            // An MCP tool by its own name: "search_issues" of "mcp__github__search_issues".
            let bare = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool
            return .using(bare.isEmpty ? fallback : bare)
        }
    }

    /// A tool call in a session's timeline: name in `tool`, input as JSON in `detail`, "Bash · npm test" as text.
    static func of(_ event: RunEvent) -> AgentActivity {
        let tool = event.tool ?? ""
        let fallback = subject(event.text) ?? ""
        if tool.hasPrefix(BridgeTool.toolPrefix), BridgeTool.named(tool) == .terminalRun {
            let command = Self.command(event) ?? fallback
            return Verification.kind(command: command).map(AgentActivity.verifying) ?? .running(ToolSummary.oneLine(command, 80))
        }
        return of(tool: tool, input: input(event.detail) ?? [:], fallback: fallback)
    }

    /// The command line of a shell tool call: from its input, else from its summary.
    static func command(_ event: RunEvent) -> String? {
        let input = input(event.detail) ?? [:]
        let tool = event.tool ?? ""
        let command = tool.hasPrefix(BridgeTool.toolPrefix) ? BridgeTool.detail(input) : ToolSummary.command(input)
        return command ?? subject(event.text)
    }

    /// The live line of a session's last turn: the tool that runs, else what the agent did last.
    static func current(_ events: [RunEvent]) -> AgentActivity {
        let turn = TimelinePresentation.split(events).last ?? []
        if let running = turn.last(where: { $0.kind == .tool && $0.state == .running }) { return of(running) }
        guard let last = turn.last(where: { [.assistant, .thinking, .tool, .fileChange, .error, .user].contains($0.kind) }) else {
            return .starting
        }
        switch last.kind {
        case .thinking:
            let headline = TimelinePresentation.headline(last.text)
            return headline.isEmpty ? .reviewing : .thinking(headline)
        case .assistant: return .writing
        case .tool, .fileChange: return last.state == .failed ? .recovering : .reviewing
        case .error: return .recovering
        default: return .starting
        }
    }

    /// The part of a summary after its tool: "npm test" of "Bash · npm test".
    static func subject(_ text: String) -> String? {
        guard let range = text.range(of: " · ") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    static func input(_ json: String?) -> [String: Any]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The task list as the live checklist shows it in the timeline.
enum TaskChecklist {
    /// While the agent works, its list shows in the timeline; a finished list waits above the composer instead.
    static func showsInline(_ steps: [RunTaskStep]?, active: Bool) -> Bool {
        guard active, let steps, !steps.isEmpty else { return false }
        return true
    }

    /// The text of the step that runs, else nil: a list where nothing runs yet (or any more) has no current step.
    static func activeStep(_ steps: [RunTaskStep]) -> String? {
        steps.first { $0.status == .active }?.text
    }
}
