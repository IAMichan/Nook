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
                case .superseded(let id, let inner):
                    walk(inner, inside: inside + ["superseded:" + id.uuidString])
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
/// rows on its own, so a streaming reply redraws this spacer and not the conversation around it.
///
/// The room comes from the distance between the message (`pinProbe`) and the end of its rows (`TurnPinSpacer`), both
/// measured in the conversation's own coordinate space while they are laid out; the view then only scrolls to its end.
/// It never scrolls to an offset worked out from the conversation's height: in a lazy stack that height is an estimate,
/// and such a scroll could land where no row was drawn, leaving the conversation blank until you scrolled.
@MainActor
final class TurnPinRoom: ObservableObject {
    /// The name of the conversation's coordinate space (on its lazy stack), where `pinProbe` and `TurnPinSpacer` measure.
    static let space = "timeline"

    @Published private(set) var height = 0.0
    /// The row held, for `pinProbe`.
    private(set) var row: String?
    /// Whether a row is held now; `row` stays after `release` (dropping the probe would rebuild that row).
    private(set) var holding = false
    /// Where the held row and the end of the conversation stand; not published, nothing draws them.
    private var rowY: Double?
    private var endY: Double?
    private var container = 0.0

    /// Starts holding `row`, which came in at the end; the room follows once it was laid out.
    func hold(row: String) {
        self.row = row
        holding = true
        rowY = nil
        recompute()
    }

    func update(_ frame: ScrollFrame) {
        guard container != frame.container else { return }
        container = frame.container
        recompute()
    }

    /// The message is no longer held: the room goes, so the conversation ends at its last row again.
    func release() {
        holding = false
        if height != 0 { height = 0 }
    }

    /// The top of the held row, in `space`.
    func measuredRow(_ y: Double) {
        rowY = y
        recompute()
    }

    /// Where the conversation's rows end (the top of the room), in `space`.
    func measuredEnd(_ y: Double) {
        endY = y
        recompute()
    }

    private func recompute() {
        guard holding, let rowY, let endY else { return }
        let next = TurnPin(below: endY - rowY).room(container: container).rounded()
        if next != height { height = next }
    }
}

extension View {
    /// Reports where this row of a conversation stands while it is the one `room` holds near the top.
    func pinProbe(_ id: String, room: TurnPinRoom) -> some View {
        modifier(PinProbe(active: room.row == id, room: room))
    }
}

/// The room under a held message, at the end of the conversation's rows. It reports where those rows end (its own
/// top, so its height does not feed back into it); in the conversation's own space that only changes when the rows do,
/// not on every frame of a scroll.
struct TurnPinSpacer: View {
    @ObservedObject var room: TurnPinRoom

    var body: some View {
        Color.clear
            .frame(height: room.height)
            .onGeometryChange(for: Double.self) { $0.frame(in: .named(TurnPinRoom.space)).minY } action: { room.measuredEnd($0) }
    }
}

private struct PinProbe: ViewModifier {
    let active: Bool
    let room: TurnPinRoom

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: Double.self) { $0.frame(in: .named(TurnPinRoom.space)).minY } action: { room.measuredRow($0) }
        } else {
            content
        }
    }
}

extension View {
    /// Brings a lazy conversation back when it stands still with none of its rows in view. A lazy stack places rows it
    /// has not measured yet by estimate; after a resize (a side panel opening narrows every row), a jump, or rows that
    /// turned out shorter than guessed, the scroll view could rest on a stretch where it drew no row at all, and the
    /// conversation stayed black until you scrolled. `recover` gets the last row that was in view (nil if none was) and
    /// scrolls there; it runs again, with nil, when the first try left the view blank.
    func recoversBlankRows<ID: Hashable>(_ type: ID.Type, rows: Int, idle: @escaping () -> Bool,
                                         recover: @escaping (ID?) -> Void) -> some View {
        modifier(BlankRowsGuard(rows: rows, idle: idle, recover: recover))
    }
}

/// What `BlankRowsGuard` saw; not state any view draws from.
@MainActor
private final class BlankRowsWatch<ID: Hashable> {
    var visible = true
    var last: ID?
    var check: Task<Void, Never>?
}

private struct BlankRowsGuard<ID: Hashable>: ViewModifier {
    let rows: Int
    let idle: () -> Bool
    let recover: (ID?) -> Void
    @State private var watch = BlankRowsWatch<ID>()

    func body(content: Content) -> some View {
        content
            .onScrollTargetVisibilityChange(idType: ID.self, threshold: 0) { ids in
                watch.visible = !ids.isEmpty
                if let first = ids.first {
                    watch.last = first
                    watch.check?.cancel()
                    watch.check = nil
                    return
                }
                guard rows > 0, watch.check == nil else { return }
                watch.check = Task { @MainActor in
                    // Ended on its own, not replaced: the next blank may start a new check.
                    defer { if !Task.isCancelled { watch.check = nil } }
                    var tries = 0
                    // A fast scroll can pass a moment with no row in view: only a view at rest that stays blank is broken.
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, !watch.visible else { return }
                        guard idle() else { continue }
                        recover(tries == 0 ? watch.last : nil)
                        tries += 1
                        if tries == 3 { return }
                    }
                }
            }
            .onDisappear { watch.check?.cancel() }
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
