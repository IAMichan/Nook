import SwiftUI

extension View {
    /// A rounded card behind the content: `fill` inside and a 1 pt `stroke` along the edge, both on the same shape.
    /// Used for field cards (`NookTheme.field` with `NookTheme.line2`) and tinted notices (amber, coral or iris at a low
    /// opacity, with a slightly stronger stroke of the same color).
    func cardBackground<Fill: ShapeStyle, Stroke: ShapeStyle>(_ fill: Fill, stroke: Stroke, radius: CGFloat) -> some View {
        roundedBackground(fill, radius: radius).roundedStroke(stroke, radius: radius)
    }

    /// A bar above the composer (the agent's activity, side chats, sub-threads, its work): the composer tray's fill and
    /// the same hairline as the tray and the box, so everything by the composer reads as one set of cards.
    func composerStripBackground() -> some View {
        cardBackground(NookTheme.composerTray, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.card)
    }

    /// A card in a conversation (a plan, a question, a task list, a subagent): the field fill and a hairline, whatever it
    /// holds, so the conversation stays one calm column. State shows in the card's marks, not in a tinted edge.
    func conversationCard(padding: CGFloat = NookTheme.Spacing.xl) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(NookTheme.field, stroke: NookTheme.border, radius: NookTheme.Radius.conversationCard)
    }
}
