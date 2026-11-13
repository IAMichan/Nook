import AppKit
import SwiftUI

/// The card a list row shows on hover, as in the Claude app: a title, then a few lines with an icon each.
/// Used by the session rows in the Agents tab and the conversation rows in the Chats and Nook lists.
struct HoverCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, NookTheme.Spacing.xxs)
            content
        }
        .padding(NookTheme.Spacing.lg + NookTheme.Spacing.xxs)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .background(DropdownStyle.panel)
        // Not combined: a card can hold buttons, and those stay reachable one by one.
        .accessibilityElement(children: .contain)
    }
}

/// A line of a hover card that does something: lit under the pointer, as wide as the card, and a click closes the card
/// unless `closes` is off (an action that shows its progress or asks a question in the card itself).
struct HoverCardButton<Label: View>: View {
    let help: String
    var closes = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            if closes { dismiss() }
            action()
        } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NookTheme.Spacing.xs)
                .hoverRowFill(radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .padding(-NookTheme.Spacing.xs)
        .pointerStyle(.link)
        .help(help)
        .accessibilityHint(help)
    }
}

/// One line of a hover card: an SF Symbol and a single line of text, cut in the middle when it is too long.
struct HoverCardRow: View {
    let symbol: String
    let text: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: symbol)
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 16)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
        .nookTip(help ?? "", enabled: help != nil)
    }
}

/// The timing a list row's card shares with the cards of the other rows (`hoverCard(warm:)`): a row's card opens after a
/// shorter rest than other cards, and at once while another row's card is open or closed a moment ago, so moving down a
/// list with the cards open swaps them like tips instead of waiting at every row.
@MainActor
enum HoverCardWarmth {
    /// How long the pointer rests on a row before its card opens, when no other row's card was open just now. Longer
    /// than a tip's rest (`TooltipTiming`), so a tip on a part of the row shows first.
    nonisolated static let rowOpenDelay: Duration = .milliseconds(400)
    /// How long after a row's card closed the next row's card still opens at once.
    nonisolated static let window: TimeInterval = 0.4

    /// When the last row's card closed.
    static var lastClosedAt: Date?
    /// The row's card on screen, and how to close it when another row's card takes its place.
    static var open: (id: UUID, close: () -> Void)?
    /// The warm row currently under the pointer, so a tooltip inside it can hold the row's card back while hovered.
    static var hoveredRow: (id: UUID, update: () -> Void)?

    /// Another row's card is open, or closed less than `window` ago.
    static func isWarm(now: Date = Date()) -> Bool {
        if open != nil { return true }
        guard let lastClosedAt else { return false }
        return now.timeIntervalSince(lastClosedAt) < window
    }

    /// The pointer entered a row: another row's card still open closes now. A popover does not always say the pointer
    /// left it, so that card could stay beside its own row while the pointer rested on another one. The list stays warm,
    /// so this row's card still opens at once.
    static func rowEntered(id: UUID, update: @escaping () -> Void) {
        hoveredRow = (id: id, update: update)
        guard let open, open.id != id else { return }
        self.open = nil
        lastClosedAt = Date()
        open.close()
    }

    /// A `.nookTip` target inside the window was entered: close any open row card and hold back the hovered row's card.
    static func tooltipEntered() {
        open?.close()
        hoveredRow?.update()
    }

    /// The pointer left the `.nookTip` target: if still on a warm row, its card can now start its rest timer.
    static func tooltipExited() {
        hoveredRow?.update()
    }
}

/// Lets the click that lands beside an open hover card act at once. The card is a popover, which takes the keyboard from
/// its window; the click on a row under it then only gave the window its key status back, and a second click was needed
/// to open the row. `acceptsFirstMouse` on the window's hosting view (`NSWindow.keyIsOwnPopover`) does not cover this:
/// AppKit asks the view the click lands on, and inside a scrolling list that is a view of the scroll view's own. So
/// before AppKit hands the click on, the cards close and the window takes its key status back itself.
@MainActor
enum HoverCardClicks {
    /// The cards on screen, and how to close each.
    private static var open: [UUID: () -> Void] = [:]
    private static var monitor: Any?

    static func opened(_ id: UUID, close: @escaping () -> Void) {
        open[id] = close
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { clicked(event) }
            return event
        }
    }

    static func closed(_ id: UUID) {
        guard open.removeValue(forKey: id) != nil, open.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private static func clicked(_ event: NSEvent) {
        // A click in a card itself (its buttons) goes on as it is.
        guard let window = event.window, !isCard(window) else { return }
        let closes = Array(open.values)
        closes.forEach { $0() }
        if takesKey(appActive: NSApp.isActive, windowIsKey: window.isKeyWindow, canBecomeKey: window.canBecomeKey,
                    hasSheet: window.attachedSheet != nil) {
            window.makeKey()
        }
    }

    /// Whether the window clicked beside an open card takes the keyboard back before the click reaches it, so the click
    /// acts instead of only activating the window: while Nook is in front, never past a sheet in front of the window.
    nonisolated static func takesKey(appActive: Bool, windowIsKey: Bool, canBecomeKey: Bool, hasSheet: Bool) -> Bool {
        appActive && !windowIsKey && canBecomeKey && !hasSheet
    }

    private static func isCard(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Popover")
    }
}

/// Opens a card next to the view once the pointer rests on it a moment (at once when its delays are zero), so sweeping
/// over a list stays quiet. The card stays while the pointer is on the view or on the card, and waits a moment after it
/// left either, so you can cross the gap between them and click what the card holds. A click on the view closes it.
/// While `suppressed` (the pointer is on the row's own buttons) it stays closed: an open popover takes the first click
/// outside it to close itself, so a click on such a button would otherwise do nothing.
private struct HoverCardModifier<Card: View>: ViewModifier {
    let arrowEdge: Edge
    let suppressed: Bool
    /// How long the pointer rests before the card opens, and how long it waits after the pointer left.
    var openDelay: Duration = .milliseconds(650)
    /// Long enough to reach a card next to the row, short enough that it is gone before the next row's card comes.
    var closeDelay: Duration = .milliseconds(300)
    /// Told whether the card is open.
    var presented: Binding<Bool>? = nil
    /// A list row's card (`HoverCardWarmth`): it opens at once while another row's card is open or just closed, and
    /// closes that one when it opens.
    var warm = false
    let card: () -> Card
    /// Tells this card apart from the other rows' in `HoverCardWarmth.open`.
    @State private var id = UUID()
    @State private var hovering = false
    @State private var onCard = false
    @State private var showCard = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if warm {
                    if inside {
                        HoverCardWarmth.rowEntered(id: id, update: { update() })
                    } else if HoverCardWarmth.hoveredRow?.id == id {
                        HoverCardWarmth.hoveredRow = nil
                    }
                }
                update()
            }
            .simultaneousGesture(TapGesture().onEnded {
                delay?.cancel()
                showCard = false
            })
            .onChange(of: suppressed) { _, _ in update() }
            .onChange(of: showCard) { _, shown in
                // A popover closed by a click elsewhere never reports the pointer leaving it.
                if !shown { onCard = false }
                if shown {
                    let showCard = $showCard
                    HoverCardClicks.opened(id) { showCard.wrappedValue = false }
                } else {
                    HoverCardClicks.closed(id)
                }
                presented?.wrappedValue = shown
                if warm { noteWarm(shown: shown) }
            }
            .onDisappear {
                delay?.cancel()
                HoverCardClicks.closed(id)
                if warm, HoverCardWarmth.open?.id == id { HoverCardWarmth.open = nil }
                if warm, HoverCardWarmth.hoveredRow?.id == id { HoverCardWarmth.hoveredRow = nil }
            }
            // Only on the row under the pointer: a popover on every row of a long list was carried along while it
            // scrolled. Behind the view, at its size, so the card points at the same place.
            .background {
                if hovering || showCard {
                    Color.clear.popover(isPresented: $showCard, arrowEdge: arrowEdge) {
                        card().onHover { inside in
                            onCard = inside
                            update()
                        }
                    }
                }
            }
    }

    private func update() {
        delay?.cancel()
        let heldBack = suppressed || (warm && TooltipActivity.isPointerOnTip)
        if heldBack, !onCard {
            showCard = false
        } else if showCard {
            guard !hovering, !onCard else { return }
            guard closeDelay > .zero else { showCard = false; return }
            delay = Task { @MainActor in
                try? await Task.sleep(for: closeDelay)
                if !Task.isCancelled { showCard = false }
            }
        } else if hovering {
            guard openDelay > .zero, !(warm && HoverCardWarmth.isWarm()) else { showCard = true; return }
            delay = Task { @MainActor in
                try? await Task.sleep(for: openDelay)
                if !Task.isCancelled, hovering, !(warm && TooltipActivity.isPointerOnTip) { showCard = true }
            }
        }
    }

    /// Keeps `HoverCardWarmth` up to date: one row's card at a time, and when the last one closed.
    private func noteWarm(shown: Bool) {
        if shown {
            // The previous row's card would otherwise wait out its close delay beside this one.
            if let previous = HoverCardWarmth.open, previous.id != id { previous.close() }
            let showCard = $showCard
            HoverCardWarmth.open = (id: id, close: { showCard.wrappedValue = false })
        } else {
            HoverCardWarmth.lastClosedAt = Date()
            if HoverCardWarmth.open?.id == id { HoverCardWarmth.open = nil }
        }
    }
}

/// A part of a row with a card of its own: underlined as soon as the pointer is on it, so you see which part it found
/// before the card opens. The row holds its own card back while the pointer is here or this card is open, also on the
/// way from here to the card.
private struct DetailCardModifier<Card: View>: ViewModifier {
    let onDetail: Binding<Bool>
    let card: () -> Card
    @State private var hovering = false
    @State private var cardOpen = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                NookDivider(tint: NookTheme.textSecondary)
                    .offset(y: NookTheme.Spacing.xxs)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { inside in
                withAnimation(NookTheme.hover) { hovering = inside }
                onDetail.wrappedValue = inside || cardOpen
            }
            .onChange(of: cardOpen) { _, open in onDetail.wrappedValue = hovering || open }
            .modifier(HoverCardModifier(arrowEdge: .trailing, suppressed: false, presented: $cardOpen, card: card))
    }
}

extension View {
    /// A part of a row with its own card (the changed files, the pull request): while the pointer is on it, `onDetail`
    /// is set so the row holds its own card back, and this part's card opens instead. Off: the view as it is.
    @ViewBuilder
    func detailCard<Card: View>(enabled: Bool = true, onDetail: Binding<Bool>,
                                @ViewBuilder _ card: @escaping () -> Card) -> some View {
        if enabled {
            modifier(DetailCardModifier(onDetail: onDetail, card: card))
        } else {
            self
        }
    }

    /// Shows `card` in a popover after the pointer rests on this view for a moment, unless `suppressed`. `instant`
    /// opens it as soon as the pointer is on the view and closes it as soon as it left, for a card that holds nothing
    /// to click (the prompt behind a mark on the conversation's rail). `warm` is for a list row's card: a shorter rest,
    /// and at once while another row's card is open or just closed (`HoverCardWarmth`).
    func hoverCard<Card: View>(arrowEdge: Edge = .trailing, suppressed: Bool = false, instant: Bool = false,
                               warm: Bool = false, @ViewBuilder _ card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(arrowEdge: arrowEdge, suppressed: suppressed,
                                   openDelay: instant ? .zero : (warm ? HoverCardWarmth.rowOpenDelay : .milliseconds(650)),
                                   closeDelay: instant ? .zero : .milliseconds(300), warm: warm && !instant, card: card))
    }
}
