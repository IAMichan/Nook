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

/// A conversation's rows in its scroll view, all drawn in full and none in a lazy stack (`HistoryWindow.drawnStart`): a
/// lazy stack guesses the height of rows it has not laid out and corrects the guess as they come into view, which moved
/// everything above what you read by hundreds of points at once, and the conversation bounced up and down while you
/// read or scrolled. Only the rows from `from` are drawn (`RowWindow.start`): the last ones, and a page more above each
/// time you scroll near their top (`RowWindow.scrolled`). Each row keeps its `.id`, so a scroll to it works once it is
/// drawn (`RowWindow.reveal`).
struct ConversationRows<Item: Identifiable, Row: View, Footer: View>: View {
    let items: [Item]
    /// The first row drawn (`RowWindow.start`).
    let from: Int
    var spacing: CGFloat = NookTheme.Spacing.sm
    /// While an agent works: the rows never get shorter (`HeldHeight`), so its output folding away at the end does not
    /// bounce the conversation. `holdKey` lets go (a new turn, a block opened or closed).
    var holdsHeight = false
    var holdKey = 0
    /// While you follow a working agent: what it writes grows into view in a glide (`GlidesGrowth`), not a line or a
    /// whole step at once: the last row, the one it writes into.
    var glidesGrowth = false
    /// The agent works: a row that comes in grows in from nothing (`GlidesGrowth.growsIn`).
    var working = false
    @ViewBuilder let row: (Item) -> Row
    /// What stands right under the rows (the live line, a card): laid out with them, so the room a fold leaves is under
    /// it rather than between the last row and it, where it read as a stray gap in the conversation.
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        let start = min(max(0, from), items.count)
        let last = items.last?.id
        HeldHeightStack(spacing: spacing, holds: holdsHeight, key: holdKey, top: start) {
            ForEach(items[start...]) { item in
                row(item).modifier(GlidesGrowth(active: glidesGrowth && item.id == last, growsIn: working))
            }
            footer()
        }
    }
}

extension ConversationRows where Footer == EmptyView {
    init(items: [Item], from: Int, spacing: CGFloat = NookTheme.Spacing.sm, holdsHeight: Bool = false,
         holdKey: Int = 0, glidesGrowth: Bool = false, working: Bool = false,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, from: from, spacing: spacing, holdsHeight: holdsHeight, holdKey: holdKey,
                  glidesGrowth: glidesGrowth, working: working, row: row, footer: { EmptyView() })
    }
}

/// Which of a conversation's rows `ConversationRows` draws: from its first drawn row to the end. New rows at the end
/// leave the first where it is; scrolling near its top draws a page more above (`scrolled`), put in above what you read
/// in the same pass of layout (`TimelineReadingAnchor.growsAbove`); a find or a jump to a row draws down from it
/// (`reveal`). Held by the conversation in `@State`; only the first drawn row is observed.
@MainActor
@Observable
final class RowWindow {
    /// The first drawn row when it was last chosen (a page drawn above, a reveal): what draws the rows again.
    private(set) var first: AnyHashable?
    /// The first drawn row as last drawn, the rows, and how far from the end that row stood: not observed.
    @ObservationIgnored private var anchor: AnyHashable?
    @ObservationIgnored private var ids: [AnyHashable] = []
    @ObservationIgnored private var fromEnd: Int?
    @ObservationIgnored private var drawnStart = 0
    /// A page was just drawn above: the next waits until it is laid out.
    @ObservationIgnored private var growing = false
    /// A row to draw down from once it is among the rows (a find in a turn the conversation did not show yet).
    @ObservationIgnored private var revealing: AnyHashable?
    /// The conversation the rows are of: another one starts again from its last rows.
    @ObservationIgnored private var key: AnyHashable?
    /// Moves the view down by what is drawn above, in the same pass, so what you read stays put.
    @ObservationIgnored weak var reading: TimelineReadingAnchor?

    /// The index of the first drawn row of `ids`; never later than the last `minimum`. The same row as before while
    /// rows come in at the end; as far from the end as before once that row is gone. Asked once per draw of the
    /// conversation, by its body. `key` names the conversation: another one starts from its last rows.
    func start(_ ids: [AnyHashable], minimum: Int, key: AnyHashable) -> Int {
        if key != self.key {
            self.key = key
            anchor = nil
            fromEnd = nil
            revealing = nil
        }
        self.ids = ids
        let index = (anchor ?? first).flatMap { ids.firstIndex(of: $0) }
        var start = HistoryWindow.drawnStart(count: ids.count, first: index, fromEnd: fromEnd, minimum: minimum)
        if let revealing, let wanted = ids.firstIndex(of: revealing) {
            self.revealing = nil
            start = min(start, max(0, wanted - 3))
        }
        drawnStart = start
        fromEnd = ids.count - start
        anchor = start < ids.count ? ids[start] : nil
        return start
    }

    /// The view stands where `frame` says: near the top of what is drawn, a page more is drawn above it.
    func scrolled(_ frame: ScrollFrame) {
        guard !growing, drawnStart > 0, drawnStart < ids.count,
              HistoryWindow.nearDrawnTop(fromTop: frame.offset - frame.minOffset, container: frame.container) else { return }
        growing = true
        reading?.growsAbove()
        set(first: ids[HistoryWindow.earlierDrawn(from: drawnStart)])
        // Laid out in the next pass; the view reports where it stands after that.
        DispatchQueue.main.async { [weak self] in self?.growing = false }
    }

    /// Draws down from the row `id` (and a few above it), for a scroll to it; nothing when it is drawn already. Unknown
    /// rows (in turns the conversation does not show yet) are left to the turn window.
    /// True when it had to draw more: a scroll to the row waits for the next pass then.
    @discardableResult
    func reveal(_ id: AnyHashable) -> Bool {
        guard let index = ids.firstIndex(of: id) else {
            // Not among the rows yet: the turn window widens for it, and the rows are drawn down from it then.
            revealing = id
            return true
        }
        guard index < drawnStart else { return false }
        set(first: ids[max(0, index - 3)])
        return true
    }

    private func set(first id: AnyHashable) {
        anchor = id
        first = id
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
    /// The first row drawn: rows drawn above keep the room held under the rows (`HeldHeight`).
    var top = 0

    func makeCache(subviews: Subviews) -> HeldHeight { HeldHeight() }
    /// Kept when the rows change: holding across those changes is the point.
    func updateCache(_ cache: inout HeldHeight, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout HeldHeight) -> CGSize {
        let natural = stacked(proposal, subviews)
        let height = cache.height(natural: natural.height, width: proposal.width ?? -1, key: key, top: top, holds: holds)
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

/// Where the rows of a conversation stand in its own space (`TimelineSpace.name`), as `countsAsDrawnRow` reports them:
/// the new turn held near the top learns where its message stands from here (`TurnPinRoom`).
@MainActor
final class DrawnRows {
    weak var pin: TurnPinRoom?

    fileprivate func placed(_ id: AnyHashable, top: Double) {
        pin?.rowPlaced(id, top: top)
    }
}

extension View {
    /// Reports where this row of a conversation stands to `drawn`, and to `reading` when given, which holds what you read
    /// in place (`TimelineReadingAnchor`). Its place in the conversation's own space only changes when the rows do, not
    /// on every frame of a scroll.
    func countsAsDrawnRow<ID: Hashable>(_ drawn: DrawnRows, id: ID, reading: TimelineReadingAnchor? = nil) -> some View {
        let key = AnyHashable(id)
        return onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineSpace.name)) } action: { frame in
            drawn.placed(key, top: frame.minY)
            reading?.place(key, top: frame.minY, height: frame.height)
        }
        .onDisappear { reading?.place(key, top: nil) }
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
