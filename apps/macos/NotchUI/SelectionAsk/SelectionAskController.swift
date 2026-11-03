import AppKit
import Combine
import SwiftUI

/// What the bar or card beside a selection shows.
@MainActor
final class SelectionAskModel: ObservableObject {
    enum Stage: Equatable {
        case hidden
        /// The bar above the selection: Ask Nook, Explain, Translate (and Quote in a session).
        case bar
        /// The card with Nook's answer, in this conversation.
        case card(UUID)
    }

    @Published fileprivate(set) var stage: Stage = .hidden
    /// The selected words the bar and card are about.
    @Published fileprivate(set) var selection = ""
    /// What the follow-up field holds.
    @Published var draft = ""
    /// Quotes the selection into the session's reply box; nil where there is none.
    fileprivate(set) var quote: ((String) -> Void)?

    var conversation: UUID? {
        if case .card(let id) = stage { return id }
        return nil
    }
}

/// The panel the bar and card live in: it floats over its window as a child, so it moves with it and belongs to it
/// (a click in it is not a click outside the notch), and it only takes the keyboard for the follow-up field.
final class SelectionAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The bar's buttons answer the first click: the panel stays out of the keyboard's way, so it is never the key window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Watches Nook's own windows for words you select and offers to ask Nook about them (`SelectionAsk`). It costs nothing
/// at rest: it only listens to the mouse button and keys going up in Nook's windows, and reads a selection once, when one
/// was just made.
@MainActor
final class SelectionAskController {
    static let shared = SelectionAskController()

    let model = SelectionAskModel()
    private weak var app: AppModel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var notchState: AnyCancellable?
    private var panel: SelectionAskPanel?
    /// The window the selection is in, and where the selection is in it (window points, so it holds when the window moves).
    private weak var source: NSWindow?
    private var anchor: NSRect = .zero
    /// Where the left button went down (screen points), and in which window.
    private var press: (point: NSPoint, window: Int)?
    private var reading: Task<Void, Never>?
    /// How big the bar or card draws itself.
    private var contentSize: CGSize = .zero

    static let cardWidth: CGFloat = 400

    func start(app: AppModel) {
        guard monitors.isEmpty else { return }
        self.app = app
        let add = { [weak self] (mask: NSEvent.EventTypeMask, handle: @escaping @MainActor (SelectionAskController, NSEvent) -> Bool) in
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated {
                    guard let self else { return event }
                    return handle(self, event) ? nil : event
                }
            }) else { return }
            self?.monitors.append(monitor)
        }
        add([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { $0.pressed($1); return false }
        add(.leftMouseUp) { $0.released($1); return false }
        add(.keyDown) { $0.keyDown($1) }
        add(.keyUp) { $0.keyUp($1); return false }
        add(.scrollWheel) { $0.scrolled($1); return false }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                                queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.source else { return }
                self.dismiss()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            // The card waits (its panel hides with Nook and comes back with it); the bar was only for that moment.
            MainActor.assumeIsolated { if self?.model.stage == .bar { self?.dismiss() } }
        })
        // The notch closed under the bar or card: they go with it.
        notchState = app.viewModel.surface.$state.map(\.isResting).removeDuplicates().sink { [weak self] resting in
            guard resting, let self, self.source is NotchPanel else { return }
            self.dismiss()
        }
    }

    /// Whether the card shows this conversation: its answer is in sight, so it needs no notice when it is done.
    func shows(_ conversation: UUID) -> Bool {
        model.conversation == conversation && panel?.isVisible == true
    }

    // MARK: Events

    private func pressed(_ event: NSEvent) {
        guard event.window == nil || event.window !== panel else { return }
        press = event.type == .leftMouseDown ? (NSEvent.mouseLocation, event.windowNumber) : nil
        // A click starts a new selection or clears this one; the card stays until you close it.
        if model.stage == .bar { dismiss() }
    }

    private func released(_ event: NSEvent) {
        guard let window = event.window, window !== panel, let press, press.window == event.windowNumber else { return }
        self.press = nil
        let release = NSEvent.mouseLocation
        guard SelectionAsk.isDeliberate(down: press.point, up: release, clicks: event.clickCount) else { return }
        look(in: window, press: press.point, release: release)
    }

    private func keyUp(_ event: NSEvent) {
        guard let window = event.window, window !== panel else { return }
        // ⇧ with an arrow (and ⌥ or ⌘ to go by word or line), or ⌘A: a selection made with the keys.
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let selectsAll = flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "a"
        guard selectsAll || (flags.contains(.shift) && arrows.contains(event.keyCode)) else { return }
        look(in: window, press: nil, release: nil)
    }

    /// True when the key was for the bar or card: Escape closes them first.
    private func keyDown(_ event: NSEvent) -> Bool {
        guard model.stage != .hidden else { return false }
        if event.keyCode == 53 {
            guard event.window === panel || event.window === source else { return false }
            dismiss()
            return true
        }
        // Typing goes on in the window under the bar: the bar is out of the way. A shortcut (⌘C) leaves it.
        if model.stage == .bar, event.window !== panel, !event.modifierFlags.contains(.command) { dismiss() }
        return false
    }

    private func scrolled(_ event: NSEvent) {
        if model.stage == .bar, event.window === source { dismiss() }
    }

    // MARK: Showing

    private func look(in window: NSWindow, press: NSPoint?, release: NSPoint?) {
        guard app?.settings.selectionAsk == true, window.isVisible, !(window is SelectionAskPanel) else { return }
        reading?.cancel()
        reading = Task { @MainActor [weak self] in
            // A double click selects its word as the button goes up: let the view settle first.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let found = await SelectionReader.read(in: window, press: press, release: release),
                  !Task.isCancelled, let self else { return }
            // The card is open about something else: a new selection asks about the new words instead.
            self.show(found, in: window)
        }
    }

    private func show(_ found: FoundSelection, in window: NSWindow) {
        if model.stage == .bar, model.selection == found.text, source === window { return }
        closePanel()
        model.selection = found.text
        model.quote = found.quote
        model.draft = ""
        model.stage = .bar
        source = window
        anchor = window.convertFromScreen(found.anchor)
        let panel = makePanel()
        panel.level = window.level
        panel.appearance = window.appearance ?? NSAppearance(named: .darkAqua)
        contentSize = panel.contentView?.fittingSize ?? CGSize(width: 320, height: 36)
        place()
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    /// Ask Nook, Explain or Translate in the bar: the bar becomes the card, with Nook's answer coming in.
    func ask(_ mode: SelectionAsk.Mode) {
        guard let app, let conversation = app.askAboutSelection(model.selection, mode: mode) else {
            dismiss()
            return
        }
        withAnimation(NookTheme.reveal) { model.stage = .card(conversation) }
    }

    /// Quote in the bar: the selection goes into the session's reply box, as Quote in the right-click menu does.
    func quoteSelection() {
        let text = model.selection
        let quote = model.quote
        dismiss()
        quote?(text)
    }

    func sendFollowUp() {
        guard let conversation = model.conversation else { return }
        let text = model.draft
        model.draft = ""
        app?.followUpOnSelection(text, in: conversation)
    }

    func continueInChat() {
        guard let conversation = model.conversation else { return }
        dismiss()
        app?.continueSelectionInChat(conversation)
    }

    func dismiss() {
        reading?.cancel()
        closePanel()
        model.stage = .hidden
        model.quote = nil
        model.draft = ""
    }

    /// The bar or card drew itself at a new size: the panel follows, next to the selection.
    func resized(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        place()
    }

    private func place() {
        guard let panel, let source else { return }
        let selection = source.convertToScreen(anchor)
        let visible = (source.screen ?? NSScreen.main)?.visibleFrame ?? source.frame
        // The panel has room for the shadow around what it shows: the gap is counted from the bar or card itself.
        let origin = SelectionAsk.origin(for: contentSize, anchor: selection, visible: visible,
                                         below: model.conversation != nil, gap: 6 - SelectionAskRoot.margin)
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
    }

    private func makePanel() -> SelectionAskPanel {
        if let panel { return panel }
        let panel = SelectionAskPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 36),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: SelectionAskRoot(model: model, controller: self)
            .environmentObject(AppModel.shared))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func closePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
