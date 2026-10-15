import SwiftUI
import AppKit

/// Your agents in the notch. On the left the sessions, with a + next to "Sessions" to start one; on the right the
/// session you picked, or, after +, the place to start a new one. Each row says at a glance whether it is working,
/// waiting for you or done, in which folder, and with which account.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case new
    }

    var body: some View {
        let live = app.agentSessions
        let past = app.demoMode ? [] : Array(app.pastSessionsOutsideWorkspace.prefix(40))
        let selection = resolve(live: live, past: past)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                listHeader(selection)
                sessionList(live: live, past: past, selection: selection)
            }
            .frame(width: 256)

            Rectangle().fill(NookTheme.line).frame(width: 1)

            Group {
                switch selection {
                case .live(let session): AgentSessionDetail(selection: .live(session)).id(session.id)
                case .past(let session): AgentSessionDetail(selection: .past(session)).id("past:" + session.id)
                case .run(let id): AgentRunPanel(workspace: app.workspace, runID: id)
                case .new:
                    if app.demoMode {
                        nothingRunning
                    } else {
                        NewSessionComposer { id in viewModel.selectedAgentID = "run:" + id.uuidString }
                    }
                }
            }
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

    /// "Sessions" with a + right next to it: the one way to start something new.
    private func listHeader(_ selection: Selection) -> some View {
        let isNew: Bool = { if case .new = selection { return true }; return false }()
        return HStack(spacing: 8) {
            Text(tr("agents.mode.sessions"))
                .font(NookTheme.font(13.5, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: 4)
            if !app.demoMode {
                Button {
                    viewModel.selectedAgentID = "new"
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isNew ? NookTheme.ink : NookTheme.paper)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isNew ? NookTheme.paper : NookTheme.smoke))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("agents.newSession"))
                .accessibilityLabel(tr("agents.newSession"))
            }
        }
        .padding(.leading, 10)
    }

    // MARK: Selection

    /// What is shown on the right. Without a choice (or when it is gone): whatever waits for you or works, otherwise the
    /// place to start a new session.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id == "new" { return .new }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = live.first(where: { !$0.isDetected }) { return .live(first) }
        if app.demoMode, let first = live.first { return .live(first) }
        return .new
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .new: return "new"
        }
    }

    // MARK: List

    private func sessionList(live: [AgentSession], past: [PastSession], selection: Selection) -> some View {
        let tracked = live.filter { !$0.isDetected }
        let untracked = live.filter { $0.isDetected }
        let current = selectedID(selection)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if !app.demoMode {
                    WorkspaceRunsSection(workspace: app.workspace, selected: current) { id in
                        viewModel.selectedAgentID = "run:" + id.uuidString
                    }
                }
                if !tracked.isEmpty {
                    SectionHeader(title: tr("agents.nowActive"), trailing: "\(tracked.count)")
                        .padding(.top, 12)
                    ForEach(tracked) { session in
                        AgentListRow(
                            title: session.summary.isEmpty ? session.project : AgentFormat.title(session.summary),
                            state: .live(session),
                            folder: session.project,
                            path: session.cwd,
                            account: accountName(app.profile(for: session)),
                            agent: session.name,
                            time: nil,
                            selected: current == session.id
                        ) { viewModel.selectedAgentID = session.id }
                    }
                }
                if !untracked.isEmpty {
                    SectionHeader(title: tr("agents.untrackedHeader"), trailing: "\(untracked.count)")
                        .padding(.top, 12)
                    ForEach(untracked) { session in
                        AgentListRow(
                            title: session.project,
                            state: .untracked,
                            folder: session.project,
                            path: session.cwd,
                            account: accountName(app.profile(for: session)),
                            agent: session.name,
                            time: nil,
                            selected: current == session.id
                        ) { viewModel.selectedAgentID = session.id }
                        .help(tr("agents.live.untrackedHelp"))
                    }
                }
                if !past.isEmpty {
                    SectionHeader(title: tr("agents.recent"), trailing: app.history.loading ? tr("agents.checking") : nil)
                        .padding(.top, 12)
                    ForEach(past) { session in
                        AgentListRow(
                            title: AgentFormat.title(session.title),
                            state: .past,
                            folder: session.project,
                            path: session.cwd,
                            account: accountName(app.profile(for: session)),
                            agent: session.agent.shortName,
                            time: NookDates.ago(session.ended),
                            selected: current == "past:" + session.id
                        ) { viewModel.selectedAgentID = "past:" + session.id }
                    }
                }
            }
        }
    }

    /// The account a session ran with, always shown: "Personal", "Work", or the organization.
    private func accountName(_ profile: AgentProfile?) -> String? {
        guard !app.demoMode, let profile else { return nil }
        return AccountLabel.name(profile, app: app)
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

/// One session in the list, the same for every kind: what it is about, its state on the right (working, waits for
/// you, done…), and underneath in which folder, with which account and which agent.
struct AgentListRow: View {
    enum Kind {
        case run(WorkspaceRun)
        case live(AgentSession)
        case untracked
        case past
    }

    let title: String
    let state: Kind
    let folder: String
    let path: String
    let account: String?
    let agent: String
    let time: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                indicator
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(NookTheme.font(12.5, .medium))
                            .foregroundStyle(muted ? NookTheme.textSecondary : NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let label {
                            Text(label.text)
                                .font(NookTheme.font(11, .semibold))
                                .foregroundStyle(label.color)
                                .fixedSize()
                        } else if let time {
                            Text(time)
                                .font(NookTheme.font(11))
                                .foregroundStyle(NookTheme.textTertiary)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        Label(folder, systemImage: "folder")
                            .help(AgentPathFormat.tilde(path))
                        if let account {
                            Label(account, systemImage: "person")
                        }
                        Text(agent)
                    }
                    .labelStyle(CompactLabel())
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? NookTheme.smoke : (hovering ? NookTheme.graphite : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var muted: Bool {
        switch state {
        case .untracked, .past: return true
        default: return false
        }
    }

    /// Working: a pulsing violet dot. Waits for you: amber. Done: a mint check. Failed: coral. Earlier: a quiet circle.
    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .run(let run):
            switch run.status {
            case .running, .preparing: PulseDot(color: NookTheme.iris, animated: true)
            case .waitingApproval: PulseDot(color: NookTheme.amber, animated: false)
            case .completed: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.mint)
            case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.coral)
            case .stopped: Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(NookTheme.textTertiary)
            }
        case .live(let session):
            if session.approvalID != nil || session.status == .waiting {
                PulseDot(color: NookTheme.amber, animated: false)
            } else if session.status == .done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.mint)
            } else if session.status == .failed {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(NookTheme.coral)
            } else {
                PulseDot(color: NookTheme.iris, animated: session.status == .running)
            }
        case .untracked:
            Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(NookTheme.textTertiary)
        case .past:
            Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }

    /// The state in words, for sessions that are not just history.
    private var label: (text: String, color: Color)? {
        switch state {
        case .run(let run):
            switch run.status {
            case .running, .preparing: return (tr("agents.live.running"), NookTheme.iris)
            case .waitingApproval: return (tr("agents.live.waiting"), NookTheme.amber)
            case .completed: return (tr("agents.live.done"), NookTheme.mint)
            case .failed: return (tr("agents.live.failed"), NookTheme.coral)
            case .stopped: return (run.status.label, NookTheme.textTertiary)
            }
        case .live(let session):
            if session.approvalID != nil || session.status == .waiting { return (tr("agents.live.waiting"), NookTheme.amber) }
            switch session.status {
            case .running: return (tr("agents.live.running"), NookTheme.iris)
            case .done: return (tr("agents.live.done"), NookTheme.mint)
            case .failed: return (tr("agents.live.failed"), NookTheme.coral)
            default: return nil
            }
        case .untracked:
            return (tr("agents.live.untrackedShort"), NookTheme.textTertiary)
        case .past:
            return nil
        }
    }
}

/// Icon and text close together, small and quiet.
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9.5))
            configuration.title
        }
    }
}

// MARK: Formatting

enum AgentFormat {
    private static var time: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private static var day: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }

    private static var weekday: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "EEEEEE"
        return formatter
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

    /// "resets at 15:40" or "resets Thu Oct 16".
    static func reset(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        if date.timeIntervalSinceNow < 20 * 3600 { return tr("agents.resetAt", time.string(from: date)) }
        return tr("agents.resetOn", day.string(from: date))
    }

    static func weekdayLetter(_ date: Date) -> String { weekday.string(from: date) }

    /// A session title stripped of tags Claude Code sometimes prefixes ("<pasted_content …>").
    static func title(_ raw: String) -> String {
        var text = raw
        if text.contains("<") {
            text = text.replacingOccurrences(of: "<[^>]*>?", with: " ", options: .regularExpression)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-:· "))
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
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))
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
        if message.fromUser {
            HStack(spacing: 0) {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.iris.opacity(0.22)))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(agentColor)
                MarkdownView(text: message.text, size: 13)
            }
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
        let color = session.isDetected ? NookTheme.amber : session.liveColor
        HStack(spacing: 6) {
            if session.isDetected {
                Image(systemName: "eye.slash").font(.system(size: 10, weight: .bold))
            } else {
                PulseDot(color: color, animated: session.status == .running && session.approvalID == nil)
                    .frame(width: 12, height: 12)
            }
            Text(session.isDetected ? tr("agents.live.runningUntracked") : session.liveLabel)
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
struct WorkspaceRunsSection: View {
    @ObservedObject var workspace: WorkspaceManager
    let selected: String
    let open: (UUID) -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let recent = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 24 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
            .prefix(12)
        ForEach(Array(recent)) { run in
            AgentListRow(
                title: run.title,
                state: .run(run),
                folder: run.isolation == .worktree ? "\(run.projectName) · \(run.branch ?? "worktree")" : run.projectName,
                path: run.workingDirectory,
                account: app.profile(for: run).map { AccountLabel.name($0, app: app) },
                agent: run.provider.kind.shortName,
                time: nil,
                selected: selected == "run:" + run.id.uuidString
            ) { open(run.id) }
        }
    }
}
