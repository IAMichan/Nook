import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The conversation: its rows, the bar under it, where you left it, and the turns that changed files.
extension AgentRunPanel {
    // MARK: Turn diffs

    /// The finished turns that changed files, with the files and lines git counted where it did.
    func turnDiffs(_ run: WorkspaceRun) -> [TurnDiff] {
        derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run)).turns
            .map { counted($0, run: run) }
            .filter { !$0.isEmpty }
    }

    /// The turn with what git counted for it, when it did.
    private func counted(_ turn: TurnDiff, run: WorkspaceRun) -> TurnDiff {
        countedLines[turn.id].map { turn.counted($0, relativeTo: run.workingDirectory) } ?? turn
    }

    /// Counts the finished turns with git, between the snapshots around them; a turn counted between both of its
    /// snapshots stays as it is, the others are counted again once their snapshot is made. The newest turn first: its
    /// card is the one in view when a session opens, and a long session has many turns before it (two git runs each).
    private func countTurns(_ turns: [TurnDiff], run: WorkspaceRun) async {
        guard !run.isRemote else { return }
        for turn in turns.reversed() where countedLines[turn.id]?.complete != true {
            guard let start = turn.start, let end = turn.end else { continue }
            if let lines = try? await workspace.turnLines(runID, paths: turn.files.map(\.path), start: start, end: end) {
                guard !Task.isCancelled else { return }
                countedLines[turn.id] = lines
                if lines.complete { CountedTurnLines.keep(lines, turn: turn.id, run: runID) }
            }
        }
    }

    // MARK: Timeline

    /// What sits under the timeline: an approval, a confirmation, the agent's question, or the composer.
    @ViewBuilder
    private func bottomBar(_ run: WorkspaceRun) -> some View {
        if let target = revertTarget {
            revertConfirmation(target)
        } else if let target = editTarget {
            editConfirmation(target)
        } else if confirmDelete {
            deleteConfirmation(run)
        } else if let pending = workspace.approvals[runID], let first = pending.first {
            // What the agent waits for takes the composer's place until answered, in every kind of session.
            approval(run, first, more: pending.count - 1).chatColumn().sessionComposerBounds()
        } else if let request = bridge.pending.first(where: { $0.caller.kind == .run(runID) }) {
            // A command or pull request the agent asks for through Nook's workspace.
            let approval = ApprovalCenter.make(request)
            ApprovalView(approval: approval, inline: true, onDecide: { app.approvals.decide(approval, $0) },
                         onSecret: { app.approvals.allow(approval, secret: $0) })
                .chatColumn()
                .sessionComposerBounds()
        } else if let question = workspace.questions[runID]?.first {
            // The agent asks something: its question takes the composer's place until answered (Stop stays).
            RunQuestionPanel(question: question, agent: run.provider.displayName, folder: run.workingDirectory,
                             onStop: { workspace.stop(runID) },
                             onDismiss: question.isRestored ? { workspace.dismissQuestion(runID, questionID: question.id) } : nil) { answers in
                workspace.answer(runID, questionID: question.id, answers: answers)
            }
            .id(question.id)
            .chatColumn()
            .sessionComposerBounds()
        } else {
            // Settled by the auto-settle rules: since when, and an Unsettle, at the end of the conversation.
            AutoSettledLine(finishKey: FinishedSessions.key(run: run)).chatColumn()
            // Redrawn on its own with every keystroke, without the conversation above it; and not for every streamed
            // token, which redraws the conversation (`timelines`) but changes nothing the composer shows.
            RunComposerHost(state: composerState, workspace: workspace, app: app, pullRequests: pullRequestSync,
                            key: RunComposerHost.Key(run: run, subagents: derived.subagents, commands: derived.commands, skills: skills,
                                                     repository: repository, shownSubagents: outputsLink.subagentsShown,
                                                     olderBranchesShown: showsOlderBranches)) {
                composer(run)
            }
            .equatable()
            .chatColumn()
        }
    }

    func timeline(_ run: WorkspaceRun) -> some View {
        let memo = derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run))
        let events = memo.events
        let blocks = memo.blocks
        let cards = memo.cards
        let found = finding ? memo.search(findQuery) : .idle
        let current = findIndex.flatMap { found.matches.indices.contains($0) ? found.matches[$0].eventID : nil } ?? flashed
        // While the agent works, as in an agent's own transcript: "Working for …" right under your message, and the step
        // that runs now only in the live line at the end, not also in the list above it.
        let active = run.status.isActive
        // A new worktree still being set up: its checklist is the live state, in place of "Working for …".
        let setup = workspace.visibleSetup(run)
        let workingUnder = active && setup == nil ? events.last(where: { $0.kind == .user })?.id : nil
        // A compaction that runs is the live line too ("Compacting the conversation…"); once done it is a row of its own.
        let liveStep = active ? events.last.flatMap {
            ($0.kind == .tool && $0.state == .running) || CompactionProgress.isRunning($0) ? $0.id : nil
        } : nil
        // Only the latest turns of a long session are drawn, from the turn the window starts at.
        let start = HistoryWindow.clamped(historyStart ?? HistoryWindow.initialStart(rowsPerTurn: memo.rowsPerTurn),
                                          turnCount: memo.rowsPerTurn.count)
        let firstRow = min(blocks.count, HistoryWindow.firstRow(rowsPerTurn: memo.rowsPerTurn, start: start))
        let shownBlocks = firstRow > 0 ? Array(blocks[firstRow...]) : blocks
        let context = TimelineRowContext(structure: memo.revision, status: run.status,
                                         directory: run.isRemote ? nil : run.workingDirectory, highlighted: current,
                                         openEvents: expanded, shownFile: sideLink.shownFile, counted: countedLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    if events.isEmpty {
                        // Still being read from disk is not an empty conversation.
                        if workspace.isTimelineLoaded(runID) {
                            ListEmptyNote(tr("agents.run.empty"))
                        } else {
                            PatientSpinner().frame(height: 160)
                        }
                    }
                    if firstRow > 0 {
                        TimelineEarlierRow {
                            // What you looked at stays where it is: the earlier turns go above it.
                            let anchor = shownBlocks.first?.id
                            scroll.userScrolled()
                            historyStart = HistoryWindow.earlier(from: start)
                            if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
                        }
                    }
                    // Finished turns fold to "Worked for …", tool calls in a row to one sentence.
                    ForEach(shownBlocks) { block in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                            if block.id == newSince { TimelineNewDivider() }
                            TimelineBlockView(block: block, expanded: openBlocks, context: context.scoped(to: block), toggle: toggleBlock) { event in
                                if event.id == liveStep { return AnyView(EmptyView()) }
                                return AnyView(
                                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                                        // What the turn changed (its card): under the final answer, inside it, as in an
                                        // agent's own transcript; a file or Open diff opens the diff beside it.
                                        // A turn that changed files only by a command still gets one, once git counted it.
                                        let card = cards[event.id].map { counted($0, run: run) }.flatMap { turn in
                                            turn.isEmpty ? nil : AnyView(TurnChangesCard(turn: turn, directory: run.workingDirectory) { file in
                                                sideLink.openDiff(TurnDiffSelection(turn: turn.id, file: file))
                                            })
                                        }
                                        let inReply = event.kind == .assistant && memo.finalAnswers.contains(event.id)
                                        eventRow(event, final: memo.finalAnswers.contains(event.id),
                                                 extras: inReply ? card : nil, answerable: memo.answerable == event.id)
                                        if !inReply, let card { card }
                                        if event.id == workingUnder { TranscriptWorkingLine(since: run.turnStartedAt) }
                                    }
                                    .padding(.vertical, current == event.id ? 4 : 0)
                                    .roundedBackground(NookTheme.iris.opacity(current == event.id ? 0.16 : 0), radius: NookTheme.Radius.control)
                                )
                            }
                            // While the agent writes, only the block it writes into is drawn again.
                            .equatable()
                        }
                        .pinProbe(block.id.uuidString, room: pinRoom)
                        .countsAsDrawnRow(drawnRows, id: block.id)
                        .id(block.id)
                    }
                    if let setup {
                        WorktreeSetupChecklist(progress: setup, active: active) { workspace.stop(runID) }
                    } else if active {
                        // The agent's task list, live, right above what it does now: the same live line as in an agent's
                        // own transcript.
                        let turn = TimelinePresentation.lastTurn(events)
                        TranscriptLiveLine(activity: AgentActivity.current(turn),
                                           tasks: TaskChecklist.showsInline(run.tasks, active: true) ? run.tasks : nil,
                                           waiting: run.status == .waitingApproval || workspace.questions[runID] != nil,
                                           asking: workspace.questions[runID] != nil,
                                           openConsole: CommandConsole.running(turn).map { command -> () -> Void in
                                               { sideLink.toggleConsole(command.id) }
                                           },
                                           help: TimelinePresentation.live(turn).tool)
                    }
                    // A usage limit ended the turn: its own card, with the reset and how to go on.
                    if UsageLimitCard.shows(run) {
                        UsageLimitCard(run: run)
                    } else if run.status == .failed || run.status == .stopped {
                        recovery(run, events: events, blocks: blocks, proxy: proxy)
                    }
                    TurnPinSpacer(room: pinRoom)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                // The conversation's own space, so the room under a message you sent is measured between rows.
                .coordinateSpace(name: TurnPinRoom.space)
                .chatColumn()
            }
            // The files and lines of every finished turn from git (`countTurns`): again when a turn ends or a snapshot is made.
            .task(id: "\(runID)|\(memo.turns.count)|\(memo.turns.last?.files.count ?? 0)|\(run.checkpoints?.count ?? 0)") {
                await countTurns(memo.turns, run: run)
            }
            // Following the end while the answer streams: the scroll view keeps its bottom in place as the content grows,
            // instead of a `scrollTo` (a layout down to the end and a scroll) for every streamed update.
            // A session opens at its end, also when its timeline arrives after the first frame: never at its first messages.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor((run.status.isActive || landsOnLoad) && scroll.shouldFollowEnd ? .bottom : nil, for: .sizeChanges)
            .scrollIndicators(.never)
            // Scrolling away from the end stops the following until you come back.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, nowAtEnd in
                atEnd = nowAtEnd
                if nowAtEnd { scroll.reachedEnd() }
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase.value = phase
                if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
            }
            .onScrollGeometryChange(for: ScrollFrame.self) { geometry in
                ScrollFrame(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                            container: geometry.containerSize.height,
                            insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
            } action: { old, frame in
                pinRoom.update(frame)
                keepEnd(old, frame, proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, now in
                overflows = now
            }
            // Never a black conversation: at rest with none of its blocks in view, back to the one you last saw (or the end).
            .recoversBlankRows(UUID.self, rows: shownBlocks.count, drawn: drawnRows, idle: { scrollPhase.value == .idle }) { last, attempt in
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if let last, !scroll.shouldFollowEnd, !atEnd {
                        proxy.scrollTo(last, anchor: .top)
                    } else if attempt == 0 {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        // Still blank at the end: let go of the room held under a sent message, land on the last block
                        // itself (a row the lazy stack must draw), and only then on the very end.
                        scroll.jumpedToEnd()
                        pinRoom.release()
                        if let lastBlock = shownBlocks.last?.id { proxy.scrollTo(lastBlock, anchor: .bottom) }
                        DispatchQueue.main.async { withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                }
            }
            // Below the scroll modifiers: the composer has scroll views of its own, and a scroll modifier over both picks one.
            // A mark per message of yours on the leading edge, as in an agent's own transcript: a click jumps to it.
            .overlay(alignment: .leading) {
                if overflows, !finding, !memo.marks.isEmpty {
                    TranscriptPromptRail(marks: memo.marks) { mark in
                        scroll.userScrolled()
                        guard let id = UUID(uuidString: mark.row) else { return }
                        if revealTurn(of: id) {
                            DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .top) } }
                        } else {
                            withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    .padding(.vertical, NookTheme.Spacing.md)
                    .transition(.opacity)
                }
            }
            // The conversation scrolls on behind the composer; the pill back to the end rides on top of it.
            .composerInset {
                VStack(spacing: NookTheme.Spacing.lg) { bottomBar(run) }
                    .toEndPill(scroll.showsToEndPill(atEnd: atEnd) && !finding) {
                        scroll.jumpedToEnd()
                        withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
            }
            .padding(.top, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                if finding {
                    TimelineFindBar(query: $findQuery, result: found, current: findIndex,
                                    previous: { stepFind(found, blocks: blocks, proxy: proxy, forward: false) },
                                    next: { stepFind(found, blocks: blocks, proxy: proxy, forward: true) },
                                    close: closeFind)
                        .padding(.horizontal, NookTheme.Spacing.xs)
                        .padding(.top, NookTheme.Spacing.xs)
                }
            }
            .keyCommand("chat.find") { openFind() }
            // From a background command's row in the bar: to its call in the conversation, lit up for a moment.
            .onChange(of: conversationFocus) { _, id in
                guard let id else { return }
                conversationFocus = nil
                scroll.userScrolled()
                revealTurn(of: id)
                for key in TimelineContainers.keys(blocks)[id] ?? [] { openBlocks.insert(key) }
                flashed = id
                DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if flashed == id { withAnimation(NookTheme.reveal) { flashed = nil } }
                }
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = nil
                let fresh = TimelineSearch.search(events, query: findQuery)
                if let first = fresh.next(after: nil) { findIndex = first; reveal(fresh, at: first, blocks: blocks, proxy: proxy) }
            }
            // Always the end, with what is new since your last visit under its line;
            // after the handlers that follow the end on a new session, hence on the next turn of the run loop.
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                DispatchQueue.main.async { land(proxy) }
            }
            .onChange(of: runID) { _, _ in
                historyStart = nil
                DispatchQueue.main.async { land(proxy) }
            }
            .onChange(of: workspace.isTimelineLoaded(runID)) { _, loaded in
                if loaded, landsOnLoad { DispatchQueue.main.async { land(proxy) } }
            }
            // Opened from a search hit: find what it matched.
            .onReceive(app.viewModel.$sessionFind) { wanted in
                guard let wanted, !wanted.isEmpty else { return }
                app.viewModel.sessionFind = nil
                openFind()
                findQuery = wanted
            }
            .onChange(of: events.count) { _, _ in
                // The agent went on to its tools and the reply filled the view: follow its work from here.
                scroll.contentGrew(toolActivityStarted: events.last?.kind == .tool, overflows: pinRoom.height == 0)
                // Not animated, and only when the view is off its end: at the end `defaultScrollAnchor` and `keepEnd`
                // already hold it there, and an animated scroll on every new event fought them.
                guard scroll.shouldFollowEnd, !atEnd else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You sent something: it is the newest thing and shows again, also when you had scrolled up. Not while the
            // message you sent before still stands near the top: going to the end gave up its room, so the conversation
            // dropped and then rose again once the new message came in and took that room over (`pinSent`).
            .onChange(of: sentCount) { _, _ in if scroll.goesToEndOnSend { settleAtEnd(proxy) } }
            .onChange(of: scroll.anchorMessageID) { _, id in if id == nil { pinRoom.release() } }
            .onChange(of: events.last(where: { $0.kind == .user })?.id) { old, new in
                // A message that came in at the end stands near the top with the reply under it. The timeline loading
                // or going back to an earlier message only lands at the end.
                if old != nil, let new, !finding, events.suffix(2).contains(where: { $0.id == new }), let row = memo.marks.last?.row,
                   let id = UUID(uuidString: row) {
                    pinSent(id, proxy)
                } else {
                    settleAtEnd(proxy)
                }
            }
        }
        // VoiceOver hears the step, the finished replies and what waits on you, as for an agent's own transcript.
        .announcesAgentProgress(key: "run:" + runID.uuidString, author: run.provider.displayName, snapshot: announcement(run))
    }

    /// What a screen reader is told about the session (`AgentAnnouncer`), from the whole timeline rather than what the
    /// timeline detail shows; only built while one listens.
    private func announcement(_ run: WorkspaceRun) -> AgentAnnouncementSnapshot {
        guard AgentAnnouncer.listening else { return .idle }
        let events = workspace.timeline(runID)
        let status: AgentAnnouncementSnapshot.Status
        if workspace.questions[runID] != nil {
            status = .question
        } else if run.status == .waitingApproval {
            status = .approval
        } else {
            status = run.status.isActive ? .working : .idle
        }
        let step = status == .working ? AgentAnnouncer.spokenStep(AgentActivity.current(TimelinePresentation.lastTurn(events))) : nil
        return AgentAnnouncements.snapshot(events, status: status, step: step)
    }

    /// Brings the message you sent near the top of the view, with room under it for the reply, until you scroll away.
    /// The room follows once the message is laid out; the view only goes to its end, again while the layout settles.
    private func pinSent(_ id: UUID, _ proxy: ScrollViewProxy) {
        pinRoom.hold(row: id.uuidString)
        scroll.sent(messageID: id)
        for delay in [0.0, 0.1, 0.25, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard scroll.anchorMessageID == id else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Scrolls to the end now and again while the layout settles: the lazy rows only learn their real height once
    /// laid out, so a single scroll from far up lands short of the end. Stops when you scroll away in the meantime.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        scroll.jumpedToEnd()
        proxy.scrollTo("bottom", anchor: .bottom)
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Where you left it

    static func visitKey(_ id: UUID) -> String { "run:" + id.uuidString }

    /// The timeline's blocks in order with their times, as `timeline(_:)` shows them (already made as it opens).
    private var visitRows: [TimelineLanding.Row] {
        guard let run = workspace.run(runID) else { return [] }
        return derived.update(workspace.timeline(runID), run: run, detail: timelineDetail(run)).blocks.map { ($0.id.uuidString, $0.visitDate) }
    }

    /// The very end of the session, with what came in since your last visit under its line.
    private func land(_ proxy: ScrollViewProxy) {
        landsOnLoad = !workspace.isTimelineLoaded(runID)
        guard !landsOnLoad else { return }
        // The window opens on the latest turns and stays there as new ones come in.
        if historyStart == nil, !derived.rowsPerTurn.isEmpty {
            historyStart = HistoryWindow.initialStart(rowsPerTurn: derived.rowsPerTurn)
        }
        newSince = visit.flatMap { TimelineLanding.firstNew(visitRows, since: $0.lastViewedAt) }.flatMap(UUID.init(uuidString:))
        settleAtEnd(proxy)
    }

    /// Keeps the run at its end while it is there, as `TranscriptConversation.keepEnd` does: the lazy blocks below
    /// measure taller after the first scroll and the composer under it grows (a card, a draft), which let the run slip
    /// up from its end as it opens. A landing on what is new that fits on screen ends at the end too, and follows from
    /// there. Only moving while the sizes stay the same is you scrolling away.
    private func keepEnd(_ old: ScrollFrame, _ new: ScrollFrame, _ proxy: ScrollViewProxy) {
        let resized = new.content != old.content || new.container != old.container || new.insetBottom != old.insetBottom
        guard resized, !finding, scroll.mode != .anchoringNewTurn else { return }
        let wasAtEnd = old.maxOffset - old.offset <= 1
        guard scroll.shouldFollowEnd || wasAtEnd, scrollPhase.value == .idle, new.maxOffset - new.offset > 0.5 else { return }
        scroll.reachedEnd()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Where you leave a session: what you opened and when.
    func rememberVisit(_ id: UUID) {
        // Left before its timeline was read: the earlier visit still says where you were.
        guard workspace.run(id) != nil, workspace.isTimelineLoaded(id) else { return }
        TimelineVisitStore.shared.remember(sessionID: Self.visitKey(id), visit: TimelineVisit(open: openBlocks, lastViewedAt: Date()))
    }

    @ViewBuilder
    private func eventRow(_ event: RunEvent, final: Bool = true, extras: AnyView? = nil, answerable: Bool = false) -> some View {
        if event.kind == .assistant, event.tool == "plan" {
            let idle = !(workspace.run(runID)?.status.isActive ?? false)
            // Only the latest plan, and only until you sent something after it.
            let timeline = workspace.timeline(runID)
            let latest = timeline.last { $0.kind == .assistant && $0.tool == "plan" }?.id == event.id
            let answered = timeline.contains { $0.kind == .user && $0.date > event.date }
            PlanCard(text: event.text, canAct: idle && latest && !answered, implementInNew: {
                // The summary of a fork cuts long messages, so the whole plan goes into the first message.
                guard let id = workspace.fork(runID) else { return }
                workspace.configure(id, mode: .agent)
                workspace.send(id, text: tr("ws.plan.implementPrompt") + "\n\n" + event.text)
                app.viewModel.selectedAgentID = "run:" + id.uuidString
            }, implement: {
                workspace.configure(runID, mode: .agent)
                workspace.send(runID, text: tr("ws.plan.implementPrompt"))
            }, implementSelected: { kept in
                // The agent carries out the plan as you edited it: the kept steps go along with the request.
                workspace.configure(runID, mode: .agent)
                workspace.send(runID, text: tr("ws.plan.implementPrompt") + "\n\n" + kept)
            })
        } else if event.kind == .user {
            eventView(event, onEdit: workspace.canEditFromHere(runID, before: event.date) ? {
                editError = nil
                revertTarget = nil
                editTarget = event
            } : nil)
                .contextMenu {
                    // "Edit from here": the worktree's files go back to how they were before this message.
                    Button(tr("ws.revert.menu")) {
                        revertError = nil
                        revertTarget = event
                    }
                    .disabled(!workspace.canRevert(runID, before: event.date))
                    // A fork that starts before this message, to try another way.
                    Button(tr("agents.fork.here")) { forkBefore(event) }
                        .disabled(!workspace.canTransfer(runID))
                }
        } else if event.kind == .assistant {
            eventView(event, final: final, extras: extras, answerable: answerable)
                .contextMenu {
                    // "Fork from this response".
                    Button(tr("agents.fork.fromResponse")) { forkThrough(event) }
                        .disabled(!workspace.canTransfer(runID))
                    // Quote the agent's words in your next message.
                    Button(tr("ws.review.quote")) {
                        draft = ReviewComments.quote(event.text, into: draft)
                        focused = true
                    }
                }
        } else {
            eventView(event)
        }
    }

    private func forkBefore(_ event: RunEvent) {
        guard let index = workspace.timeline(runID).firstIndex(where: { $0.id == event.id }),
              let id = workspace.fork(runID, keepingEvents: index) else { return }
        app.viewModel.selectedAgentID = "run:" + id.uuidString
    }

    private func forkThrough(_ event: RunEvent) {
        guard let index = workspace.timeline(runID).firstIndex(where: { $0.id == event.id }),
              let id = workspace.fork(runID, keepingEvents: index + 1) else { return }
        app.viewModel.selectedAgentID = "run:" + id.uuidString
    }

    private func eventView(_ event: RunEvent, final: Bool = true, extras: AnyView? = nil, answerable: Bool = false,
                           onEdit: (() -> Void)? = nil) -> some View {
        EventRow(
            event: event,
            final: final,
            extras: extras,
            // A question at the end of the newest answer, answered with a click, as in an agent's own transcript.
            onChoose: answerable ? { workspace.send(runID, text: $0) } : nil,
            expanded: expanded.contains(event.id),
            toggle: { toggle(event.id) },
            openFile: { path in
                // In the session's Changes tab; a session on another machine has no git here, so its own review.
                if headerAccessory != nil, let run = workspace.run(runID), !run.isRemote {
                    sideLink.openDiff(TurnDiffSelection(turn: TurnDiffSelection.branch,
                                                        file: TurnDiff.relative(path, to: run.workingDirectory)))
                } else {
                    app.viewModel.open(.changes(runID, file: path))
                }
            },
            decide: { decision in
                if let request = event.callID { app.approvals.decide(run: runID, requestID: request, ApprovalDecision(decision)) }
            },
            showFile: sideLink.showFile,
            // A session on another machine has its files there, not on this Mac.
            directory: workspace.run(runID).flatMap { $0.isRemote ? nil : $0.workingDirectory },
            shownFile: sideLink.shownFile,
            onEdit: onEdit,
            // In the bar while it is there (this turn's commands, and any still running); else in the side panel.
            showBackground: {
                if derived.commands.contains(where: { $0.id == event.id }) { barFocus = event.id } else { outputsLink.showSubagents?() }
            },
            onSuggestion: { app.chooseSuggestion($0, event: event, in: runID) }
        )
        // Undone by going back to before an earlier message: the agent no longer remembers it.
        .opacity(event.rolledBack == true ? 0.45 : 1)
    }

    private func toggleBlock(_ key: String) {
        withAnimation(NookTheme.reveal) {
            if openBlocks.contains(key) { openBlocks.remove(key) } else { openBlocks.insert(key) }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// The turns git counted completely (between the snapshots on both sides), per session, kept across visits: those
/// snapshots never change, so opening a session again shows its cards whole at once instead of waiting for git to
/// count every turn again. Only the most recently counted sessions are kept.
@MainActor
enum CountedTurnLines {
    private static var byRun: [UUID: [String: TurnLines]] = [:]
    private static var order: [UUID] = []
    private static let limit = 16

    static func forRun(_ id: UUID) -> [String: TurnLines] { byRun[id] ?? [:] }

    static func keep(_ lines: TurnLines, turn: String, run id: UUID) {
        guard lines.complete else { return }
        byRun[id, default: [:]][turn] = lines
        if order.last != id {
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > limit { byRun[order.removeFirst()] = nil }
        }
    }
}
