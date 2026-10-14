import SwiftUI

/// De hele notch: één zwarte vorm die van maat verandert, met Nook er altijd links in.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let size = viewModel.size
        let radius = viewModel.cornerRadius
        let floating = viewModel.geometry.isFloating
        let topRadius = floating ? radius : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: topRadius,
            style: .continuous
        )

        ZStack(alignment: .top) {
            // De inhoud heeft meteen zijn eindmaat; de zwarte vorm groeit eromheen en onthult hem.
            // Zo hoeft SwiftUI tijdens de animatie niets opnieuw uit te leggen.
            ZStack(alignment: .top) {
                content(size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(shape.fill(NookTheme.notch))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(floating ? 0.1 : 0), lineWidth: 1))
            .shadow(color: Color.black.opacity(isExpanded ? 0.45 : (floating ? 0.3 : 0)), radius: isExpanded ? 18 : 8, x: 0, y: isExpanded ? 8 : 3)
            // Een lichte zwelling als de muis op de notch staat: laat zien dat hij reageert.
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

    /// Verandert er iets wezenlijks, dan faden we de inhoud in plaats van te laten verspringen.
    private var contentKey: String {
        switch viewModel.state {
        case .idle: return "idle"
        case .music: return "music"
        case .track(let title, let artist): return "track-\(title)-\(artist)"
        case .done: return "done"
        case .card(let card): return "card-\(card.id)"
        case .nudge(_, let card): return "nudge-\(card.id)"
        case .panel: return "panel"   // wisselen van tab gebeurt binnen het paneel, zonder alles te vervangen
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let nw = viewModel.geometry.notchWidth
        let nh = viewModel.geometry.notchHeight

        Group {
            switch viewModel.state {
            case .idle:
                let active = app.activeAgents
                if !active.isEmpty {
                    // Er werkt een agent: Nook denkt mee, rechts één stipje per sessie.
                    let waiting = active.contains { $0.status == .waiting || $0.approvalID != nil }
                    wings(nh: nh, nw: nw, mood: waiting ? .waiting : .think, animated: true) {
                        AgentDots(sessions: active)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.openPanel() }
                    .floatingDrag(viewModel)
                } else if app.chat.anyBusy {
                    // Een Nook werkt op de achtergrond aan iets: hij denkt zichtbaar mee.
                    wings(nh: nh, nw: nw, mood: .think, animated: true) {
                        idleBadge
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.openPanel() }
                    .floatingDrag(viewModel)
                } else if app.settings.hideWhenIdle && !viewModel.geometry.isFloating {
                    Color.clear
                } else {
                    wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside) {
                        idleBadge
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.openPanel() }
                    .floatingDrag(viewModel)
                }
            case .music:
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside) {
                    EqualizerBars(color: NookTheme.music, height: 14)
                }
                .contentShape(Rectangle())
                .onTapGesture { viewModel.openPanel() }
                .floatingDrag(viewModel)
            case .track(let title, let artist):
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest, animated: viewModel.pointerInside) {
                    trackLabel(title: title, artist: artist)
                }
                .contentShape(Rectangle())
                .onTapGesture { viewModel.openPanel() }
                .floatingDrag(viewModel)
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
                        onReply: { app.handleUserText($0) },
                        onChoose: { viewModel.choose($0, $1) }
                    )
                }
            case .panel(let tab):
                expanded(nh: nh, mood: viewModel.mood(for: tab)) {
                    PanelView(viewModel: viewModel, tab: tab)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .id(contentKey)
        .transition(.notchContent)
    }

    // MARK: Rust en muziek: Nook links van de notch, iets kleins rechts

    /// Rechts in rust: wacht er een agent, dan amber; anders het aantal punten voor vandaag.
    @ViewBuilder
    private var idleBadge: some View {
        let waiting = app.hub.approvals.count + app.agentSessions.filter { $0.status == .waiting && $0.approvalID == nil }.count
        if waiting > 0 {
            HStack(spacing: 4) {
                Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                Text("\(waiting)")
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.amber)
            }
        } else if app.todayItems.count > 0 {
            Text("\(app.todayItems.count)")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.amber)
        }
    }

    private func wings<Right: View>(
        nh: CGFloat,
        nw: CGFloat,
        mood: NookMood,
        animated: Bool,
        @ViewBuilder right: () -> Right
    ) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        return HStack(spacing: 0) {
            NookOrb(mood: mood, size: 24, animated: animated)
                .frame(width: wing, height: nh)
            Spacer(minLength: 0)
            right()
                .frame(width: wing, height: nh)
        }
        .frame(height: nh)
    }

    /// Rechts van de notch: welk nummer er nu begint.
    private func trackLabel(title: String, artist: String) -> some View {
        HStack(spacing: 8) {
            EqualizerBars(color: NookTheme.music, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(NookTheme.font(11.5, .semibold))
                    .foregroundStyle(NookTheme.paper)
                if !artist.isEmpty {
                    Text(artist)
                        .font(NookTheme.font(10))
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artist.isEmpty ? "Nu: \(title)" : "Nu: \(title) van \(artist)")
    }

    // MARK: Net iets gedaan

    private func doneStrip(message: String, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: .done, size: 24)
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

    // MARK: Nook denkt mee

    /// Een korte zin onder de notch, zoals "Zal ik dit in je agenda zetten?". Wijs of klik voor het hele voorstel.
    private func nudgeStrip(line: String, nh: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NookOrb(mood: .seen, size: 24, animated: true)
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

    // MARK: Uitgeklapt: Nook links, inhoud rechts

    private func expanded<Inner: View>(
        nh: CGFloat,
        mood: NookMood,
        @ViewBuilder inner: () -> Inner
    ) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Button {
                viewModel.show(.panel(.nook))
            } label: {
                NookOrb(mood: mood, size: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("notch.goToHome"))
            inner()
        }
        .padding(.top, nh + 14)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .overlay(alignment: .top) {
            // Zwevend: sleep aan de bovenrand om het paneel te verplaatsen.
            if viewModel.geometry.isFloating {
                Color.clear
                    .frame(height: nh)
                    .contentShape(Rectangle())
                    .floatingDrag(viewModel)
            }
        }
    }
}

/// Eén stipje per actieve agent, in de kleur van zijn toestand. Wacht er een op je, dan knippert die zacht.
private struct AgentDots: View {
    let sessions: [AgentSession]

    var body: some View {
        let shown = Array(sessions.prefix(4))
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.55 + 0.45 * abs(sin(t * 2.4))
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
    /// In zwevende stand kun je Nook aan dit onderdeel verslepen. Tikken blijft gewoon werken.
    func floatingDrag(_ viewModel: NotchViewModel) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in if viewModel.geometry.isFloating { viewModel.onDragMoved?() } }
                .onEnded { _ in if viewModel.geometry.isFloating { viewModel.onDragEnded?() } }
        )
    }
}
