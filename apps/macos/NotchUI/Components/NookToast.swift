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
/// Where it shows: on one surface with a `.nookToastHost()` (the panel in the notch, the main window, Settings), at its
/// bottom edge, and only there: the key window's, else the one you opened last. With none of them on screen, the notch
/// shows it in its own confirmation strip (`NotchViewModel.showToast`). Toasts wait their turn; the same message twice
/// only restarts the timer. Errors stay longest, and any toast stays while the pointer is on it. Like every notice that
/// closes by itself, it ends in the OK with the countdown ring of that time (`NookNotice`).
///
/// A toast is for a result. What waits for a decision is a card or an approval (`NookNoticeActions`); a problem with a
/// form you are filling in stays next to that form; something that stays true (a disconnected account) is a status row.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: NookToast?
    /// The host that shows `current`; nil while the notch shows it, or while nothing does.
    @Published private(set) var activeHost: UUID?

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
    /// Runs out the current toast's time while the pointer is off it, like the ring on its OK.
    private let clock = NoticeClock()
    /// The pointer is on the toast: its clock and ring hold.
    @Published private(set) var paused = false
    /// New each time the current toast's time starts over (the same message again), so its ring starts over too.
    @Published private(set) var stamp = UUID()

    // MARK: Showing

    /// Shows a toast; `duration` nil uses the kind's own.
    func show(_ title: String, detail: String? = nil, kind: NookToastKind = .info, duration: TimeInterval? = nil,
              action: NookToastAction? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toast = NookToast(kind: kind, title: title, detail: detail?.isEmpty == false ? detail : nil,
                              duration: duration ?? kind.duration, action: action)
        if let current, current.says(toast) {
            schedule(current)
            return
        }
        guard !queue.contains(where: { $0.says(toast) }) else { return }
        if current == nil { present(toast) } else { queue.append(toast) }
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

    /// Closes the current toast and shows the next one waiting.
    func dismiss() {
        clock.cancel()
        paused = false
        withAnimation(NookTheme.close) {
            current = nil
            activeHost = nil
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        // Let the old one leave before the next comes in.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            self?.present(next)
        }
    }

    /// The pointer is on the toast: it stays, and runs out the rest of its time once the pointer leaves.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused, current != nil else { return }
        self.paused = paused
        if paused { clock.hold() } else { clock.resume() }
    }

    /// Runs the toast's action and closes it.
    func performAction() {
        let action = current?.action
        dismiss()
        action?.perform()
    }

    // MARK: Hosts

    func register(_ id: UUID, window: NSWindow?) {
        hosts.removeAll { $0.id == id }
        hosts.append(Host(id: id, window: window))
        // Opened while a toast shows in the notch, or on another surface: it moves to where you now look.
        if current != nil { route() }
    }

    func unregister(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        if activeHost == id, current != nil { route() }
    }

    private func present(_ toast: NookToast) {
        withAnimation(NookTheme.open) { current = toast }
        route()
        guard current != nil else { return }
        schedule(toast)
    }

    /// Shows `current` on the key window's host, else the one opened last, or in the notch when no host is on screen.
    private func route() {
        guard let current else { return }
        hosts.removeAll { $0.window == nil }
        let visible = hosts.filter { $0.window?.isVisible == true }
        // The window you work in first; else the surface you opened last.
        if let host = visible.last(where: { $0.window?.isKeyWindow == true }) ?? visible.last {
            if activeHost != host.id { withAnimation(NookTheme.open) { activeHost = host.id } }
            return
        }
        activeHost = nil
        if notchFallback?(current) != true {
            // Nowhere to show it without covering something that waits for you: on to the next one.
            dismiss()
        }
    }

    /// Starts the toast's time over, from its full duration.
    private func schedule(_ toast: NookToast) {
        let id = toast.id
        stamp = UUID()
        clock.start(toast.duration, held: paused) { [weak self] in
            guard let self, self.current?.id == id else { return }
            self.dismiss()
        }
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
    let perform: () -> Void
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        NookNotice(title: toast.title, detail: toast.detail, symbol: toast.kind.symbol, tone: toast.kind.color,
                   countdown: toast.duration, paused: paused, restart: restart, wraps: true, onOK: close) {
            if let action = toast.action {
                NookGhostButton(title: action.title, compact: true, height: 30, action: perform)
            }
            if toast.kind == .error, let detail = toast.detail {
                ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", tr("toast.copy"), height: 20) {
                    Pasteboard.copy([toast.title, detail].joined(separator: "\n"))
                    copied = true
                }
                .help(tr("toast.copy"))
            }
        }
        .textSelection(.enabled)
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: 480, alignment: .leading)
        // Lifted a step above the panel it floats over; its kind shows in the symbol and a faint edge, not a loud frame.
        .cardBackground(NookTheme.graphite, stroke: toast.kind.color.opacity(0.22), radius: NookTheme.Radius.panel, style: .continuous)
        .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
    }
}

/// Shows `ToastCenter`'s current toast over the bottom edge of this view, when this is the surface it belongs to.
private struct NookToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    @State private var id = UUID()
    @State private var window: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current, center.activeHost == id {
                    NookToastView(toast: toast, paused: center.paused, restart: center.stamp, perform: { center.performAction() },
                                  close: { center.dismiss() })
                        .onHover { center.setPaused($0) }
                        .padding(.horizontal, NookTheme.Spacing.xl)
                        .padding(.bottom, NookTheme.Spacing.xl)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        .onAppear { announce(toast) }
                }
            }
            .background(ToastWindowReader { window = $0 })
            .onChange(of: window) { _, window in
                if let window { center.register(id, window: window) } else { center.unregister(id) }
            }
            .onAppear { if let window { center.register(id, window: window) } }
            .onDisappear { center.unregister(id) }
    }

    /// VoiceOver reads the toast without having to find it.
    private func announce(_ toast: NookToast) {
        let text = [toast.title, toast.detail].compactMap { $0 }.joined(separator: ". ")
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Reports the window a view is in, and nil when it leaves it.
private struct ToastWindowReader: NSViewRepresentable {
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
        modifier(NookToastHost())
    }
}
