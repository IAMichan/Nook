import SwiftUI

/// Which closed block (group, fold) hides which event, so a match inside one can open it.
/// An event maps to the keys of every block around it, outermost first.
enum TimelineContainers {
    static func keys(_ blocks: [TimelineBlock]) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        func walk(_ blocks: [TimelineBlock], inside: [String]) {
            for block in blocks {
                switch block {
                case .event: break
                case .tools(let id, let events, _):
                    let path = inside + ["group:" + id.uuidString]
                    for event in events { result[event.id] = path }
                case .fold(let id, _, let inner, _):
                    let path = inside + ["fold:" + id.uuidString]
                    for case .event(let event) in inner { result[event.id] = path }
                    for case .tools(let gid, let events, _) in inner {
                        for event in events { result[event.id] = path + ["group:" + gid.uuidString] }
                    }
                }
            }
        }
        walk(blocks, inside: [])
        return result
    }
}

/// "Find in session" (⌘F): a small bar on top of the timeline with the match count and previous/next. Return goes to
/// the next match, Shift-Return to the previous one, Escape closes. A stacked diff's find uses the same bar.
struct TimelineFindBar: View {
    @Binding var query: String
    let state: TimelineSearchResult.State
    /// How many matches there are.
    let count: Int
    let current: Int?
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    init(query: Binding<String>, result: TimelineSearchResult, current: Int?, previous: @escaping () -> Void,
         next: @escaping () -> Void, close: @escaping () -> Void) {
        self.init(query: query, state: result.state, count: result.matches.count, current: current, previous: previous,
                  next: next, close: close)
    }

    init(query: Binding<String>, state: TimelineSearchResult.State, count: Int, current: Int?,
         previous: @escaping () -> Void, next: @escaping () -> Void, close: @escaping () -> Void) {
        _query = query
        self.state = state
        self.count = count
        self.current = current
        self.previous = previous
        self.next = next
        self.close = close
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "magnifyingglass").font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
            TextField(tr("timeline.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .focused($focused)
                .onSubmit(next)
                // Shift-Return steps back; a plain Return goes on to `onSubmit`.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    previous()
                    return .handled
                }
            Text(label)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(state == .noResults || state == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                .monospacedDigit()
            button("chevron.up", tr("timeline.search.previous"), previous)
            button("chevron.down", tr("timeline.search.next"), next)
            button("xmark", tr("button.close"), close)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .cardBackground(NookTheme.smoke, stroke: NookTheme.line2, radius: NookTheme.Radius.card, style: .continuous)
        .onAppear { focused = true }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private var label: String {
        switch state {
        case .idle, .searching: return ""
        case .noResults: return tr("timeline.search.none")
        case .failed: return tr("timeline.search.tooLong")
        case .results:
            guard let current, current < count else { return "0/\(count)" }
            return "\(current + 1)/\(count)"
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, help, height: 20, width: 20, action)
    }
}

/// "Scroll to end" shown while you read earlier output and the agent keeps going.
struct TimelineToEndPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(NookTheme.font(10, .bold))
                Text(tr("timeline.toEnd")).font(NookTheme.TextStyle.label)
            }
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 28)
            .background(Capsule().fill(NookTheme.smoke))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The room under a reply that lets the message you sent stand near the top of the view (`TurnPin`). It follows the
/// scroll view's size on its own, so a streaming reply redraws this spacer and not the conversation around it.
///
/// The lazy rows above only learn their real height while scrolling, so where the message ends up cannot be worked out
/// ahead: `hold` brings it into view on an estimate, then `settle` measures it (`pinProbe`) a few times and the view
/// scrolls to that exact offset. Measuring never scrolls by itself: that fed back into itself without end.
@MainActor
final class TurnPinRoom: ObservableObject {
    /// The name of the scroll view's coordinate space, where `pinProbe` measures.
    static let space = "timeline"

    @Published private(set) var height = 0.0
    /// The row held, for `pinProbe`.
    private(set) var row: String?
    /// Where that row stands in the view; not published, nothing draws it.
    var rowY: Double?
    private var pin: TurnPin?

    /// Starts holding `row`, which came in at the end of `frame`.
    func hold(row: String, in frame: ScrollFrame) {
        self.row = row
        rowY = nil
        pin = TurnPin(messageTop: frame.content - height)
        update(frame)
    }

    func update(_ frame: ScrollFrame) {
        guard let pin else { return }
        let next = pin.room(in: frame, current: height).rounded()
        if next != height { height = next }
    }

    /// The message is no longer held: the room goes, so the conversation ends at its last row again. `row` stays until
    /// the next `hold`, as dropping the probe would rebuild that row.
    func release() {
        pin = nil
        if height != 0 { height = 0 }
    }

    /// Measures the row and makes room for it. The offset to scroll to; nil until it was laid out.
    func settle(in frame: ScrollFrame) -> Double? {
        guard let rowY else { return nil }
        let measured = TurnPin(messageTop: frame.offset + rowY)
        pin = measured
        update(frame)
        return measured.messageTop - measured.anchorOffset
    }
}

extension View {
    /// Reports where this row of a conversation stands while it is the one `room` holds near the top.
    func pinProbe(_ id: String, room: TurnPinRoom) -> some View {
        modifier(PinProbe(active: room.row == id, room: room))
    }
}

private struct PinProbe: ViewModifier {
    let active: Bool
    let room: TurnPinRoom

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: Double.self) { $0.frame(in: .named(TurnPinRoom.space)).minY } action: { room.rowY = $0 }
        } else {
            content
        }
    }
}

extension View {
    /// The "scroll to end" pill just above this view (a composer over a conversation), without taking room from it.
    /// Centered on the conversation's column, as the composer is: the bar under it can be wider than that column (the
    /// column keeps its place in the row it shares with the side panels), and centering on the bar put the pill off to
    /// one side of the composer.
    func toEndPill(_ shown: Bool, action: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    if shown {
                        TimelineToEndPill(action: action)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                            .chatColumn()
                            .padding(.bottom, NookTheme.Spacing.md)
                    }
                }
        }
    }
}
