import SwiftUI
import UniformTypeIdentifiers

/// Single session view: header with state and usage, timeline, pending approvals, and input field.
struct RunDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    let runID: UUID
    @State private var draft = ""
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var expanded: Set<UUID> = []
    @State private var followTail = true
    @State private var diffFile: GitFileChange?
    @FocusState private var composerFocused: Bool
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        if let run = workspace.run(runID) {
            VStack(spacing: 0) {
                header(run)
                Divider().overlay(WS.border)
                timeline(run)
                if let pending = workspace.approvals[runID], !pending.isEmpty {
                    ApprovalBar(run: run, pending: pending)
                } else if let request = bridge.pending.first(where: { $0.caller.kind == .run(runID) }) {
                    // A command or pull request the agent asks for through Nook's workspace (same as in the notch).
                    let approval = ApprovalCenter.make(request)
                    ApprovalView(approval: approval, maxHeight: 220) { app.approvals.decide(approval, $0) }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                }
                if let question = workspace.questions[runID]?.first {
                    // The agent asks something: answer it here; Stop stays available.
                    RunQuestionPanel(question: question, agent: run.provider.displayName,
                                     onStop: { workspace.stop(runID) }) { answers in
                        workspace.answer(runID, questionID: question.id, answers: answers)
                    }
                    .id(question.id)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                } else {
                    if run.limitedAt != nil, !run.status.isActive {
                        UsageLimitBanner(run: run)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }
                    if let waiting = workspace.queued[runID], !waiting.isEmpty {
                        QueuedMessagesStrip(queue: waiting, remove: { workspace.removeQueued(runID, message: $0) },
                                            steer: workspace.canSteer(runID) ? { workspace.steerQueued(runID, message: $0) } : nil,
                                            move: { workspace.moveQueued(runID, message: $0, toIndex: $1) },
                                            sendNow: run.status.isActive ? nil : { workspace.sendQueuedNow(runID) })
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }
                    composer(run)
                }
            }
            .onAppear {
                workspace.loadTimeline(runID)
                workspace.refreshGit(runID)
                workspace.prewarm(runID)
                composerFocused = true
            }
            .sheet(item: $diffFile) { file in
                ChangesSheet(runID: runID, initialFile: file)
            }
        }
    }

    // MARK: Header

    private func header(_ run: WorkspaceRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if editingTitle {
                    TextField(tr("ws.title.placeholder"), text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(NookTheme.font(17, .semibold))
                        .onSubmit {
                            workspace.rename(runID, to: titleDraft)
                            editingTitle = false
                        }
                        .onExitCommand { editingTitle = false }
                } else {
                    Text(run.title)
                        .font(NookTheme.font(17, .semibold))
                        .foregroundStyle(WS.text)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            titleDraft = run.title
                            editingTitle = true
                        }
                        .help(tr("ws.title.renameHelp"))
                }
                StatusBadge(status: run.status)
                Spacer(minLength: 8)
                if run.status.isActive, let started = run.turnStartedAt {
                    HStack(spacing: 4) {
                        Image(systemName: "timer").font(.system(size: 10))
                        ElapsedText(since: started)
                    }
                    .font(NookTheme.font(12))
                    .foregroundStyle(WS.secondary)
                    .help(tr("ws.header.elapsed"))
                }
                usageSummary(run)
            }
            HStack(spacing: 6) {
                Chip(text: run.provider.displayName, color: run.provider.color, agent: run.provider.kind)
                if let profile = app.profile(for: run) {
                    Chip(text: AccountLabel.name(profile, app: app), color: WS.secondary, systemImage: "person.crop.circle")
                        .help(tr("ws.header.accountHelp", AccountLabel.line(profile, app: app)))
                } else {
                    Chip(text: tr("ws.header.accountGone"), color: NookTheme.amber, systemImage: "person.crop.circle.badge.exclamationmark")
                }
                Chip(text: (run.resolvedModel ?? (run.model.isEmpty ? tr("ws.model.default") : run.model)), systemImage: "cpu")
                // Mode, permissions and model of the next turn: click to change, also while the agent works.
                Menu {
                    Section(tr("agents.run.nextTurn")) { NextTurnSettings(run: run) }
                } label: {
                    HStack(spacing: 6) {
                        Chip(text: run.mode.label, color: run.mode == .plan ? Color(hex: 0x8AB4F8) : WS.secondary)
                        Chip(text: run.permission.label, color: run.permission == .bypass ? NookTheme.coral : WS.secondary,
                             systemImage: run.permission == .bypass ? "exclamationmark.shield" : "checkmark.shield")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(WS.tertiary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(run.permission.help(for: run.provider))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: run.isolation == .worktree ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 10))
                Text(AgentPathFormat.tilde(run.workingDirectory))
                    .font(NookTheme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let branch = run.branch {
                    Text("·")
                    Text(branch).font(NookTheme.mono(11))
                }
                if let base = run.baseBranch {
                    Text("← \(base)").font(NookTheme.mono(11)).foregroundStyle(WS.tertiary)
                }
            }
            .foregroundStyle(WS.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func usageSummary(_ run: WorkspaceRun) -> some View {
        HStack(spacing: 10) {
            if let total = run.usage.totalTokens {
                Label(TokenTally.format(total), systemImage: "number")
                    .help(tr("ws.header.tokensHelp"))
            }
            if workspace.settings.showCost, let cost = run.usage.reportedCostUSD {
                Text(AgentPathFormat.cost(cost))
                    .help(tr("ws.usage.costReportedHelp"))
            }
            if let fraction = run.usage.contextFraction {
                HStack(spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 46)
                        .tint(fraction > 0.85 ? NookTheme.coral : (fraction > 0.6 ? NookTheme.amber : NookTheme.iris))
                    Text("\(Int((fraction * 100).rounded()))%")
                }
                .help(tr("ws.header.contextHelp"))
            }
        }
        .font(NookTheme.font(12))
        .foregroundStyle(WS.secondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: Timeline

    private func timeline(_ run: WorkspaceRun) -> some View {
        let events = workspace.timeline(runID)
        return ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not a LazyVStack: lazily estimated row heights plus scrolling to the bottom made SwiftUI's
                // scroll view re-adjust its offset forever (the window froze) whenever the width changed, e.g. when the
                // sidebar collapsed or a sheet opened.
                VStack(alignment: .leading, spacing: 10) {
                    if events.isEmpty {
                        Text(tr("ws.timeline.empty"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(WS.tertiary)
                            .padding(.top, 20)
                    }
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            expanded: expanded.contains(event.id),
                            toggle: { toggle(event.id) },
                            openFile: { path in openDiff(run, path: path) },
                            decide: { decision in
                                if let request = event.callID { workspace.decide(runID, requestID: request, decision) }
                            }
                        )
                        .id(event.id)
                    }
                    if run.status.isActive {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(run.status == .waitingApproval ? tr("ws.timeline.waiting") : tr("ws.timeline.working"))
                                .font(NookTheme.font(12))
                                .foregroundStyle(WS.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    if run.status == .failed || run.status == .stopped {
                        recoveryHint(run)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: events.count) { _, _ in
                if followTail { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: events.last?.text.count ?? 0) { _, _ in
                if followTail && run.status.isActive { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func recoveryHint(_ run: WorkspaceRun) -> some View {
        HStack(spacing: 10) {
            Image(systemName: run.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                .foregroundStyle(run.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.status == .failed ? tr("ws.recovery.failed") : (run.statusDetail == "interrupted" ? tr("ws.recovery.interrupted") : tr("ws.recovery.stopped")))
                    .font(NookTheme.font(12.5, .semibold))
                    .foregroundStyle(WS.text)
                Text(run.providerSessionID != nil ? tr("ws.recovery.canResume") : tr("ws.recovery.noResume"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(WS.secondary)
            }
            Spacer()
            Button(tr("ws.action.retry")) { workspace.retry(runID) }
                .controlSize(.small)
                .help(tr("ws.action.retry.help"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(WS.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(WS.border, lineWidth: 1))
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func openDiff(_ run: WorkspaceRun, path: String) {
        let base = run.workingDirectory
        let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        let status = workspace.git[runID]?.status
        diffFile = status?.files.first { $0.path == relative }
            ?? GitFileChange(path: relative, oldPath: nil, kind: .modified, staged: false, unstaged: true)
    }

    // MARK: Input

    private func composer(_ run: WorkspaceRun) -> some View {
        let active = run.status.isActive
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(active ? tr("ws.composer.placeholderBusy") : tr("ws.composer.placeholder"))
                        .font(NookTheme.font(13))
                        .foregroundStyle(WS.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(NookTheme.font(13))
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(minHeight: 44, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        insertPaths(providers)
                        return true
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(WS.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(composerFocused ? NookTheme.iris.opacity(0.5) : WS.border, lineWidth: 1))

            HStack(spacing: 8) {
                Text(active ? tr("ws.composer.hintBusy") : tr("ws.composer.hint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(WS.tertiary)
                Spacer()
                if active {
                    // While it works: Codex over app-server and Claude Code take the message now (steer), others after the turn (queue).
                    let steers = workspace.canSteer(runID)
                    Button {
                        queueOrSteer()
                    } label: {
                        Label(steers ? tr("ws.action.steer") : tr("ws.action.queue"),
                              systemImage: steers ? "arrow.turn.down.right" : "text.append")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(steers ? tr("compose.steer") : tr("compose.queue"))
                    Button(role: .destructive) {
                        workspace.stop(runID)
                    } label: {
                        Label(tr("ws.action.stop"), systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .help(tr("ws.action.stop.help"))
                } else {
                    Button {
                        send()
                    } label: {
                        Label(run.status == .completed ? tr("ws.action.send") : tr("ws.action.continue"), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(tr("ws.action.send.help"))
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: 956)
        .frame(maxWidth: .infinity)
    }

    private func queueOrSteer() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        followTail = true
        if !workspace.steer(runID, text: text) { workspace.enqueue(runID, text: text) }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        followTail = true
        workspace.send(runID, text: text)
    }

    /// Dragging a file into the input field inserts its path; the agent reads it directly.
    private func insertPaths(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let path = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
                    draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + path + " "
                }
            }
        }
    }
}

// MARK: Timeline rows

struct EventRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void
    let openFile: (String) -> Void
    let decide: (WorkspaceManager.Decision) -> Void

    var body: some View {
        switch event.kind {
        case .user:
            ConversationMessage(fromUser: true, text: event.text)
                .padding(.top, 6)

        case .assistant:
            ConversationMessage(fromUser: false, text: event.text)
                .padding(.horizontal, 2)

        case .thinking:
            // The agent's reasoning in the chat itself: muted, live while it is written, the first
            // lines at once and the rest a click away.
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(.system(size: 10.5, weight: .medium)).foregroundStyle(NookTheme.iris)
                        Text(event.state == .running ? tr("ws.event.thinkingLive") : tr("ws.event.thinking"))
                            .font(NookTheme.font(11.5, .medium))
                            .foregroundStyle(WS.tertiary)
                        if event.text.count > 280 || event.text.split(separator: "\n").count > 4 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(WS.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Spacer(minLength: 0)
                    }
                    Text(event.text)
                        .font(NookTheme.font(12))
                        .foregroundStyle(WS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(expanded || event.state == .running ? nil : 4)
                        .opacity(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(NookTheme.iris.opacity(0.35)).frame(width: 2) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case .tool:
            ToolRow(event: event, expanded: expanded, toggle: toggle)

        case .fileChange:
            Button { openFile(event.detail ?? event.text) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(NookTheme.iris)
                    Text(event.text).font(NookTheme.mono(11.5)).foregroundStyle(WS.text)
                    Text(tr("ws.change." + (event.tool ?? "modified"))).font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundStyle(WS.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help(tr("ws.change.openDiff"))

        case .approval:
            ApprovalRow(event: event, expanded: expanded, toggle: toggle, decide: decide)

        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(NookTheme.coral)
                Text(event.text)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.coralSoft)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.coral.opacity(0.08)))

        case .system where event.tool == "handoff":
            // What the new agent was given: a summary you can read, not a hidden prompt.
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { _ in toggle() })) {
                Text(event.detail ?? "")
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(WS.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap").font(.system(size: 10))
                    Text(event.text).font(NookTheme.font(11.5)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(WSFormat.time(event.date)).font(NookTheme.font(10.5))
                }
                .foregroundStyle(WS.tertiary)
            }

        case .system:
            HStack(spacing: 6) {
                Image(systemName: event.tool == "launch" ? "terminal" : "info.circle").font(.system(size: 10))
                Text(event.text)
                    .font(event.tool == "launch" ? NookTheme.mono(11) : NookTheme.font(11.5))
                    .lineLimit(event.tool == "launch" ? 1 : 3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(WSFormat.time(event.date)).font(NookTheme.font(10.5))
            }
            .foregroundStyle(WS.tertiary)

        case .result:
            HStack(spacing: 8) {
                Rectangle().fill(WS.border).frame(height: 1)
                Image(systemName: event.state == .failed ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(event.state == .failed ? NookTheme.coral : NookTheme.mint)
                Text(event.text.isEmpty ? tr("ws.event.turnDone") : tr("ws.event.turnDoneWith", event.text))
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(WS.tertiary)
                    .fixedSize()
                Rectangle().fill(WS.border).frame(height: 1)
            }
            .padding(.vertical, 4)
        }
    }
}

/// A tool call: single-line summary, expandable to inspect input and output.
struct ToolRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    stateIcon
                        .frame(width: 14)
                    Image(systemName: Self.symbol(event.tool ?? ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(WS.tertiary)
                    Text(event.text)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(WS.text.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if event.state != .failed, let lines = EditLines.of(event) { EditLinesLabel(lines: lines) }
                    // A test run, build or linter says how it went.
                    if let check = Verification.check(event) { VerificationChips(checks: [check]) }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WS.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(event.text)
            .accessibilityHint(tr("ws.tool.expandHint"))

            // An MCP app is there to be used: shown whether or not the call is open.
            if let app = McpUI.resource(in: event.output) {
                McpAppBlock(resource: app, event: event).padding(.leading, 22)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // A task list (TodoWrite, update_plan) reads as the list, not as its JSON.
                    if let steps = SessionOutputs.taskList(tool: event.tool ?? "", input: AgentActivity.input(event.detail) ?? [:]),
                       !steps.isEmpty {
                        TaskListRows(steps: steps)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
                    } else if let detail = event.detail, !detail.isEmpty, detail != "{}" {
                        CodeBlock(title: tr("ws.tool.input"), text: detail)
                    }
                    if let output = event.output.map(McpUI.stripped), !output.isEmpty {
                        CodeBlock(title: tr("ws.tool.output"), text: output, failed: event.state == .failed)
                    } else if event.state == .running {
                        Text(tr("ws.tool.running")).font(NookTheme.font(11.5)).foregroundStyle(WS.tertiary)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch event.state {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NookTheme.coral)
        default: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NookTheme.mint.opacity(0.8))
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Bash", "shell", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch", "web_search": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct CodeBlock: View {
    let title: String
    let text: String
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(NookTheme.font(10.5, .semibold)).foregroundStyle(WS.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WS.tertiary)
                .help(tr("button.copy"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(failed ? NookTheme.coralSoft : Color(hex: 0xC9C7D2))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 260)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(WS.code))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WS.border, lineWidth: 1))
    }
}

/// An approval request in the timeline. If still pending, you can respond directly here.
struct ApprovalRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void
    let decide: (WorkspaceManager.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tr("ws.approval.asks", event.tool ?? "tool"))
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(WS.text)
                Text(event.text).font(NookTheme.mono(11.5)).foregroundStyle(WS.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(stateLabel).font(NookTheme.font(11.5, .semibold)).foregroundStyle(color)
            }
            if expanded, let detail = event.detail {
                CodeBlock(title: tr("ws.tool.input"), text: detail)
            }
        }
        .padding(10)
        // Calm: the state label carries the color, the row itself stays neutral.
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .onTapGesture { toggle() }
    }

    private var color: Color {
        switch event.state {
        case .pending: return NookTheme.amber
        case .allowed: return NookTheme.mint
        case .denied: return NookTheme.coral
        default: return WS.tertiary
        }
    }

    private var stateLabel: String {
        switch event.state {
        case .pending: return tr("ws.approval.pending")
        case .allowed: return tr("ws.approval.allowed")
        case .denied: return tr("ws.approval.denied")
        default: return tr("ws.approval.expired")
        }
    }
}

/// Above the input field: the oldest pending question awaiting your decision, with action buttons.
struct ApprovalBar: View {
    @EnvironmentObject private var app: AppModel
    let run: WorkspaceRun
    let pending: [PendingPermission]

    var body: some View {
        if let first = pending.first {
            let approval = ApprovalCenter.make(first, run: run)
            ApprovalView(approval: approval, more: pending.count - 1, maxHeight: 220) { app.approvals.decide(approval, $0) }
                .background {
                    // ⌘⇧↩ allows, ⌘⇧⌫ denies: kept from before.
                    Group {
                        Button("") { app.approvals.decide(approval, .allow) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                        Button("") { app.approvals.decide(approval, .deny) }.keyboardShortcut(.delete, modifiers: [.command, .shift])
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .frame(maxWidth: 956)
                .frame(maxWidth: .infinity)
        }
    }
}
