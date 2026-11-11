import SwiftUI

/// Compact main action for use in chat: filled with the accent.
struct SmallPrimaryButton: View {
    let title: String
    var systemName: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemName { NookSymbol(systemName, size: 12).font(NookTheme.font(11, .semibold)) }
                // One line in its 30 pt capsule: the text beside the button gives way, not the button's title.
                Text(title).font(NookTheme.TextStyle.strong).lineLimit(1).fixedSize()
            }
            .foregroundStyle(NookTheme.onPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .roundedBackground(hovering ? NookTheme.primaryHover : NookTheme.primary, radius: NookTheme.Radius.control)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// The "OK" that closes a notice at once: the main (accent) button of a notice. With `countdown` set, a ring in it runs
/// out in that many seconds, as the notice closes by itself; it stands still while `paused` (the pointer is on the notch).
struct NookAcknowledgeButton: View {
    let title: String
    var compact: Bool = false
    var countdown: TimeInterval? = nil
    var paused: Bool = false
    /// A fixed height, e.g. to fit inside the notch's own row; nil follows `compact`.
    var height: CGFloat? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let countdown { CountdownRing(duration: countdown, paused: paused, size: compact ? 16 : 18) }
                Text(title).font(NookTheme.font(compact ? 13 : 14, .semibold))
            }
            .foregroundStyle(NookTheme.onPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, countdown == nil ? (compact ? 12 : 16) : (compact ? 7 : 9))
            .padding(.trailing, compact ? 12 : 16)
            .frame(height: height ?? (compact ? 30 : 38))
            .roundedBackground(hovering ? NookTheme.primaryHover : NookTheme.primary, radius: NookTheme.Radius.control)
            .roundedHitShape(NookTheme.Radius.control)
            .hoverLift(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small ring that empties over `duration` seconds and holds while `paused`. Starts when it appears; give it a new
/// `.id` to start over. The ring runs as one linear animation instead of a per-frame clock, so it keeps moving in the
/// notch panel and costs nothing between frames; holding snaps it to where it is, resuming animates the rest.
struct CountdownRing: View {
    let duration: TimeInterval
    var paused: Bool = false
    var size: CGFloat = 18
    /// The part of the ring still left, 1 = full.
    @State private var left: CGFloat = 1
    /// What was left when the ring last started running, and when that was; nil while held.
    @State private var runFrom: CGFloat = 1
    @State private var runningSince: Date?

    var body: some View {
        ZStack {
            Circle().stroke(NookTheme.ink.opacity(0.14), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: left)
                .stroke(NookTheme.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
        .frame(width: size, height: size)
        .onAppear {
            // A turn later, so the run does not merge into the notice's own opening animation.
            DispatchQueue.main.async { if !paused { run() } }
        }
        .onChange(of: paused) { _, now in now ? hold() : run() }
        .accessibilityHidden(true)
    }

    private func run() {
        guard runningSince == nil, left > 0 else { return }
        runFrom = left
        runningSince = Date()
        withAnimation(.linear(duration: max(duration, 0.1) * Double(left))) { left = 0 }
    }

    private func hold() {
        guard let since = runningSince else { return }
        runningSince = nil
        let now = max(0, runFrom - CGFloat(Date().timeIntervalSince(since) / max(duration, 0.1)))
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { left = now }
    }
}

/// A notice's own actions side by side in one dark bar, split by thin lines: the first reads brightest. Every notice
/// that closes by itself shows its actions this way, next to its OK (`NookNoticeEnd`).
struct NookActionBar: View {
    let actions: [NookNoticeAction]
    var compact: Bool = false
    /// A fixed height, e.g. to fit inside the notch's own row; nil follows `compact`.
    var height: CGFloat? = nil

    var body: some View {
        let barHeight = height ?? (compact ? 34 : 40)
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 {
                    Rectangle().fill(NookTheme.line2).frame(width: 1, height: min(18, barHeight - 12))
                }
                NookActionBarItem(action: action, bright: index == 0, compact: compact, height: barHeight - 6)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: barHeight)
        .background(
            NookTheme.shape(NookTheme.Radius.panel).fill(NookTheme.graphite)
                .overlay(NookTheme.shape(NookTheme.Radius.panel).strokeBorder(NookTheme.line2, lineWidth: 1))
        )
    }
}

private struct NookActionBarItem: View {
    let action: NookNoticeAction
    let bright: Bool
    let compact: Bool
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        Button(action: action.perform) {
            HStack(spacing: 6) {
                if let symbol = action.symbol {
                    Image(icon: symbol).font(NookTheme.font(compact ? 11 : 12, .semibold))
                }
                Text(action.label).font(NookTheme.font(compact ? 13 : 13.5, .semibold))
            }
            .foregroundStyle(bright || hovering ? NookTheme.paper : NookTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 10 : 14)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small borderless symbol button for a panel header or a message's actions (copy, retry, close). The label is the
/// tooltip and what VoiceOver reads.
struct ToolbarIconButton: View {
    let symbol: String
    let label: String
    var height: CGFloat = 24
    var width: CGFloat = 24
    var enabled: Bool = true
    /// A toggle that is on (a diff's display option): lit and on a quiet fill, also at rest.
    var selected: Bool = false
    /// The symbol's size: larger in a diff's toolbar, whose buttons are 28 pt.
    var symbolSize: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ label: String, height: CGFloat = 24, width: CGFloat = 24, enabled: Bool = true,
         selected: Bool = false, symbolSize: CGFloat = 11, _ action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.height = height
        self.width = width
        self.enabled = enabled
        self.selected = selected
        self.symbolSize = symbolSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(NookTheme.font(symbolSize, .medium))
                .foregroundStyle(!enabled ? NookTheme.textTertiary.opacity(0.5)
                                 : (hovering || selected ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: width, height: height)
                .roundedBackground(hovering && enabled ? NookTheme.graphite : (selected ? NookTheme.rowSelected : Color.clear),
                                   radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Copied" for a moment after a copy. `copy(_:)` puts the text on the pasteboard and raises `copied` for `hold`; a
/// second copy within that time starts the moment over instead of cutting it short. The copy buttons below hold one;
/// a button of another shape (a Settings button) keeps its own as a `@StateObject`.
@MainActor
final class CopiedMoment: ObservableObject {
    /// How long the checkmark and "Copied" stay.
    static let hold: Duration = .milliseconds(1500)
    @Published private(set) var copied = false
    private var reset: Task<Void, Never>?

    func copy(_ text: String) {
        Pasteboard.copy(text)
        reset?.cancel()
        if !copied { copied = true }
        reset = Task { [weak self] in
            try? await Task.sleep(for: Self.hold)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }
}

/// The copy button in a header, a row, or under a message: a `ToolbarIconButton` with the copy symbol that turns into a
/// checkmark, and its tooltip into "Copied", for a moment after the click. `text` is read on the click, so a long text
/// is not joined on every redraw. `showing` follows that moment, for a row that keeps the button in sight meanwhile.
struct CopyIconButton: View {
    let symbol: String
    let label: String
    let copiedLabel: String
    let height: CGFloat
    let width: CGFloat
    let showing: Binding<Bool>?
    let text: () -> String
    @StateObject private var moment = CopiedMoment()

    /// `symbol` sets the icon apart when a second copy button sits next to the plain one (a link, not the words).
    init(_ label: String, symbol: String = "doc.on.doc", copiedLabel: String? = nil, height: CGFloat = 24,
         width: CGFloat = 24, showing: Binding<Bool>? = nil, text: @escaping () -> String) {
        self.symbol = symbol
        self.label = label
        self.copiedLabel = copiedLabel ?? tr("button.copied")
        self.height = height
        self.width = width
        self.showing = showing
        self.text = text
    }

    var body: some View {
        ToolbarIconButton(moment.copied ? "checkmark" : symbol, moment.copied ? copiedLabel : label,
                          height: height, width: width) { moment.copy(text()) }
            .onChange(of: moment.copied) { _, copied in showing?.wrappedValue = copied }
    }
}

/// The copy button as a word (`SmallGhostButton`): "Copy", then "Copied" for a moment after the click.
struct CopyGhostButton: View {
    let title: String
    let copiedTitle: String
    let text: () -> String
    @StateObject private var moment = CopiedMoment()

    init(title: String? = nil, copiedTitle: String? = nil, text: @escaping () -> String) {
        self.title = title ?? tr("button.copy")
        self.copiedTitle = copiedTitle ?? tr("button.copied")
        self.text = text
    }

    var body: some View {
        SmallGhostButton(title: moment.copied ? copiedTitle : title) { moment.copy(text()) }
    }
}

/// The backdrop of a list row's hover buttons: the row's own fill behind the buttons, fading in from the left, so a long
/// title runs out softly underneath them instead of colliding with them. The fade passes clicks through to the row.
struct RowActionsBackdrop: ViewModifier {
    /// The row's current fill (`NookTheme.rowFill`).
    let fill: Color
    var fade: CGFloat = NookTheme.Spacing.xxl

    func body(content: Content) -> some View {
        content
            .padding(.leading, fade)
            .background(
                HStack(spacing: 0) {
                    LinearGradient(colors: [fill.opacity(0), fill], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                    fill
                }
                .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Lays a row's hover buttons on the row's fill, with the title fading out underneath (`RowActionsBackdrop`).
    func rowActionsBackdrop(_ fill: Color) -> some View { modifier(RowActionsBackdrop(fill: fill)) }
}

/// Compact subtle button for use in chat.
struct SmallGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .roundedBackground(hovering ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}
