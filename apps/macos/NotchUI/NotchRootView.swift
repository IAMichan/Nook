import SwiftUI

/// The entire notch: a single black shape that changes size, with Nook always on the left.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var ringHovered: String?
    // Redraws the ring when you mark a chat as finished.
    @ObservedObject private var finishedMarks = FinishedSessions.shared

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
            // Open, the sides and bottom corners can be dragged to make the notch larger or smaller.
            .overlay { if case .panel = viewModel.state { NotchResizeHandles(viewModel: viewModel) } }
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

    /// Nook without a bar. A dot top-right when something is waiting; visibly thinking while work is running.
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
                       frameRate: viewModel.pointerInside ? 30 : 12)
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) { bareBadge }
            .contentShape(Circle())
            .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
            .floatingDrag(viewModel)
            .accessibilityElement()
            .accessibilityLabel("Nook")
            .accessibilityAddTraits(.isButton)
    }

    /// Small dot next to the orb: amber when something is waiting for you, otherwise nothing.
    @ViewBuilder
    private var bareBadge: some View {
        let waiting = app.hub.approvals.count + app.agentSessions.filter { $0.status == .waiting && $0.approvalID == nil }.count
        if waiting > 0 {
            Circle()
                .fill(NookTheme.amber)
                .frame(width: 9, height: 9)
                .padding(4)
        }
    }

    @ViewBuilder
    private func regularContent(nh: CGFloat, nw: CGFloat) -> some View {
        switch viewModel.state {
        case .idle:
            let active = app.activeAgents
            if !active.isEmpty {
                // An agent is working: Nook is thinking along, one dot per session on the right.
                let waiting = active.contains { $0.status == .waiting || $0.approvalID != nil }
                wings(nh: nh, nw: nw, mood: waiting ? .waiting : .think, animated: true) {
                    AgentDots(sessions: active)
                }
                .contentShape(Rectangle())
                .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
                .floatingDrag(viewModel)
            } else if app.chat.anyBusy {
                // A Nook is working on something in the background: visibly thinking along.
                wings(nh: nh, nw: nw, mood: .think, animated: true) {
                    idleBadge
                }
                .contentShape(Rectangle())
                .onTapGesture { NookPresence.shared.poke(); viewModel.openPanel() }
                .floatingDrag(viewModel)
            } else if app.settings.hideWhenIdle && !viewModel.geometry.isFloating {
                Color.clear
            } else {
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside, orbSize: 20, orbInset: 3) {
                    idleBadge
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
        case .done(let message):
            doneStrip(message: message, nh: nh)
        case .nudge(let line, _):
            nudgeStrip(line: line, nh: nh)
        case .card(let card):
            expanded(nh: nh, mood: card.mood) {
                CardView(
                    card: card,
                    onAction: { viewModel.perform($0) },
                    onVoice: { viewModel.startListening() },
                    onReply: { app.handleCardReply($0, card: card) },
                    onChoose: { viewModel.choose($0, $1) }
                )
            }
        case .panel(let tab):
            expanded(nh: nh, mood: viewModel.mood(for: tab), ring: true) {
                PanelView(viewModel: viewModel, tab: tab)
            }
        }
    }

    // MARK: Idle and Music: Nook left of the notch, something compact on the right

    /// On the right when idle: amber if an agent is waiting; otherwise, quietly, how many things are on today.
    @ViewBuilder
    private var idleBadge: some View {
        let waiting = app.hub.approvals.count + app.agentSessions.filter { $0.status == .waiting && $0.approvalID == nil }.count
        // Built from every source and session: worked out once per redraw.
        let today = waiting > 0 ? 0 : app.todayItems.count
        if waiting > 0 {
            HStack(spacing: 4) {
                Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                Text("\(waiting)")
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.amber)
            }
        } else if today > 0 {
            // Calm: what is on today is information, not an alarm. Amber is kept for things that wait for you.
            Text("\(today)")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private func wings<Right: View>(
        nh: CGFloat,
        nw: CGFloat,
        mood: NookMood,
        animated: Bool,
        orbSize: CGFloat = 24,
        orbInset: CGFloat = 0,
        @ViewBuilder right: () -> Right
    ) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        return HStack(spacing: 0) {
            // Full rate while the pointer is on the notch (Nook follows it); slower while it only thinks along.
            NookOrb(mood: mood, size: orbSize, animated: animated, glow: viewModel.geometry.isFloating,
                    frameRate: viewModel.pointerInside ? 30 : 12)
                .offset(x: orbInset)
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
        .accessibilityLabel(artist.isEmpty ? "Nu: \(title)" : "Nu: \(title) van \(artist)")
    }

    // MARK: Recent action

    private func doneStrip(message: String, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: .done, size: 24, glow: viewModel.geometry.isFloating)
                    .padding(.leading, 18)
                Spacer()
            }
            .frame(height: nh)
            .contentShape(Rectangle())
            .floatingDrag(viewModel)

            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NookTheme.mint)
                Text(message)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NookGhostButton(title: viewModel.doneButtonTitle) { viewModel.doneButtonPressed() }
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text(line)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
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

    // MARK: Expanded: Nook on the left, content on the right

    /// `ring`: the open panel shows Nook's task ring around him; a card does not.
    private func expanded<Inner: View>(
        nh: CGFloat,
        mood: NookMood,
        ring: Bool = false,
        @ViewBuilder inner: () -> Inner
    ) -> some View {
        // Built from every agent session and every conversation: once per redraw, shared by the ring and its label.
        let items = ring ? ringItems : []
        return HStack(alignment: .top, spacing: ring ? 34 : 20) {
            Button {
                NookPresence.shared.poke()
                viewModel.show(.panel(.nook), inNotch: true)
            } label: {
                NookOrb(mood: mood, size: 46, glow: viewModel.geometry.isFloating)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("notch.goToHome"))
            .background {
                if ring {
                    NookTaskRing(items: items, orbSize: 46, hovered: $ringHovered) { openRingItem($0) }
                }
            }
            .overlay {
                if ring { NookTaskRingLabel(items: items, hovered: ringHovered, orbSize: 46) }
            }
            .zIndex(1)
            inner()
        }
        .padding(.top, nh + 14)
        .padding(.leading, ring ? 32 : 28)
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
}

extension NotchRootView {
    /// What Nook's ring shows: every agent session that runs, waits or failed (and recently finished), and every Nook
    /// that works, waits for you or has news.
    fileprivate var ringItems: [TaskRingItem] {
        var items: [TaskRingItem] = []
        let recent = Date().addingTimeInterval(-20 * 60)
        for session in app.agentSessions where !session.isDetected {
            let kind: TaskRingItem.Kind
            var settled = false
            if session.status == .waiting || session.approvalID != nil {
                kind = .waiting
            } else if session.status == .running {
                // Marked as finished by you: shown as done, drawn at once.
                kind = app.isSettledWhileBusy(session) ? .done : .running
                settled = kind == .done
            } else if session.status == .failed {
                kind = .failed
            } else if session.status == .done, app.demoMode || (session.updated ?? .distantPast) > recent {
                kind = .done
                settled = app.isMarkedFinished(session)
            } else {
                continue
            }
            let label = kind == .waiting ? AgentStatus.waiting.label : (settled ? AgentStatus.done.label : session.status.label)
            let detail = session.project.isEmpty ? label : "\(session.project) · \(label)"
            items.append(TaskRingItem(id: "agent-\(session.id)", title: session.name, detail: detail, state: kind, target: .agent(session.id), instant: settled))
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
        return Array(items.prefix(8))
    }

    /// A piece of the ring was clicked: go to that agent or that Nook.
    fileprivate func openRingItem(_ item: TaskRingItem) {
        NookPresence.shared.lookAngle = nil
        switch item.target {
        case .agent(let id):
            viewModel.selectedAgentID = id
            viewModel.show(.panel(.agents), inNotch: true)
        case .nook(let id):
            app.openConversation(id)
        }
    }
}

/// Strips along the open notch's sides and bottom, and its bottom corners: drag one to make the notch larger or smaller,
/// double-click it to go back to the size each tab starts at. The top stays under the camera. A small grip in each bottom
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

/// One dot per active agent, in the color of its state. If one is waiting for you, it pulses gently.
private struct AgentDots: View {
    let sessions: [AgentSession]

    var body: some View {
        let shown = Array(sessions.prefix(4))
        let anyWaiting = shown.contains { $0.status == .waiting || $0.approvalID != nil }
        // A gentle pulse, possibly for hours (an approval left open): ten frames a second are smooth enough.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: !anyWaiting)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = anyWaiting ? (0.55 + 0.45 * abs(sin(t * 2.4))) : 1.0
            HStack(spacing: 5) {
                ForEach(shown) { session in
                    let waiting = session.status == .waiting || session.approvalID != nil
                    Circle()
                        .fill(waiting ? NookTheme.amber : session.status.color)
                        .frame(width: 8, height: 8)
                        .opacity(waiting ? pulse : 1)
                }
                if sessions.count > shown.count {
                    Text("+\(sessions.count - shown.count)")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
        }
        .accessibilityLabel(tr("notch.agentsActive", sessions.count))
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(artworkURL != nil ? NookTheme.graphite : NookTheme.music.opacity(0.18))
            if let artworkURL {
                AsyncImage(url: artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NookTheme.music.opacity(0.6))
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NookTheme.music)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}
