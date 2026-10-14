import SwiftUI

/// De hele notch: één zwarte vorm die van maat verandert, met Nook er altijd links in.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let size = viewModel.size
        let radius = viewModel.cornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
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
            .shadow(color: Color.black.opacity(isExpanded ? 0.45 : 0), radius: 18, x: 0, y: 8)
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
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest) {
                    if app.todayItems.count > 0 {
                        Text("\(app.todayItems.count)")
                            .font(NookTheme.font(12, .semibold))
                            .foregroundStyle(NookTheme.amber)
                    }
                }
            case .music:
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest) {
                    EqualizerBars(color: NookTheme.music, height: 14)
                }
            case .track(let title, let artist):
                wings(nh: nh, nw: nw, mood: viewModel.pointerInside ? .seen : .rest) {
                    trackLabel(title: title, artist: artist)
                }
            case .done(let message):
                doneStrip(message: message, nh: nh)
            case .card(let card):
                expanded(nh: nh, mood: card.mood) {
                    CardView(
                        card: card,
                        onAction: { viewModel.perform($0) },
                        onVoice: { viewModel.startListening() },
                        onReply: { app.handleUserText($0) }
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

    private func wings<Right: View>(
        nh: CGFloat,
        nw: CGFloat,
        mood: NookMood,
        @ViewBuilder right: () -> Right
    ) -> some View {
        let wing = (viewModel.size.width - nw) / 2
        return HStack(spacing: 0) {
            NookOrb(mood: mood, size: 24)
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

    // MARK: Uitgeklapt: Nook links, inhoud rechts

    private func expanded<Inner: View>(
        nh: CGFloat,
        mood: NookMood,
        @ViewBuilder inner: () -> Inner
    ) -> some View {
        HStack(alignment: .top, spacing: 20) {
            NookOrb(mood: mood, size: 46)
            inner()
        }
        .padding(.top, nh + 14)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }
}
