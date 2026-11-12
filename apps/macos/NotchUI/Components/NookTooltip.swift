import AppKit
import SwiftUI

extension View {
    /// A short label for this control, shown after a brief rest (150 ms) and at once while another tip was just shown
    /// (the warm window), fading in over 100 ms. Drawn in a click-through child window, so a scroll view or a narrow
    /// column never clips it. Empty text or `enabled: false` installs nothing (no `.help("")`).
    ///
    /// Use it instead of `.help` on symbol-only controls in lists, sidebars and toolbars: AppKit's own tooltip waits about
    /// a second and never swaps instantly. The text also goes to VoiceOver as the accessibility hint.
    func nookTip(_ text: String, edge: Edge = .top, enabled: Bool = true) -> some View {
        let active = enabled && !text.isEmpty
        return background {
            if active {
                TooltipAnchor(edge: edge, key: text) { AnyView(TooltipLabel(text: text)) }
            }
        }
        .accessibilityHint(active ? text : "")
    }

    /// A richer tip (title + detail lines), same timing and window, placed beside the view (`.trailing`, top-aligned).
    /// For content that holds nothing to click; for clickable cards keep `.hoverCard`. The card is drawn in its own
    /// window: it gets `AppModel` as an environment object, but no other environment of the view it belongs to, so hand
    /// it the values it shows.
    func nookTipCard<Card: View>(edge: Edge = .trailing, enabled: Bool = true,
                                 @ViewBuilder _ card: @escaping () -> Card) -> some View {
        background {
            if enabled {
                TooltipAnchor(edge: edge, key: nil) {
                    AnyView(TooltipCard(content: card()).environmentObject(AppModel.shared))
                }
            }
        }
    }
}

// MARK: - The tip's look

/// The text tip: a small dark label, wrapped when long (the composer's tip look).
private struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.paper)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .cardBackground(DropdownStyle.panel, stroke: NookTheme.line2, radius: NookTheme.Radius.control)
            .accessibilityHidden(true)
    }
}

/// A card tip: the caller's content on the same dark card.
private struct TooltipCard<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .padding(NookTheme.Spacing.lg)
            .cardBackground(DropdownStyle.panel, stroke: NookTheme.line2, radius: NookTheme.Radius.panel)
            .accessibilityHidden(true)
    }
}

/// What the tip window shows: the tip, at most `NookTheme.tooltipMaxWidth` wide.
private struct TooltipRoot: View {
    let content: AnyView

    var body: some View {
        TooltipWidthLimit(maxWidth: NookTheme.tooltipMaxWidth) { content }
    }
}

/// Offers its one subview at most `maxWidth`, also when asked for its ideal size, so a long text wraps instead of
/// growing into one line.
private struct TooltipWidthLimit: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        return first.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - The view that hears the pointer

/// Sits behind the view with the tip and hears the pointer through a tracking area of its own (also in the main
/// window's title bar row, where SwiftUI's hover is deaf). It costs nothing until the pointer enters: no SwiftUI state
/// changes on hover, so the view around it never redraws for its tip. It takes no clicks.
private struct TooltipAnchor: NSViewRepresentable {
    let edge: Edge
    /// The text of a text tip, to see whether it changed; nil for a card, which is redrawn on every update while shown.
    let key: String?
    let content: () -> AnyView

    func makeNSView(context: Context) -> TooltipAnchorView {
        let view = TooltipAnchorView()
        view.edge = edge
        view.key = key
        view.content = content
        return view
    }

    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        let changed = key == nil || key != view.key || edge != view.edge
        view.edge = edge
        view.key = key
        view.content = content
        if changed { view.contentChanged() }
    }

    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) {
        view.leave()
    }
}

@MainActor
private final class TooltipAnchorView: NSView {
    var edge: Edge = .top
    var key: String?
    var content: (() -> AnyView)?
    private var inside = false
    private weak var presenter: TooltipPresenter?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setInside(false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The area is what shows of this view itself (`shownBounds`), set again whenever the view moves or a scroll view
        // shows another part of it. Not `.inVisibleRect`: that follows `visibleRect`, which reaches out to the nearest
        // ancestor that clips, so a button in the sidebar's list heard the pointer anywhere in the list.
        trackingAreas.forEach(removeTrackingArea)
        let shown = shownBounds
        if !shown.isEmpty {
            addTrackingArea(NSTrackingArea(rect: shown, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        // The view moved (a list scrolled or changed) under a pointer that did not: see whether the pointer is still on
        // it. Only the one view under the pointer asks, so a scrolling list does no work per row.
        guard inside else { return }
        DispatchQueue.main.async { [weak self] in self?.recheck() }
    }

    /// The SwiftUI view went away.
    func leave() { setInside(false) }

    /// The text or card changed: a tip on screen follows.
    func contentChanged() {
        guard inside else { return }
        presenter?.refresh(self)
    }

    /// Where the visible part of this view is on screen, read only when a tip is about to show.
    var screenFrame: NSRect? {
        guard let window else { return nil }
        let shown = shownBounds
        let rect = shown.isEmpty ? bounds : shown
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func recheck() {
        guard inside else { return }
        guard let window else { return setInside(false) }
        if !shownBounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { setInside(false) }
    }

    private func setInside(_ value: Bool) {
        guard value != inside else { return }
        if value {
            guard let window else { return }
            inside = true
            let presenter = TooltipPresenter.shared(for: window)
            self.presenter = presenter
            presenter.enter(self)
        } else {
            inside = false
            presenter?.exit(self)
        }
    }
}

extension NSView {
    /// What shows of this view itself: its bounds, less what an ancestor clips away. `visibleRect` alone is not that:
    /// with AppKit's unclipped views (macOS 14 and later) it is the part of the nearest clipping ancestor (a scroll
    /// view, the window) that this view could draw in, so a 22-point button in a list "showed" as the whole list.
    var shownBounds: NSRect {
        let shown = visibleRect.intersection(bounds)
        return shown.isNull ? .zero : shown
    }
}

// MARK: - The tip window

/// The window a tip is drawn in: a click-through child of the window it belongs to, so it moves with it, is never
/// clipped by a scroll view or a column, and never takes the keyboard or a click.
private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the tips of one window (one at a time), with the timing of `TooltipTiming`. Made on the first hover in that
/// window and gone with it.
@MainActor
enum TooltipActivity {
    static var isPointerOnTip: Bool { TooltipPresenter.isPointerOnTip }
}

@MainActor
private final class TooltipPresenter {
    private static let presenters = NSMapTable<NSWindow, TooltipPresenter>.weakToStrongObjects()
    /// Room kept between a tip and the edge of the screen or window.
    private static let margin: CGFloat = 5
    /// How long a tip fades in: the window's opacity, over `NookTheme.tipFade`'s 100 ms.
    private static let fadeDuration: TimeInterval = 0.1

    static func shared(for window: NSWindow) -> TooltipPresenter {
        if let presenter = presenters.object(forKey: window) { return presenter }
        let presenter = TooltipPresenter(window: window)
        presenters.setObject(presenter, forKey: window)
        return presenter
    }

    private weak var window: NSWindow?
    private var timing = TooltipTiming()
    private var pending: Task<Void, Never>?
    private weak var shown: TooltipAnchorView?
    private var panel: TooltipPanel?
    private var host: NSHostingController<TooltipRoot>?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        })
    }

    // MARK: Pointer

    /// True while any non-popover window has a tooltip shown or waiting for its open delay.
    static var isPointerOnTip: Bool {
        presenters.objectEnumerator()?.allObjects
            .compactMap { $0 as? TooltipPresenter }
            .contains { $0.window?.parent == nil && $0.timing.isActive } ?? false
    }

    func enter(_ anchor: TooltipAnchorView) {
        installMonitor()
        let id = AnyHashable(ObjectIdentifier(anchor))
        pending?.cancel()
        pending = nil
        let decision = timing.enter(id, now: Date())
        if window?.parent == nil { HoverCardWarmth.tooltipEntered() }
        switch decision {
        case .showNow(let animated):
            show(anchor, animated: animated)
        case .showAfter(let delay):
            pending = Task { @MainActor [weak self, weak anchor] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard let anchor else { return self.cancelAll() }
                guard self.timing.fire(id) else { return }
                self.show(anchor, animated: true)
            }
        case .hide:
            hide()
        case .keep:
            break
        }
    }

    func exit(_ anchor: TooltipAnchorView) {
        if timing.exit(AnyHashable(ObjectIdentifier(anchor)), now: Date()) == .hide { hide() }
        if window?.parent == nil, !Self.isPointerOnTip { HoverCardWarmth.tooltipExited() }
    }

    /// The shown tip's text or card changed: redraw it in place, without a fade.
    func refresh(_ anchor: TooltipAnchorView) {
        guard shown === anchor else { return }
        show(anchor, animated: false)
    }

    /// A click, a scroll, a drag, a key, or the window or app losing focus: no tip, and the next one waits again.
    func cancelAll() {
        timing.cancelAll(now: Date())
        hide()
    }

    // MARK: Showing

    private func show(_ anchor: TooltipAnchorView, animated: Bool) {
        guard let window, window.isVisible, let content = anchor.content, let target = anchor.screenFrame else {
            return hide()
        }
        let panel = makePanel()
        guard let host else { return }
        host.rootView = TooltipRoot(content: content())
        let fitted = host.sizeThatFits(in: CGSize(width: NookTheme.tooltipMaxWidth, height: 4_000))
        let size = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        guard size.width > 0, size.height > 0 else { return hide() }
        let frame = Self.frame(for: size, around: target, edge: anchor.edge, in: Self.area(of: window))
        panel.level = window.level
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        shown = anchor
        if animated {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
    }

    /// Closes at once (no fade), and drops a pending open.
    private func hide() {
        pending?.cancel()
        pending = nil
        shown = nil
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Let go of what the tip showed (a card may observe the app model).
        host?.rootView = TooltipRoot(content: AnyView(EmptyView()))
    }

    private func makePanel() -> TooltipPanel {
        if let panel { return panel }
        let panel = TooltipPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        // The tip is always the dark card (`DropdownStyle.panel`): its text and marks resolve for dark, on any theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: TooltipRoot(content: AnyView(EmptyView())))
        host.sizingOptions = []
        panel.contentView = host.view
        self.host = host
        self.panel = panel
        return panel
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // Momentum scrolling and drags send no hover exit: any of these ends the tip and a pending open.
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.timing.isActive else { return }
                self.cancelAll()
            }
            return event
        }
    }

    private func tearDown() {
        cancelAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        panel?.close()
        panel = nil
        host = nil
        if let window { Self.presenters.removeObject(forKey: window) }
    }

    // MARK: Placement

    /// Where a tip may go: the screen's visible part (plus the window itself for the notch panel in the menu bar band),
    /// less a margin.
    private static func area(of window: NSWindow) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let bounds = window.parent == nil ? visible.union(window.frame) : visible
        return bounds.insetBy(dx: margin, dy: margin)
    }

    /// The tip's frame on `edge` of `target` (centred above or below; top-aligned beside), on the opposite edge when
    /// there is no room, then kept inside `area`.
    private static func frame(for size: CGSize, around target: NSRect, edge: Edge, in area: NSRect) -> NSRect {
        let gap = NookTheme.Spacing.xs

        func origin(_ edge: Edge) -> CGPoint {
            switch edge {
            case .top: return CGPoint(x: target.midX - size.width / 2, y: target.maxY + gap)
            case .bottom: return CGPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height)
            case .trailing: return CGPoint(x: target.maxX + gap, y: target.maxY - size.height)
            case .leading: return CGPoint(x: target.minX - gap - size.width, y: target.maxY - size.height)
            }
        }

        func fits(_ point: CGPoint, _ edge: Edge) -> Bool {
            switch edge {
            case .top: return point.y + size.height <= area.maxY
            case .bottom: return point.y >= area.minY
            case .trailing: return point.x + size.width <= area.maxX
            case .leading: return point.x >= area.minX
            }
        }

        let opposite: Edge
        switch edge {
        case .top: opposite = .bottom
        case .bottom: opposite = .top
        case .leading: opposite = .trailing
        case .trailing: opposite = .leading
        }
        var point = origin(edge)
        if !fits(point, edge) {
            let flipped = origin(opposite)
            if fits(flipped, opposite) { point = flipped }
        }
        point.x = max(area.minX, min(point.x, area.maxX - size.width))
        point.y = max(area.minY, min(point.y, area.maxY - size.height))
        return NSRect(origin: point, size: size)
    }
}
