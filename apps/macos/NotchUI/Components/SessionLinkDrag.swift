import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A session row dragged out of the Agents list carries its `SessionLink`. Dropped in an agent's text, the text view
/// inserts the link and the composer turns it into the session's chip; dropped on the rest of the composer, `receive`
/// does it. Elsewhere (another app, a note) it is just the link.
@MainActor
enum SessionLinkDrag {
    /// The session being dragged in Nook now: a drop on the composer's frame is only taken for it, so a web link dragged
    /// in from a browser is left alone.
    fileprivate(set) static var current: SessionLink?

    /// The drop types a composer for an agent adds for session rows.
    static let types: [UTType] = [.url]

    /// How far the pointer moves with the button down before a press becomes a drag. A click on a trackpad often moves
    /// the pointer a point or two; with SwiftUI's own `onDrag` that already started a drag and the click was lost.
    /// As far as a sweep (`RowSweep`) waits, so a press on a row's button that moves goes to the sweep.
    static let threshold: CGFloat = 6

    /// Starts dragging the session from `event` (the mouse-dragged event that passed `threshold`). `grab` is where in the
    /// row the pointer went down, from the row's top-left corner, so the dragged chip sits under the pointer there.
    static func begin(id: String, title: String, event: NSEvent, grab: CGPoint) -> Bool {
        guard let url = SessionLink.build(id: id, title: title), let link = SessionLink.parse(url),
              let window = event.window, let view = window.contentView else { return false }
        current = link
        // A link (a composer, a browser, a note) and its text (anything that only takes text).
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = chipImage(title: link.title, dark: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let size = image?.size ?? CGSize(width: 1, height: 1)
        let pointer = view.convert(event.locationInWindow, from: nil)
        // The chip's left edge where the row's is, as far as it fits, level with the pointer.
        let x = pointer.x - min(max(grab.x, 0), max(size.width - 12, 0))
        let y = pointer.y - size.height / 2
        dragging.setDraggingFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), contents: image)
        view.beginDraggingSession(with: [dragging], event: event, source: DragSource.shared)
        return true
    }

    /// What follows the pointer: the session's title as the chip it becomes in a composer.
    private static func chipImage(title: String, dark: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: SessionLinkDragChip(title: title)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    /// The drag's source: a link may be copied or linked anywhere; inside Nook the composer takes it.
    private final class DragSource: NSObject, NSDraggingSource {
        static let shared = DragSource()

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .link, .generic]
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Dropped nowhere that took it: a later drop of a web link on the composer is not taken for this session.
            if operation.isEmpty { MainActor.assumeIsolated { SessionLinkDrag.current = nil } }
        }
    }

    /// Takes a dragged session row: true when one was dropped (the chip is added once its link is read).
    static func receive(_ providers: [NSItemProvider], add: @escaping (SessionLink) -> Void) -> Bool {
        guard current != nil,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        current = nil
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                // The link itself decides which session: the drag that started in Nook only said one may come.
                if let url, let link = SessionLink.parse(url) { add(link) }
            }
        }
        return true
    }
}

/// The chip a dragged session row shows under the pointer.
private struct SessionLinkDragChip: View {
    let title: String

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: "link")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textTertiary)
            Text(title)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: 280)
        .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.surface))
        .overlay(NookTheme.shape(NookTheme.Radius.control).stroke(NookTheme.paper.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

extension View {
    /// Makes a session row draggable as its link (sessions Nook runs only: other rows pass nil and are not dragged).
    /// The drag starts only once the pointer moved `SessionLinkDrag.threshold` with the button down, so a click that
    /// wobbles a little stays the row's click. `unless` holds it back when the press went to something else of the row
    /// (a sweep started on its buttons). `onStart` runs once the drag began: what floats over the composer (the command
    /// palette) gets out of the way so the drop can land there.
    @ViewBuilder
    func sessionLinkDrag(id: String?, title: String, unless: (() -> Bool)? = nil, onStart: (() -> Void)? = nil) -> some View {
        if let id {
            modifier(SessionLinkDragGesture(id: id, title: title, unless: unless, onStart: onStart))
        } else {
            self
        }
    }
}

/// The press-and-move behind `sessionLinkDrag`. Alongside the row's own click, not instead of it: a press that does not
/// travel `threshold` never becomes a drag. Once the drag runs, AppKit has the mouse and the row never sees it come up.
private struct SessionLinkDragGesture: ViewModifier {
    let id: String
    let title: String
    let unless: (() -> Bool)?
    let onStart: (() -> Void)?
    /// Resets by itself when the press ends or is taken over, so the next press can drag again.
    @GestureState private var started = false
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: SessionLinkDrag.threshold, coordinateSpace: .global)
                .updating($started) { value, started, _ in
                    guard !started else { return }
                    started = true
                    guard let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return }
                    let grab = CGPoint(x: value.startLocation.x - frame.minX, y: value.startLocation.y - frame.minY)
                    let id = id, title = title, unless = unless, onStart = onStart
                    // On the next turn: a sweep that this press started on the row's buttons has said so by then.
                    DispatchQueue.main.async {
                        guard unless?() != true, NSEvent.pressedMouseButtons & 1 == 1 else { return }
                        if SessionLinkDrag.begin(id: id, title: title, event: event, grab: grab) { onStart?() }
                    }
                })
    }
}
