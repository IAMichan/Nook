import AppKit
import SwiftUI

/// Nook's own cursor while it takes over a task: a small violet pointer that glides to where Nook clicks or types, so you
/// see what it does while your own pointer stays yours. It never takes a click (the window ignores the mouse) and fades
/// out when Nook has not acted for a moment.
@MainActor
final class TakeoverCursor {
    static let shared = TakeoverCursor()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model = TakeoverCursorModel()
    private static let side: CGFloat = 120

    /// Moves the cursor to `point` (screen point, top-left origin, as the accessibility layer and `UIDriver` give it).
    func move(to point: CGPoint, label: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // The pointer's tip sits at the panel's top-left corner, a little inset for the glow.
        let origin = NSPoint(x: point.x - 10, y: mainHeight - point.y - Self.side + 10)
        model.label = String(label.prefix(40))
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        model.pulse += 1
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TakeoverCursorView(model: model))
        return panel
    }
}

@MainActor
final class TakeoverCursorModel: ObservableObject {
    @Published var label = ""
    @Published var pulse = 0
}

/// The pointer itself, with what Nook acts on beside it.
struct TakeoverCursorView: View {
    @ObservedObject var model: TakeoverCursorModel
    @State private var ring = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(NookTheme.violet.opacity(ring ? 0 : 0.7), lineWidth: 2)
                .frame(width: ring ? 34 : 6, height: ring ? 34 : 6)
                .offset(x: ring ? -7 : 7, y: ring ? -7 : 7)
            Image(systemName: "cursorarrow")
                .font(NookTheme.font(22, .bold))
                .foregroundStyle(NookTheme.violet)
                .shadow(color: NookTheme.violet.opacity(0.8), radius: 6)
                .offset(x: 6, y: 6)
            if !model.label.isEmpty {
                Text(model.label)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(Capsule().fill(NookTheme.violet.opacity(0.85)))
                    .offset(x: 30, y: 30)
            }
        }
        .frame(width: 120, height: 120, alignment: .topLeading)
        .onChange(of: model.pulse) { _, _ in
            ring = false
            withAnimation(.easeOut(duration: 0.6)) { ring = true }
        }
    }
}
