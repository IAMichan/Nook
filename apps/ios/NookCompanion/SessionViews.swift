import SwiftUI

// MARK: One session

/// A session as a conversation: a header with where it works, the messages, the agent's steps folded into groups,
/// what waits on you, and a field to reply.
struct SessionDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var message = ""
    @State private var confirmStop = false

    private var session: SessionDigest? { client.sessions.first { $0.id == sessionID } }
    private var entries: [TimelineEntry] { client.timelines[sessionID] ?? [] }

    var body: some View {
        if let session {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SessionHeader(session: session)
                        if client.can(CompanionFeature.timeline) {
                            ForEach(TimelineBlock.blocks(entries)) { block in
                                switch block {
                                case .message(let entry): TimelineMessage(entry: entry)
                                case .activity(let steps): ActivityGroup(steps: steps)
                                }
                            }
                        } else if !session.excerpt.isEmpty {
                            SectionHeader(title: "Latest reply")
                            MessageBubble(text: session.excerpt, mine: false)
                        }
                        ForEach(session.items) { item in
                            ItemView(session: session, item: item)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.md)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: entries.last?.id) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onChange(of: session.items.count) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBar(placeholder: "Message to the agent", text: $message) { text in
                    Haptics.tap()
                    Task { await client.send(session, text: text) }
                }
            }
            .navigationTitle(session.folder)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.attention == "working" || session.attention == "approval" || session.attention == "input" {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { confirmStop = true } label: { Image(systemName: "stop.circle.fill").foregroundStyle(Theme.coral) }
                            .accessibilityLabel("Stop")
                    }
                }
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the session", role: .destructive) { Task { await client.stop(session) } }
            }
            .screen()
            // While the session is on screen its conversation stays current; leaving the screen ends the loop.
            .task {
                while !Task.isCancelled {
                    await client.loadTimeline(sessionID)
                    let working = client.sessions.first { $0.id == sessionID }?.attention == "working"
                    try? await Task.sleep(for: .seconds(working ? 2 : 5))
                }
            }
        } else {
            EmptyState(symbol: "tray", title: "This session is gone.", message: "It was closed or archived on your Mac.") {}
                .screen()
        }
    }

    private static let bottom = "bottom"
}

private struct SessionHeader: View {
    let session: SessionDigest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                AgentIcon(agent: session.agent, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(session.agent).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                StatusPill(attention: session.attention)
                MetaChip(symbol: "folder", text: session.folder)
                if let branch = session.branch, !branch.isEmpty { MetaChip(symbol: "arrow.triangle.branch", text: branch) }
            }
        }
        .card()
        .padding(.top, Theme.Spacing.sm)
    }
}

private struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.raised, in: Capsule())
    }
}

/// The timeline in readable pieces: each message on its own, and the steps between two messages folded together.
enum TimelineBlock: Identifiable {
    case message(TimelineEntry)
    case activity([TimelineEntry])

    var id: String {
        switch self {
        case .message(let entry): return entry.id
        case .activity(let steps): return "steps-" + (steps.first?.id ?? "")
        }
    }

    static func blocks(_ entries: [TimelineEntry]) -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var steps: [TimelineEntry] = []
        for entry in entries {
            switch entry.kind {
            case .tool, .change, .notice:
                steps.append(entry)
            case .user, .assistant, .error:
                if !steps.isEmpty { blocks.append(.activity(steps)); steps = [] }
                blocks.append(.message(entry))
            }
        }
        if !steps.isEmpty { blocks.append(.activity(steps)) }
        return blocks
    }
}

private struct TimelineMessage: View {
    let entry: TimelineEntry

    var body: some View {
        switch entry.kind {
        case .user:
            MessageBubble(text: entry.text, mine: true)
        case .error:
            Label { Text(entry.text).foregroundStyle(Theme.text).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
            }
            .font(.callout)
            .card(padding: Theme.Spacing.md, tint: Theme.coral)
        default:
            MessageBubble(text: entry.text, mine: false)
        }
    }
}

/// What the agent did between two messages: the last step, and the rest one tap away.
private struct ActivityGroup: View {
    let steps: [TimelineEntry]
    @State private var expanded = false

    private var changes: Int { steps.filter { $0.kind == .change }.count }
    private var tools: Int { steps.filter { $0.kind == .tool }.count }
    private var failed: Bool { steps.contains { $0.failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: failed ? "exclamationmark.circle.fill" : "gearshape.2.fill")
                        .foregroundStyle(failed ? Theme.coral : Theme.textTertiary)
                    Text(summary).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if steps.count > 1 {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.caption.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(steps.count < 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(expanded ? steps : Array(steps.suffix(1))) { StepLine(entry: $0) }
            }
            .padding(.leading, Theme.Spacing.sm)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2) }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var summary: String {
        var parts: [String] = []
        if tools > 0 { parts.append(String(localized: "\(tools) steps")) }
        if changes > 0 { parts.append(String(localized: "\(changes) files changed")) }
        return parts.isEmpty ? String(localized: "Activity") : parts.joined(separator: " · ")
    }
}

private struct StepLine: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(entry.failed ? Theme.coral : Theme.textTertiary).frame(width: 14)
            if let detail = entry.detail, !detail.isEmpty, entry.kind != .notice {
                Text(detail).fontWeight(.semibold).foregroundStyle(Theme.textSecondary)
            }
            Text(entry.text).foregroundStyle(Theme.textTertiary).lineLimit(2)
        }
        .font(.caption.monospaced())
        .padding(.leading, Theme.Spacing.sm)
    }

    private var symbol: String {
        switch entry.kind {
        case .change: return "doc.text"
        case .notice: return "info.circle"
        default: return entry.failed ? "xmark" : "chevron.right"
        }
    }
}

/// What waits on you in a session: an approval with Deny/Allow, or a question with its options and your own answer.
struct ItemView: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let item: SessionDigest.Item
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(heading, systemImage: item.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.amber)
            Text(item.title).font(.body).foregroundStyle(Theme.text).textSelection(.enabled)
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
            }
            switch item.kind {
            case .approval:
                HStack(spacing: Theme.Spacing.sm) {
                    Button("Deny") { Haptics.warning(); Task { await client.decide(session, item: item, allow: false) } }
                        .buttonStyle(ActionButtonStyle(color: Theme.coral))
                    if item.canAllow {
                        Button("Allow") { Haptics.success(); Task { await client.decide(session, item: item, allow: true) } }
                            .buttonStyle(ActionButtonStyle(color: Theme.mint, filled: true))
                    }
                }
                if !item.canAllow {
                    Label("This is risky or unknown: it can only be allowed on your Mac.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(Theme.amber)
                }
            case .question:
                if item.canAllow {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(item.options, id: \.self) { option in
                            Button(option) { Haptics.success(); Task { await client.answer(session, item: item, text: option) } }
                                .buttonStyle(ActionButtonStyle(color: Theme.amber))
                        }
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        TextField("Your own answer", text: $text)
                            .padding(.horizontal, Theme.Spacing.md)
                            .frame(minHeight: 38)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        Button {
                            let answer = text
                            text = ""
                            Haptics.success()
                            Task { await client.answer(session, item: item, text: answer) }
                        } label: { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
                            .buttonStyle(ActionButtonStyle(color: Theme.amber, filled: true))
                            .frame(width: 52)
                            .disabled(text.isEmpty)
                            .accessibilityLabel("Send")
                    }
                } else {
                    Label("Several questions at once: answer them on your Mac.", systemImage: "laptopcomputer")
                        .font(.caption).foregroundStyle(Theme.amber)
                }
            }
        }
        .card(tint: Theme.amber)
    }

    /// Typed, so both words go through the String Catalog.
    private var heading: LocalizedStringKey { item.kind == .approval ? "Approval" : "Question" }
}

// MARK: Starting a session

/// A new session on the Mac: the task, the agent and the folder, all on one screen. Account, model and permissions
/// come from the Mac's own defaults for that agent, and "allow everything" is never used for a session started here.
struct NewSessionView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let started: (String) -> Void

    @State private var task = ""
    @State private var title = ""
    @State private var agent = ""
    @State private var project = ""
    @State private var plan = false
    @State private var worktree = false
    @State private var loaded = false
    @State private var prepared = false
    @State private var starting = false
    /// Why the last start did not work; shown in the sheet, where the app's alert cannot appear.
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var options: LaunchOptions? { client.launchOptions }
    private var chosenAgent: LaunchOptions.Agent? { options?.agents.first { $0.id == agent } }
    private var chosenProject: LaunchOptions.Project? { options?.projects.first { $0.path == project } }
    private var canStart: Bool {
        !starting && chosenAgent != nil && chosenProject != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    content(options)
                } else if loaded {
                    EmptyState(symbol: "wifi.slash", title: "Your Mac does not answer.",
                               message: "Is the companion on, and are you on the same Wi‑Fi?") {}
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .screen()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.textSecondary) }
            }
            .onAppear(perform: prepare)
            .task {
                await client.loadLaunchOptions()
                loaded = true
                prepare()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.iris)
    }

    @ViewBuilder
    private func content(_ options: LaunchOptions) -> some View {
        if options.agents.isEmpty {
            EmptyState(symbol: "person.crop.circle.badge.questionmark", title: "No agent is ready on your Mac.",
                       message: "Connect one in Nook › Settings › Agents.") {}
        } else if options.projects.isEmpty {
            EmptyState(symbol: "folder", title: "No folders yet.",
                       message: "Start a session on your Mac once: its folder then shows up here.") {}
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TextField("What should the agent do?", text: $task, axis: .vertical)
                        .font(.body)
                        .lineLimit(5...12)
                        .focused($focused)
                        .card()

                    SectionHeader(title: "Agent")
                    ForEach(options.agents) { option in
                        ChoiceChip(title: option.name, selected: agent == option.id,
                                   icon: AnyView(AgentIcon(agent: option.id, size: 30))) {
                            withAnimation(.spring(duration: 0.25)) { agent = option.id }
                        }
                    }

                    SectionHeader(title: "Folder")
                    ForEach(options.projects) { option in
                        ChoiceChip(title: option.name, detail: Self.tilde(option.path), selected: project == option.path,
                                   icon: AnyView(Image(systemName: "folder.fill").foregroundStyle(Theme.iris).frame(width: 30))) {
                            withAnimation(.spring(duration: 0.25)) { project = option.path }
                        }
                    }

                    SectionHeader(title: "Options")
                    VStack(spacing: Theme.Spacing.md) {
                        if chosenAgent?.canPlan == true {
                            Toggle(isOn: $plan) { OptionLabel(symbol: "list.bullet.clipboard", title: "Plan first", detail: "Without changing anything") }
                            Divider().overlay(Theme.hairline)
                        }
                        if chosenProject?.canWorktree == true {
                            Toggle(isOn: $worktree) { OptionLabel(symbol: "arrow.triangle.branch", title: "Own branch", detail: "In a separate worktree") }
                            Divider().overlay(Theme.hairline)
                        }
                        TextField("Title (optional)", text: $title)
                    }
                    .tint(Theme.iris)
                    .card()

                    Label("Nook uses your account, model and permissions for this agent. Anything risky still waits for your approval.",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.xs)

                    if let failure {
                        Banner(text: failure, symbol: "exclamationmark.triangle.fill", color: Theme.coral)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button(action: start) {
                    if starting { ProgressView().tint(.white) } else { Label("Start session", systemImage: "play.fill") }
                }
                .buttonStyle(PrimaryButtonStyle(color: canStart || starting ? Theme.iris : Theme.raised))
                .disabled(!canStart)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.canvas)
            }
        }
    }

    /// Your defaults from the Mac, once.
    private func prepare() {
        guard !prepared, let options else { return }
        prepared = true
        agent = options.defaultAgent ?? options.agents.first?.id ?? ""
        project = options.defaultProject ?? options.projects.first?.path ?? ""
        plan = options.defaultPlan
        worktree = options.defaultWorktree
        focused = true
    }

    private func start() {
        guard canStart else { return }
        starting = true
        failure = nil
        let launch = LaunchRequest(agent: agent, project: project, task: task, title: title.isEmpty ? nil : title,
                                   plan: plan && chosenAgent?.canPlan == true,
                                   worktree: worktree && chosenProject?.canWorktree == true)
        Task {
            let id = await client.start(launch)
            starting = false
            guard let id else {
                Haptics.warning()
                failure = client.notice ?? String(localized: "Your Mac refused this.")
                client.notice = nil
                return
            }
            Haptics.success()
            dismiss()
            started(id)
        }
    }

    /// `/Users/name/code/app` as `~/code/app`: the folder's place without the long prefix.
    private static func tilde(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        return "~/" + parts.dropFirst(2).joined(separator: "/")
    }
}

private struct OptionLabel: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(Theme.iris).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
