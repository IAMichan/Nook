import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The conversation: its rows, the bar under it, where you left it, and the turns that changed files.
extension AgentRunPanel {
    /// Keeps `derived` up to date for `run` using O(1) timeline version checks, preserving cached content while an
    /// evicted timeline reloads from disk.
    @discardableResult
    func currentDerived(_ run: WorkspaceRun) -> RunTimelineDerived {
        guard workspace.isTimelineLoaded(runID) || !derived.hasContent else { return derived }
        return derived.update(
            workspace.timeline(runID),
            version: workspace.timelineVersion(runID),
            structureVersion: workspace.timelineStructureVersion(runID),
            run: run,
            detail: timelineDetail(run)
        )
    }

    // MARK: Turn diffs

    /// The finished turns that changed files, with the files and lines git counted where it did.
    func turnDiffs(_ run: WorkspaceRun) -> [TurnDiff] {
        currentDerived(run).countedTurns(countedLines, directory: run.workingDirectory).all
    }

    /// The turn with what git counted for it, when it did.
    private func counted(_ turn: TurnDiff, run: WorkspaceRun) -> TurnDiff {
        currentDerived(run).countedTurns(countedLines, directory: run.workingDirectory).byID[turn.id] ?? turn
    }

    /// Counts the finished turns with git, between the snapshots around them; a turn counted between both of its
    /// snapshots stays as it is, the others are counted again once their snapshot is made. The newest turn first: its
    /// card is the one in view when a session opens, and a long session has many turns before it (two git runs each).
    ///
    /// Each change to `countedLines` draws the whole session again, so the counts come in together: the newest turn's
    /// at once, the rest in batches of `countBatch`, and a count that is what the card already shows changes nothing.
    /// Without that, opening a session whose turns had no snapshot after them yet redrew it once per turn, for seconds
    /// after the switch.
    private func countTurns(_ turns: [TurnDiff], run: WorkspaceRun) async {
        guard !run.isRemote else { return }
        var pending: [String: TurnLines] = [:]
        var shownNewest = false
        for turn in turns.reversed() where countedLines[turn.id]?.complete != true {
            guard let start = turn.start, let end = turn.end else { continue }
            if let lines = try? await workspace.turnLines(runID, paths: turn.files.map(\.path), start: start, end: end) {
                guard !Task.isCancelled else { return }
                CountedTurnLines.keep(lines, turn: turn.id, run: runID)
                guard countedLines[turn.id] != lines else { continue }
                pending[turn.id] = lines
                if !shownNewest || pending.count >= Self.countBatch {
                    shownNewest = true
                    countedLines.merge(pending) { $1 }
                    pending = [:]
                }
            }
        }
        if !pending.isEmpty { countedLines.merge(pending) { $1 } }
    }

    /// How many counted turns `countTurns` hands to the cards at once.
    private static let countBatch = 16

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
        let memo = currentDerived(run)
        let events = memo.events
        let blocks = memo.blocks
        let cards = memo.cards
        let found = finding ? memo.search(findQuery) : .idle
        let current = findIndex.flatMap { found.matches.indices.contains($0) ? found.matches[$0].eventID : nil } ?? flashed
        // While the agent works, as in an agent's own transcript: "Working for …" right under your message, and the step
        // that runs now only in the live line at the end, not also in the list above it.
        let active = run.status.isActive
        // Just finished: for one frame the end still looks as it did while working, then it glides into its finished look.
        let settling = finishGlided >= 0 && finishGlide.settling(runID, active: active, following: scroll.shouldFollowEnd,
                                                                 glided: $finishGlided, gliding: $glidingEnd)
        let lastAnswer = settling ? events.last(where: { $0.kind == .assistant })?.id : nil
        // A new worktree still being set up: its checklist is the live state, in place of "Working for …".
        let setup = workspace.visibleSetup(run)
        let workingUnder = active && setup == nil ? events.last(where: { $0.kind == .user })?.id : nil
        // A compaction that runs is the live line too ("Compacting the conversation…"); once done it is a row of its own.
        let liveStep = active ? events.last.flatMap {
            ($0.kind == .tool && $0.state == .running) || CompactionProgress.isRunning($0) ? $0.id : nil
        } : nil
        // A step that just ended stays on the live line a moment (`EndedStepHold`), and out of the rows as long.
        let ended = active && liveStep == nil ? TimelinePresentation.endedStep(events) : nil
        let held = endedHold.held(ended?.id)
        let hidden = liveStep ?? held
        // Only the latest turns of a long session are drawn, from the turn the window starts at.
        let start = HistoryWindow.clamped(historyStart ?? HistoryWindow.initialStart(rowsPerTurn: memo.rowsPerTurn),
                                          turnCount: memo.rowsPerTurn.count)
        let firstRow = min(blocks.count, HistoryWindow.firstRow(rowsPerTurn: memo.rowsPerTurn, start: start))
        let shownBlocks = firstRow > 0 ? Array(blocks[firstRow...]) : blocks
        let context = TimelineRowContext(structure: memo.revision, status: run.status,
                                         directory: run.isRemote ? nil : run.workingDirectory, highlighted: current,
                                         openEvents: expanded, shownFile: sideLink.shownFile, counted: countedLines,
                                         settling: settling)
        // The latest turns drawn in full, the rest lazily (`ConversationRows`): the end never stays blank.
        let eager = HistoryWindow.eagerRows(rowsPerTurn: memo.rowsPerTurn, start: start)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
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
                    // While the agent works, its last rows never get shorter: what folds away into "Ran 3 commands"
                    // leaves room instead of bouncing the conversation down. Also once you scroll up: letting go then
                    // shrank the end the moment you started to scroll, and the view jumped under your fingers.
                    ConversationRows(items: shownBlocks, eager: eager,
                                     holdsHeight: (active || settling) && !finding,
                                     holdKey: Self.holdKey(turn: workingUnder, open: openBlocks, expanded: expanded, start: start),
                                     holdsSplit: !scroll.shouldFollowEnd, drawn: drawnRows,
                                     glidesGrowth: mayGlide || (settling && !glidingEnd), working: active) { block in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                            if block.id == newSince { TimelineNewDivider() }
                            // The held step is in the last block; its block is drawn again when it lets go of it.
                            TimelineBlockView(block: block, expanded: block.scopedOpen(openBlocks), context: context.scoped(to: block),
                                              hidden: block.id == shownBlocks.last?.id ? held : nil, toggle: toggleBlock) { event in
                                if event.id == hidden { return AnyView(EmptyView()) }
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
                                        let final: Bool = memo.finalAnswers.contains(event.id) && event.id != lastAnswer
                                        let inReply: Bool = event.kind == .assistant && final
                                        eventRow(event, final: final,
                                                 extras: inReply ? card : nil, answerable: memo.answerable == event.id)
                                        let cardBelow: Bool = !inReply && event.id != lastAnswer
                                        if cardBelow, let card { card }
                                        if event.id == workingUnder { TranscriptWorkingLine(since: run.turnStartedAt) }
                                    }
                                    .padding(.vertical, current == event.id ? 4 : 0)
                                    .roundedBackground(NookTheme.iris.opacity(current == event.id ? 0.16 : 0), radius: NookTheme.Radius.control)
                                )
                            }
                            // While the agent writes, only the block it writes into is drawn again.
                            .equatable()
                        }
                        .countsAsDrawnRow(drawnRows, id: block.id, reading: reading)
                        .id(block.id)
                    } footer: {
                        // Laid out with the rows: the room a fold leaves while the agent works goes under the live
                        // line, not between it and the rows above.
                        if let setup {
                            WorktreeSetupChecklist(progress: setup, active: active) { workspace.stop(runID) }
                        } else if active || settling {
                            // The agent's task list, live, right above what it does now: the same live line as in an agent's
                            // own transcript.
                            let turn = TimelinePresentation.runningTurn(events)
                            TranscriptLiveLine(activity: held != nil ? ended.map(AgentActivity.of) ?? .reviewing
                                                   : AgentActivity.current(turn, composing: workspace.composing[runID]),
                                               tasks: TaskChecklist.showsInline(run.tasks, active: true) ? run.tasks : nil,
                                               waiting: run.status == .waitingApproval || workspace.questions[runID] != nil,
                                               asking: workspace.questions[runID] != nil,
                                               openConsole: CommandConsole.running(turn).map { command -> () -> Void in
                                                   { sideLink.toggleConsole(command.id) }
                                               },
                                               help: TimelinePresentation.live(turn).tool,
                                               progress: turn.last(where: TimelinePresentation.isLive).flatMap { memo.progress[$0.id] })
                        }
                        // A usage limit ended the turn: its own card, with the reset and how to go on.
                        if UsageLimitCard.shows(run) {
                            UsageLimitCard(run: run)
                        } else if run.status == .failed || run.status == .stopped {
                            recovery(run, events: events, blocks: blocks, proxy: proxy)
                        }
                    }
                    // Room under a new turn held near the top while its reply grows (`TurnPinRoom`).
                    TurnPinRoomSpacer(pin: pinRoom)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                // The conversation's own space, where its rows report where they stand (`countsAsDrawnRow`).
                .coordinateSpace(name: TimelineSpace.name)
                .readingStackTop(reading)
                .readingScroller(reading, followsEnd: { scroll.shouldFollowEnd && !finding && !glidingEnd && !pinRoom.holds && scrollPhase.value != .animating }) { deltaY in
                    if scroll.releases(wheel: deltaY) {
                        scroll.userScrolled()
                    } else if scroll.returns(wheel: deltaY) {
                        scroll.userScrolledDown()
                    }
                }
                .chatColumn()
                .coordinateSpace(name: TimelineSpace.content)
            }
            // Made again when the blank guard finds its lazy stack stuck (`RowsInView.rebuilds`).
            .id(timelineBuild)
            // The files and lines of every finished turn from git (`countTurns`): again when a turn ends or a snapshot is made.
            .task(id: "\(runID)|\(memo.turns.count)|\(memo.turns.last?.files.count ?? 0)|\(run.checkpoints?.count ?? 0)") {
                await countTurns(memo.turns, run: run)
            }
            // Following the end while the answer streams: the scroll view keeps its bottom in place as the content grows,
            // instead of a `scrollTo` (a layout down to the end and a scroll) for every streamed update.
            // A session opens at its end, also when its timeline arrives after the first frame: never at its first messages.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Also once the run is done, as in an agent's own transcript: the turn folds to "Worked for …" in the update
            // that ends the run and its card comes under it, and rows above are measured anew; let go then, the
            // conversation jumped up by hundreds of points (thousands in a long session) before `keepEnd` caught it.
            // Not while a new turn is held near the top: its room shrinks as its reply grows, and the view stays put.
            .defaultScrollAnchor(scroll.shouldFollowEnd && !glidingEnd && !pinRoom.holds ? .bottom : nil, for: .sizeChanges)
            // A run that just finished: from where the view stands to its new end, in one glide (`FinishGlide`).
            .glidesToEnd(after: finishGlided, gliding: $glidingEnd, proxy: proxy)
            .scrollIndicators(.never)
            // Scrolling away from the end stops the following until you come back.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Within the toolbar and composer around the view: forgetting the toolbar left the pill up at the end.
                ScrollFrame(geometry).nearEnd
            } action: { _, nowAtEnd in
                atEnd = nowAtEnd
                // Back at the end follows again when you scrolled down to it, not when it came into view by itself
                // (`ScrollModel.endInView`).
                scroll.endInView(nowAtEnd)
            }
            // Only a step of yours up stops following (`readingScroller`), never where the view stands: while the agent
            // works, the end leaves the view for a frame with each new line before the view catches up, and a scroll
            // under way at that moment (also one down, to the end) stopped following, and the view stayed behind.
            .onScrollPhaseChange { _, phase in scrollPhase.value = phase }
            .onScrollGeometryChange(for: ScrollFrame.self) { geometry in
                ScrollFrame(geometry)
            } action: { old, frame in
                lastFrame.value = frame
                pinRoom.viewed(container: frame.container)
                // Reading back: what you read stays put while the rows above it change height.
                reading.moved(offset: frame.offset, container: frame.container, insetTop: frame.insetTop, holding: holdsReading)
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
                        // Still blank at the end: follow the end again, land on the last block
                        // itself (a row the lazy stack must draw), and only then on the very end.
                        scroll.jumpedToEnd()
                        // Scrolling brought nothing back: a new scroll view, which opens at its end.
                        if RowsInView.rebuilds(attempt: attempt) { timelineBuild += 1 }
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
            // The step that just ended goes back into the rows once its moment on the live line is over.
            .task(id: ended?.id) {
                guard let id = ended?.id else { return }
                try? await Task.sleep(for: .seconds(AgentActivity.stepDwell))
                guard !Task.isCancelled else { return }
                endedHold.release(id)
            }
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
                // Not animated, and only when the view is off its end: at the end `defaultScrollAnchor` and `keepEnd`
                // already hold it there, and an animated scroll on every new event fought them. Nor while it glides to
                // its end (`glidesToEnd`): this took it there at once.
                guard scroll.shouldFollowEnd, !atEnd, !glidingEnd else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You sent something: it is the newest thing and shows again, also when you had scrolled up. It glides up near
            // the top and its reply grows under it (`TurnPinRoom`), as in t3code.
            .onChange(of: sentCount) { _, _ in pinNewTurn(sent: true, proxy) }
            // A message that came in otherwise (a queued one going out, a goal's next turn, one from your phone) only
            // while you follow: reading higher up, it pulled you down to the end.
            .onChange(of: events.last(where: { $0.kind == .user })?.id) { _, _ in pinNewTurn(sent: false, proxy) }
            // The reply filled the view and the agent works with tools: on to the end, and following from there.
            .onChange(of: PinRelease(holds: pinRoom.holds, work: workUnderPin(events))) { _, now in
                guard scroll.releasesPin(room: now.holds ? 1 : 0, workStarted: now.work) else { return }
                scroll.jumpedToEnd()
                pinRoom.drop()
                // Down to the end in one glide (`glidesToEnd`), holding no end meanwhile: what the reply wrote past its
                // room came in at once as the view took its end again.
                glidingEnd = true
                finishGlided += 1
            }
            .onChange(of: runID) { _, _ in pinRoom.reset() }
            .onAppear { drawnRows.pin = pinRoom }
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
        let step = status == .working ? AgentAnnouncer.spokenStep(AgentActivity.current(events)) : nil
        return AgentAnnouncements.snapshot(events, status: status, step: step)
    }

    /// What lets go of the held height of the last rows (`HeldHeight`): a new turn, a block or event opened or closed,
    /// earlier turns drawn above.
    static func holdKey(turn: UUID?, open: Set<String>, expanded: Set<UUID>, start: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(turn)
        hasher.combine(open)
        hasher.combine(expanded)
        hasher.combine(start)
        return hasher.finalize()
    }

    /// Whether the block you read is held in place (`TimelineReadingAnchor`): you read back, so not while the view
    /// follows the end, finds, or runs an animated scroll of its own (to a mark on the rail, a find, the end).
    var holdsReading: Bool {
        !scroll.shouldFollowEnd && !finding && scrollPhase.value != .animating
    }

    /// Whether what the agent writes grows into view in a glide (`ConversationRows.glidesGrowth`): you follow it working.
    /// Also in the pass it finishes (`settling`), until the glide to the end takes over: what was left of the last line's
    /// glide came in at once with the view still holding its end, and the answer jumped up.
    private var mayGlide: Bool {
        guard scroll.shouldFollowEnd, !finding else { return false }
        return workspace.run(runID)?.status.isActive == true
    }

    /// What decides whether a held new turn gives way to following (`ScrollModel.releasesPin`).
    struct PinRelease: Equatable {
        let holds: Bool
        let work: Bool
    }

    /// The agent works with tools or thinks under the held message.
    private func workUnderPin(_ events: [RunEvent]) -> Bool {
        guard pinRoom.pinned != nil else { return false }
        return TimelinePresentation.runningTurn(events).contains { $0.kind == .tool || $0.kind == .thinking }
    }

    /// A new turn came in (`sent`: you sent it): held near the top with its reply growing under it, gliding up to there
    /// once it is laid out; or, while you read back or find, as before (only what you sent shows again).
    private func pinNewTurn(sent: Bool, _ proxy: ScrollViewProxy) {
        guard let run = workspace.run(runID),
              let message = workspace.timeline(runID).last(where: { $0.kind == .user }),
              let block = currentDerived(run).blocks.last(where: { $0.eventIDs.contains(message.id) })?.id else {
            if sent { settleAtEnd(proxy) }
            return
        }
        guard AnyHashable(block) != pinRoom.pinned else { return }
        pinRoom.track(block)
        guard scroll.pinsNewTurn(sentByYou: sent) else {
            if sent || scroll.shouldFollowEnd { settleAtEnd(proxy) }
            return
        }
        pinRoom.pin(block)
        // Once the message and its room are laid out (a pass or two): up to it in one glide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard scroll.isPinned, pinRoom.pinned == AnyHashable(block) else { return }
            withAnimation(NookTheme.scroll) { proxy.scrollTo(block, anchor: .top) }
        }
    }

    /// Scrolls to the end now and again while the layout settles (`EndSettle`): the lazy rows only learn their real
    /// height once laid out, so a single scroll from far up lands short of the end. Stops when you scroll away.
    /// Again only while it is not there yet: at its end, `keepEnd` holds it as the rows grow, and every `scrollTo`
    /// first brings the whole panel up to date, which cost the click that opened the session a full update each time.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        scroll.jumpedToEnd()
        // Each frame until it stays there (`EndSettle`); exactly at its end (not `atEnd`, which allows a margin) it does
        // nothing.
        EndSettle.run(following: { scroll.shouldFollowEnd && !glidingEnd }, frame: { lastFrame.value }) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: Where you left it

    static func visitKey(_ id: UUID) -> String { "run:" + id.uuidString }

    /// The timeline's blocks in order with their times, as `timeline(_:)` shows them (already made as it opens).
    private var visitRows: [TimelineLanding.Row] {
        guard let run = workspace.run(runID) else { return [] }
        return currentDerived(run).blocks.map { ($0.id.uuidString, $0.visitDate) }
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
    /// up from its end as it opens. A landing follows the end (`settleAtEnd`), so it ends there too. Only moving while the
    /// sizes stay the same, or a wheel step up, is you scrolling away. Also while a scroll of yours toward the end runs
    /// out (`ScrollModel.keepsEnd`), and at once (`TimelineReadingAnchor.jump`), so no frame shows the view off its end.
    private func keepEnd(_ old: ScrollFrame, _ new: ScrollFrame, _ proxy: ScrollViewProxy) {
        guard !finding, !glidingEnd, !pinRoom.holds, scroll.keepsEnd(movedFrom: old, to: new, animating: scrollPhase.value == .animating) else { return }
        if reading.jump(to: new.maxOffset) { return }
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
            let canRewind = !workspace.rewindScopes(runID, before: event.date).isEmpty
            let rewind = {
                revertError = nil
                editTarget = nil
                revertTarget = event
            }
            eventView(event, onEdit: workspace.canEditFromHere(runID, before: event.date) ? {
                editError = nil
                revertTarget = nil
                editTarget = event
            } : nil, onRewind: canRewind ? rewind : nil)
                .contextMenu {
                    // Rewind: back to before this message, with the files, the conversation, or both.
                    Button(tr("ws.rewind.menu"), action: rewind)
                        .disabled(!canRewind)
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
                           onEdit: (() -> Void)? = nil, onRewind: (() -> Void)? = nil) -> some View {
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
            onRewind: onRewind,
            // In the bar while it is there (this turn's commands, and any still running); else in the side panel.
            showBackground: {
                if derived.commands.contains(where: { $0.id == event.id }) { barFocus = event.id } else { outputsLink.showSubagents?() }
            },
            onSuggestion: { app.chooseSuggestion($0, event: event, in: runID) }
        )
        // Undone by going back to before an earlier message: the agent no longer remembers it.
        .opacity(event.rolledBack == true ? 0.45 : 1)
    }

    /// Opens or closes a group or fold at once: animated, every row of a long conversation moved for each frame of it,
    /// a third of a second of the main thread (more while the agent works) for one click.
    private func toggleBlock(_ key: String) {
        if openBlocks.contains(key) { openBlocks.remove(key) } else { openBlocks.insert(key) }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// The turns git counted, per session, kept across visits, so opening a session again shows its cards counted at once
/// instead of waiting for git. A turn counted completely (between the snapshots on both sides) stays as it is: those
/// snapshots never change. One counted without its later snapshot is shown as last counted and counted again
/// (`countTurns`). Only the most recently counted sessions are kept.
@MainActor
enum CountedTurnLines {
    private static var byRun: [UUID: [String: TurnLines]] = [:]
    private static var order: [UUID] = []
    private static let limit = 16

    static func forRun(_ id: UUID) -> [String: TurnLines] { byRun[id] ?? [:] }

    static func keep(_ lines: TurnLines, turn: String, run id: UUID) {
        byRun[id, default: [:]][turn] = lines
        if order.last != id {
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > limit { byRun[order.removeFirst()] = nil }
        }
    }
}
