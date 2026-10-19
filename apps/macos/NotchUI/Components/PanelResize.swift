import SwiftUI

extension View {
    /// Makes this side panel as wide as `width` with a drag line on `edge`: drag it to make the panel wider or narrower,
    /// double-click it to go back to `defaultWidth`. `available` is the width the panel shares with what sits next to it,
    /// which keeps `rest` of it; the width itself is the caller's, usually remembered with `@AppStorage`.
    func resizablePanel(width: Binding<Double>, defaultWidth: Double, minimum: Double, available: Double, rest: Double,
                        edge: HorizontalEdge, divider: Bool = false) -> some View {
        modifier(ResizablePanel(width: width, defaultWidth: defaultWidth, minimum: minimum, available: available,
                                rest: rest, edge: edge, divider: divider))
    }
}

private struct ResizablePanel: ViewModifier {
    @Binding var width: Double
    let defaultWidth: Double
    let minimum: Double
    let available: Double
    let rest: Double
    let edge: HorizontalEdge
    let divider: Bool
    @State private var dragStart: Double?

    func body(content: Content) -> some View {
        let shown = PanelSplit.width(width, minimum: minimum, available: available, rest: rest)
        HStack(alignment: .top, spacing: 0) {
            if edge == .leading { handle(shown) }
            content.frame(width: shown)
            if edge == .trailing { handle(shown) }
        }
    }

    private func handle(_ shown: Double) -> some View {
        EmbeddedSplitHandle(
            divider: divider,
            help: "panel.resize",
            onDrag: { offset in
                let start = dragStart ?? shown
                dragStart = start
                width = PanelSplit.width(PanelSplit.dragged(from: start, offset: offset, handleOnLeading: edge == .leading),
                                         minimum: minimum, available: available, rest: rest)
            },
            onEnd: { dragStart = nil },
            onReset: { width = defaultWidth }
        )
    }
}

/// Where the resizable panels start out, and how much room the conversation beside them always keeps.
enum PanelLayout {
    /// The session list on the left of the Agents tab.
    static let agentsList: Double = 280
    /// A session's results on the right; "widen" in its header jumps to `outputsWide`.
    static let outputs: Double = 400
    static let outputsWide: Double = 620
    /// A command's terminal on the left of a session.
    static let console: Double = 400
    /// The list of Nooks beside the chat, in the notch and in the main window.
    static let chatList: Double = 200
    static let chatListWindow: Double = 260
    /// The narrowest a list beside a conversation gets.
    static let minimumList: Double = 160
    /// The narrowest a side panel gets.
    static let minimumPanel: Double = 240
    /// What a conversation keeps next to the panels.
    static let minimumConversation: Double = 360

    /// The width a panel may share with the conversation, `total` minus the other panel open beside it (with its line);
    /// 0 while the total is not known yet.
    static func room(_ total: Double, besides other: Double?) -> Double {
        guard total > 0 else { return 0 }
        return max(1, total - (other.map { $0 + PanelSplit.handle } ?? 0))
    }

    /// "Widen" in the results' header: on at the wide width or wider, and switching between the two starting widths.
    static func wide(_ width: Binding<Double>) -> Binding<Bool> {
        Binding(get: { width.wrappedValue >= outputsWide }, set: { width.wrappedValue = $0 ? outputsWide : outputs })
    }
}
