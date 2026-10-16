import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Sources in chat: scope, references, attachments, screen text and the context handed to the brain.
extension AppModel {
    // MARK: Sources in Chat

    func scope(of conversation: UUID?) -> SourceScope {
        conversation.flatMap { chat.conversation($0)?.scope } ?? .automatic
    }

    func setScope(_ scope: SourceScope) {
        let id = chat.ensureActive()
        chat.setScope(scope, conversation: id)
    }

    /// The scope as it applies to the active brain: with an external brain the "only on this Mac" sources are taken
    /// out, whatever the source picker or the question says. With a brain on this Mac nothing changes.
    func privacyScope(_ scope: SourceScope) -> SourceScope {
        scope.keepingLocal(settings.privateSources)
    }

    /// The "only on this Mac" sources the question asked for by name (or the scope puts first) that an external brain
    /// therefore did not use, so the answer can say why they are missing.
    func withheldSources(asked text: String, scope: SourceScope) -> Set<String> {
        let hidden = settings.privateSources
        guard !hidden.isEmpty else { return [] }
        let named = Set(SourceCatalog.mentions(in: text).flatMap { $0.ids })
        return hidden.intersection(named.union(scope.focus).union(scope.mode == .only ? scope.included : []))
    }

    /// Opens a cited source safely (https URL, local file inside user home, or mail URL).
    func openReference(_ reference: SourceReference) {
        guard SourceReference.isOpenable(reference.url), let raw = reference.url, let url = URL(string: raw) else { return }
        if url.isFileURL {
            guard FileText.isAllowed(url) else { return }
            // Opening an app, script or installer would run it: show those in Finder instead.
            if FileText.couldExecute(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Retries the last user question in the conversation.
    func retryLast() {
        guard let id = chat.activeID, let question = chat.lastQuestion(in: id) else { return }
        ask(question)
    }

    /// Select a file to attach to context (analogous to dropping onto Shelf).
    func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileText.isAllowed(url) else {
            viewModel.show(.card(errorCard(tr("chat.attach.notAllowed"))))
            return
        }
        askAbout(url)
    }

    func clearAttachment() {
        attachment = nil
    }

    func sendMail(_ draft: MailDraft) {
        chat.updateMail(draft.id) { $0 = draft; $0.state = .sending }
        Task {
            do {
                try await MailSender.deliver(draft, send: true)
                store.audit(tool: "send_mail", args: "\(draft.to) · \(draft.subject)", result: "verstuurd")
                chat.updateMail(draft.id) { $0.state = .sent }
            } catch {
                chat.updateMail(draft.id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    func openMail(_ draft: MailDraft) {
        chat.updateMail(draft.id) { $0 = draft }
        Task {
            do {
                try await MailSender.deliver(draft, send: false)
                chat.updateMail(draft.id) { $0.state = .opened }
            } catch {
                chat.updateMail(draft.id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Text from all visible windows: from live cache if enabled, or read on-demand.
    func screenSnapshot() async throws -> ScreenSnapshot {
        let local = settings.brainProfile.isSmall
        if settings.liveScreen {
            if !screenContext.isRunning, screenContext.hasPermission { screenContext.start() }
            return try await screenContext.snapshot(totalLimit: local ? 3500 : 12_000)
        }
        return try await screen.captureAll(maxWindows: local ? 3 : 6, totalLimit: local ? 3500 : 9000)
    }

    /// Keywords and phrases indicating a query refers to on-screen content.
    static let screenCue = try? NSRegularExpression(
        pattern: #"\b(hier\w*|dit|deze|daar\w*|erbij|ervoor|ervan|erover|scherm|kijk mee|lees mee)\b|\ber\b.{0,25}\b(afspraak|herinnering|taak|mail|punt|agenda)\b"#,
        options: [.caseInsensitive]
    )

    private static let commonApps: [String: String] = [
        "notities": "Notes", "notes": "Notes",
        "slack": "Slack", "whatsapp": "WhatsApp",
        "teams": "Teams", "msteams": "MSTeams",
        "discord": "Discord", "telegram": "Telegram",
        "safari": "Safari", "chrome": "Google Chrome",
        "edge": "Microsoft Edge", "arc": "Arc",
        "spotify": "Spotify", "terminal": "Terminal",
        "xcode": "Xcode", "cursor": "Cursor",
        "figma": "Figma", "excel": "Excel", "word": "Word",
        "notion": "Notion", "things": "Things"
    ]

    /// Whether the brain reads the question before the research: not for a greeting, nor for a plain command
    /// ("zet de muziek zachter") that looks nothing up.
    static func shouldPlan(_ text: String, intent: ChatIntent) -> Bool {
        guard !intent.isSmallTalk else { return false }
        if intent.wantsAction, !Research.isLookup(text) { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    /// The sources the planner may choose from: every source this chat allows, with what Nook can do in it. A source
    /// Nook cannot read right now is listed too, so a question about it is not sent elsewhere.
    func plannerSources(available: [Prefetch.Available], scope: SourceScope, active: Set<String>) -> [QueryPlanner.Source] {
        var ids = Set(available.map(\.source))
        ids.formUnion(connectors.sources.map(\.id))
        let order = SourceCatalog.all.map(\.id)
        return ids.filter { scope.allows($0) && !Prefetch.inContext.contains($0) }
            .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { id in
                let tools = available.filter { $0.source == id }
                let title = SourceCatalog.title(id) + (active.contains(id) ? "" : " (cannot be read right now)")
                return QueryPlanner.Source(id: id, title: title, canSearch: tools.contains(where: Research.isSearch),
                                           canList: tools.contains { $0.required.isEmpty })
            }
    }

    /// Apps whose data Nook reads directly through a source of their own.
    static let appSources: [String: String] = ["WhatsApp": "whatsapp", "Notes": "notes", "Things": "things", "Notion": "notion"]

    /// Why a source the question asks for cannot be read right now, in words for the user.
    static func unreachableReason(_ source: ContextSource) -> String {
        switch source.status.state {
        case .error(let message):
            return message
        case .off where !source.status.detail.isEmpty:
            return source.status.detail
        case .loading:
            return "\(source.title) wordt nog geladen."
        default:
            return "\(source.title) is niet verbonden of staat uit (Instellingen › Accounts & koppelingen)."
        }
    }

    /// An app the question names ("wat staat er in Notities", "lees Slack", "kijk in WhatsApp"),
    /// including open apps and well-known Mac apps.
    static func appNamed(in text: String) -> String? {
        let own: Set<String> = ["com.apple.mail", "com.apple.iCal", "com.apple.reminders", "com.apple.finder"]
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in words {
            if let appName = commonApps[word] { return appName }
        }

        for app in ScreenReader.openApps() where !own.contains(app.bundleIdentifier ?? "") {
            guard let name = app.localizedName, name.count >= 3 else { continue }
            if words.contains(name.lowercased()) { return name }
            let pattern = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\d])"#
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return name }
        }
        return nil
    }

    /// A short list from looked-up data, for when the model gives no usable answer: headings, list lines, or the start.
    static func digest(_ fetched: [String]) -> String {
        let lines = fetched.joined(separator: "\n").components(separatedBy: .newlines)
        let headings = lines.filter { $0.hasPrefix("### ") }.prefix(10).map { "- " + $0.dropFirst(4) }
        if !headings.isEmpty { return tr("app.digest.found") + "\n\n" + headings.joined(separator: "\n") }
        let items = lines.filter { $0.hasPrefix("- ") || $0.hasSuffix(":") }.prefix(20)
        if !items.isEmpty { return tr("app.digest.found") + "\n\n" + items.joined(separator: "\n") }
        return tr("app.digest.found") + "\n\n" + String(lines.joined(separator: "\n").prefix(800))
    }

    private static let codeTopicRegex = try? NSRegularExpression(
        pattern: #"code|json|script|programm\w*|regex|sql|swift|python|javascript|html|css|\bapi\b|terminal|commando"#,
        options: [.caseInsensitive]
    )
    private static let proseCleanRegex = try? NSRegularExpression(pattern: #"```[\s\S]*?```|\[[0-9]+\]|\*\*"#)

    /// An answer that is no answer: code or JSON for a question that is not about code, or in another language than asked.
    static func looksBroken(_ answer: String, question: String, expected: NLLanguage?) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let aboutCode = codeTopicRegex?.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)) != nil
        if !aboutCode, trimmed.contains("```") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        // Language only on real prose: names, titles and numbers say little.
        let prose: String
        if let rx = proseCleanRegex {
            prose = rx.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: "")
        } else {
            prose = trimmed
        }
        if let expected, prose.count >= 40, let answered = AppSettings.detectLanguage(prose), answered != expected { return true }
        return false
    }

    static func refersToScreen(_ text: String) -> Bool {
        guard let screenCue else { return false }
        return screenCue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Everything the brain needs for one question. Chat answers and notch cards (looking at the screen, thinking along)
    /// are built the same way: the same source choice, the same scoped tools recorded in a ledger, the same up-front
    /// lookups and the same context text.
    struct PreparedRun {
        var scope: SourceScope
        /// Sources relevant to the question: included in full in the context.
        var relevant: Set<String>
        var summary: (text: String, titles: [String])
        var ledger: RetrievalLedger
        var tools: [ToolSpec]
        /// Context text for the brain, including what was looked up in advance.
        var context: String
        /// What was looked up in advance (empty when nothing was relevant).
        var fetched: [String]
    }

    /// `prefetch: false` skips the up-front lookups (for questions about the screen itself, where they only add waiting).
    /// `history` lets a follow-up ("en het budget?") search on with what the conversation was about.
    /// `onSummary` fires as soon as the source choice is known, before the lookups run.
    func prepareRun(
        text: String, scope: SourceScope, snapshotText: String?, ledger: RetrievalLedger, prefetch: Bool = true,
        history: [ChatTurn] = [], onSummary: ((_ summary: (text: String, titles: [String])) -> Void)? = nil
    ) async -> PreparedRun {
        // Every route to the brain (chat, cards, thinking along) passes here: sources kept on this Mac stay out of reach
        // of an external brain, even for a caller that passes the automatic scope.
        let scope = privacyScope(scope)
        // Only sources relevant to this query are included in full; others as one-line summaries.
        var activeIDs = Set(connectors.searchable.map { $0.id })
        activeIDs.insert(SourceCatalog.loops)
        let relevant = SourceRouter.relevant(to: text, scope: scope, active: activeIDs)
        let summary = contextSummary(scope: scope, relevant: relevant)
        onSummary?(summary)
        let tools = scopedTools(scope, ledger: ledger)

        // Nook does the research itself, for every model: it searches each relevant source with the words that carry
        // the question (everywhere it can search when the question names no source), ranks what it finds across
        // sources and reads the best matches in full. The model answers from the documents themselves and never has
        // to work out on its own which tool to call with which words.
        var found: [String] = []
        var opened: [String] = []
        var searched = ""
        var blocked: [String] = []
        var goal = ""
        let intent = ChatIntent.detect(text)
        if prefetch, !intent.isSmallTalk {
            let profile = settings.brainProfile
            let roomy = !profile.isSmall || profile.contextTokens >= 16_000
            let available = tools.compactMap { spec -> Prefetch.Available? in
                guard spec.kind == .read, let source = SourceCatalog.source(forTool: spec.name) else { return nil }
                return Prefetch.Available(name: spec.name, source: source, required: (spec.schema["required"] as? [String]) ?? [],
                                          query: Prefetch.Available.queryField(spec.schema))
            }
            // First the brain reads the question itself: what the user wants, where that lives and what to search for.
            // Keyword lists alone take "heb ik chats openstaan in WhatsApp?" for a search for "chats whatsapp" in files.
            var plan: QueryPlan?
            if Self.shouldPlan(text, intent: intent) {
                plan = await brain.plan(question: text, history: history, sources: plannerSources(available: available, scope: scope, active: activeIDs))
            }
            goal = plan?.goal ?? ""
            let regexTerms = Research.terms(in: text, history: history)
            let terms: Research.Terms
            if let plan, !plan.queries.isEmpty { terms = plan.terms } else if plan?.kind == .listing { terms = Research.Terms() } else { terms = regexTerms }
            let previous = history.last(where: \.fromUser).map { SourceRouter.relevant(to: $0.text, scope: scope, active: activeIDs) } ?? []
            // The sources the question names itself ("in WhatsApp"), or the plan picked: the user said where to look, so
            // Nook never searches everywhere else instead, and says so plainly when it cannot read that source right now.
            let named = Set(SourceCatalog.mentions(in: text).flatMap { $0.ids } + (plan?.sources ?? [])).filter { scope.allows($0) }
            let unreachable = connectors.sources.filter { named.contains($0.id) && !activeIDs.contains($0.id) }
            for source in unreachable {
                let reason = Self.unreachableReason(source)
                blocked.append("\(source.title) (\(reason))")
                // Shown as a failed source when the user has it but Nook may not read it, not for a service never set up.
                var failed = source is AppDatabaseConnector
                if case .error = source.status.state { failed = true }
                if failed { ledger.noteUnavailable(source: source.id, tool: source.tools.first?.name ?? source.id, reason: reason) }
            }
            let sources: Set<String>
            var calls: [Prefetch.Call]
            if let plan, !plan.sources.isEmpty || plan.kind == .general || plan.kind == .chat {
                // The plan says where to look and with which words (several searches, synonyms included).
                var usable = plan
                usable.sources = plan.sources.filter { activeIDs.contains($0) && scope.allows($0) }
                sources = Set(usable.sources).union(Prefetch.inContext.intersection(relevant))
                calls = QueryPlanner.lookups(usable, question: text, available: available, limit: roomy ? 12 : 9)
            } else {
                sources = Research.sources(question: text, intent: intent, terms: terms, relevant: relevant, previous: previous,
                                           named: named, available: available, active: activeIDs.filter { scope.allows($0) })
                calls = Research.lookups(question: text, terms: terms, sources: sources, available: available, limit: roomy ? 12 : 9)
            }
            // An app the question names is read from its window, unless Nook already reads its data directly (a closed
            // app would otherwise be launched for nothing). Without that access, its window is the next best thing.
            if scope.allows(SourceCatalog.screen), let app = Self.appNamed(in: text),
               !(Self.appSources[app].map { sources.contains($0) && activeIDs.contains($0) } ?? false) {
                calls.insert(Prefetch.Call(tool: "read_app", input: ["app": app]), at: 0)
            }
            // Only what is about the question reaches the model: unrelated items that matched one common word are left
            // out, and of an app's whole window only the passages about the question are kept.
            let searchLimit = profile.isSmall ? (roomy ? 2_500 : 1_800) : 5_000
            let shape: (String, String) -> String = { tool, output in
                tool == "read_app" ? Research.focus(output, terms: terms, limit: searchLimit) : Research.relevantOnly(output, tool: tool, terms: terms)
            }
            let results = await Self.runAll(calls, tools: tools, timeout: 8, limit: searchLimit, shape: shape)
            found = results.map(\.output)

            // Open the best hits in full: the start of a note or a file name is rarely the answer. A source Nook does
            // not know (an MCP server) is opened with its own read tool.
            let readers = Set(tools.map(\.name))
            let hits = Research.toOpen(results, terms: terms, wantsContent: Research.wantsContent(text), available: readers,
                                       limit: profile.isSmall ? (roomy ? 3 : 2) : 4, openers: Research.openers(available))
            let reads = hits.compactMap { hit in hit.read.map { Prefetch.Call(tool: $0, input: hit.input) } }
            let readLimit = profile.isSmall ? (roomy ? 4_000 : 2_500) : 10_000
            opened = await Self.runAll(reads, tools: tools, timeout: 6, limit: readLimit) { _, output in
                // A long document keeps the parts about the question, so they are not cut off.
                output.count > readLimit ? Research.focus(output, terms: terms, limit: readLimit) : output
            }.map(\.output)

            if !ledger.steps.isEmpty {
                let words = terms.query(limit: 6)
                let outcomes = ledger.steps.map { step -> String in
                    switch step.outcome {
                    case .found(let count): return "\(step.sourceTitle) (\(step.tool): \(count) results)"
                    case .empty: return "\(step.sourceTitle) (\(step.tool): nothing found)"
                    case .failed(let error): return "\(step.sourceTitle) (\(step.tool): failed, \(error))"
                    case .running: return "\(step.sourceTitle) (\(step.tool))"
                    }
                }
                searched = (words.isEmpty ? "Nook looked in: " : "Nook searched for \"\(words)\" in: ") + outcomes.joined(separator: "; ") + "."
            }
        }

        // What was found goes first: when the context is too long for the model, the general overview gives way, not
        // the documents that answer the question.
        let overview = summary.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var context = overview.first.map(String.init) ?? ""
        if !goal.isEmpty {
            context += "\n\nWhat the user wants (Nook's reading of the question): " + goal
        }
        if !blocked.isEmpty {
            context += "\n\nThe user asks about a source Nook cannot read right now: " + blocked.joined(separator: "; ")
                + ". Say this plainly at the start of the answer, with how to fix it. Never guess what is in that source and never answer yes or no about it from other sources. Only if its app window was read (read_app) below, answer from that and say so."
        }
        if !found.isEmpty || !opened.isEmpty || !searched.isEmpty {
            context += "\n\nLooked up for this question (use what is really about the question; ignore the rest):\n" + searched
            if !opened.isEmpty {
                context += "\n\nRead in full (the best matches):\n" + opened.joined(separator: "\n\n")
            }
            if !found.isEmpty {
                context += "\n\nSearch results:\n" + found.joined(separator: "\n\n")
            }
        }
        if overview.count > 1 { context += "\n\n" + overview[1] }

        // URLs the user or the screen mentioned may be opened by the web tools.
        web.note(text)
        if let snapshotText { web.note(snapshotText) }
        web.note(connectors.contextLines(scope: scope, full: relevant).lines.joined(separator: "\n"))
        return PreparedRun(scope: scope, relevant: relevant, summary: summary, ledger: ledger, tools: tools, context: context,
                           fetched: opened + found)
    }

    /// Runs lookups at once, each with a time limit; returns the ones that answered, in the order asked.
    private static func runAll(_ calls: [Prefetch.Call], tools: [ToolSpec], timeout: Double, limit: Int,
                               shape: @escaping (String, String) -> String = { $1 }) async -> [(tool: String, output: String)] {
        let runnable = calls.compactMap { call in tools.first(where: { $0.name == call.tool }).map { (call, $0) } }
        guard !runnable.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, String, String?).self) { group in
            for (index, item) in runnable.enumerated() {
                group.addTask { @MainActor in
                    let output = try? await RetrievalLedger.withTimeout(timeout) { try await item.1.run(item.0.input) }
                    return (index, item.0.tool, output)
                }
            }
            var results: [(Int, String, String)] = []
            for await (index, tool, output) in group {
                guard let raw = output, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let output = shape(tool, raw)
                var text = String(output.prefix(limit))
                if output.count > limit { text += "\n… (shortened)" }
                results.append((index, tool, text))
            }
            return results.sorted { $0.0 < $1.0 }.map { (tool: $0.1, output: $0.2) }
        }
    }

    func contextSummary() -> String {
        contextSummary(scope: .automatic, relevant: nil).text
    }

    /// Prepares context payload. `relevant` nil = full context; otherwise only relevant sources
    /// are included in full and others as single-line summaries. Excluded sources are omitted.
    func contextSummary(scope: SourceScope, relevant: Set<String>?) -> (text: String, titles: [String]) {
        let now = Date()
        var lines = ["Nu: \(NookDates.long(now))"]

        if relevant != nil {
            lines.append("Sources for this question:")
            lines.append("- Keuze: \(scope.label())")
            if !scope.excluded.isEmpty || scope.mode == .only {
                let blocked = SourceCatalog.all.filter { !scope.allows($0.id) }.map { $0.title }
                lines.append("- Do not use (user preference): " + blocked.joined(separator: ", "))
            }
            if !scope.focus.isEmpty {
                lines.append("- Specifically requested by user, prioritize: " + scope.focus.map(SourceCatalog.title).sorted().joined(separator: ", "))
            }
            let unavailable = connectors.sources.filter { !$0.isActive && !$0.canLookUp && scope.allows($0.id) }.map { $0.title }
            if !unavailable.isEmpty { lines.append("- Not connected or disabled: " + unavailable.joined(separator: ", ")) }
            // Every app is a source too: without a connector, read_app reads what is in it.
            if scope.allows(SourceCatalog.screen) {
                let apps = ScreenReader.openApps().compactMap(\.localizedName).sorted()
                if !apps.isEmpty { lines.append("- Open apps (read one with read_app; closed apps work too): " + apps.joined(separator: ", ")) }
            }
        }

        // Calendar (from start of today), reminders, mail, browser, services: cached connector state.
        if scope.allows("calendar"), !connectors.active.contains(where: { $0.id == "calendar" }) {
            lines.append(calendar.hasEventAccess ? "Calendar: disabled in Connectors." : "Calendar: no access.")
        }
        let sourceContext = connectors.contextLines(scope: scope, full: relevant)
        lines.append(contentsOf: sourceContext.lines)

        if !loops.isEmpty, scope.allows(SourceCatalog.loops) {
            lines.append("Open punten (id tussen haken, voor complete_open_loop):")
            for loop in loops.prefix(10) { lines.append("- \(loop.title) [\(loop.id.prefix(8))]") }
        }

        let sessions = hub.sessions
        if !sessions.isEmpty {
            lines.append("Draaiende agents:")
            for session in sessions { lines.append("- \(session.name) (\(session.project)): \(session.status.label)") }
        }

        if let playing = nowPlaying.current {
            lines.append("Speelt nu: \(playing.title) – \(playing.artist)")
        }

        if let usage = hub.planUsage {
            lines.append("Claude-abonnement gebruikt: \(usage.label)" + (usage.resetLabel.map { " (\($0))" } ?? ""))
        }
        if let codexLine = codex.contextLine { lines.append(codexLine) }
        return (lines.joined(separator: "\n"), sourceContext.fullTitles)
    }
}
