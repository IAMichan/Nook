import SwiftUI

/// One clock for every animation that runs on its own for long stretches: Nook, his ring, the equalizer, the working
/// dots and spinners, the shimmer on a running step.
///
/// Each `TimelineView(.animation(minimumInterval:))` keeps its own time. Five of them at 12, 30 and 60 frames a second
/// land on different display frames, so together they asked for a frame almost every time the display had one, and
/// every frame lays out and commits the whole window they are in (four notches, the main window with a long chat).
/// On this clock every frame falls on a shared grid of 1/120 s counted from a fixed moment, a whole number of steps
/// apart: frames of different animations that coincide carry the same date and cost one update of the window. Rates
/// that divide each other (60, 30, 15, 7.5) fall entirely on each other's frames.
struct NookFrames: TimelineSchedule {
    /// Steps of the shared grid in one second.
    private static let grid = 120.0

    /// Grid steps between two frames.
    private let step: Int
    private let paused: Bool

    /// Frames at about `fps` a second, on the shared grid; one frame only (the content as it is now) while `paused`.
    init(fps: Double, paused: Bool = false) {
        step = max(1, Int((Self.grid / max(1, fps)).rounded()))
        self.paused = paused
    }

    struct Entries: Sequence, IteratorProtocol {
        fileprivate var tick: Int
        fileprivate let step: Int
        fileprivate var single: Date?
        fileprivate let paused: Bool

        mutating func next() -> Date? {
            if paused {
                defer { single = nil }
                return single
            }
            defer { tick += step }
            return Date(timeIntervalSinceReferenceDate: Double(tick) / NookFrames.grid)
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // The frame at or just before `startDate`, so the content shows at once; then every `step` on the grid.
        let now = Int((startDate.timeIntervalSinceReferenceDate * Self.grid).rounded(.down))
        return Entries(tick: now - now % step, step: step, single: startDate, paused: paused)
    }
}

extension TimelineSchedule where Self == NookFrames {
    /// Nook's shared animation clock (`NookFrames`) at about `fps` frames a second.
    static func nookFrames(fps: Double, paused: Bool = false) -> NookFrames {
        NookFrames(fps: fps, paused: paused)
    }
}

/// Draws `content` in a hosting view of its own: its frames update only this small SwiftUI graph and layer tree, not the
/// window it sits in. Without it, each frame of Nook or his ring laid out and committed the whole window (the open panel,
/// the main window with a long transcript or chat), many times a second. It takes no clicks or hover: those stay with
/// the views around it, so give the place it covers a `contentShape` there.
struct SeparateGraph<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> PassThroughHostingView<Content> {
        let host = PassThroughHostingView(rootView: content)
        // SwiftUI around it decides its size; it does not ask for one of its own.
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: PassThroughHostingView<Content>, context: Context) {
        host.rootView = content
    }
}

/// A hosting view that lets every click and hover through to the views behind it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Where you look

/// Which screen and which of Nook's windows the pointer is over. Published only when that changes, not on every move.
@MainActor
final class PointerWhere: ObservableObject {
    static let shared = PointerWhere()

    @Published private(set) var screen: CGDirectDisplayID?
    /// The window number of Nook's own window under the pointer; nil over another app or the desktop.
    @Published private(set) var window: Int?

    /// The pointer moved (`NotchController`'s monitors call this for every move, in Nook and outside it).
    func moved() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.flatMap(Self.displayID)
        if screen != self.screen { self.screen = screen }
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        let window = NSApp.windows.contains { $0.windowNumber == number } ? number : nil
        if window != self.window { self.window = window }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension EnvironmentValues {
    /// The pointer is where this view is: on the screen of its notch, or over its window. Elsewhere the animations that
    /// run on their own draw at `EnergyPlan.unattendedFrameRate`.
    @Entry var nookAttended = true
}

extension View {
    /// Tells the views in this window whether the pointer is where they are (`nookAttended`): for a notch, on its screen;
    /// for any other window, over it. Put on the root of each window.
    func nookAttention() -> some View {
        modifier(NookAttention())
    }
}

private struct NookAttention: ViewModifier {
    @ObservedObject private var pointer = PointerWhere.shared
    @StateObject private var window = WeakWindow()

    func body(content: Content) -> some View {
        content
            .environment(\.nookAttended, attended)
            .background(WindowProbe(found: window))
    }

    private var attended: Bool {
        // Before the window is known (its first frame), as it was: at the full rate.
        guard let window = window.window else { return true }
        if window is NotchPanel {
            guard let screen = window.screen.flatMap(PointerWhere.displayID), let pointer = pointer.screen else { return true }
            return screen == pointer
        }
        return pointer.window == window.windowNumber
    }
}

/// The window a view is in, held weakly, found once the view is in one; its views learn it at once.
@MainActor
private final class WeakWindow: ObservableObject {
    weak var window: NSWindow? {
        willSet { if newValue !== window { objectWillChange.send() } }
    }
}

private struct WindowProbe: NSViewRepresentable {
    let found: WeakWindow

    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let found: WeakWindow
        init(found: WeakWindow) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found.window = window
            // The window is known now: tell the views at once instead of at the next move.
            PointerWhere.shared.moved()
        }
    }
}
