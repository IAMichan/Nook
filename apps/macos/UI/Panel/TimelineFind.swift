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
    /// While you read back (not following the end): no row moves from the part drawn in full into the lazy part
    /// (`HistoryWindow.heldSplit`). A row that moves is made again and its height guessed, so every move of the split
    /// changed the height of everything above what you read, by thousands of points at once in a long session.
    var holdsSplit = false
    /// Learns where the part drawn in full starts (`RowsInView.blank`): the blank guard leaves that part alone.
    var drawn: DrawnRows? = nil
    /// While you follow a working agent: what it writes grows into view in a glide (`GlidesGrowth`), not a line or a
    /// whole step at once: the last row, the one it writes into.
    var glidesGrowth = false
    /// The agent works: a row that comes in grows in from nothing (`GlidesGrowth.growsIn`).
    var working = false
    @ViewBuilder let row: (Item) -> Row
    /// The first row drawn in full while the split is held; not state any view draws from.
    @State private var firstEager = Unobserved<Item.ID?>(nil)

    var body: some View {
        let split = lazyRows()
        if split > 0 {
            LazyVStack(alignment: .leading, spacing: spacing) {
                ForEach(items[..<split]) { row($0) }
            }
            .scrollTargetLayout()
        }
        // Rows moving into the lazy part make the rows drawn in full shorter: that lets go too.
        let last = items.last?.id
        HeldHeightStack(spacing: spacing, holds: holdsHeight, key: holdKey &* 31 &+ split) {
            ForEach(items[split...]) { item in
                row(item).modifier(GlidesGrowth(active: glidesGrowth && item.id == last, growsIn: working))
            }
        }
        .onGeometryChange(for: Double.self) { $0.frame(in: .named(TimelineSpace.name)).minY } action: { drawn?.drawnFrom = $0 }
    }

    /// How many of the rows go into the lazy stack, held while you read back (`holdsSplit`).
    private func lazyRows() -> Int {
        let natural = HistoryWindow.lazyRows(count: items.count, eager: eager)
        let held = holdsSplit ? firstEager.value.flatMap { id in items.firstIndex { $0.id == id } } : nil
        let split = HistoryWindow.heldSplit(natural: natural, held: held)
        firstEager.value = split < items.count ? items[split].id : nil
        return split
    }
}

/// After a jump to the end, as t3code's `settleListScroll`: the lazy rows learn their real height only as they are laid
/// out, so one scroll from far up lands short of the end, and a few scrolls at set times (as before) still missed it when
/// a pass took longer. Checks each frame instead, for up to a second, and scrolls again while the view is not at its
/// end; done once it stood there for two frames with the content no longer changing, or once you scroll away
/// (`following`).
@MainActor
final class EndSettle {
    /// The most frames it checks.
    static let frames = 60
    private let following: () -> Bool
    private let frame: () -> ScrollFrame?
    private let scroll: () -> Void
    private var left = EndSettle.frames
    private var stable = 0
    private var content: Double?
    private var timer: Timer?

    private init(following: @escaping () -> Bool, frame: @escaping () -> ScrollFrame?, scroll: @escaping () -> Void) {
        self.following = following
        self.frame = frame
        self.scroll = scroll
    }

    /// Scrolls with `scroll` now and checks on each frame after, while `following`; `frame` is where the view stands.
    static func run(following: @escaping () -> Bool, frame: @escaping () -> ScrollFrame?, scroll: @escaping () -> Void) {
        let settle = EndSettle(following: following, frame: frame, scroll: scroll)
        scroll()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { settle.check() }
        }
        settle.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func check() {
        left -= 1
        guard left > 0, following() else { return stop() }
        guard let frame = frame() else { return scroll() }
        let atEnd = frame.maxOffset - frame.offset <= 0.5
        stable = atEnd && frame.content == content ? stable + 1 : 0
        content = frame.content
        if stable >= 2 { return stop() }
        if !atEnd { scroll() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The last row of a conversation, growing to its new height in a glide while `active`, as t3code animates its scroll
/// to the end while the agent works. The view holds its end as the row grows (`defaultScrollAnchor`), so each new line or
/// part of the answer moved what you read up at once, 30 to 70 pt in a frame. Now the row keeps the height it had (what
/// is new is cut off under it) and grows to the new one a part of the way each frame, and the view glides with it; a
/// row that comes in while the agent works grows in from nothing. Stepped, not animated: an animated height is laid out
/// at its end at once, and the view jumped there all the same. A row that gets shorter or wider does so at once, as
/// does one that is no longer the last (it is all there by then, or nearly).
private struct GlidesGrowth: ViewModifier {
    let active: Bool
    /// A row that comes in now grows in from nothing; not one that comes as the agent finishes (its card, its footer),
    /// whose glide the glide to the end would cut short.
    var growsIn = true
    @State private var growth = GrowthSteps()

    func body(content: Content) -> some View {
        let height = active ? growth.shown.map { CGFloat($0) } : nil
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { growth.measured($0, gliding: active, growsIn: growsIn) }
            .frame(height: height, alignment: .top)
            .clipShape(GrowthClip(cuts: height != nil))
    }
}

/// The height `GlidesGrowth` draws, a part of the way to the row's own height each frame.
@MainActor
@Observable
private final class GrowthSteps {
    /// The height drawn; 0 for a row that came in gliding, before it is measured.
    private(set) var shown: Double?
    @ObservationIgnored private var target = 0.0
    @ObservationIgnored private var width: Double?
    @ObservationIgnored private var timer: Timer?
    /// The part of what is left that each frame grows by: most of the way in about a tenth of a second.
    private static let part = 0.25
    private static let stride = 24.0
    private static let lag = 400.0

    func measured(_ size: CGSize, gliding: Bool, growsIn: Bool) {
        let height = Double(size.height)
        let newWidth = Double(size.width)
        let from = shown ?? (gliding && growsIn && width == nil ? 0 : nil)
        defer { target = height; width = newWidth }
        guard gliding, let from, width.map({ abs($0 - newWidth) < 0.5 }) ?? true, height > from + 0.5 else {
            stop(at: height)
            return
        }
        shown = from
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let shown else { return stop(at: target) }
        let left = target - shown
        guard left > 1 else { return stop(at: target) }
        // At most `stride` a frame, as a scroll would move; never further behind than `lag`, when the agent writes faster.
        let step = min(max(1, (left * Self.part).rounded()), Self.stride)
        self.shown = shown + max(step, left - Self.lag)
    }

    private func stop(at height: Double) {
        timer?.invalidate()
        timer = nil
        if shown != height { shown = height }
    }
}

/// Cuts off what is under the row's drawn height (`GlidesGrowth`), never what sticks out to its sides.
private struct GrowthClip: Shape {
    let cuts: Bool

    func path(in rect: CGRect) -> Path {
        Path(cuts ? rect.insetBy(dx: -1000, dy: 0) : rect.insetBy(dx: -1000, dy: -100_000))
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
    /// Where each row last said it stands, also once it is no longer drawn. A row that scrolls back into view is often
    /// the lazy stack's own row again, and its `onGeometryChange` only reports a place that differs from the one it
    /// reported last: without this, a row you scrolled back to stayed "not known to be anywhere", the view counted as
    /// blank with rows on screen, and the guard pulled it to the end while you read.
    private var known: [AnyHashable: RowsInView.Span] = [:]
    /// How many copies of each row are drawn. A scroll view made again (`RowsInView.rebuilds`) draws its rows before the
    /// old one lets go of the same rows; without the count, the old row's `onDisappear` struck the new one off, and the
    /// conversation counted as blank (and was made again) for good.
    private var copies: [AnyHashable: Int] = [:]
    fileprivate var changed: (() -> Void)?
    /// The new turn held near the top learns where its message stands from here (`TurnPinRoom`).
    weak var pin: TurnPinRoom?
    /// Where the rows drawn in full start (`ConversationRows`); everything from there down is always drawn.
    fileprivate var drawnFrom: Double? {
        didSet { if drawnFrom != oldValue { changed?() } }
    }

    var count: Int { spans.count + pending.count }

    /// The row is drawn; returns where it stands when that is known already (it was laid out before and did not move).
    @discardableResult
    fileprivate func appeared(_ id: AnyHashable) -> RowsInView.Span? {
        copies[id, default: 0] += 1
        if spans[id] == nil {
            if let span = known[id] { spans[id] = span } else { pending.insert(id) }
        }
        changed?()
        return spans[id]
    }

    fileprivate func placed(_ id: AnyHashable, _ span: RowsInView.Span) {
        pin?.rowPlaced(id, top: span.top)
        pending.remove(id)
        known[id] = span
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
            reading?.place(key, top: $0.top, height: $0.bottom - $0.top)
        }
        .onAppear {
            if let span = drawn.appeared(key) { reading?.place(key, top: span.top, height: span.bottom - span.top) }
        }
        .onDisappear {
            drawn.disappeared(key)
            reading?.place(key, top: nil)
        }
    }

    /// Tells `reading` where this stack of rows (the view in `TimelineSpace.name`) starts within the scroll view's
    /// content (the view in `TimelineSpace.content`), and how wide it is (a tall row wraps anew at another width).
    func readingStackTop(_ reading: TimelineReadingAnchor) -> some View {
        onGeometryChange(for: Double.self) { $0.frame(in: .named(TimelineSpace.content)).minY } action: { reading.stack(at: $0) }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { reading.width($0) }
    }

    /// Lets `reading` scroll the conversation's scroll view; on a view inside its content. `wheel` gets each scroll-wheel
    /// or trackpad step of yours over the conversation (its vertical delta, above zero toward the start) before the view
    /// moves by it (`ScrollModel.releases(wheel:)`), and each key that scrolls it (`ScrollKey`) as a step of 1 or -1.
    ///
    /// `followsEnd` says whether the conversation follows its end now (not while finding or during a scroll of the
    /// view's own): while it does, the AppKit scroll view is put back at its end the moment it leaves it without you
    /// (`ScrollModel.lostEnd`), before that frame is drawn.
    func readingScroller(_ reading: TimelineReadingAnchor?, followsEnd: @escaping () -> Bool = { false },
                         wheel: @escaping (Double) -> Void = { _ in }) -> some View {
        background(ReadingAnchorScroller(reading: reading, followsEnd: followsEnd, wheel: wheel).frame(width: 0, height: 0))
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
        return RowsInView.blank(rows: rows, drawn: drawn.spans.values, top: top, height: height, drawnFrom: drawn.drawnFrom)
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
            view \(Int(self.top))–\(Int(self.top + self.height)) of \(Int(self.content)), drawn in full from \(Int(self.drawn?.drawnFrom ?? -1)), nearest row \(Int(nearest?.top ?? -1))–\(Int(nearest?.bottom ?? -1)), \
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
                // From under the toolbar: `containerSize` is the height between the insets (`ScrollFrame.maxOffset`).
                BlankRowsView(top: geometry.contentOffset.y + geometry.contentInsets.top, height: geometry.containerSize.height,
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
///
/// And it holds the end while the conversation follows it, on the clip view itself (`followsEnd`). When a working
/// agent's rows move into the lazy part of the conversation (16 at a time), the content shrinks and grows back within
/// one pass. The scroll view reported itself at the new end, then its clip view went back to the offset the shrink had
/// clamped it to, thousands of points up; or the content grew under a clip view that stayed put. SwiftUI reported
/// neither (measured offscreen on 2026-11-24, `LongSessionStaysAtEnd`), so `keepEnd` never heard of it, and the view
/// stayed there until the next size change, for good once the agent paused: you scrolled down to the end and the
/// conversation jumped back up by a chunk.
private struct ReadingAnchorScroller: NSViewRepresentable {
    let reading: TimelineReadingAnchor?
    let followsEnd: () -> Bool
    let wheel: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollerProbe()
        view.wheel = wheel
        view.followsEnd = followsEnd
        view.reading = reading
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ScrollerProbe)?.wheel = wheel
        (view as? ScrollerProbe)?.followsEnd = followsEnd
        (view as? ScrollerProbe)?.reading = reading
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? ScrollerProbe)?.stopWatching()
    }

    private final class ScrollerProbe: NSView {
        weak var reading: TimelineReadingAnchor? { didSet { connect() } }
        var wheel: (Double) -> Void = { _ in }
        var followsEnd: () -> Bool = { false }
        private var monitor: Any?
        private var keyMonitor: Any?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private weak var watchedClip: NSClipView?
        private weak var watchedDocument: NSView?
        /// Where the clip view stood when it last moved.
        private var lastFrame: ScrollFrame?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
            if window == nil {
                stopWatching()
            } else {
                watchWheel()
                watchEnd()
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            monitor = nil
            keyMonitor = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            boundsObserver = nil
            frameObserver = nil
            watchedClip = nil
            watchedDocument = nil
            lastFrame = nil
        }

        private func watchWheel() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.saw(event)
                return event
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.sawKey(event)
                return event
            }
        }

        /// A key that scrolls this conversation (`ScrollKey`): Page Up and the like while the keyboard is in the
        /// conversation, not in a field or the composer, where the same keys move the caret.
        private func sawKey(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView, let window, event.window === window,
                  let responder = window.firstResponder as? NSView, responder.isDescendant(of: scrollView),
                  !((responder as? NSTextView)?.isEditable ?? false),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let step = ScrollKey.step(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) else { return }
            reading?.userStep(deltaY: step, precise: false)
            wheel(step)
        }

        /// Watches the clip view move and the content change size: while the conversation follows its end, the scroll
        /// view leaving the end by itself goes back to it at once, in the same pass, so no frame shows it. Both, as the
        /// content also grew under a clip view that stayed where it was, with no report from SwiftUI either.
        private func watchEnd() {
            guard let scrollView = enclosingScrollView else { return }
            let center = NotificationCenter.default
            let clip = scrollView.contentView
            if clip !== watchedClip {
                if let boundsObserver { center.removeObserver(boundsObserver) }
                watchedClip = clip
                lastFrame = nil
                clip.postsBoundsChangedNotifications = true
                boundsObserver = center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clipMoved() }
                }
            }
            if let document = scrollView.documentView, document !== watchedDocument {
                if let frameObserver { center.removeObserver(frameObserver) }
                watchedDocument = document
                document.postsFrameChangedNotifications = true
                frameObserver = center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clipMoved() }
                }
            }
        }

        /// The clip view moved or the content changed size.
        private func clipMoved() {
            guard let scrollView = enclosingScrollView else { return }
            // SwiftUI may give the scroll view a new document view.
            if scrollView.documentView !== watchedDocument { watchEnd() }
            let frame = Self.frame(of: scrollView)
            let old = lastFrame
            lastFrame = frame
            // Content that grew all above what you read (older messages drawn above, `growsAbove`): the view moves down
            // by as much now, before the frame is drawn, so what you read stays where it is.
            if let old, let reading, frame.content > old.content + 0.5, reading.takesGrowthAbove() {
                let delta = frame.content - old.content
                reading.shifted(by: delta)
                let clip = scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
                scrollView.reflectScrolledClipView(clip)
                return
            }
            guard let old, followsEnd(), ScrollModel.lostEnd(from: old, to: frame) else { return }
            // Moves the clip view again, which comes back here at the end.
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: frame.maxOffset))
            scrollView.reflectScrolledClipView(clip)
        }

        /// Where the scroll view stands, as SwiftUI's `ScrollGeometry` gives it (`ScrollFrame(_:)`).
        private static func frame(of scrollView: NSScrollView) -> ScrollFrame {
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            return ScrollFrame(offset: Double(clip.bounds.origin.y), content: Double(scrollView.documentView?.frame.height ?? 0),
                               container: Double(clip.bounds.height - insets.top - insets.bottom),
                               insetTop: Double(insets.top), insetBottom: Double(insets.bottom))
        }

        /// A mostly vertical step over this conversation, not over a scroll view of its own inside a row (a long
        /// command's output) that takes it.
        private func saw(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView, let window, event.window === window,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: scrollView) else { return }
            let deltaY = Double(event.scrollingDeltaY)
            var view: NSView? = hit
            while let current = view, current !== scrollView {
                if let inner = current as? NSScrollView, Self.canScroll(inner, deltaY: deltaY) { return }
                view = current.superview
            }
            reading?.userStep(deltaY: deltaY, precise: event.hasPreciseScrollingDeltas)
            wheel(deltaY)
        }

        /// Whether an inner scroll view (a long command's output) takes a step of `deltaY` itself. At its own top or
        /// bottom it does not, and the step goes on to the conversation: it used to count as the inner view's all the
        /// same, so a step up over a command's output moved the conversation while it still followed the end, and the
        /// agent's output pulled it back down under your fingers.
        private static func canScroll(_ scrollView: NSScrollView, deltaY: Double) -> Bool {
            guard let document = scrollView.documentView else { return false }
            let clip = scrollView.contentView.bounds
            let range = document.frame.height - clip.height
            guard range > 1 else { return false }
            // Above zero is toward the start; a flipped document starts at its top (y 0), an unflipped one at its maximum.
            let fromStart = document.isFlipped ? clip.minY : range - clip.minY
            return deltaY > 0 ? fromStart > 0.5 : fromStart < range - 0.5
        }

        private func connect() {
            guard let reading, let scrollView = enclosingScrollView else { return }
            reading.scroll = { [weak scrollView] y in
                guard let scrollView else { return }
                let clip = scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
            reading.currentOffset = { [weak scrollView] in scrollView.map { Double($0.contentView.bounds.origin.y) } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The moment a conversation's agent finishes, as two steps instead of one. While an agent works, the end of its
/// conversation is its answer being written and the live line under it; once it is done, the work above the answer folds
/// to "Worked for …" and under the answer come its footer and the card of what the turn changed, while the live line goes.
/// All of that in one frame, at the end the view follows, threw the answer up by about 100 pt at once (measured in
/// `AnswerStreamsSmoothly`): the view jumped the moment the agent stopped typing. Letting the end grow in an animation does
/// not help: the scroll view takes its new end at once while the rows animate, so the answer went up, down and up again.
///
/// Now the fold comes first, in the frame the agent stops (above the answer: the view holds its end, so nothing you see
/// moves), with the end still as it was while working (`settling`). In the next frame the end takes its finished look
/// while the view stays where it is (`gliding`: the view does not hold its end meanwhile), and then the view scrolls down
/// to the new end in one animation (`glidesToEnd`). Not state any view observes: the body asks it once per pass.
@MainActor
final class FinishGlide {
    private var key: AnyHashable?
    private var wasActive = false
    private var settlingKey: AnyHashable?

    /// Whether the conversation `key` (a run, a transcript, a chat) still shows its end as it did while working.
    /// `glided` is bumped to draw the finished look, and `gliding` set while the view glides to its end (only when it
    /// follows the end: read back, nothing under the answer moves what you read).
    func settling(_ key: AnyHashable, active: Bool, following: Bool, glided: Binding<Int>, gliding: Binding<Bool>) -> Bool {
        if key != self.key {
            self.key = key
            wasActive = active
            settlingKey = nil
            return false
        }
        if wasActive, !active {
            wasActive = false
            settlingKey = key
            DispatchQueue.main.async { [weak self] in
                guard let self, self.settlingKey == key else { return }
                self.settlingKey = nil
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if following { gliding.wrappedValue = true }
                    glided.wrappedValue += 1
                }
            }
            return true
        }
        wasActive = active
        if active { settlingKey = nil }
        return settlingKey == key
    }
}

extension View {
    /// After a finished agent's end took its finished look (`FinishGlide`): from where the view stands down to its new
    /// end ("bottom"), in one animation, and `gliding` lets go when it gets there.
    func glidesToEnd(after glided: Int, gliding: Binding<Bool>, proxy: ScrollViewProxy) -> some View {
        onChange(of: glided) {
            guard gliding.wrappedValue else { return }
            DispatchQueue.main.async {
                withAnimation(NookTheme.scroll, completionCriteria: .logicallyComplete) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } completion: {
                    gliding.wrappedValue = false
                }
            }
        }
    }
}

/// The room under a new turn held near the top of the view while its reply grows (`ScrollModel.Mode.pinned`, as in
/// t3code's anchored new turn): `TurnPin.room` of where the held message stands (its row's report to `DrawnRows`), where
/// the rows end (`TurnPinRoomSpacer`) and the view's height. As the reply grows the room shrinks by as much, so the
/// conversation keeps its height and nothing on screen moves. Only the spacer draws `room`; the timeline draws `holds`,
/// which changes when the room comes or goes, not with every line of the reply.
@MainActor
@Observable
final class TurnPinRoom {
    /// The room under the rows, drawn by `TurnPinRoomSpacer`.
    private(set) var room = 0.0
    /// There is room under the rows: the view does not hold its end (it would move with the room), and stays put instead.
    private(set) var holds = false
    /// The row of the held message.
    private(set) var pinned: AnyHashable?
    /// The row of the newest message, held or not; the reply grows under it.
    @ObservationIgnored private var turn: AnyHashable?
    @ObservationIgnored private var messageTop: Double?
    @ObservationIgnored private var rowsEnd: Double?
    @ObservationIgnored private var container = 0.0

    /// The newest message is the row `id`: the reply grows under it from now on.
    func track(_ id: AnyHashable) {
        guard id != turn else { return }
        turn = id
        messageTop = nil
    }

    /// Holds the row `id` near the top from now on; its room comes once it is laid out.
    func pin(_ id: AnyHashable) {
        track(id)
        guard id != pinned else { return }
        pinned = id
        update()
    }

    /// Lets go: the rows end where they end, with no room under them.
    func drop() {
        guard pinned != nil || room > 0 else { return }
        pinned = nil
        set(room: 0)
    }

    /// Another conversation: nothing held or tracked.
    func reset() {
        drop()
        turn = nil
        messageTop = nil
    }

    func rowPlaced(_ id: AnyHashable, top: Double) {
        guard id == turn, top != messageTop else { return }
        messageTop = top
        update()
    }

    fileprivate func rowsEnded(at y: Double) {
        guard y != rowsEnd else { return }
        rowsEnd = y
        update()
    }

    /// The height of the view between its toolbar and composer (`ScrollFrame.container`).
    func viewed(container: Double) {
        guard abs(container - self.container) > 0.5 else { return }
        self.container = container
        update()
    }

    private func update() {
        guard pinned != nil, let messageTop, let rowsEnd else { return }
        set(room: TurnPin.room(container: container, messageTop: messageTop, rowsEnd: rowsEnd))
    }

    private func set(room new: Double) {
        if abs(new - room) > 0.5 { room = new }
        let holding = room > 0.5
        if holding != holds { holds = holding }
    }
}

/// Where a conversation's rows end, and the room under them for a new turn held near the top (`TurnPinRoom`): put it
/// last in the rows, before the "bottom" mark, so scrolling to the end shows the held message near the top.
struct TurnPinRoomSpacer: View {
    let pin: TurnPinRoom

    var body: some View {
        Color.clear
            .frame(height: pin.room)
            .onGeometryChange(for: Double.self) { $0.frame(in: .named(TimelineSpace.name)).minY } action: { pin.rowsEnded(at: $0) }
    }
}
