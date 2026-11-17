import SwiftUI
import AppKit

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
    /// The whole content of the conversation's scroll view, where the stack of rows stands (`readingStackTop`).
    static let content = "timeline.content"
}

/// A conversation's rows in its scroll view, inside a plain stack: the older ones lazily, the last `eager` drawn in full
/// (`HistoryWindow.eagerRows`). A lazy stack can come to rest drawing none of its rows where the view stands, also at
/// its end and also after its scroll view was made again; rows drawn in full cannot, so the end of a conversation always
/// shows, and `recoversBlankRows` scrolling there always lands on rows. Each row keeps its `.id`, so a scroll to it works
/// in either part.
struct ConversationRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let eager: Int
    /// The gap between rows in the lazy part; the plain stack around it should use the same.
    var spacing: CGFloat = NookTheme.Spacing.sm
    /// While you follow a working agent: the rows drawn in full never get shorter (`HeldHeight`), so its output folding
    /// away at the end does not bounce the conversation. `holdKey` lets go (a new turn, a block opened or closed).
    var holdsHeight = false
    var holdKey = 0
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        let split = HistoryWindow.lazyRows(count: items.count, eager: eager)
        if split > 0 {
            LazyVStack(alignment: .leading, spacing: spacing) {
                ForEach(items[..<split]) { row($0) }
            }
            .scrollTargetLayout()
        }
        // Rows moving into the lazy part make the rows drawn in full shorter: that lets go too.
        HeldHeightStack(spacing: spacing, holds: holdsHeight, key: holdKey &* 31 &+ split) {
            ForEach(items[split...]) { row($0) }
        }
    }
}

/// A leading-aligned stack, as `VStack(alignment: .leading, spacing:)`, that while `holds` never comes out shorter than
/// it already was at the same width (`HeldHeight`); the room it keeps is under its rows. In a layout rather than a
/// spacer sized after the rows were measured: that would show each fold for a frame before the room came back.
struct HeldHeightStack: Layout {
    var spacing: CGFloat
    var holds: Bool
    var key: Int

    func makeCache(subviews: Subviews) -> HeldHeight { HeldHeight() }
    /// Kept when the rows change: holding across those changes is the point.
    func updateCache(_ cache: inout HeldHeight, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout HeldHeight) -> CGSize {
        let natural = stacked(proposal, subviews)
        let height = cache.height(natural: natural.height, width: proposal.width ?? -1, key: key, holds: holds)
        return CGSize(width: natural.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout HeldHeight) {
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += spacing }
            let size = subview.sizeThatFits(offer)
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
    }

    /// The rows one under the other, as a `VStack` lays them out.
    private func stacked(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGSize {
        let offer = ProposedViewSize(width: proposal.width, height: nil)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(offer)
            width = max(width, size.width)
            height += size.height + (index > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
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
    /// `reading`, when given, learns where the row starts too, to hold what you read in place (`TimelineReadingAnchor`).
    func countsAsDrawnRow<ID: Hashable>(_ drawn: DrawnRows, id: ID, reading: TimelineReadingAnchor? = nil) -> some View {
        let key = AnyHashable(id)
        return onGeometryChange(for: RowsInView.Span.self) { proxy in
            let frame = proxy.frame(in: .named(TimelineSpace.name))
            return RowsInView.Span(top: frame.minY, bottom: frame.maxY)
        } action: {
            drawn.placed(key, $0)
            reading?.place(key, top: $0.top)
        }
        .onAppear { drawn.appeared(key) }
        .onDisappear {
            drawn.disappeared(key)
            reading?.place(key, top: nil)
        }
    }

    /// Tells `reading` where this stack of rows (the view in `TimelineSpace.name`) starts within the scroll view's
    /// content (the view in `TimelineSpace.content`).
    func readingStackTop(_ reading: TimelineReadingAnchor) -> some View {
        onGeometryChange(for: Double.self) { $0.frame(in: .named(TimelineSpace.content)).minY } action: { reading.stack(at: $0) }
    }

    /// Lets `reading` scroll the conversation's scroll view; on a view inside its content. `wheel` gets each scroll-wheel
    /// or trackpad step of yours over the conversation (its vertical delta, above zero toward the start) before the view
    /// moves by it (`ScrollModel.reaction(toWheel:nearEnd:)`).
    func readingScroller(_ reading: TimelineReadingAnchor, wheel: @escaping (Double) -> Void = { _ in }) -> some View {
        background(ReadingAnchorScroller(reading: reading, wheel: wheel).frame(width: 0, height: 0))
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

/// Hands `TimelineReadingAnchor`'s scrolls to the AppKit scroll view under the conversation. Not through a
/// `ScrollPosition` binding: the binding put the view back at the offset last asked for after a step of the scroll
/// wheel (measured offscreen: every step of yours after a keep was taken back), and writing it drew the conversation
/// again. Scrolling the clip view moves the view as a wheel step does, and the scroll view reports it as usual.
///
/// It also watches the wheel over the conversation (a local event monitor, which sees a step before any view handles
/// it, also over a page or a command's output in a row): the step is what tells you scrolling apart from the rows
/// changing size under you.
private struct ReadingAnchorScroller: NSViewRepresentable {
    let reading: TimelineReadingAnchor
    let wheel: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollerProbe()
        view.wheel = wheel
        view.reading = reading
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ScrollerProbe)?.wheel = wheel
        (view as? ScrollerProbe)?.reading = reading
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? ScrollerProbe)?.stopWatching()
    }

    private final class ScrollerProbe: NSView {
        weak var reading: TimelineReadingAnchor? { didSet { connect() } }
        var wheel: (Double) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
            if window == nil { stopWatching() } else { watchWheel() }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func watchWheel() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.saw(event)
                return event
            }
        }

        /// A mostly vertical step over this conversation, not over a scroll view of its own inside a row (a long
        /// command's output) that takes it.
        private func saw(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView, let window, event.window === window,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: scrollView) else { return }
            var view: NSView? = hit
            while let current = view, current !== scrollView {
                if let inner = current as? NSScrollView, inner.hasVerticalScroller || Self.scrollsVertically(inner) { return }
                view = current.superview
            }
            wheel(Double(event.scrollingDeltaY))
        }

        private static func scrollsVertically(_ scrollView: NSScrollView) -> Bool {
            (scrollView.documentView?.frame.height ?? 0) > scrollView.contentView.bounds.height + 1
        }

        private func connect() {
            guard let reading, let scrollView = enclosingScrollView else { return }
            reading.scroll = { [weak scrollView] y in
                guard let scrollView else { return }
                let clip = scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
