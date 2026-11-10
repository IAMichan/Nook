import AppKit
import SwiftUI

/// A chat's messages for asking Nook about them (`SelectionAsk`): where each one is, so a drag from one message to
/// another picks every message between them (a message's text alone selects only within itself), and the chat around a
/// selection, which goes with the question so "what do you mean?" is asked with what it is about.
///
/// Each `ChatTranscript` has one; `SelectionAskController` finds it under the pointer.
@MainActor
final class TranscriptSelection: ObservableObject {
    /// The coordinate space of the transcript's messages, the same as its `TranscriptSelectionAnchor`'s (y going down).
    static let space = "transcript.selection"
    /// The transcripts on screen: each adds itself when its anchor is in a window.
    private static let live = NSHashTable<TranscriptSelection>.weakObjects()

    /// The messages a drag picked: two or more, or none.
    @Published private(set) var picked: Set<String> = []
    /// Every message of the chat, oldest first, and who it is with (for the lines of a private chat).
    fileprivate(set) var bubbles: [ChatBubble] = []
    fileprivate(set) var contact = ""
    /// Where each drawn message is, in `space`.
    private var frames: [String: CGRect] = [:]
    fileprivate weak var anchor: NSView? {
        didSet { if anchor != nil { Self.live.add(self) } else { Self.live.remove(self) } }
    }

    /// The window the transcript is in.
    var window: NSWindow? { anchor?.window }

    func place(_ id: String, at frame: CGRect?) {
        frames[id] = frame
    }

    /// The transcript in `window` with a message at `point` (window points), and that message.
    static func hit(in window: NSWindow, at point: NSPoint) -> (chat: TranscriptSelection, message: String)? {
        for chat in live.allObjects {
            guard let anchor = chat.anchor, anchor.window === window else { continue }
            let local = anchor.convert(point, from: nil)
            guard anchor.visibleRect.contains(local),
                  let message = chat.drawn.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(local) })?.id
            else { continue }
            return (chat, message)
        }
        return nil
    }

    /// The chat around a selection at `point` (window points) in `window`, for the note: nil outside a chat.
    static func context(in window: NSWindow, at point: NSPoint) -> String? {
        for chat in live.allObjects {
            guard let anchor = chat.anchor, anchor.window === window else { continue }
            let local = anchor.convert(point, from: nil)
            guard anchor.visibleRect.insetBy(dx: -4, dy: -4).contains(local),
                  let message = SelectionAsk.nearest(to: local.y, in: chat.drawn) else { continue }
            return chat.context(around: [message])
        }
        return nil
    }

    static func clearAll() {
        for chat in live.allObjects where !chat.picked.isEmpty { chat.picked = [] }
    }

    /// The pointer is at `screen` (screen points) while the button is down since a press on `start`: the messages from
    /// there to the one under the pointer are picked, and none while it is still on `start`.
    func drag(from start: String, to screen: NSPoint) {
        guard let anchor, let window = anchor.window else { return }
        let local = anchor.convert(window.convertPoint(fromScreen: screen), from: nil)
        guard let end = SelectionAsk.nearest(to: local.y, in: drawn) else { return }
        let ids = Set(SelectionAsk.picked(from: start, to: end, in: bubbles.map(\.id)))
        if ids != picked { picked = ids }
    }

    /// What the picked messages say, as the chat's copied lines ("[09:54] Anna: …"), and where they are on screen.
    func pickedSelection() -> FoundSelection? {
        guard picked.count > 1, let anchor, let window = anchor.window,
              let text = SelectionAsk.offered(ChatBubble.transcript(bubbles.filter { picked.contains($0.id) }, contact: contact))
        else { return nil }
        // The bar goes above the first picked message in sight: dragged up, that is where the pointer is.
        let shown = drawn.filter { picked.contains($0.id) }.map(\.frame).filter { anchor.visibleRect.intersects($0) }
        guard let top = shown.min(by: { $0.minY < $1.minY }) else { return nil }
        let line = NSRect(x: top.minX, y: top.minY, width: top.width, height: min(top.height, 20))
        return FoundSelection(text: text, anchor: window.convertToScreen(anchor.convert(line, to: nil)), quote: nil)
    }

    /// The chat around the picked messages, for the note.
    func pickedContext() -> String? {
        context(around: Array(picked))
    }

    private func context(around messages: [String]) -> String? {
        let indices = messages.compactMap { id in bubbles.firstIndex { $0.id == id } }
        guard let first = indices.min(), let last = indices.max() else { return nil }
        let range = SelectionAsk.contextRange(first: first, last: last, count: bubbles.count)
        return SelectionAsk.chatNote(contact: contact, transcript: ChatBubble.transcript(Array(bubbles[range]), contact: contact),
                                     you: tr("chat.you"))
    }

    /// The drawn messages of this chat with where they are, oldest first.
    private var drawn: [(id: String, frame: CGRect)] {
        bubbles.compactMap { bubble in frames[bubble.id].map { (bubble.id, $0) } }
    }
}

/// Behind a transcript's messages, the size of them: the AppKit view the pointer is measured against, so a point in the
/// window is a point among the messages however far the chat is scrolled.
struct TranscriptSelectionAnchor: NSViewRepresentable {
    let selection: TranscriptSelection
    let bubbles: [ChatBubble]
    let contact: String

    final class Anchor: NSView {
        weak var selection: TranscriptSelection?
        override var isFlipped: Bool { true }
        // Clicks go to the messages above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                guard let selection else { return }
                if window != nil {
                    selection.anchor = self
                } else if selection.anchor === self {
                    selection.anchor = nil
                }
            }
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.selection = selection
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.selection = selection
        selection.bubbles = bubbles
        selection.contact = contact
        if view.window != nil, selection.anchor !== view { selection.anchor = view }
    }
}

/// The mark behind a message a drag picked. Only these marks follow the picks: the messages themselves stay as drawn.
struct TranscriptPickMark: View {
    @ObservedObject var selection: TranscriptSelection
    let id: String

    var body: some View {
        NookTheme.shape(NookTheme.Radius.card)
            .fill(selection.picked.contains(id) ? NookTheme.rowSelected : Color.clear)
            .padding(.horizontal, -NookTheme.Spacing.xs)
            .padding(.vertical, -NookTheme.Spacing.xxs)
            .allowsHitTesting(false)
    }
}
