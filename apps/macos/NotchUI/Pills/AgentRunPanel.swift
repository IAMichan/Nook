import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// A session that Nook runs itself, inside the Agents tab: the whole conversation, approvals, stop, follow-up
/// messages, and the settings for the next turn (mode, permissions, model). Everything you would otherwise do in a
/// terminal happens here.
struct AgentRunPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    /// The timeline changes as the agent streams (`WorkspaceManager.timelines`); only this panel redraws for it.
    @ObservedObject var timelines: TimelineChanges
    let runID: UUID
    /// The terminal and browser icons, next to the branch button.
    var headerAccessory: AnyView? = nil
    /// What you are writing: held, not observed, so a keystroke redraws the composer (`Observing` around it) and not the
    /// conversation above it. Read and written through `draft`, `images`, `quotes` and `editingQueued` below.
    @State var composerState = RunComposerState()
    @State var expanded: Set<UUID> = []
    /// Opened groups and folded turns ("group:<id>", "fold:<id>").
    @State var openBlocks: Set<String> = []
    /// "Back to before this message": the message, and why it could not, if it could not.
    @State var revertTarget: RunEvent?
    @State var revertError: String?
    /// "Edit from here": the message to go back to before and write again, why it could not, and whether it runs.
    @State var editTarget: RunEvent?
    @State var editError: String?
    @State var editWorking = false
    /// Bumped when the session's machine was unlocked with its password, so the field goes away.
    @State var unlockedAt: Date?
    @State var reverting = false
    @State var confirmDelete = false
    @State var renaming = false
    @State var titleDraft = ""
    @FocusState var titleFocused: Bool
    /// The older branches of a session that worked on many, shown in the tray above the composer.
    @State var showsOlderBranches = false
    /// The `#` list needs the repository ("owner/repo") of the session's folder.
    @State var repository: String?
    /// The agent's skills for `$`, read from its skill folders.
    @State var skills: [Skill] = []
    @State var scroll = ScrollModel()
    /// Quote and Ask about this, for every answer's text view: the same two closures on every redraw, so a streamed token
    /// does not hand each answer a new environment.
    @State private var selectionActions = StableSelectionActions()
    /// Held, not observed: its height changes as streamed rows are laid out, and only `TurnPinSpacer` draws it.
    @State var pinRoom = TurnPinRoom()
    @State var atEnd = true
    /// Read only by the handlers: as state, each start and stop of a scroll drew every block of the run again.
    @State var scrollPhase = Unobserved(ScrollPhase.idle)
    /// Rows the lazy stack draws now, for `recoversBlankRows`; nothing draws from it.
    @State var drawnRows = DrawnRows()
    /// Bumped to make the conversation's scroll view again when its lazy stack is stuck drawing nothing (`recoversBlankRows`).
    @State var timelineBuild = 0
    /// Counts the messages you sent from the composer (also those that steer or wait in line): each brings the
    /// conversation down to its end, wherever you had scrolled.
    @State var sentCount = 0
    /// The timeline is taller than the view: only then the rail with your messages shows.
    @State var overflows = false
    /// Where you left this session's conversation last time (TimelineVisitStore), read as it opens.
    @State var visit: TimelineVisit?
    /// The block the "New since your last visit" line sits above; decided as the session opens.
    @State var newSince: UUID?
    /// The session opened before its timeline was read from disk (`requestTimeline`): it lands once that is here.
    @State var landsOnLoad = false
    /// The first turn drawn (`HistoryWindow`): a long session opens with its latest turns, "Show earlier messages" and
    /// any jump to an earlier event widen it. Nil until the session has landed.
    @State var historyStart: Int?
    @State var finding = false
    @State var findQuery = ""
    @State var findIndex: Int?
    /// A background command is one thing in two places: its call in the conversation and its row in the bar above the
    /// composer. `barFocus` opens its row in the bar (from the conversation), `conversationFocus` scrolls to its call (from
    /// the bar), and `flashed` lights the call up for a moment once there.
    @State var barFocus: UUID?
    @State var conversationFocus: UUID?
    @State var flashed: UUID?
    /// Held, not observed: only its suggestion list watches it (`ComposerSuggestionSlot`), so a key that changes the
    /// list does not redraw this whole panel.
    @State var composerModel = ComposerModel()
    @FocusState var focused: Bool
    @ObservedObject var finishedMarks = FinishedSessions.shared
    @ObservedObject var bridge = WorkspaceBridge.shared
    /// For how much of the work the timeline shows (`TimelineDetail`), when the session follows Settings.
    @ObservedObject var workspaceSettings = WorkspaceSettings.shared
    /// The pull requests of the session's branches, for the tray above the box.
    @ObservedObject var pullRequestSync = PullRequestSync.shared
    /// The outputs tab of the side panel around this session (`SessionWorkbench`), which shows what the agent produced.
    @Environment(\.sessionOutputs) var outputsLink
    @Environment(\.sessionSide) var sideLink
    @Environment(\.sessionHeaderInset) var headerInset
    /// The outputs (by signature) you have seen, for the dot on the outputs tab; nil until the session shows.
    @State var seenOutputs: Set<String>?
    /// The subagents (`Subagents.signature`) you have seen, for the dot on the Subagents tab; nil until the session shows.
    @State private var seenSubagents: String?
    /// The lines git counted per turn (by the turn's id), in place of those read from the agent's edits.
    @State var countedLines: [String: TurnLines] = [:]
    /// The timeline's blocks, turns and outputs, made again only when the events change (not on every keystroke); the
    /// session's own from its last visit (`RunTimelineDerived.forRun`), so opening it again lays nothing out.
    @State var derived: RunTimelineDerived
    /// Git, the agent's connection and the repository, started once the session stayed open a moment: passing through
    /// sessions with the arrow keys starts no process for each.
    @State private var settleTask: Task<Void, Never>?

    init(workspace: WorkspaceManager, timelines: TimelineChanges, runID: UUID, headerAccessory: AnyView? = nil) {
        _workspace = ObservedObject(wrappedValue: workspace)
        _timelines = ObservedObject(wrappedValue: timelines)
        self.runID = runID
        self.headerAccessory = headerAccessory
        _derived = State(initialValue: .forRun(runID))
        _countedLines = State(initialValue: CountedTurnLines.forRun(runID))
    }

    var draft: String {
        get { composerState.draft }
        nonmutating set { composerState.draft = newValue }
    }
    var images: [ImageAttachment] {
        get { composerState.images }
        nonmutating set { composerState.images = newValue }
    }
    var quotes: ComposerQuotes {
        get { composerState.quotes }
        nonmutating set { composerState.quotes = newValue }
    }
    var editingQueued: UUID? {
        get { composerState.editingQueued }
        nonmutating set { composerState.editingQueued = newValue }
    }

    var body: some View {
        if let run = workspace.run(runID) {
            // While an evicted timeline is read from disk again, what it showed last time stays (and its caches with it).
            let _ = workspace.isTimelineLoaded(runID) || !derived.hasContent
                ? derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run)) : derived
            let outputs = derived.outputs
            let signatures = derived.outputSignatures
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                header(run)
                // After Nook restarted, a session on a machine with a password waits for it before the next turn.
                if let machine = lockedMachine(run) {
                    RemotePasswordField(machine: machine) { _ in unlockedAt = Date() }
                }
                timeline(run)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A file the agent links to (`src/app.swift:12`) opens in your editor at that line.
            .environment(\.fileLinkBase, run.isRemote ? nil : run.workingDirectory)
            // Selected words of an answer go with the reply as a chip above the composer (right-click › Quote in your
            // message, or Ask about this, which also puts the keyboard in the box; the same with ⇧⌘L and ⌘L).
            .environment(\.quoteSelection, selectionActions.bind { addQuote($0, ask: $1) }.quote)
            .environment(\.askAboutSelection, selectionActions.ask)
            // "Reply" under an answer: it goes as a quote to the top of the composer, with the keyboard there.
            .environment(\.replyToAnswer, { answer in replyToAnswer(answer) })
            .keyCommands(["selection.quote": { quoteSelected(ask: false) }, "selection.ask": { quoteSelected(ask: true) }])
            // What the agent produced goes to the outputs tab of the side panel, with a dot while something is new.
            .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(
                outputs: outputs,
                subagents: derived.allSubagents,
                commands: derived.allCommands,
                subagentsFresh: !outputsLink.subagentsShown && seenSubagents.map { $0 != derived.subagentsSignature } == true,
                turns: turnDiffs(run),
                pullRequest: derived.createdPullRequest,
                fresh: !outputsLink.shown && seenOutputs.map { seen in signatures.contains { !seen.contains($0) } } == true))
            // What the outputs tab shows is seen.
            .onChange(of: outputsLink.shown) { _, isShown in
                if isShown { seenOutputs = Set(signatures) }
            }
            // What the Subagents tab shows is seen, also while it streams in.
            .onChange(of: outputsLink.subagentsShown) { _, isShown in
                if isShown { seenSubagents = derived.subagentsSignature }
            }
            // A subagent the agent starts while it works opens the tab, as a new plan opens the outputs tab; what a
            // session that just opened already had is not news.
            .onChange(of: derived.allSubagents.count) { before, after in
                if run.status.isActive, seenSubagents != nil, after > before, outputsLink.openSubagents() {
                    seenSubagents = derived.subagentsSignature
                }
            }
            .onChange(of: derived.subagentsSignature) { _, next in
                if outputsLink.subagentsShown || seenSubagents == nil { seenSubagents = next }
            }
            .onChange(of: signatures) { _, _ in
                noticeOutputs(outputs, working: run.status.isActive, turnStart: run.turnStartedAt)
            }
            .onAppear {
                workspace.requestTimeline(runID)
                landsOnLoad = !workspace.isTimelineLoaded(runID)
                visit = TimelineVisitStore.shared.visit(for: Self.visitKey(runID))
                if let visit { openBlocks = visit.open }
                focused = true
                // What was there before you opened the session is not news.
                seenOutputs = Set(signatures)
                seenSubagents = derived.subagentsSignature
                loadComposerState(run)
                settleTask?.cancel()
                let (id, hasRepository) = (runID, run.repoRoot != nil)
                settleTask = Task { @MainActor in
                    try? await Task.sleep(for: NookTheme.tabSettle)
                    guard !Task.isCancelled else { return }
                    // Quiet: the branch shown so far stays up while it is read again, and only a change redraws (a
                    // spinner first would redraw every view that follows the workspace twice as the session opens).
                    if hasRepository { workspace.refreshGit(id, quiet: true) }
                    // The agent's connection opens now, so your first message goes straight in.
                    workspace.prewarm(id)
                    let found = await workspace.githubRepository(id)
                    guard !Task.isCancelled else { return }
                    repository = found
                }
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
                rememberVisit(runID)
            }
            .onAppear { workspace.timelineShown(runID) }
            .onDisappear { workspace.timelineHidden(runID) }
            // What the side panel hands to this session lands in the draft, to read before sending; also when it
            // arrived while this composer was not on screen.
            .onReceive(ComposerInbox.shared.$delivery.compactMap { $0 }) { _ in takeFromSidePanel() }
            .onAppear { takeFromSidePanel() }
            // F2 or the command palette's Rename: the name field in the header, with the keyboard in it.
            .onReceive(SessionRenameRequest.shared.$pending.removeDuplicates()) { id in
                guard id == runID, let title = workspace.run(runID)?.title else { return }
                SessionRenameRequest.shared.take(runID)
                titleDraft = title
                renaming = true
            }
            .onChange(of: runID) { previous, current in
                workspace.timelineHidden(previous)
                workspace.timelineShown(current)
                rememberVisit(previous)
                workspace.requestTimeline(runID)
                if workspace.run(runID)?.repoRoot != nil { workspace.refreshGit(runID, quiet: true) }
                workspace.prewarm(runID)
                // A queued message you were editing in the session you left goes back to its queue as it was, and the
                // draft that waited behind it becomes that session's draft again.
                if composerState.editingQueued != nil {
                    let restored = workspace.endEditQueued(previous, save: false)
                    ComposerDraftStore.shared.save(sessionID: previous.uuidString, text: restored ?? "")
                    composerState.editingQueued = nil
                }
                // The draft of the session you left stays saved, and the one of this session comes back.
                composerState.show(session: runID.uuidString)
                if let fresh = workspace.run(runID) { loadComposerState(fresh) }
                renaming = false
                confirmDelete = false
                // Nothing of the previous session carries over: above all not a pending "restore files".
                revertTarget = nil
                revertError = nil
                reverting = false
                editTarget = nil
                editError = nil
                editWorking = false
                openBlocks = []
                expanded = []
                // What git counted on an earlier visit comes back at once: only turns not counted yet wait for git.
                countedLines = CountedTurnLines.forRun(runID)
                quotes.removeAll()
                seenOutputs = nil
                seenSubagents = nil
                // Folds you had open in this session last time come back (the timeline lands on its own, below).
                visit = TimelineVisitStore.shared.visit(for: Self.visitKey(runID))
                openBlocks = visit?.open ?? []
            }
        } else {
            Text(tr("agents.run.gone"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
