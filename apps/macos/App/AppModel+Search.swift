import Foundation

/// Search everything: what it searches (conversations with Nook, agent sessions with their transcripts, chats, call
/// notes, memories, notices, settings and actions) and where a hit takes you. Everything stays on this Mac; nothing here
/// goes to a brain. The engine is `SearchIndex`; `SearchCenter` runs it for the panel.
extension AppModel {
    /// Everything search can find, as it is now. `transcripts` holds the passages of sessions whose timeline is not in
    /// memory, read from disk earlier by `SearchCenter`.
    func searchDocuments(transcripts: [UUID: [SearchPassage]] = [:]) -> [SearchDocument] {
        var documents = searchActions() + searchSettings()
        documents += searchConversations()
        documents += searchSessions(transcripts: transcripts)
        documents += searchChats()
        documents += searchNotes()
        documents += searchMemories()
        documents += searchNotices()
        return documents
    }

    // MARK: What it finds

    /// Things to do, found by their name: the same as the Agents palette (⌘K), and a few more.
    private func searchActions() -> [SearchDocument] {
        let actions: [(id: String, title: String)] = [
            ("newChat", tr("search.action.newChat")),
            ("newSession", tr("agents.newSession")),
            ("pullRequests", tr("agents.footer.pullRequests")),
            ("usage", tr("agents.footer.usage")),
            ("terminals", tr("agents.footer.terminals")),
            ("browser", tr("agents.footer.browser")),
            ("worktrees", tr("agents.footer.worktrees")),
            ("recordCall", NoteTaker.shared.isRecording ? tr("notes.menu.stop") : tr("notes.menu.start")),
            ("window", tr("menu.window")),
            ("settings", tr("agents.footer.settings")),
        ]
        return actions.map { SearchDocument(id: "action:" + $0.id, kind: .action, title: $0.title, boost: 0.2) }
    }

    /// Every setting by its name on screen, with its English name too, so "language" finds "Taal".
    private func searchSettings() -> [SearchDocument] {
        let sections = SettingsSection.allCases.map { section in
            SearchDocument(id: "setting:section." + section.rawValue, kind: .setting, title: section.title, subtitle: section.subtitle,
                           facets: ["section": section.title],
                           passages: [SearchPassage(text: I18n.text("settings.section.\(section.rawValue)", [], for: .en))])
        }
        let settings = SettingsSearch.index.map { entry in
            SearchDocument(id: "setting:" + entry.key, kind: .setting, title: tr(entry.key), subtitle: entry.section.title,
                           facets: ["section": entry.section.title],
                           passages: [SearchPassage(text: I18n.text(entry.key, [], for: .en))])
        }
        return sections + settings
    }

    private func searchConversations() -> [SearchDocument] {
        chat.conversations.filter { !$0.isEmpty }.map { conversation in
            var flags: Set<String> = []
            if conversation.pinned { flags.insert("pinned") }
            if conversation.archived { flags.insert("archived") }
            if conversation.busy { flags.insert("running") }
            switch conversation.status {
            case .unread: flags.insert("unread")
            case .waiting: flags.insert("waiting")
            case .working, .idle: break
            }
            let passages = conversation.messages.filter { !$0.text.isEmpty }.map { message in
                SearchPassage(text: message.text, author: message.role == .user ? "me" : "nook", date: message.date,
                              anchor: message.id.uuidString)
            }
            return SearchDocument(id: "conversation:" + conversation.id.uuidString, kind: .conversation, title: conversation.title,
                                  subtitle: conversation.preview, date: conversation.updated, flags: flags, passages: passages,
                                  boost: conversation.pinned ? 0.4 : 0)
        }
    }

    /// Sessions Nook runs, with their whole conversation, and the agents it follows in a terminal or an editor.
    private func searchSessions(transcripts: [UUID: [SearchPassage]]) -> [SearchDocument] {
        let runs = workspace.runs.map { run -> SearchDocument in
            var flags: Set<String> = []
            if run.archived { flags.insert("archived") }
            if run.status.isActive { flags.insert("running") }
            switch run.status {
            case .failed: flags.insert("failed")
            case .waitingApproval: flags.insert("waiting")
            case .completed: flags.insert("done")
            case .preparing, .running, .stopped: break
            }
            if run.hasUnreviewedChanges { flags.insert("changes") }
            if run.isRemote { flags.insert("remote") }
            var facets = ["agent": [run.provider.displayName, run.resolvedModel ?? run.model].filter { !$0.isEmpty }.joined(separator: " "),
                          "project": run.projectName]
            if let branch = run.branch { facets["branch"] = branch }
            var passages = [SearchPassage(text: run.task, author: "me", date: run.createdAt)]
            if !run.instructions.isEmpty { passages.append(SearchPassage(text: run.instructions, author: "me", date: run.createdAt)) }
            if let detail = run.statusDetail, !detail.isEmpty { passages.append(SearchPassage(text: detail, date: run.updatedAt)) }
            if let loaded = workspace.events[run.id] {
                passages += Self.searchPassages(loaded, run: run)
            } else if let read = transcripts[run.id] {
                passages += read
            }
            let subtitle = [run.provider.displayName, run.projectName, run.branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return SearchDocument(id: "run:" + run.id.uuidString, kind: .session, title: run.title, subtitle: subtitle,
                                  date: run.updatedAt, facets: facets, flags: flags, passages: passages,
                                  boost: run.status.isActive ? 0.3 : 0)
        }
        let followed = hub.sessions.filter { !$0.id.hasPrefix("run:") }.map { session -> SearchDocument in
            var flags: Set<String> = []
            switch session.status {
            case .running, .detected: flags.insert("running")
            case .waiting: flags.insert("waiting")
            case .failed: flags.insert("failed")
            case .done: flags.insert("done")
            }
            var passages: [SearchPassage] = []
            if !session.lastPrompt.isEmpty { passages.append(SearchPassage(text: session.lastPrompt, author: "me", date: session.turnStarted)) }
            if !session.lastReply.isEmpty { passages.append(SearchPassage(text: session.lastReply, author: session.name, date: session.updated)) }
            if !session.summary.isEmpty { passages.append(SearchPassage(text: session.summary, author: session.name, date: session.updated)) }
            return SearchDocument(id: "agent:" + session.id, kind: .session, title: session.project.isEmpty ? session.name : session.project,
                                  subtitle: [session.name, AgentPathFormat.tilde(session.cwd)].filter { !$0.isEmpty }.joined(separator: " · "),
                                  date: session.updated ?? session.started, facets: ["agent": session.name, "project": session.project],
                                  flags: flags, passages: passages)
        }
        return runs + followed
    }

    /// The text of a session's timeline worth finding: what you asked, what the agent said, what failed, which tools ran.
    /// Thinking and tool output stay out; they drown the conversation.
    nonisolated static func searchPassages(_ events: [RunEvent], run: WorkspaceRun) -> [SearchPassage] {
        events.compactMap { event in
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch event.kind {
            case .user: return SearchPassage(text: text, author: "me", date: event.date, anchor: event.id.uuidString)
            case .assistant, .result, .error:
                return SearchPassage(text: text, author: run.provider.displayName, date: event.date, anchor: event.id.uuidString)
            case .tool, .fileChange:
                let line = [event.tool ?? "", text, event.kind == .fileChange ? (event.detail ?? "") : ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return SearchPassage(text: line, author: run.provider.displayName, date: event.date, anchor: event.id.uuidString)
            case .thinking, .approval, .system: return nil
            }
        }
    }

    /// Every chat in the Chats tab: WhatsApp's with a linked phone, and the ones from other apps (Instagram, Telegram,
    /// Messenger, Messages, Slack…), each with every message Nook has of it and a group's people.
    private func searchChats() -> [SearchDocument] {
        var documents: [SearchDocument] = []
        let link = WhatsAppLink.shared
        if link.isConnected {
            for conversation in link.inbox.sorted where !link.filters.ignored.contains(conversation.id) {
                let unread = link.unread(conversation.id)
                var flags: Set<String> = conversation.isGroup ? ["group"] : []
                if unread > 0 { flags.insert("unread") }
                let passages = conversation.messages.map { message in
                    SearchPassage(text: Self.whatsAppText(message),
                                  author: message.fromMe ? "me" : (message.senderName.isEmpty ? conversation.name : message.senderName),
                                  date: message.date, anchor: message.id)
                }
                var facets = ["app": "WhatsApp"]
                if conversation.members != nil { facets["people"] = conversation.memberNames.joined(separator: " ") }
                documents.append(SearchDocument(id: "chat:wa|" + conversation.id, kind: .chat, title: conversation.name, subtitle: "WhatsApp",
                                                date: conversation.lastActivity, facets: facets, flags: flags,
                                                passages: passages, boost: unread > 0 ? 0.3 : 0))
            }
            // The phone's other chats, quiet since Nook was linked: found by their name, as the Chats tab lists them.
            var listed = Set(documents.map(\.id))
            for chat in link.knownChats where WAJID.kind(chat.jid) != .status && !link.filters.ignored.contains(chat.jid) {
                let id = "chat:wa|" + chat.jid
                guard listed.insert(id).inserted else { continue }
                var flags: Set<String> = WAJID.kind(chat.jid) == .group ? ["group"] : []
                if link.unread(chat.jid) > 0 { flags.insert("unread") }
                documents.append(SearchDocument(id: id, kind: .chat, title: chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name,
                                                subtitle: "WhatsApp", date: chat.last, facets: ["app": "WhatsApp"], flags: flags))
            }
        }
        let capture = ChatCaptureService.shared
        for thread in capture.inbox.sorted where capture.sources.isOn(thread.app) {
            let app = MessagingApps.app(id: thread.app)?.name ?? thread.app
            var flags: Set<String> = thread.isGroup ? ["group"] : []
            if thread.unread > 0 { flags.insert("unread") }
            let passages = thread.messages.map { message in
                SearchPassage(text: message.summary, author: message.isMine ? "me" : (message.sender.isEmpty ? thread.name : message.sender),
                              date: message.date, anchor: message.id)
            }
            var facets = ["app": app]
            if let members = thread.members, !members.isEmpty { facets["people"] = members.joined(separator: " ") }
            documents.append(SearchDocument(id: "chat:" + thread.id, kind: .chat, title: thread.name, subtitle: app, date: thread.last,
                                            facets: facets, flags: flags, passages: passages, boost: thread.unread > 0 ? 0.3 : 0))
        }
        return documents
    }

    /// Recorded calls: the summary, key points, to-dos and every line, by who said it.
    private func searchNotes() -> [SearchDocument] {
        NoteTaker.shared.notes.map { note in
            let names = Dictionary(note.speakers.map { ($0.id, $0.isMe ? "me" : $0.name) }, uniquingKeysWith: { first, _ in first })
            var passages: [SearchPassage] = []
            if let summary = note.summary, !summary.isEmpty { passages.append(SearchPassage(text: summary, date: note.start)) }
            passages += note.keyPoints.map { SearchPassage(text: $0, date: note.start) }
            passages += note.todos.map { SearchPassage(text: $0.text, author: $0.owner ?? "", date: note.start) }
            passages += note.lines.map { line in
                SearchPassage(text: line.text, author: names[line.speaker] ?? line.speaker, date: note.start.addingTimeInterval(line.start),
                              anchor: line.id.uuidString)
            }
            let speakers = note.speakers.filter { !$0.isMe }.map(\.name).joined(separator: " ")
            var facets = ["speaker": speakers]
            if let app = note.app { facets["app"] = app }
            return SearchDocument(id: "note:" + note.id.uuidString, kind: .note, title: note.title,
                                  subtitle: [note.app ?? "", speakers].filter { !$0.isEmpty }.joined(separator: " · "),
                                  date: note.end ?? note.start, facets: facets, flags: [note.status.rawValue], passages: passages)
        }
    }

    private func searchMemories() -> [SearchDocument] {
        memory.items.map { item in
            var flags: Set<String> = [item.kind.rawValue, item.origin.rawValue]
            if item.pinned { flags.insert("pinned") }
            if item.localOnly { flags.insert("local") }
            return SearchDocument(id: "memory:" + item.id, kind: .memory, title: item.text, subtitle: item.subject,
                                  date: item.updated, facets: ["type": item.kind.rawValue], flags: flags,
                                  boost: item.pinned ? 0.2 : 0)
        }
    }

    private func searchNotices() -> [SearchDocument] {
        NoticeHistory.shared.log.entries.map { entry in
            var flags: Set<String> = [entry.kind.rawValue]
            if !entry.seen { flags.insert("unread") }
            return SearchDocument(id: "notice:" + entry.id.uuidString, kind: .notice, title: entry.title, subtitle: entry.context,
                                  date: entry.date, flags: flags,
                                  passages: entry.detail.isEmpty ? [] : [SearchPassage(text: entry.detail, date: entry.date)])
        }
    }

    // MARK: Opening a hit

    /// Goes to what a hit is about. Returns the panel tab to show it on, which the panel selects itself (in the notch or
    /// the main window); nil when it opened somewhere else (Settings) or only ran an action.
    func openSearchHit(_ hit: SearchHit) -> PanelTab? {
        let id = hit.document.id
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let value = String(id[id.index(after: colon)...])
        switch hit.document.kind {
        case .action:
            return runSearchAction(value)
        case .setting:
            let key: String? = value.hasPrefix("section.") ? nil : value
            let section = SettingsSection(rawValue: String(value.dropFirst("section.".count)))
                ?? SettingsSearch.index.first { $0.key == key }?.section
            openSettings(section: section)
            return nil
        case .conversation:
            guard let uuid = UUID(uuidString: value), chat.conversation(uuid) != nil else { return .chat }
            chat.select(uuid)
            return .chat
        case .session:
            if hit.document.id.hasPrefix("run:"), let uuid = UUID(uuidString: value) {
                workspace.selectedRunID = uuid
                viewModel.selectedAgentID = "run:" + uuid.uuidString
                // The session opens on what matched: its find bar takes the first highlighted words.
                if hit.passage?.anchor != nil, let words = Self.highlighted(hit) { viewModel.sessionFind = words }
            } else {
                viewModel.selectedAgentID = value
            }
            viewModel.sheet = nil
            viewModel.windowSheet = nil
            return .agents
        case .chat:
            viewModel.chatsFocus = ChatsFocus(chat: value)
            return .inbox
        case .note:
            guard let uuid = UUID(uuidString: value), let note = NoteTaker.shared.notes.first(where: { $0.id == uuid }) else { return nil }
            // A call note reads as a conversation, the way it arrived when the call ended.
            let conversation = chat.startNew()
            var message = ChatMessage(role: .nook, text: NoteTaker.shared.markdown(note))
            message.sources = [tr("notes.source")]
            chat.append(message, to: conversation)
            chat.select(conversation)
            return .chat
        case .memory:
            openSettings(section: .memory)
            return nil
        case .notice:
            guard let uuid = UUID(uuidString: value),
                  let entry = NoticeHistory.shared.log.entries.first(where: { $0.id == uuid }) else { return nil }
            switch entry.target {
            case .agent(let session):
                viewModel.selectedAgentID = session
                return .agents
            case .run(let run):
                workspace.selectedRunID = run
                viewModel.selectedAgentID = "run:" + run.uuidString
                return .agents
            case .agents:
                return .agents
            case .conversation(let conversation):
                if chat.conversation(conversation) != nil { chat.select(conversation) }
                return .chat
            case .whatsApp(let jid):
                viewModel.chatsFocus = ChatsFocus(chat: "wa|" + jid)
                return .inbox
            case .chat(let chatID):
                viewModel.chatsFocus = ChatsFocus(chat: chatID)
                return .inbox
            case .nowhere:
                return nil
            }
        }
    }

    /// Asks Nook in a new conversation: for a search that found nothing, or a question rather than words.
    func askFromSearch(_ text: String) {
        chat.startNew()
        ask(text)
    }

    private func runSearchAction(_ action: String) -> PanelTab? {
        switch action {
        case "newChat":
            chat.startNew()
            return .chat
        case "newSession":
            viewModel.selectedAgentID = "new"
            return .agents
        case "pullRequests":
            viewModel.selectedAgentID = AgentsPage.pullRequests
            return .agents
        case "usage":
            viewModel.selectedAgentID = AgentsPage.usage
            return .agents
        case "terminals":
            viewModel.selectedAgentID = AgentsPage.terminals
            return .agents
        case "browser":
            viewModel.selectedAgentID = AgentsPage.browser
            return .agents
        case "worktrees":
            viewModel.selectedAgentID = AgentsPage.worktrees
            return .agents
        case "recordCall":
            NoteTaker.shared.toggle()
            return nil
        case "window":
            openWindow()
            return nil
        case "settings":
            openSettings()
            return nil
        default:
            return nil
        }
    }

    /// The first highlighted words of a hit's snippet, as they are written there.
    private static func highlighted(_ hit: SearchHit) -> String? {
        guard let range = hit.snippetRanges.first else { return nil }
        let ns = hit.snippet as NSString
        guard range.upperBound <= ns.length else { return nil }
        let words = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
        return words.trimmingCharacters(in: .whitespaces).isEmpty ? nil : words
    }
}
