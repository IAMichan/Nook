import SwiftUI

/// The entire notch: a single black shape that changes size, with Nook always on the left.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    // Redraws the closed notch's ring when you mark a chat as finished or read a session.
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared
    /// Nook's idle frame rate follows the energy plan: a little slower on battery.
    @ObservedObject private var energy = EnergyMonitor.shared

    var body: some View {
        let size = viewModel.size
        let radius = viewModel.cornerRadius
        let floating = viewModel.geometry.isFloating
        // Floating and idle: only Nook itself is on screen, without the black shape around it.
        let bare = viewModel.isBareOrb
        let topRadius = floating ? radius : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: topRadius,
            style: .continuous
        )

        ZStack(alignment: .top) {
            // The content immediately has its final size; the black shape expands around it and reveals it.
            // This avoids SwiftUI having to recalculate layout during the animation.
            ZStack(alignment: .top) {
                content(size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(shape.fill(NookTheme.notch.opacity(bare ? 0 : 1)))
            .clipShape(bare ? AnyShape(Rectangle().inset(by: -24)) : AnyShape(shape))
            .overlay(shape.strokeBorder(Color.white.opacity(floating && !bare ? 0.1 : 0), lineWidth: 1))
            // Open, or showing a conversation, the sides and bottom corners can be dragged to make the notch larger or smaller.
            .overlay { if viewModel.isResizable { NotchResizeHandles(viewModel: viewModel) } }
            .shadow(color: Color.black.opacity(floating ? (isExpanded ? 0.45 : (bare ? 0 : 0.3)) : 0), radius: isExpanded ? 18 : 8, x: 0, y: isExpanded ? 8 : 3)
            // A subtle expansion when hovering over the notch: indicates responsiveness.
            .scaleEffect(hoverGrow ? 1.04 : 1, anchor: .top)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hoverGrow)
        }
        .frame(
            width: NotchController.panelSize.width,
            height: NotchController.panelSize.height,
            alignment: .top
        )
    }

    private var hoverGrow: Bool {
        viewModel.pointerInside && viewModel.state.isResting
    }

    private var isExpanded: Bool {
        switch viewModel.state {
        case .card, .panel: return true
        default: return false
        }
    }

    /// When something substantial changes, fade the content instead of abruptly jumping.
    private var contentKey: String {
        if viewModel.isBareOrb { return "bare" }
        switch viewModel.state {
        case .idle: return "idle"
        case .music, .track: return "music"
        case .done: return "done"
        case .card(let card): return "card-\(card.id)"
        case .nudge(_, let card): return "nudge-\(card.id)"
        case .moment(let moment): return "moment-\(moment.id)"
        case .panel: return "panel"   // tab switching happens within the panel, without replacing everything
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let nw = viewModel.geometry.notchWidth
        let nh = viewModel.geometry.notchHeight

        Group {
            if viewModel.isBareOrb {
                bareOrb
            } else {
                regularContent(nh: nh, nw: nw)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .id("\(contentKey)-\(app.settings.accentHex)")
        .transition(.notchContent)
    }

    // MARK: Floating and idle: just Nook

    /// Nook without a bar, in the same ring as the closed notch and the open panel.
    private var bareOrb: some View {
        let active = app.activeAgents
        let waiting = active.contains { $0.status == .waiting || $0.approvalID != nil }
        let mood: NookMood
        if !active.isEmpty {
            mood = waiting ? .waiting : .think
        } else if app.chat.anyBusy {
            mood = .think
        } else {
            mood = viewModel.pointerInside ? .seen : .rest
        }
        let side = NotchViewModel.floatingOrbSide
        return NookOrb(mood: mood, size: 28, animated: viewModel.pointerInside || !active.isEmpty || app.chat.anyBusy,
                       frameRate: viewModel.pointerInside ? 30 : energy.plan.idleOrbFrameRate)
            .background {
                let ring = TaskRingItem.all(app: app, selected: viewModel.selectedAgentID)
                if !ring.isEmpty { NookTaskRing(items: ring, style: .compact, orbSize: 28, maxSide: side) }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
            .floatingDrag(viewModel)
            .accessibilityElement()
            .accessibilityLabel("Nook")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func regularContent(nh: CGFloat, nw: CGFloat) -> some View {
        switch viewModel.state {
        case .idle:
            let active = app.activeAgents
            if !active.isEmpty {
                // An agent is working: Nook is thinking along inside a thin ring, one piece per session, like in the panel.
                let waiting = active.contains { $0.status == .waiting || $0.approvalID != nil }
                wings(nh: nh, nw: nw, mood: waiting ? .waiting : .think, animated: true, orbSize: 20, ring: TaskRingItem.all(app: app, selected: viewModel.selectedAgentID)) {
                    EmptyView()
                }
                .contentShape(Rectangle())
                .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
                .floatingDrag(viewModel)
            } else if app.chat.anyBusy {
                // A Nook is working on something in the background: visibly thinking along.
                wings(nh: nh, nw: nw, mood: .think, animated: true, orbSize: 20, ring: TaskRingItem.all(app: app, selected: viewModel.selectedAgentID)) {
                    EmptyView()
                }
                .contentShape(Rectangle())
                .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
                .floatingDrag(viewModel)
            } else if app.settings.hideWhenIdle && !viewModel.geometry.isFloating {
                Color.clear
            } else {
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside, orbSize: 20, ring: TaskRingItem.all(app: app, selected: viewModel.selectedAgentID)) {
                    EmptyView()
                }
                .contentShape(Rectangle())
                .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
                .floatingDrag(viewModel)
            }
        case .music:
            wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside) {
                EqualizerBars(color: NookTheme.music, height: 14, isPlaying: app.nowPlaying.current?.isPlaying ?? true, frameRate: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
            .floatingDrag(viewModel)
        case .track(let title, let artist):
            trackStrip(title: title, artist: artist, nh: nh, nw: nw)
        case .done(let message) where viewModel.doneAcknowledge && viewModel.geometry.hasNotch && !viewModel.geometry.isFloating:
            inlineDoneStrip(message: message, nh: nh, nw: nw)
        case .done(let message):
            doneStrip(message: message, nh: nh)
        case .nudge(let line, _):
            nudgeStrip(line: line, nh: nh)
        case .moment(let moment):
            momentStrip(moment, nh: nh)
        case .card(let card):
            expanded(nh: nh, mood: card.mood) {
                CardView(
                    card: card,
                    onAction: { viewModel.perform($0) },
                    onVoice: { viewModel.startListening() },
                    onReply: { app.handleCardReply($0, card: card) },
                    onChoose: { viewModel.choose($0, $1) },
                    onOpen: { app.openCardAttachment($0, card: card) },
                    paused: viewModel.pointerInside
                )
            }
        case .panel(let tab):
            expanded(nh: nh, mood: viewModel.mood(for: tab), ring: true) {
                PanelView(viewModel: viewModel, tab: tab, headerInset: Self.panelHeaderInset)
            }
        }
    }

    // MARK: Idle and Music: Nook left of the notch, something compact on the right

    private func wings<Right: View>(
        nh: CGFloat,
        nw: CGFloat,
        mood: NookMood,
        animated: Bool,
        orbSize: CGFloat = 24,
        ring: [TaskRingItem] = [],
        @ViewBuilder right: () -> Right
    ) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        return HStack(spacing: 0) {
            // Full rate while the pointer is on the notch (Nook follows it); slower while it only thinks along.
            NookOrb(mood: mood, size: orbSize, animated: animated, glow: viewModel.geometry.isFloating,
                    frameRate: viewModel.pointerInside ? 30 : energy.plan.idleOrbFrameRate)
                .background {
                    if !ring.isEmpty { NookTaskRing(items: ring, style: .compact, orbSize: orbSize, maxSide: nh) }
                }
                .frame(width: wing, height: nh)
            Spacer(minLength: 0)
            right()
                .frame(width: wing, height: nh)
        }
        .frame(height: nh)
    }

    /// The "new track" strip: Nook and artwork on the left end, title and equalizer on the right end.
    private func trackStrip(title: String, artist: String, nh: CGFloat, nw: CGFloat) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        let isPlaying = app.nowPlaying.current?.isPlaying ?? true
        return HStack(spacing: 0) {
            // Left wing: Nook pinned to the far left, album cover beside it
            HStack(spacing: 8) {
                NookOrb(mood: viewModel.pointerInside ? .seen : .rest, size: 24, animated: true, glow: viewModel.geometry.isFloating)
                TrackCover(artworkURL: app.nowPlaying.current?.artworkURL)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: wing, height: nh)

            Spacer(minLength: 0)

            // Right wing: track title & artist, equalizer bars pinned to the far right
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0.5) {
                    Text(title)
                        .font(NookTheme.font(11.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(NookTheme.font(10))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .truncationMode(.tail)
                Spacer(minLength: 6)
                EqualizerBars(color: NookTheme.music, height: 13, isPlaying: isPlaying)
            }
            .padding(.trailing, 14)
            .frame(width: wing, height: nh)
        }
        .frame(height: nh)
        .contentShape(Rectangle())
        .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
        .floatingDrag(viewModel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artist.isEmpty ? tr("notch.nowPlaying", title) : tr("notch.nowPlayingBy", title, artist))
    }

    // MARK: Recent action

    /// A compact agent notice in the notch's own row, like a track: mark and message left of the notch, View and OK right
    /// of it. The notch keeps its height and only grows wider.
    private func inlineDoneStrip(message: String, nh: CGFloat, nw: CGFloat) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        let button = min(24, nh - 8)
        let tone = viewModel.doneTone
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: tone.symbol)
                    .font(NookTheme.font(tone == .waiting ? 13 : 11, .bold))
                    .foregroundStyle(tone.color)
                    .frame(width: 16)
                Text(message)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(width: wing, height: nh)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                NookGhostButton(title: viewModel.doneButtonTitle, compact: true, height: button) {
                    viewModel.doneButtonPressed()
                }
                NookAcknowledgeButton(title: tr("button.ok"), compact: true, countdown: NotchViewModel.doneSeconds,
                                      height: button) {
                    viewModel.show(.idle)
                }
                .id(viewModel.doneStamp)
            }
            .padding(.trailing, 10)
            .frame(width: wing, height: nh)
        }
        .frame(height: nh)
        .floatingDrag(viewModel)
        .accessibilityElement(children: .contain)
    }

    private func doneStrip(message: String, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: viewModel.doneTone.mood, size: 24, glow: viewModel.geometry.isFloating)
                    .padding(.leading, 18)
                Spacer()
            }
            .frame(height: nh)
            .contentShape(Rectangle())
            .floatingDrag(viewModel)

            HStack(spacing: 10) {
                Image(systemName: viewModel.doneTone.symbol)
                    .font(NookTheme.font(viewModel.doneTone == .waiting ? 14 : 12, .bold))
                    .foregroundStyle(viewModel.doneTone.color)
                Text(message)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NookGhostButton(title: viewModel.doneButtonTitle, compact: viewModel.doneAcknowledge) {
                    viewModel.doneButtonPressed()
                }
                if viewModel.doneAcknowledge {
                    NookAcknowledgeButton(title: tr("button.ok"), compact: true, countdown: NotchViewModel.doneSeconds) {
                        viewModel.show(.idle)
                    }
                    .id(viewModel.doneStamp)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
        }
    }

    // MARK: Nook thinking along

    /// A short sentence below the notch, like "Shall I add this to your calendar?". Hover or click for the full proposal.
    private func nudgeStrip(line: String, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: .seen, size: 24, animated: true, curious: true, glow: viewModel.geometry.isFloating)
                    .padding(.leading, 18)
                Spacer()
            }
            .frame(height: nh)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text(line)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(NookTheme.font(10, .bold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.openNudge() }
        .floatingDrag(viewModel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("notch.nudgeProposal", line))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Nook's own moments

    /// A friendly moment below the notch: Nook in the moment's mood, the line, and at most one button. Clicking the
    /// line does what the button says (the good morning shows today's events), or puts it away otherwise.
    private func momentStrip(_ moment: NookMoment, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: moment.mood, size: 24, animated: true, glow: viewModel.geometry.isFloating, outfit: moment.outfit)
                    .padding(.leading, 18)
                Spacer()
            }
            .frame(height: nh)
            .floatingDrag(viewModel)

            HStack(spacing: 10) {
                Group {
                    if moment.mood == .breathe {
                        // The line follows the breath: in, hold, out.
                        TimelineView(.periodic(from: moment.started, by: 0.5)) { context in
                            Text(tr(NookMoment.breathPhaseKey(context.date.timeIntervalSince(moment.started))))
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.4), value: NookMoment.breathPhaseKey(context.date.timeIntervalSince(moment.started)))
                        }
                    } else {
                        Text(moment.line)
                    }
                }
                .font(NookTheme.font(13.5, .medium))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Breathing along is only started with the button: a click on the line never surprises you with it.
                    if let action = moment.action, action != .breathe { app.performMomentAction(moment) } else { viewModel.show(.idle) }
                }
                Spacer(minLength: 8)
                if moment.action != nil, !moment.actionTitle.isEmpty {
                    NookGhostButton(title: moment.actionTitle, compact: true) { app.performMomentAction(moment) }
                }
                Button { viewModel.show(.idle) } label: {
                    Image(systemName: "xmark")
                        .font(NookTheme.font(10, .bold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("button.close"))
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(height: 40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("buddy.accessibility", moment.mood.label, moment.line))
    }

    // MARK: Expanded: Nook on the left, content on the right

    private static var panelOrbSize: CGFloat { PanelOrb.panelSize }
    private static var panelHeaderInset: CGFloat { PanelOrb.headerInset }

    /// `ring`: the open panel shows Nook's task ring around him, in the header row so the panel's content runs the
    /// full width below him; a card keeps him in a column of his own.
    private func expanded<Inner: View>(
        nh: CGFloat,
        mood: NookMood,
        ring: Bool = false,
        @ViewBuilder inner: () -> Inner
    ) -> some View {
        Group {
            if ring {
                ZStack(alignment: .topLeading) {
                    inner()
                    expandedOrb(mood: mood, size: Self.panelOrbSize, ring: true)
                        .offset(y: (PanelView.headerHeight - Self.panelOrbSize) / 2)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    expandedOrb(mood: mood, size: 46, ring: false)
                    inner()
                }
            }
        }
        .padding(.top, nh + 14)
        .padding(.leading, 28)
        .padding(.trailing, 28)
        .padding(.bottom, 22)
        .overlay(alignment: .top) {
            // Floating: drag the top edge to move the panel.
            if viewModel.geometry.isFloating {
                Color.clear
                    .frame(height: nh)
                    .contentShape(Rectangle())
                    .floatingDrag(viewModel)
            }
        }
    }

    /// Nook in the expanded notch; tap him to go home. In the open panel the task ring circles him.
    private func expandedOrb(mood: NookMood, size: CGFloat, ring: Bool) -> some View {
        PanelOrb(viewModel: viewModel, mood: mood, size: size, ring: ring, glow: viewModel.geometry.isFloating)
    }
}

/// Nook in the open panel (in the notch or the main window); tap him to go home. With `ring`, the task ring circles him.
struct PanelOrb: View {
    /// Nook's size in the open panel, where he sits in the header row next to the tabs.
    static let panelSize: CGFloat = 40
    /// The room the header row leaves for Nook and his task ring.
    static var headerInset: CGFloat { panelSize + 30 }

    @ObservedObject var viewModel: NotchViewModel
    let mood: NookMood
    let size: CGFloat
    var ring = true
    var glow = false
    /// In the main window: going home and opening a ring item stay in the window instead of opening the notch.
    var inWindow = false
    @EnvironmentObject private var app: AppModel
    @StateObject private var ringPointer = TaskRingPointer()
    // Redraws the ring when you mark a chat as finished or read a session.
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared

    var body: some View {
        // Built from every agent session and every conversation: once per redraw, shared by the ring and its label.
        let items = ring ? ringItems : []
        return Button {
            NookPresence.shared.poke()
            if inWindow {
                viewModel.windowSheet = nil
                viewModel.windowTab = .chat
            } else {
                viewModel.show(.panel(.nook), inNotch: true)
            }
        } label: {
            NookOrb(mood: mood, size: size, glow: glow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("notch.goToHome"))
        .background {
            if ring {
                NookTaskRing(items: items, orbSize: size, hovered: ringPointer.hovered, pointer: ringPointer) { openRingItem($0) }
            }
        }
        .overlay {
            if ring {
                NookTaskRingLabel(items: items, hovered: ringPointer.hovered, orbSize: size, pointer: ringPointer) { openRingItem($0) }
            }
        }
        .zIndex(1)
    }
}

extension TaskRingItem {
    /// What Nook's ring shows: the sessions in the Agents list that run, wait for you, failed or finished since you last
    /// looked (the same answer the list gives), and every Nook that works, waits for you or has news. A session you
    /// marked as finished, or already read, is not on it. `selected` is the session open in the Agents tab: what it
    /// finished while you look at it is not news.
    @MainActor
    static func all(app: AppModel, selected: String? = nil) -> [TaskRingItem] {
        var items: [TaskRingItem] = []
        let finished = FinishedSessions.shared
        func unseen(_ id: String, _ date: Date?) -> Bool {
            if app.demoMode { return true }
            guard let date, id != selected else { return false }
            return SessionVisits.shared.isUnseen(id, finished: date)
        }
        func detail(_ project: String, _ status: AgentStatus) -> String {
            project.isEmpty ? status.label : "\(project) · \(status.label)"
        }
        // Sessions Nook runs itself, as the Agents list reads them.
        for run in app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace) {
            let id = "run:" + run.id.uuidString
            let key = FinishedSessions.key(run: run)
            let attention = app.workspace.attention(run, unseen: run.status == .completed && unseen(id, run.updatedAt))
            let kind: TaskRingItem.Kind
            let status: AgentStatus
            switch attention {
            case .approval, .input: kind = .waiting; status = .waiting
            case .failed, .limited: kind = .failed; status = .failed
            case .working:
                // Marked as finished during this busy spell (a turn that hangs): out of the way, like in the list.
                if finished.isMarkedWhileBusy(key) { continue }
                kind = .running; status = .running
            case .ready:
                if finished.isFinished(key: key, idle: true, lastActive: run.updatedAt, now: Date()) { continue }
                kind = .done; status = .done
            case .idle, .finished: continue
            }
            items.append(TaskRingItem(id: id, title: run.title, detail: detail(run.projectName, status), state: kind, target: .agent(id)))
        }
        for session in app.agentSessions where !session.isDetected {
            let kind: TaskRingItem.Kind
            let status: AgentStatus
            if session.status == .waiting || session.approvalID != nil {
                kind = .waiting; status = .waiting
            } else if session.status == .running {
                if app.isSettledWhileBusy(session) { continue }
                kind = .running; status = .running
            } else if session.status == .failed {
                kind = .failed; status = .failed
            } else if session.status == .done, unseen(session.id, session.updated), app.demoMode || !app.isMarkedFinished(session) {
                kind = .done; status = .done
            } else {
                continue
            }
            items.append(TaskRingItem(id: "agent-\(session.id)", title: session.name, detail: detail(session.project, status),
                                      state: kind, target: .agent(session.id)))
        }
        for conversation in app.chat.list(query: "", showArchived: false) {
            let kind: TaskRingItem.Kind
            let detail: String
            switch conversation.status {
            case .working: kind = .running; detail = tr("nooks.working")
            case .waiting: kind = .waiting; detail = tr("nooks.waiting")
            case .unread: kind = .done; detail = tr("nooks.doneAt", NookDates.ago(conversation.updated))
            case .idle: continue
            }
            items.append(TaskRingItem(id: "nook-\(conversation.id)", title: conversation.title, detail: detail, state: kind, target: .nook(conversation.id)))
        }
        // What asks for you first, then what works, then news: what does not fit on the ring is the least urgent.
        let rank: [TaskRingItem.Kind: Int] = [.waiting: 0, .failed: 1, .running: 2, .done: 3]
        let ordered = items.enumerated().sorted { (rank[$0.element.state] ?? 4, $0.offset) < (rank[$1.element.state] ?? 4, $1.offset) }
        return Array(ordered.map(\.element).prefix(8))
    }
}

extension PanelOrb {
    fileprivate var ringItems: [TaskRingItem] { TaskRingItem.all(app: app, selected: viewModel.selectedAgentID) }

    /// A piece of the ring was clicked: go to that agent or that Nook.
    fileprivate func openRingItem(_ item: TaskRingItem) {
        NookPresence.shared.lookAngle = nil
        switch item.target {
        case .agent(let id):
            viewModel.selectedAgentID = id
            if inWindow {
                viewModel.windowSheet = nil
                viewModel.windowTab = .agents
            } else {
                viewModel.show(.panel(.agents), inNotch: true)
            }
        case .nook(let id):
            app.openConversation(id)
        }
    }
}

/// Strips along the open notch's sides and bottom, and its bottom corners: drag one to make the notch larger or smaller,
/// double-click it to go back to the size each tab (or a conversation card) starts at. The top stays under the camera. A small grip in each bottom
/// corner shows that it can be done, and the edge under the pointer lights up.
private struct NotchResizeHandles: View {
    @ObservedObject var viewModel: NotchViewModel
    /// How far into the notch a side reaches: inside the margin around the content, so nothing there is covered.
    private let thickness: CGFloat = 12
    private let corner: CGFloat = 32
    @State private var hovered: NotchResize.Edge?

    var body: some View {
        // Below the strip along the top, which belongs to the camera (and, floating, to moving the notch).
        let top = viewModel.geometry.notchHeight
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .leading) {
                handle(.left, .leading).frame(width: thickness).padding(.top, top).padding(.bottom, corner)
            }
            .overlay(alignment: .trailing) {
                handle(.right, .trailing).frame(width: thickness).padding(.top, top).padding(.bottom, corner)
            }
            .overlay(alignment: .bottom) {
                handle(.bottom, .bottom).frame(height: thickness).padding(.horizontal, corner)
            }
            .overlay(alignment: .bottomLeading) { handle(.bottomLeft, .bottomLeading).frame(width: corner, height: corner) }
            .overlay(alignment: .bottomTrailing) { handle(.bottomRight, .bottomTrailing).frame(width: corner, height: corner) }
    }

    private func handle(_ edge: NotchResize.Edge, _ position: FrameResizePosition) -> some View {
        let lit = hovered == edge
        return Color.clear
            .overlay { marker(edge, lit: lit) }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position))
            .onHover { inside in
                if inside { hovered = edge } else if hovered == edge, !viewModel.resizing { hovered = nil }
            }
            .gesture(
                // Global coordinates: the edge itself moves while you drag it.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { hovered = edge; viewModel.resize(edge, translation: $0.translation) }
                    .onEnded { _ in viewModel.endResize(); hovered = nil }
            )
            .onTapGesture(count: 2) { viewModel.resetPanelSize() }
            .help(tr("notch.resize"))
            .accessibilityLabel(tr("notch.resize"))
            .animation(.easeOut(duration: 0.15), value: lit)
    }

    /// What you see of a handle: a grip in the bottom corners (always, faintly), a short bar on a side or the bottom
    /// while the pointer is on it.
    @ViewBuilder
    private func marker(_ edge: NotchResize.Edge, lit: Bool) -> some View {
        switch edge {
        case .bottomLeft, .bottomRight:
            ResizeGrip(mirrored: edge == .bottomLeft)
                .stroke(Color.white.opacity(lit ? 0.75 : 0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 10, height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .bottomLeft ? .bottomLeading : .bottomTrailing)
                .padding(edge == .bottomLeft ? .leading : .trailing, 11)
                .padding(.bottom, 11)
        case .left, .right:
            Capsule().fill(Color.white.opacity(lit ? 0.45 : 0)).frame(width: 3, height: 44)
        case .bottom:
            Capsule().fill(Color.white.opacity(lit ? 0.45 : 0)).frame(width: 44, height: 3)
        }
    }
}

/// Two short diagonal lines, the usual sign for "drag this corner".
private struct ResizeGrip: Shape {
    var mirrored: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = { (value: CGFloat) in mirrored ? rect.maxX - value : rect.minX + value }
        path.move(to: CGPoint(x: x(rect.width), y: rect.minY))
        path.addLine(to: CGPoint(x: x(0), y: rect.maxY))
        path.move(to: CGPoint(x: x(rect.width), y: rect.midY))
        path.addLine(to: CGPoint(x: x(rect.width / 2), y: rect.maxY))
        return path
    }
}

private extension View {
    /// In floating mode, you can drag Nook by this component. Tapping continues to work as expected.
    /// With ⌥ held, the drag attaches the window you drop Nook on to the chat instead (any placement).
    func floatingDrag(_ viewModel: NotchViewModel) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    if WindowAttach.shared.isDragging || NSEvent.modifierFlags.contains(.option) {
                        WindowAttach.shared.dragMoved()
                    } else if viewModel.geometry.isFloating {
                        viewModel.onDragMoved?()
                    }
                }
                .onEnded { _ in
                    if WindowAttach.shared.isDragging {
                        WindowAttach.shared.dragEnded()
                    } else if viewModel.geometry.isFloating {
                        viewModel.onDragEnded?()
                    }
                }
        )
    }
}

/// Album artwork or playback placeholder in the new-track strip.
private struct TrackCover: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(artworkURL != nil ? NookTheme.graphite : NookTheme.music.opacity(0.18))
            if let artworkURL {
                AsyncImage(url: artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note")
                        .font(NookTheme.font(9, .bold))
                        .foregroundStyle(NookTheme.music.opacity(0.6))
                }
            } else {
                Image(systemName: "music.note")
                    .font(NookTheme.font(10, .bold))
                    .foregroundStyle(NookTheme.music)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}
