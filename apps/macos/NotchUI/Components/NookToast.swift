import SwiftUI
import AppKit

/// What a toast reports. The color keeps its meaning: mint is done, coral an error, amber waits on you, iris is Nook.
enum NookToastKind: Equatable {
    case success
    case error
    case warning
    case info

    var color: Color {
        switch self {
        case .success: return NookTheme.mint
        case .error: return NookTheme.coral
        case .warning: return NookTheme.amber
        case .info: return NookTheme.iris
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    /// The same result in the notch's confirmation strip, when no window or panel is open to show the toast.
    var doneTone: DoneTone {
        switch self {
        case .success, .info: return .done
        case .warning: return .waiting
        case .error: return .failed
        }
    }

    /// How long it stays by itself: an error is read more slowly than a confirmation.
    var duration: TimeInterval {
        switch self {
        case .success, .info: return 3.5
        case .warning: return 5
        case .error: return 7
        }
    }
}

/// The one button a toast may carry: the obvious next step after the result ("View PR", "Open").
struct NookToastAction {
    let title: String
    let perform: () -> Void
}

/// One short message: a title, an optional line under it, its kind, and at most one action.
struct NookToast: Identifiable, Equatable {
    let id = UUID()
    let kind: NookToastKind
    let title: String
    var detail: String?
    var duration: TimeInterval
    var action: NookToastAction?

    /// Two toasts that say the same thing; the second only restarts the first one's timer.
    func says(_ other: NookToast) -> Bool {
        kind == other.kind && title == other.title && detail == other.detail
    }

    static func == (lhs: NookToast, rhs: NookToast) -> Bool { lhs.id == rhs.id }
}

/// The one place any part of Nook reports the result of something you did: "Key saved", "Push failed", "Approved".
///
///     ToastCenter.shared.success(tr("settings.brain.keySaved"))
///     ToastCenter.shared.error(error, title: tr("toast.failed", tr("ws.quick.push")))
///
/// Where it shows: on one surface with a `.nookToastHost()` (the panel in the notch, the main window, Settings), in its
/// top-right corner under the header, and only there: the key window's, else the one you opened last. Up to
/// `ToastCenter.limit` toasts show at once as a stack: the newest in front, the older ones peeking out under it, spread
/// out while the pointer is on the stack; more wait their turn. With none of the surfaces on screen, the notch shows
/// them one at a time in its own confirmation strip (`NotchViewModel.showToast`). The same message twice only restarts
/// its timer. Errors stay longest, and every toast stays while the pointer is on the stack. Like every notice that
/// closes by itself, it ends in the OK with the countdown ring of that time (`NookNotice`).
///
/// A toast is for a result. What waits for a decision is a card or an approval (`NookNoticeActions`); a problem with a
/// form you are filling in stays next to that form; something that stays true (a disconnected account) is a status row.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    /// How many toasts a surface shows at once; the notch's strip shows one.
    static let limit = 3

    /// On screen, oldest first: the last one is in front.
    @Published private(set) var toasts: [NookToast] = []
    /// The host that shows `toasts`; nil while the notch shows them, or while nothing does.
    @Published private(set) var activeHost: UUID?

    /// The newest toast on screen.
    var current: NookToast? { toasts.last }

    /// Set by the notch: shows a toast in its confirmation strip when no host is on screen. False when it cannot now
    /// (a card or a question is open there), and the toast is then left out rather than covering what waits for you.
    var notchFallback: ((NookToast) -> Bool)?

    private struct Host {
        let id: UUID
        weak var window: NSWindow?
    }
    /// In the order they appeared: the last one on screen is where you are looking.
    private var hosts: [Host] = []
    private var queue: [NookToast] = []
    /// Runs out each toast's time while the pointer is off the stack, like the ring on its OK.
    private var clocks: [UUID: NoticeClock] = [:]
    /// The pointer is on the stack: every clock and ring holds.
    @Published private(set) var paused = false
    /// New each time a toast's time starts over (the same message again), so its ring starts over too.
    @Published private(set) var stamps: [UUID: UUID] = [:]

    /// As many as fit where they show now: a stack on a surface, one in the notch's strip.
    private var capacity: Int { activeHost == nil ? 1 : Self.limit }

    // MARK: Showing

    /// Shows a toast; `duration` nil uses the kind's own.
    func show(_ title: String, detail: String? = nil, kind: NookToastKind = .info, duration: TimeInterval? = nil,
              action: NookToastAction? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toast = NookToast(kind: kind, title: title, detail: detail?.isEmpty == false ? detail : nil,
                              duration: duration ?? kind.duration, action: action)
        if let shown = toasts.first(where: { $0.says(toast) }) {
            schedule(shown)
            return
        }
        guard !queue.contains(where: { $0.says(toast) }) else { return }
        // Where it would show now: a new stack goes to the surface you look at.
        if toasts.isEmpty { pickHost() }
        if toasts.count < capacity { present(toast) } else { queue.append(toast) }
    }

    func success(_ title: String, detail: String? = nil, action: NookToastAction? = nil) {
        show(title, detail: detail, kind: .success, action: action)
    }

    func info(_ title: String, detail: String? = nil, action: NookToastAction? = nil) {
        show(title, detail: detail, kind: .info, action: action)
    }

    func warning(_ title: String, detail: String? = nil, action: NookToastAction? = nil) {
        show(title, detail: detail, kind: .warning, action: action)
    }

    func error(_ title: String, detail: String? = nil, action: NookToastAction? = nil) {
        show(title, detail: detail, kind: .error, action: action)
    }

    /// An error as Nook says it: what failed as the title (`title`, or the generic "Something went wrong"), and the
    /// error's own description under it.
    func error(_ error: Error, title: String? = nil, action: NookToastAction? = nil) {
        show(title ?? tr("toast.error"), detail: error.localizedDescription, kind: .error, action: action)
    }

    /// Closes the toast `id` (nil: the one in front, which is the one the notch's strip shows) and lets the next
    /// one waiting take its place.
    func dismiss(_ id: UUID? = nil) {
        guard let id = id ?? current?.id, toasts.contains(where: { $0.id == id }) else { return }
        forget(id)
        withAnimation(NookTheme.close) {
            toasts.removeAll { $0.id == id }
            if toasts.isEmpty { activeHost = nil }
        }
        if toasts.isEmpty { paused = false }
        guard !queue.isEmpty else { return }
        if activeHost != nil {
            fill()
        } else {
            // The notch's strip: let the old one leave before the next comes in.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard let self, self.toasts.isEmpty, !self.queue.isEmpty else { return }
                self.pickHost()
                self.fill()
            }
        }
    }

    /// The pointer is on the stack: every toast stays, and runs out the rest of its time once the pointer leaves.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused, !toasts.isEmpty || !paused else { return }
        self.paused = paused
        for clock in clocks.values {
            if paused { clock.hold() } else { clock.resume() }
        }
    }

    /// Runs the action of toast `id` (nil: the one in front) and closes it.
    func performAction(_ id: UUID? = nil) {
        guard let toast = toasts.first(where: { $0.id == (id ?? current?.id) }) else { return }
        dismiss(toast.id)
        toast.action?.perform()
    }

    // MARK: Hosts

    func register(_ id: UUID, window: NSWindow?) {
        hosts.removeAll { $0.id == id }
        hosts.append(Host(id: id, window: window))
        // Opened while a toast shows in the notch, or on another surface: they move to where you now look.
        if !toasts.isEmpty { route() }
    }

    func unregister(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        guard activeHost == id, !toasts.isEmpty else { return }
        // The surface that showed them went away (the panel closed): the toasts go with it, instead of turning up again
        // in the notch's strip. They move only to another surface that is on screen.
        hosts.removeAll { $0.window == nil }
        if hosts.contains(where: { $0.window?.isVisible == true }) {
            route()
        } else {
            for toast in toasts { forget(toast.id) }
            withAnimation(NookTheme.close) {
                toasts.removeAll()
                activeHost = nil
            }
            paused = false
            dismissQueueToNotch()
        }
    }

    /// The surface went away with its stack: what still waits shows in the notch, one at a time.
    private func dismissQueueToNotch() {
        guard !queue.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, self.toasts.isEmpty else { return }
            self.pickHost()
            self.fill()
        }
    }

    private func present(_ toast: NookToast) {
        withAnimation(NookTheme.open) { toasts.append(toast) }
        schedule(toast)
        if activeHost == nil { showInNotch() }
    }

    /// Brings the next ones waiting on screen, as far as there is room.
    private func fill() {
        while toasts.count < capacity, !queue.isEmpty {
            present(queue.removeFirst())
        }
    }

    /// The key window's host, else the one opened last; nil when no host is on screen.
    private func pickHost() {
        hosts.removeAll { $0.window == nil }
        let visible = hosts.filter { $0.window?.isVisible == true }
        // The window you work in first; else the surface you opened last.
        let host = visible.last(where: { $0.window?.isKeyWindow == true }) ?? visible.last
        if activeHost != host?.id { withAnimation(NookTheme.open) { activeHost = host?.id } }
    }

    /// Shows the stack on the host where you look, or the toast in front in the notch when no host is on screen.
    private func route() {
        guard !toasts.isEmpty else { return }
        pickHost()
        if activeHost != nil {
            fill()
            return
        }
        // The notch's strip shows one: the older ones wait their turn again.
        while toasts.count > 1 {
            let older = toasts.removeFirst()
            forget(older.id)
            queue.insert(older, at: 0)
        }
        showInNotch()
    }

    /// Hands the toast in front to the notch's strip; when it cannot show it now, it is left out for the next one.
    private func showInNotch() {
        guard let current else { return }
        if notchFallback?(current) != true {
            // Nowhere to show it without covering something that waits for you: on to the next one.
            dismiss(current.id)
        }
    }

    /// Starts the toast's time over, from its full duration.
    private func schedule(_ toast: NookToast) {
        let id = toast.id
        stamps[id] = UUID()
        let clock = clocks[id] ?? NoticeClock()
        clocks[id] = clock
        clock.start(toast.duration, held: paused) { [weak self] in
            self?.dismiss(id)
        }
    }

    private func forget(_ id: UUID) {
        clocks.removeValue(forKey: id)?.cancel()
        stamps.removeValue(forKey: id)
    }
}

/// The toast itself: the shared `NookNotice` in a bubble. The kind's symbol, the title and its line, an optional
/// action, and the OK with the countdown of the toast closing by itself. An error with a detail can be copied in one
/// click, so a long git or network message is never lost when the toast closes.
struct NookToastView: View {
    let toast: NookToast
    var paused: Bool = false
    /// New when the toast's time starts over: its ring starts over with it.
    var restart: AnyHashable? = nil
    /// Behind another toast in the folded stack: only its bubble shows, at this height (the one in front's), peeking out
    /// under it. Nil when it shows in full.
    var coveredHeight: CGFloat? = nil
    /// Its full height, also while covered: where the stack puts the toasts behind it.
    var onHeight: ((CGFloat) -> Void)? = nil
    let perform: () -> Void
    let close: () -> Void

    /// Narrow enough to sit in a corner without covering the page under it.
    static let maxWidth: CGFloat = 360

    var body: some View {
        NookNotice(title: toast.title, detail: toast.detail, symbol: toast.kind.symbol, tone: toast.kind.color,
                   actions: toast.action.map { [NookNoticeAction($0.title, perform: perform)] } ?? [],
                   countdown: toast.duration, paused: paused, restart: restart, wraps: true, onOK: close) {
            if toast.kind == .error, let detail = toast.detail {
                CopyIconButton(tr("toast.copy"), height: 20) { [toast.title, detail].joined(separator: "\n") }
            }
        }
        .textSelection(.enabled)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight?($0 + NookTheme.Spacing.md * 2) }
        .opacity(coveredHeight == nil ? 1 : 0)
        .frame(height: coveredHeight.map { max(0, $0 - NookTheme.Spacing.md * 2) }, alignment: .top)
        .toastBubble(tone: toast.kind.color, maxWidth: Self.maxWidth)
    }
}

extension View {
    /// The toast's bubble: lifted a step above the panel it floats over, its tone in the symbol and a faint edge, not a
    /// loud frame. Also worn by what waits for you in the same corner (`PanelNoticeBar(floating:)`), so a request and a
    /// result read as the same kind of thing in the same place.
    func toastBubble(tone: Color, maxWidth: CGFloat = 480) -> some View {
        padding(.leading, NookTheme.Spacing.lg)
            .padding(.trailing, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .cardBackground(NookTheme.graphite, stroke: tone.opacity(0.22), radius: NookTheme.Radius.panel)
            .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
    }
}

extension AnyTransition {
    /// The enter and leave of a toast or a request in the top-right corner: it slides in from the trailing edge and back out, or only
    /// fades under Reduce Motion.
    static func nookToast(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing))
    }
}

/// Shows `ToastCenter`'s toasts in the top-right corner of this view, under the header, when this is the surface they
/// belong to (`NookToastStack`). `above` (what waits for you on this surface: a permission request, an agent's question)
/// sits in the same corner, on top of the toasts, so a request and a result show in one place and never cover the page
/// or the box you type in.
private struct NookToastHost<Above: View>: ViewModifier {
    let above: Above
    @ObservedObject private var center = ToastCenter.shared
    @State private var id = UUID()
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            // Top right, under the header (the panel's tabs, the window's traffic lights), out of the way of the page and
            // the composer: first what waits for you, then the results.
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: NookTheme.Spacing.md) {
                    above
                    NookToastStack(center: center, shown: center.activeHost == id)
                }
                .padding(.top, PanelView.headerHeight + NookTheme.Spacing.md)
                .padding(.horizontal, NookTheme.Spacing.xl)
            }
            .background(WindowReader { window = $0 })
            .onChange(of: window) { _, window in
                if let window { center.register(id, window: window) } else { center.unregister(id) }
            }
            .onAppear { if let window { center.register(id, window: window) } }
            .onDisappear { center.unregister(id) }
    }
}

/// The toasts of one surface as a stack: the newest in front, each older one a step smaller and
/// peeking out a little lower under it, its content hidden. With the pointer on the stack it spreads out into a column
/// so every toast can be read, closed or acted on, and every clock holds. A new toast slides in from the trailing edge,
/// and one that closes slides back out; the rest move up into place.
struct NookToastStack: View {
    @ObservedObject var center: ToastCenter
    /// This surface shows the stack now.
    let shown: Bool
    @State private var expanded = false
    /// Each toast's full height, unscaled: where the ones behind it go.
    @State private var heights: [UUID: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far each older toast peeks out under the one in front of it.
    private static let peek = NookTheme.Spacing.lg
    /// How much smaller each step back is.
    private static let shrink: CGFloat = 0.06

    /// Newest first: depth 0 is in front.
    private var stack: [NookToast] { shown ? center.toasts.reversed() : [] }

    var body: some View {
        let stack = stack
        let front = stack.first.flatMap { heights[$0.id] } ?? 0
        ZStack(alignment: .topTrailing) {
            ForEach(Array(stack.enumerated()), id: \.element.id) { depth, toast in
                let covered = !expanded && depth > 0
                NookToastView(toast: toast, paused: center.paused, restart: center.stamps[toast.id],
                              coveredHeight: covered ? front : nil, onHeight: { heights[toast.id] = $0 },
                              perform: { center.performAction(toast.id) }, close: { center.dismiss(toast.id) })
                    .scaleEffect(scale(depth), anchor: .top)
                    .offset(y: offset(depth, in: stack, front: front))
                    .zIndex(Double(-depth))
                    .allowsHitTesting(!covered)
                    .accessibilityHidden(covered)
                    .transition(.nookToast(reduceMotion: reduceMotion))
                    .onAppear { announce(toast) }
            }
        }
        // The whole stack is the hover area, folded or spread out, so moving between toasts keeps it open.
        .frame(height: stack.isEmpty ? 0 : height(of: stack, front: front), alignment: .top)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(NookTheme.reveal) { expanded = inside && stack.count > 1 }
            center.setPaused(inside)
        }
        .onChange(of: stack.count) { _, count in
            if count <= 1 { withAnimation(NookTheme.reveal) { expanded = false } }
            let ids = Set(stack.map(\.id))
            heights = heights.filter { ids.contains($0.key) }
        }
        .animation(reduceMotion ? nil : NookTheme.open, value: stack.map(\.id))
    }

    private func scale(_ depth: Int) -> CGFloat {
        expanded ? 1 : max(0, 1 - CGFloat(depth) * Self.shrink)
    }

    /// Folded: the older toast, as tall as the one in front and a step smaller, its bottom edge `peek` under the one
    /// before it. Spread out: under every newer toast.
    private func offset(_ depth: Int, in stack: [NookToast], front: CGFloat) -> CGFloat {
        guard depth > 0 else { return 0 }
        if expanded {
            return stack.prefix(depth).reduce(0) { $0 + (heights[$1.id] ?? 0) } + CGFloat(depth) * NookTheme.Spacing.md
        }
        return CGFloat(depth) * Self.peek + front * (1 - scale(depth))
    }

    private func height(of stack: [NookToast], front: CGFloat) -> CGFloat {
        guard let last = stack.indices.last else { return 0 }
        if expanded {
            return offset(last, in: stack, front: front) + (heights[stack[last].id] ?? 0)
        }
        return front + CGFloat(last) * Self.peek
    }

    /// VoiceOver reads the toast without having to find it.
    private func announce(_ toast: NookToast) {
        let text = [toast.title, toast.detail].compactMap { $0 }.joined(separator: ". ")
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Reports the window a view is in, and nil when it leaves it (the toast host, `AgentAnnouncer`).
struct WindowReader: NSViewRepresentable {
    let changed: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowView)?.changed = changed
    }

    private final class WindowView: NSView {
        var changed: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Not while SwiftUI is still updating the view that holds this one.
            DispatchQueue.main.async { [weak self] in self?.changed?(window) }
        }
    }
}

extension View {
    /// Lets this surface show Nook's toasts (see `ToastCenter`). Add it once, at the root of a window or panel.
    func nookToastHost() -> some View {
        modifier(NookToastHost(above: EmptyView()))
    }

    /// The same, with `above` (what waits for you on this surface) floating over the toast at the bottom edge.
    func nookToastHost<Above: View>(@ViewBuilder above: () -> Above) -> some View {
        modifier(NookToastHost(above: above()))
    }
}
