import SwiftUI

/// The card a list row shows on hover, as in the Claude app: a title, then a few lines with an icon each.
/// Used by the session rows in the Agents tab and the conversation rows in the Chat tab.
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

/// A line of a hover card that does something: lit under the pointer, as wide as the card, and a click closes the card.
struct HoverCardButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NookTheme.Spacing.xs)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                    .fill(NookTheme.rowFill(selected: false, hovering: hovering, rest: .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-NookTheme.Spacing.xs)
        .onHover { hovering = $0 }
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
            Image(systemName: symbol)
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 16)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
        .help(help ?? "")
    }
}

/// Opens a card next to the view once the pointer rests on it a moment, so sweeping over a list stays quiet. The card
/// stays while the pointer is on the view or on the card, and waits a moment after it left either, so you can cross the
/// gap between them and click what the card holds. A click on the view closes it. While `suppressed` (the pointer is on
/// the row's own buttons) it stays closed: an open popover takes the first click outside it to close itself, so a click
/// on such a button would otherwise do nothing.
private struct HoverCardModifier<Card: View>: ViewModifier {
    let arrowEdge: Edge
    let suppressed: Bool
    /// Told whether the card is open.
    var presented: Binding<Bool>? = nil
    let card: () -> Card
    @State private var hovering = false
    @State private var onCard = false
    @State private var showCard = false
    @State private var delay: Task<Void, Never>?

    private static var openDelay: Duration { .milliseconds(650) }
    /// Long enough to reach a card next to the row, short enough that it is gone before the next row's card comes.
    private static var closeDelay: Duration { .milliseconds(300) }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
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
                presented?.wrappedValue = shown
            }
            .onDisappear { delay?.cancel() }
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
        if suppressed, !onCard {
            showCard = false
        } else if showCard {
            guard !hovering, !onCard else { return }
            delay = Task { @MainActor in
                try? await Task.sleep(for: Self.closeDelay)
                if !Task.isCancelled { showCard = false }
            }
        } else if hovering {
            delay = Task { @MainActor in
                try? await Task.sleep(for: Self.openDelay)
                if !Task.isCancelled, hovering { showCard = true }
            }
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

    /// Shows `card` in a popover after the pointer rests on this view for a moment, unless `suppressed`.
    func hoverCard<Card: View>(arrowEdge: Edge = .trailing, suppressed: Bool = false,
                               @ViewBuilder _ card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(arrowEdge: arrowEdge, suppressed: suppressed, card: card))
    }
}
