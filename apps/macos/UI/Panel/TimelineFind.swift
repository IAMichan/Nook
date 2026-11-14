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
            Image(icon: "magnifyingglass").font(NookTheme.font(11, .medium))
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
        .cardBackground(NookTheme.smoke, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
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
                Image(icon: "arrow.down").font(NookTheme.font(10, .bold))
                Text(tr("timeline.toEnd")).font(NookTheme.TextStyle.label)
            }
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 28)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.smoke))
            .overlay(NookTheme.shape(NookTheme.Radius.control).stroke(NookTheme.line2, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.nookPlain)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The conversation's own coordinate space (on its stack of rows), where its rows report where they stand
/// (`countsAsDrawnRow`).
enum TimelineSpace {
    static let name = "timeline"
}

/// A conversation's rows in its scroll view, inside a plain stack: the older ones lazily, the last `eager` drawn in full
/// (`HistoryWindow.eagerRows`). A lazy stack can come to rest drawing none of its rows where the view stands, also at
/// its end and also after its scroll view was made again; rows drawn in full cannot, so the end of a conversation always
/// shows, and `recoversBlankRows` scrolling there always lands on rows. Each row keeps its `.id`, so a scroll to it works
/// in either part.
struct ConversationRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let eager: Int
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        let split = HistoryWindow.lazyRows(count: items.count, eager: eager)
        if split > 0 {
            LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                ForEach(items[..<split]) { row($0) }
            }
            .scrollTargetLayout()
        }
        ForEach(items[split...]) { row($0) }
    }
}

/// The rows of a lazy conversation drawn now, with where each stands in the conversation's own space
/// (`TimelineSpace.name`), kept by `countsAsDrawnRow`. Neither of a lazy stack's own reports tells a blank view:
/// `onScrollTargetVisibilityChange` reports nothing after a jump to a stretch where nothing is drawn (the rows it last
/// reported still count as in view), and a row the stack keeps drawn just outside the view counts as drawn. Where the
/// drawn rows stand, held against what the scroll view shows (`RowsInView`), is what the user sees.
@MainActor
final class DrawnRows {
    fileprivate private(set) var spans: [AnyHashable: RowsInView.Span] = [:]
    /// Rows that appeared but were not laid out yet: drawn, but not known to be anywhere.
    fileprivate private(set) var pending: Set<AnyHashable> = []
    /// How many copies of each row are drawn. A scroll view made again (`RowsInView.rebuilds`) draws its rows before the
    /// old one lets go of the same rows; without the count, the old row's `onDisappear` struck the new one off, and the
    /// conversation counted as blank (and was made again) for good.
    private var copies: [AnyHashable: Int] = [:]
    fileprivate var changed: (() -> Void)?

    var count: Int { spans.count + pending.count }

    fileprivate func appeared(_ id: AnyHashable) {
        copies[id, default: 0] += 1
        if spans[id] == nil { pending.insert(id) }
        changed?()
    }

    fileprivate func placed(_ id: AnyHashable, _ span: RowsInView.Span) {
        pending.remove(id)
        guard spans[id] != span else { return }
        spans[id] = span
        changed?()
    }

    fileprivate func disappeared(_ id: AnyHashable) {
        let left = (copies[id] ?? 1) - 1
        copies[id] = left > 0 ? left : nil
        guard left <= 0 else { return }
        pending.remove(id)
        spans[id] = nil
        changed?()
    }
}

extension View {
    /// Keeps this row of a lazy conversation in `drawn` while the lazy stack draws it, with where it stands. Its place in
    /// the conversation's own space only changes when the rows do, not on every frame of a scroll.
    func countsAsDrawnRow<ID: Hashable>(_ drawn: DrawnRows, id: ID) -> some View {
        let key = AnyHashable(id)
        return onGeometryChange(for: RowsInView.Span.self) { proxy in
            let frame = proxy.frame(in: .named(TimelineSpace.name))
            return RowsInView.Span(top: frame.minY, bottom: frame.maxY)
        } action: { drawn.placed(key, $0) }
        .onAppear { drawn.appeared(key) }
        .onDisappear { drawn.disappeared(key) }
    }

    /// Brings a lazy conversation back when it stands still with none of its rows in view. A lazy stack places rows it
    /// has not measured yet by estimate; after a resize (a side panel opening narrows every row), a jump, a finished turn
    /// that folds (or a turn that opens again) or rows that turned out shorter than guessed, the scroll view could rest
    /// on a stretch where it drew no row at all, and the conversation stayed black until you scrolled. Blank is: none of
    /// the drawn rows (`drawn`, which every row reports to with `countsAsDrawnRow`) reaches into what the scroll view
    /// shows. `recover` gets the last row that was in view (nil if none was, or on a later try) and the number of the try
    /// (0 first): from the second try on it should go to the end the hard way (drop the room held under a sent message,
    /// scroll to the last row itself), and on the tries `RowsInView.rebuilds` names make the scroll view again (a new
    /// `.id`), since a stuck lazy stack draws nothing wherever it scrolls. It keeps trying for as long as the view stays blank: a guard that gave up after a
    /// few tries left the conversation black for good. Every try is logged with where the rows and the view stood.
    func recoversBlankRows<ID: Hashable>(_ type: ID.Type, rows: Int, drawn: DrawnRows, idle: @escaping () -> Bool,
                                         recover: @escaping (_ last: ID?, _ attempt: Int) -> Void) -> some View {
        modifier(BlankRowsGuard(rows: rows, drawn: drawn, idle: idle, recover: recover))
    }
}

/// What `BlankRowsGuard` saw; not state any view draws from.
@MainActor
private final class BlankRowsWatch<ID: Hashable> {
    /// Whether the last report of rows in view named any; only for the log, the lazy stack's reports go stale.
    var reportedInView = true
    var last: ID?
    var check: Task<Void, Never>?
    /// The newest values from the view: a check that runs for a while must not scroll with rows of an older draw.
    var rows = 0
    var drawn: DrawnRows?
    /// The part of the conversation in view, in its own coordinates; zero height until the scroll view reported it.
    var top = 0.0
    var height = 0.0
    var content = 0.0
    var idle: () -> Bool = { true }
    var recover: (ID?, Int) -> Void = { _, _ in }

    /// Checks of 250 ms a blank view waits for the scroll to come to rest before it recovers anyway.
    private let restWait = 8

    var blank: Bool {
        guard let drawn else { return false }
        return RowsInView.blank(rows: rows, drawn: drawn.spans.values, top: top, height: height)
    }

    func reported(_ ids: [ID]) {
        reportedInView = !ids.isEmpty
        if let first = ids.first { last = first }
        settle()
    }

    func viewed(_ view: BlankRowsView) {
        top = view.top
        height = view.height
        content = view.content
        settle()
    }

    /// Stops a check once a row shows again, starts one when the view went blank.
    func settle() {
        guard blank else {
            check?.cancel()
            check = nil
            return
        }
        guard check == nil else { return }
        check = Task { @MainActor [weak self] in
            var attempt = 0
            var waited = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(attempt < 3 ? 250 : 1000))
                guard let self, !Task.isCancelled else { return }
                guard self.blank else {
                    self.check = nil
                    return
                }
                waited += 1
                // A fast scroll can pass a moment with no row in view: only a view at rest that stays blank is broken.
                // A scroll cut short can leave the phase on "animating" for good, so after two seconds of blank it
                // recovers whatever the phase says.
                guard self.idle() || waited >= self.restWait else { continue }
                self.log(attempt)
                self.recover(attempt == 0 ? self.last : nil, attempt)
                attempt += 1
                waited = 0
            }
        }
    }

    /// Where the rows and the view stood, so a blank conversation leaves something to go on. Numbers only.
    private func log(_ attempt: Int) {
        guard attempt < 5 || attempt % 10 == 0 else { return }
        let spans = Array(drawn?.spans.values ?? [AnyHashable: RowsInView.Span]().values)
        let nearest = spans.min { abs($0.top - top) < abs($1.top - top) }
        Log.app.notice("""
            Blank conversation, recovering (try \(attempt)): rows \(self.rows), drawn \(spans.count) + \(self.drawn?.pending.count ?? 0) unplaced, \
            view \(Int(self.top))–\(Int(self.top + self.height)) of \(Int(self.content)), nearest row \(Int(nearest?.top ?? -1))–\(Int(nearest?.bottom ?? -1)), \
            reported in view \(self.reportedInView), idle \(self.idle()), rebuilds \(RowsInView.rebuilds(attempt: attempt))
            """)
    }

    func stop() {
        check?.cancel()
        check = nil
    }
}

/// The part of a conversation a scroll view shows, in the conversation's coordinates (as `ScrollFrame` measures it).
private struct BlankRowsView: Equatable {
    var top: Double
    var height: Double
    var content: Double
}

private struct BlankRowsGuard<ID: Hashable>: ViewModifier {
    let rows: Int
    let drawn: DrawnRows
    let idle: () -> Bool
    let recover: (ID?, Int) -> Void
    @State private var watch = BlankRowsWatch<ID>()

    func body(content: Content) -> some View {
        let watch = watch
        watch.rows = rows
        watch.drawn = drawn
        watch.idle = idle
        watch.recover = recover
        drawn.changed = { [weak watch] in watch?.settle() }
        return content
            .onScrollTargetVisibilityChange(idType: ID.self, threshold: 0) { watch.reported($0) }
            .onScrollGeometryChange(for: BlankRowsView.self) { geometry in
                BlankRowsView(top: geometry.contentOffset.y, height: geometry.containerSize.height,
                              content: geometry.contentSize.height)
            } action: { _, view in watch.viewed(view) }
            .onDisappear { watch.stop() }
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

extension ScrollFrame {
    /// Where `geometry`'s scroll view stands.
    init(_ geometry: ScrollGeometry) {
        self.init(offset: geometry.contentOffset.y, content: geometry.contentSize.height, container: geometry.containerSize.height,
                  insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
    }
}
