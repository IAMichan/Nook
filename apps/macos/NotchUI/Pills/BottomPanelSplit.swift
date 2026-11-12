import AppKit
import Combine
import SwiftUI

/// How tall the bottom panel under a conversation is: what you dragged it to, leaving the conversation room.
enum BottomPanelLayout {
    static let standard: Double = 240
    static let minimum: Double = 120
    /// Room the conversation (its header and composer) keeps above the bottom panel.
    static let conversation: Double = 200

    static func height(_ wanted: Double, available: Double) -> Double {
        let most = max(minimum, available - conversation)
        return min(max(wanted, minimum), most)
    }
}

/// The line above the bottom panel: drag it to make the panel taller or shorter, double-click for its usual height.
struct BottomSplitHandle: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.lineBleed) private var bleed

    var body: some View {
        ZStack {
            NookDivider().bleedsHorizontally(bleed)
            Capsule()
                .fill(hovering || dragging ? NookTheme.textSecondary : NookTheme.line2)
                .frame(width: 36, height: 4)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .contentShape(Rectangle())
        // The system's resize cursor, which also stays while the pointer runs ahead of the line during a drag.
        .pointerStyle(.rowResize)
        .onHover { hovering = $0 }
        .gesture(
            // Global coordinates: the line itself moves while you drag it.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { dragging = true }
                    onDrag(Double(value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .help(tr("panel.resize"))
        .accessibilityLabel(tr("panel.resize"))
    }
}
