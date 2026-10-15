import SwiftUI
import AppKit

/// Your agents at a glance, in two views.
/// Sessions: currently running at the top (prominently marked), recent sessions below; selected item on the right.
/// Accounts: accounts per agent (personal, work…) with login, limits, and usage. Switch the default account
/// at the top with a single click; new sessions and Nook's brain will use that account.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case nothing
    }

    var body: some View {
        let live = app.agentSessions
        let past = app.demoMode ? [] : Array(app.pastSessionsOutsideWorkspace.prefix(40))
        let selection = resolve(live: live, past: past)
        VStack(alignment: .leading, spacing: 12) {
            header(live: live, past: past, selection: selection)
            HStack(alignment: .top, spacing: 16) {
                sessionList(live: live, past: past, selection: selection)
                    .frame(width: 236)

                Rectangle().fill(NookTheme.line).frame(width: 1)

                Group {
                    switch selection {
                    case .live(let session): AgentSessionDetail(selection: .live(session)).id(session.id)
                    case .past(let session): AgentSessionDetail(selection: .past(session)).id("past:" + session.id)
                    case .run(let id): AgentRunPanel(workspace: app.workspace, runID: id)
                    case .nothing: nothingRunning
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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

    // MARK: Top bar

    private func header(live: [AgentSession], past: [PastSession], selection: Selection) -> some View {
        let tracked = live.filter { !$0.isDetected }
        let waiting = tracked.filter { $0.status == .waiting || $0.approvalID != nil }.count
        let working = tracked.filter { $0.status == .running }.count
        let badge: (String, Color)? = waiting > 0 ? ("\(waiting)", NookTheme.amber)
            : (working > 0 ? ("\(working)", NookTheme.iris) : (live.isEmpty ? nil : ("\(live.count)", NookTheme.textTertiary)))

        return HStack(spacing: 8) {
            Text(tr("agents.mode.sessions"))
                .font(NookTheme.font(13.5, .semibold))
                .foregroundStyle(NookTheme.paper)
            if let badge {
                Text(badge.0)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(badge.1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(badge.1.opacity(0.16)))
            }
            Spacer(minLength: 8)
            if !app.demoMode {
                // Starting a session and managing accounts happen in the window and in Settings, not here.
                NookGhostButton(title: tr("agents.newSession")) { app.openWorkspace(newSession: true) }
                WorkspaceButton(workspace: app.workspace) { app.openWorkspace() }
            }
        }
    }

    // MARK: Selection

    /// Content displayed on the right. Falls back sensibly if the selected item is gone: running items take priority.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if let first = live.first(where: { !$0.isDetected }) { return .live(first) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = past.first { return .past(first) }
        if let first = live.first { return .live(first) }
        return .nothing
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .nothing: return ""
        }
    }

    // MARK: Sessions: list

    private func sessionList(live: [AgentSession], past: [PastSession], selection: Selection) -> some View {
        let tracked = live.filter { !$0.isDetected }
        let untracked = live.filter { $0.isDetected }
        let current = selectedID(selection)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if !tracked.isEmpty {
                    SectionHeader(title: tr("agents.nowActive"), trailing: "\(tracked.count)")
                    ForEach(tracked) { session in
                        LiveCard(session: session, account: accountTag(session), selected: current == session.id) {
                            viewModel.selectedAgentID = session.id
                        }
                    }
                }
                if !untracked.isEmpty {
                    SectionHeader(title: tr("agents.untrackedHeader"), trailing: "\(untracked.count)")
                        .padding(.top, tracked.isEmpty ? 0 : 12)
                    ForEach(untracked) { session in
                        UntrackedRow(session: session, account: accountTag(session), selected: current == session.id) {
                            viewModel.selectedAgentID = session.id
                        }
                    }
                }
                if live.isEmpty && past.isEmpty {
                    Text(tr("agents.noneWorkingNow"))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                if !app.demoMode {
                    WorkspaceRunsSection(workspace: app.workspace, selected: current) { id in
                        viewModel.selectedAgentID = "run:" + id.uuidString
                    }
                }
                if !past.isEmpty {
                    SectionHeader(title: tr("agents.recent"), trailing: app.history.loading ? tr("agents.checking") : nil)
                        .padding(.top, live.isEmpty ? 0 : 12)
                    ForEach(past) { session in
                        PastRow(session: session, account: accountTag(session), selected: current == "past:" + session.id) {
                            viewModel.selectedAgentID = "past:" + session.id
                        }
                    }
                }
            }
        }
    }

    /// "Work": only shown when you have multiple accounts for this agent, otherwise redundant.
    private func accountTag(_ session: AgentSession) -> String? {
        guard !app.demoMode, let profile = app.profile(for: session),
              app.profiles.profiles(for: profile.kind).count > 1 else { return nil }
        return displayName(profile)
    }

    private func accountTag(_ session: PastSession) -> String? {
        guard let profile = app.profile(for: session), app.profiles.profiles(for: profile.kind).count > 1 else { return nil }
        return displayName(profile)
    }

    /// Nothing active and no history: explain how to get started.
    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("agents.noneWorkingNow"))
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.nothingRunningDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !app.demoMode {
                HStack(spacing: 4) {
                    NookPrimaryButton(title: tr("agents.newSession")) { app.openWorkspace(newSession: true) }
                    NookGhostButton(title: tr("agents.accountsInSettings")) { app.openSettings(section: .connections) }
                    Spacer()
                }
            }
        }
    }

    // MARK: Sessions: running

    // MARK: Sessions: past

    // MARK: Data

    /// "Work", or for the first unnamed account: organization name, otherwise "Personal".
    private func displayName(_ profile: AgentProfile) -> String {
        if !profile.label.isEmpty { return profile.label }
        let account = app.history.profileAccounts[profile.id]
        if let org = account?.organization, !org.isEmpty { return org }
        if account?.name == "API-sleutel" { return account?.name ?? "" }
        return tr("agents.personal")
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

/// A past session in the list.
struct PastRow: View {
    let session: PastSession
    /// The account, shown only if you have multiple accounts for this agent.
    let account: String?
    let selected: Bool
    var showAgent = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(showAgent ? session.agent.color.opacity(0.8) : NookTheme.line2)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentFormat.title(session.title))
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper.opacity(0.92))
                        .lineLimit(1)
                    Text(([session.project] + (account.map { [$0] } ?? []) + [NookDates.ago(session.ended)]).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

/// A tracked session: accented with its state color.
struct LiveCard: View {
    let session: AgentSession
    let account: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = session.liveColor
        Button(action: action) {
            HStack(spacing: 10) {
                PulseDot(color: color, animated: session.status == .running && session.approvalID == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(([session.name] + (account.map { [$0] } ?? [])).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.liveLabel)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(color)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(selected ? 0.18 : (hovering ? 0.12 : 0.08))))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(selected ? 0.55 : 0.25), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A running agent not tracked by Nook: muted appearance to avoid looking active.
struct UntrackedRow: View {
    let session: AgentSession
    let account: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper.opacity(0.8))
                        .lineLimit(1)
                    Text(([session.name] + (account.map { [$0] } ?? []) + [tr("agents.live.untrackedShort")]).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(NookTheme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("agents.live.untrackedHelp"))
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


// MARK: Workspace in the notch

/// "Workspace" at the top of the Agents tab, with a badge when sessions are running or waiting.
struct WorkspaceButton: View {
    @ObservedObject var workspace: WorkspaceManager
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let waiting = workspace.runs.filter { $0.status == .waitingApproval }.count
        let active = workspace.activeRuns.count
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                Text(tr("ws.windowTitle"))
                    .font(NookTheme.font(12, .semibold))
                if waiting > 0 || active > 0 {
                    Text("\(waiting > 0 ? waiting : active)")
                        .font(NookTheme.mono(10.5, .semibold))
                        .foregroundStyle(waiting > 0 ? NookTheme.amber : NookTheme.iris)
                }
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(NookTheme.field))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("ws.openHelp"))
    }
}

/// Sessions Nook runs itself (started here, taken over, or from the workspace): working, waiting, or recently finished.
/// Selecting one shows it in the tab, where you control it completely.
struct WorkspaceRunsSection: View {
    @ObservedObject var workspace: WorkspaceManager
    let selected: String
    let open: (UUID) -> Void

    var body: some View {
        let recent = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 24 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
            .prefix(8)
        if !recent.isEmpty {
            SectionHeader(title: tr("agents.inNook"), trailing: "\(recent.count)")
                .padding(.top, 12)
            ForEach(Array(recent)) { run in
                let isSelected = selected == "run:" + run.id.uuidString
                Button { open(run.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: run.status.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(run.status.color)
                            .symbolEffect(.pulse, options: .repeating, isActive: run.status == .running)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title)
                                .font(NookTheme.font(12.5, .medium))
                                .foregroundStyle(NookTheme.paper.opacity(0.92))
                                .lineLimit(1)
                            Text([run.projectName, run.provider.kind.shortName, run.status.label].joined(separator: " · "))
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(run.status == .waitingApproval ? NookTheme.amber : NookTheme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? NookTheme.field : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
