import SwiftUI
import AppKit

/// Your agents in the notch. On the left every session, from whichever agent, started here or in a terminal; on the
/// right the session you picked, or, after the new-session button, the place to start one. A row shows the folder and
/// how long the session has been going, its name, and its branch with the agent's logo; the badge on the logo says
/// whether it runs under a personal or a work account. Finished sessions wait folded away at the bottom.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var showFinished = false
    @ObservedObject private var finishedMarks = FinishedSessions.shared

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case pullRequests
        case usage
        case terminals
        case browser
        case worktrees
        case new
    }

    var body: some View {
        let transcripts = app.demoMode ? [:] : app.detectedTranscripts()
        // A process Nook only sees is shown when its conversation can be read; agents are linked in Settings › Agents.
        let live = app.agentSessions.filter { app.demoMode || !$0.isDetected || transcripts[$0.id] != nil }
        let past = app.demoMode ? [] : Array(app.pastSessionsOutsideWorkspace.prefix(60))
        let selection = resolve(live: live, past: past)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                listHeader(selection)
                sessionList(live: live, past: past, transcripts: transcripts, selection: selection)
                if !app.demoMode {
                    AgentsFooter(selected: selectedID(selection)) { viewModel.selectedAgentID = $0 }
                }
            }
            .padding(.trailing, 12)
            .frame(width: 280)

            Rectangle().fill(Color(hex: 0x19191B)).frame(width: 1)

            Group {
                switch selection {
                case .live(let session):
                    SessionWorkbench(viewModel: viewModel, title: liveTitle(session), directory: session.cwd) { tools in
                        AgentSessionDetail(selection: .live(session), headerAccessory: tools)
                    }
                    .id(session.id)
                case .past(let session):
                    SessionWorkbench(viewModel: viewModel, title: AgentFormat.title(session.title), directory: session.cwd) { tools in
                        AgentSessionDetail(selection: .past(session), headerAccessory: tools)
                    }
                    .id("past:" + session.id)
                case .run(let id):
                    let run = app.workspace.run(id)
                    SessionWorkbench(viewModel: viewModel, title: run?.title ?? "", directory: run?.workingDirectory ?? "") { tools in
                        AgentRunPanel(workspace: app.workspace, runID: id, headerAccessory: tools)
                    }
                case .pullRequests: PullRequestsPanel()
                case .usage: AgentsUsagePanel()
                case .terminals: AgentsToolPage(title: tr("agents.footer.terminals")) { TerminalsView() }
                case .browser: AgentsToolPage(title: tr("agents.footer.browser")) { BrowserView() }
                case .worktrees: AgentsToolPage(title: tr("agents.footer.worktrees")) { WorktreesView() }
                case .new:
                    if app.demoMode {
                        nothingRunning
                    } else {
                        NewSessionComposer { id in viewModel.selectedAgentID = "run:" + id.uuidString }
                    }
                }
            }
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            app.hub.refreshDetected()
            app.adoptAccounts()
            app.history.refresh()
        }
        // Keep sessions and usage up to date while the tab remains open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                app.adoptAccounts()
                app.history.refresh()
            }
        }
    }

    // MARK: List header

    /// "Agents" with the button that starts a new session.
    private func listHeader(_ selection: Selection) -> some View {
        let isNew: Bool = { if case .new = selection { return true }; return false }()
        return HStack(spacing: 8) {
            Text(tr("tab.agents"))
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: 4)
            if !app.demoMode {
                Button {
                    viewModel.selectedAgentID = "new"
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isNew ? NookTheme.paper : NookTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isNew ? NookTheme.smoke : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("agents.newSession"))
                .accessibilityLabel(tr("agents.newSession"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }

    // MARK: Selection

    /// What is shown on the right. Without a choice (or when it is gone): whatever waits for you or works, otherwise the
    /// place to start a new session.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id == "new" { return .new }
        if id == AgentsPage.pullRequests && !app.demoMode { return .pullRequests }
        if id == AgentsPage.usage && !app.demoMode { return .usage }
        if id == AgentsPage.terminals && !app.demoMode { return .terminals }
        if id == AgentsPage.browser && !app.demoMode { return .browser }
        if id == AgentsPage.worktrees && !app.demoMode { return .worktrees }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = live.first(where: { $0.status == .waiting || $0.approvalID != nil || $0.status == .running }) { return .live(first) }
        if app.demoMode, let first = live.first { return .live(first) }
        return .new
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .pullRequests: return AgentsPage.pullRequests
        case .usage: return AgentsPage.usage
        case .terminals: return AgentsPage.terminals
        case .browser: return AgentsPage.browser
        case .worktrees: return AgentsPage.worktrees
        case .new: return "new"
        }
    }

    /// The name a live session goes by in its tools' header.
    private func liveTitle(_ session: AgentSession) -> String {
        session.summary.isEmpty ? session.name : AgentFormat.title(session.summary)
    }

    // MARK: List

    private func sessionList(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession],
                             selection: Selection) -> some View {
        let current = selectedID(selection)
        let runs = app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace)
        let running = sorted(runs.map { item($0) } + live.map { item($0, transcript: transcripts[$0.id]) })
        let busyKeys = Set(running.filter(\.isBusy).map(\.finishKey))

        return TimelineView(.periodic(from: .now, by: 30)) { context in
            // Marked as finished by you, or done and quiet for ten minutes: the chat moves down. Not while the agent works.
            let moved = running.filter { entry in
                guard !entry.isBusy else { return false }
                // A process Nook only sees (id "proc-…") is running in a terminal: never finished by itself.
                let idle = (entry.status == .idle || entry.status == .finished) && !entry.id.hasPrefix("proc-")
                return finishedMarks.isFinished(key: entry.finishKey, idle: idle, lastActive: entry.started, now: context.date)
            }
            let active = running.filter { entry in !moved.contains { $0.id == entry.id } }
            let movedKeys = Set(moved.map(\.finishKey))
            let finished = moved.map { $0.markedFinished() } + past.map { item($0) }.filter { !movedKeys.contains($0.finishKey) }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(active) { entry in
                        AgentListRow(item: entry, now: context.date, selected: current == entry.id) {
                            viewModel.selectedAgentID = entry.id
                        }
                        .contextMenu { finishMenu(entry, finished: false) }
                    }
                    if active.isEmpty && finished.isEmpty {
                        Text(app.history.loading ? tr("agents.checking") : tr("agents.noneWorkingNow"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(12)
                    }
                    if !finished.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showFinished.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(tr("agents.finishedCount", finished.count))
                                Image(systemName: showFinished ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                Spacer(minLength: 0)
                            }
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, active.isEmpty ? 0 : 6)
                        if showFinished {
                            ForEach(finished) { entry in
                                AgentListRow(item: entry, now: context.date, selected: current == entry.id) {
                                    viewModel.selectedAgentID = entry.id
                                }
                                .contextMenu { finishMenu(entry, finished: true) }
                            }
                        }
                    }
                }
            }
        }
        // The agent works in a chat you had marked as finished: it is not finished after all.
        .onChange(of: busyKeys) { _, keys in finishedMarks.reopenAll(keys) }
        .onAppear { finishedMarks.reopenAll(busyKeys) }
    }

    /// The finish/reopen action of a row, in its context menu.
    @ViewBuilder
    private func finishMenu(_ entry: AgentListItem, finished: Bool) -> some View {
        if entry.isBusy {
            Button(tr("agents.finish.mark")) {}.disabled(true)
        } else if finished {
            // Earlier sessions from transcripts are finished by nature; only chats that were running can be reopened.
            if !entry.id.hasPrefix("past:") {
                Button(tr("agents.finish.reopen")) { finishedMarks.reopenByUser(entry.finishKey) }
            }
        } else {
            Button(tr("agents.finish.mark")) { finishedMarks.mark(entry.finishKey) }
        }
    }

    /// Waiting for you first, then working, then the rest; newest first within each.
    private func sorted(_ items: [AgentListItem]) -> [AgentListItem] {
        func rank(_ status: AgentListItem.Status) -> Int {
            switch status {
            case .waiting: return 0
            case .failed: return 1
            case .working: return 2
            case .idle: return 3
            case .finished: return 4
            }
        }
        return items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.status), rank(b.element.status))
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func account(_ profile: AgentProfile?) -> AccountKind? {
        guard !app.demoMode, let profile else { return nil }
        return AccountKind.of(profile, app: app)
    }

    private func item(_ run: WorkspaceRun) -> AgentListItem {
        let status: AgentListItem.Status
        switch run.status {
        case .preparing, .running: status = .working
        case .waitingApproval: status = .waiting
        case .failed: status = .failed
        case .completed: status = .idle
        case .stopped: status = .finished
        }
        return AgentListItem(
            id: "run:" + run.id.uuidString,
            folder: run.projectName,
            title: run.title,
            branch: run.branch ?? GitHead.branch(for: run.workingDirectory),
            agent: run.provider.displayName,
            account: account(app.profile(for: run)),
            status: status,
            started: run.status.isActive ? (run.turnStartedAt ?? run.createdAt) : run.updatedAt,
            path: run.workingDirectory,
            finishKey: FinishedSessions.key(run: run)
        )
    }

    private func item(_ session: AgentSession, transcript: PastSession?) -> AgentListItem {
        let status: AgentListItem.Status
        if session.approvalID != nil || session.status == .waiting {
            status = .waiting
        } else {
            switch session.status {
            case .running: status = .working
            case .failed: status = .failed
            default: status = .idle
            }
        }
        let conversation = app.conversationID(for: session)
        let known = transcript ?? conversation.flatMap { id in app.history.sessions.first { $0.sessionID == id } }
        var title = session.project
        if !session.summary.isEmpty { title = AgentFormat.title(session.summary) }
        else if let known, !known.title.isEmpty { title = AgentFormat.title(known.title) }
        let branch = known.flatMap { $0.branch.isEmpty ? nil : $0.branch } ?? GitHead.branch(for: session.cwd)
        return AgentListItem(
            id: session.id,
            folder: session.project,
            title: title,
            branch: branch,
            agent: session.name,
            account: account(app.profile(for: session)),
            status: status,
            started: status == .idle ? (session.updated ?? session.started ?? known?.started) : (session.started ?? known?.started),
            path: session.cwd,
            finishKey: FinishedSessions.key(agent: session.name, conversation: conversation, fallback: session.id)
        )
    }

    private func item(_ session: PastSession) -> AgentListItem {
        AgentListItem(
            id: "past:" + session.id,
            folder: session.project,
            title: AgentFormat.title(session.title),
            branch: session.branch.isEmpty ? nil : session.branch,
            agent: session.agent.name,
            account: account(app.profile(for: session)),
            status: .finished,
            started: session.ended,
            path: session.cwd,
            finishKey: FinishedSessions.key(agent: session.agent.name, conversation: session.sessionID, fallback: "past:" + session.id)
        )
    }

    /// Sample data only: nothing to start.
    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("agents.noneWorkingNow"))
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.nothingRunningDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Session row

/// One session in the list, the same for every kind of session.
struct AgentListItem: Identifiable {
    enum Status { case working, waiting, failed, idle, finished }

    /// The selection id: a hub session id, "run:<uuid>" or "past:<id>".
    let id: String
    let folder: String
    let title: String
    let branch: String?
    /// The agent's display name, for its logo.
    let agent: String
    let account: AccountKind?
    let status: Status
    /// Working or waiting: when it started. Otherwise: when it was last active.
    let started: Date?
    let path: String
    /// Identifies the conversation for "mark as finished", the same for a running and an earlier session of it.
    let finishKey: String

    /// Busy or waiting for you: it cannot be marked as finished yet.
    var isBusy: Bool { status == .working || status == .waiting }

    func markedFinished() -> AgentListItem {
        AgentListItem(id: id, folder: folder, title: title, branch: branch, agent: agent, account: account, status: .finished,
                      started: started, path: path, finishKey: finishKey)
    }
}

/// The folder and the time on top, the name of the session, and its branch with the agent's logo underneath.
struct AgentListRow: View {
    let item: AgentListItem
    let now: Date
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var background: Color { selected ? Color(hex: 0x17171A) : (hovering ? Color(hex: 0x111113) : Color(hex: 0x09090A)) }
    private var dimmed: Bool { item.status == .finished }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.folder)
                        .lineLimit(1)
                        .help(AgentPathFormat.tilde(item.path))
                    Spacer(minLength: 6)
                    time
                }
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)

                Text(item.title)
                    .font(NookTheme.font(14.5, .medium))
                    .foregroundStyle(dimmed ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium))
                    Text(item.branch ?? tr("agents.noBranch")).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    AgentMark(agent: item.agent, account: item.account, size: 15, dimmed: dimmed, ring: background)
                        .padding(.trailing, item.account == nil ? 0 : 3)
                }
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    /// "bezig 12 min" while it works, "wacht op jou" when it waits, otherwise how long ago.
    @ViewBuilder
    private var time: some View {
        switch item.status {
        case .working:
            Text(item.started.map { tr("agents.time.busy", AgentFormat.short(now.timeIntervalSince($0))) } ?? tr("agents.live.running"))
                .foregroundStyle(Color(hex: 0x8CA2FF))
                .fixedSize()
        case .waiting:
            Text(tr("agents.live.waiting"))
                .foregroundStyle(NookTheme.amber)
                .fixedSize()
        case .failed:
            Text(tr("agents.live.failed"))
                .foregroundStyle(NookTheme.coral)
                .fixedSize()
        case .idle, .finished:
            if let started = item.started {
                Text(AgentFormat.short(now.timeIntervalSince(started)))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// The branch a folder is on, read straight from `.git/HEAD` (no git process), so every row can show it cheaply.
@MainActor
enum GitHead {
    private static var cache: [String: (branch: String?, read: Date)] = [:]

    static func branch(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if let hit = cache[path], Date().timeIntervalSince(hit.read) < 30 { return hit.branch }
        let branch = read(path)
        cache[path] = (branch, Date())
        return branch
    }

    private static func read(_ path: String) -> String? {
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<12 {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue {
                    // A worktree: ".git" is a file pointing at the real git directory.
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : folder.appendingPathComponent(target)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }
}

// MARK: Formatting

enum AgentFormat {
    private static let formatterLock = NSLock()
    private static var cachedLanguage: String = ""
    private static var cachedTimeFormatter = DateFormatter()
    private static var cachedDayFormatter = DateFormatter()
    private static var cachedWeekdayFormatter = DateFormatter()
    private static let tagStripperRegex = try? NSRegularExpression(pattern: "<[^>]*>?")
    private static let titleTrimSet = CharacterSet(charactersIn: "#*-:· ")

    private static func updateFormattersIfNeeded() {
        let lang = I18n.shared.language.rawValue
        guard cachedLanguage != lang else { return }
        cachedLanguage = lang
        let locale = Locale(identifier: lang)
        cachedTimeFormatter.locale = locale
        cachedTimeFormatter.dateFormat = "HH:mm"
        cachedDayFormatter.locale = locale
        cachedDayFormatter.dateFormat = "EEE d MMM"
        cachedWeekdayFormatter.locale = locale
        cachedWeekdayFormatter.dateFormat = "EEEEEE"
    }

    private static func formatTime(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedTimeFormatter.string(from: date)
    }

    private static func formatDay(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedDayFormatter.string(from: date)
    }

    /// "< 1 min", "12 min", "1h 20m", "3 days".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)u" : "\(hours)u \(minutes % 60)m" }
        return "\(hours / 24) d"
    }

    /// Short, for lists: "now", "12 min", "3 h", "2 d".
    static func short(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return tr("agents.time.now") }
        if minutes < 60 { return tr("agents.time.minutes", minutes) }
        let hours = minutes / 60
        if hours < 24 { return tr("agents.time.hours", hours) }
        return tr("agents.time.days", hours / 24)
    }

    /// "resets at 15:40" or "resets Thu Oct 16".
    static func reset(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        if date.timeIntervalSinceNow < 20 * 3600 { return tr("agents.resetAt", formatTime(date)) }
        return tr("agents.resetOn", formatDay(date))
    }

    static func weekdayLetter(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedWeekdayFormatter.string(from: date)
    }

    /// A session title stripped of tags Claude Code sometimes prefixes ("<pasted_content …>").
    static func title(_ raw: String) -> String {
        var text = raw
        if text.contains("<"), let regex = tagStripperRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: titleTrimSet)
        if text.isEmpty { return raw.contains("pasted") ? tr("agents.pastedText") : tr("agents.untitledSession") }
        return text
    }

    static func count(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    static func color(percent: Double) -> Color {
        switch percent {
        case ..<60: return NookTheme.mint
        case ..<85: return NookTheme.amber
        default: return NookTheme.coral
        }
    }
}

/// A single subscription limit: percentage consumed and reset time.
struct UsageLimit: Identifiable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { label }
}

// MARK: Components


struct SectionHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(NookTheme.font(11.5, .semibold))
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NookTheme.font(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2)
                Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 4)
    }
}

struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(value)
                .font(NookTheme.font(12.5, .semibold))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(NookTheme.field))
    }
}

struct Message: View {
    let author: String
    let text: String
    let color: Color
    /// Agent replies are Markdown; render them formatted instead of as raw text.
    var markdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(author)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(color)
            if markdown {
                MarkdownView(text: text, size: 12.5)
            } else {
                Text(text)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(Color(hex: 0xC9C7D2))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The conversation of a running session: what you asked and what the agent answered, newest at the bottom.
struct AgentConversation: View {
    let session: AgentSession
    @State private var messages: [AgentChatMessage] = []

    private var agentColor: Color { AgentKind(agentName: session.name)?.color ?? NookTheme.iris }

    /// Messages from the transcript, or, without one, the last prompt and reply the hooks reported.
    private var shown: [AgentChatMessage] {
        if !messages.isEmpty { return messages }
        var fallback: [AgentChatMessage] = []
        if !session.lastPrompt.isEmpty { fallback.append(AgentChatMessage(id: "p", fromUser: true, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { fallback.append(AgentChatMessage(id: "r", fromUser: false, text: session.lastReply)) }
        return fallback
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    if shown.isEmpty {
                        Text(tr("agents.noMessagesInTranscript"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    ForEach(shown) { message in
                        bubble(message).id(message.id)
                    }
                    if session.status == .running {
                        HStack(spacing: 6) {
                            PulseDot(color: agentColor, animated: true)
                            Text(tr("agents.reply.working", session.name))
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                        .id("working")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: shown) { _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
        .task(id: session.id + session.transcriptPath) {
            // While the agent works the transcript keeps growing: read it again every couple of seconds.
            while !Task.isCancelled {
                let path = session.transcriptPath
                if !path.isEmpty {
                    let fresh = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
                    if fresh != messages { messages = fresh }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AgentChatMessage) -> some View {
        if message.isThinking {
            ThinkingBubble(text: message.text)
        } else {
            ChatBubble(fromUser: message.fromUser, text: message.text)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let last = session.status == .running ? "working" : shown.last?.id
        guard let last else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }
}


/// Color and label for the status of a tracked session.
private extension AgentSession {
    var liveColor: Color {
        if approvalID != nil { return NookTheme.amber }
        switch status {
        case .waiting: return NookTheme.amber
        case .running: return NookTheme.iris
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        case .detected: return NookTheme.textTertiary
        }
    }

    var liveLabel: String {
        if approvalID != nil { return tr("agents.live.waiting") }
        switch status {
        case .waiting: return tr("agents.live.waiting")
        case .running: return tr("agents.live.running")
        case .failed: return tr("agents.live.failed")
        case .done: return tr("agents.live.done")
        case .detected: return tr("agents.live.notTracked")
        }
    }
}

/// One message in a conversation: what you wrote in a soft box on the right, the agent's answer as plain text.
struct ChatBubble: View {
    let fromUser: Bool
    let text: String

    var body: some View {
        if fromUser {
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(text)
                    .font(NookTheme.font(13.5))
                    .foregroundStyle(NookTheme.paper)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x19191B)))
            }
        } else {
            MarkdownView(text: text, size: 13.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A collapsible bubble displaying internal model reasoning / thoughts.
struct ThinkingBubble: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NookTheme.iris)
                    Text(tr("ws.event.thinking"))
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x141416))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dot that gently pulses while the agent is running.
struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.3 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Top of detail view: "● Working", "● Waiting for you", "Nook is not monitoring".
struct StatusPill: View {
    let session: AgentSession

    var body: some View {
        let color = session.isDetected ? NookTheme.textSecondary : session.liveColor
        HStack(spacing: 6) {
            if session.isDetected {
                Image(systemName: "terminal").font(.system(size: 10, weight: .bold))
            } else {
                PulseDot(color: color, animated: session.status == .running && session.approvalID == nil)
                    .frame(width: 12, height: 12)
            }
            Text(session.isDetected ? tr("agents.live.inTerminal") : session.liveLabel)
                .font(NookTheme.font(12, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}



/// The step currently being executed: a shimmer effect traversing the text.
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x8A8896), location: 0),
                            .init(color: Color(hex: 0x8A8896), location: max(0, phase - 0.15)),
                            .init(color: NookTheme.paper, location: phase),
                            .init(color: Color(hex: 0x8A8896), location: min(1, phase + 0.15)),
                            .init(color: Color(hex: 0x8A8896), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}



/// Sessions Nook runs itself (started here, taken over, or from the workspace): working, waiting, or finished in the
/// last day, newest first. Selecting one shows it on the right, where you control it completely.
@MainActor
enum WorkspaceRunsSection {
    static func recent(_ workspace: WorkspaceManager) -> [WorkspaceRun] {
        let list = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 24 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
        return Array(list.prefix(12))
    }
}
