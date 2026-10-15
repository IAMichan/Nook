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

    /// An app the question names ("wat staat er in Notities", "lees Slack", "kijk in WhatsApp"),
    /// including open apps and well-known Mac apps.
    static func appNamed(in text: String) -> String? {
        let own: Set<String> = ["com.apple.mail", "com.apple.iCal", "com.apple.reminders", "com.apple.finder"]
        let lower = text.lowercased()

        // Common apps mentioned directly in questions
        let common = [
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
        for (keyword, appName) in common {
            let pattern = #"(?<![\p{L}\d])"# + keyword + #"(?![\p{L}\d])"#
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return appName
            }
        }

        for app in ScreenReader.openApps() where !own.contains(app.bundleIdentifier ?? "") {
            guard let name = app.localizedName, name.count >= 3 else { continue }
            let pattern = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\d])"#
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return name }
        }
        return nil
    }

    /// A short list from looked-up data, for when the model gives no usable answer: headings, list lines, or the start.
    static func digest(_ fetched: [String]) -> String {
        let lines = fetched.joined(separator: "\n").components(separatedBy: .newlines)
        let headings = lines.filter { $0.hasPrefix("### ") }.prefix(10).map { "- " + $0.dropFirst(4) }
        if !headings.isEmpty { return "Dit vond ik:\n\n" + headings.joined(separator: "\n") }
        let items = lines.filter { $0.hasPrefix("- ") || $0.hasSuffix(":") }.prefix(20)
        if !items.isEmpty { return "Dit vond ik:\n\n" + items.joined(separator: "\n") }
        return "Dit vond ik:\n\n" + String(lines.joined(separator: "\n").prefix(800))
    }

    /// An answer that is no answer: code or JSON for a question that is not about code, or in another language than asked.
    static func looksBroken(_ answer: String, question: String, expected: NLLanguage?) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let aboutCode = question.range(of: #"code|json|script|programm\w*|regex|sql|swift|python|javascript|html|css|\bapi\b|terminal|commando"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
        if !aboutCode, trimmed.contains("```") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        // Language only on real prose: names, titles and numbers say little.
        let prose = trimmed.replacingOccurrences(of: #"```[\s\S]*?```|\[[0-9]+\]|\*\*"#, with: "", options: .regularExpression)
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
    /// `onSummary` fires as soon as the source choice is known, before the lookups run.
    func prepareRun(
        text: String, scope: SourceScope, snapshotText: String?, ledger: RetrievalLedger, prefetch: Bool = true,
        onSummary: ((_ summary: (text: String, titles: [String])) -> Void)? = nil
    ) async -> PreparedRun {
        // Only sources relevant to this query are included in full; others as one-line summaries.
        var activeIDs = Set(connectors.searchable.map { $0.id })
        activeIDs.insert(SourceCatalog.loops)
        let relevant = SourceRouter.relevant(to: text, scope: scope, active: activeIDs)
        let summary = contextSummary(scope: scope, relevant: relevant)
        onSummary?(summary)
        let tools = scopedTools(scope, ledger: ledger)

        // Nook looks up what the question is about itself, for every relevant source and any app the question names,
        // all at once, and hands the results to the brain. The answer never waits on the model deciding to call a tool,
        // and a cloud model saves its tool round trips.
        var context = summary.text
        var fetched: [String] = []
        if prefetch {
            let available = tools.compactMap { spec -> Prefetch.Available? in
                guard spec.kind == .read, let source = SourceCatalog.source(forTool: spec.name) else { return nil }
                return Prefetch.Available(name: spec.name, source: source, required: (spec.schema["required"] as? [String]) ?? [])
            }
            var calls = Prefetch.calls(for: text, relevant: relevant, available: available)
            if scope.allows(SourceCatalog.screen), let app = Self.appNamed(in: text) {
                calls.insert(Prefetch.Call(tool: "read_app", input: ["app": app]), at: 0)
            }
            let runnable = calls.compactMap { call in tools.first(where: { $0.name == call.tool }).map { (call, $0) } }
            if !runnable.isEmpty {
                fetched = await withTaskGroup(of: (Int, String?).self) { group in
                    for (index, item) in runnable.enumerated() {
                        group.addTask { @MainActor in
                            let output = try? await RetrievalLedger.withTimeout(8) { try await item.1.run(item.0.input) }
                            return (index, output)
                        }
                    }
                    var results: [(Int, String)] = []
                    for await (index, output) in group { if let output { results.append((index, String(output.prefix(5000)))) } }
                    return results.sorted { $0.0 < $1.0 }.map(\.1)
                }
            }
            if !fetched.isEmpty {
                context += "\n\nLooked up for this question (answer from this):\n" + fetched.joined(separator: "\n\n")
            }
        }

        // URLs the user or the screen mentioned may be opened by the web tools.
        web.note(text)
        if let snapshotText { web.note(snapshotText) }
        web.note(connectors.contextLines(scope: scope, full: relevant).lines.joined(separator: "\n"))
        return PreparedRun(scope: scope, relevant: relevant, summary: summary, ledger: ledger, tools: tools, context: context, fetched: fetched)
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
            lines.append(calendar.hasEventAccess ? "Calendar: disabled in Connectors." : "Agenda: geen toegang.")
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
