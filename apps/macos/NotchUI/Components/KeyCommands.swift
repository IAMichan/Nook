import AppKit
import SwiftUI
import SwiftTerm

/// The panel's keys, as rules (see `Keybindings`): one key monitor builds the `when` context from what is on screen,
/// finds the command the pressed chord means there (the defaults, then the user's `~/.nook/keybindings.json`) and runs
/// the handler a view registered for it with `keyCommands`. A chord no rule claims, or a command nothing on screen
/// handles, goes on to the view with the keyboard as before.
@MainActor
final class KeyCommandCenter: ObservableObject {
    static let shared = KeyCommandCenter()

    /// The user's file as last read: its rules, the rules it had to skip, and whether it was there at all.
    @Published private(set) var file = Keybindings.LoadResult(rules: [], problems: [], state: .missing)
    /// The rules in use: the defaults, then the user's.
    @Published private(set) var rules = Keybindings.defaults

    /// A view on screen that offers commands.
    private struct Registration {
        /// Later registrations win; a negative priority yields to any view that offers the same command.
        var order: Int
        var priority: Int
        weak var window: NSWindow?
        var enabled: Bool
        var context: [String: Bool]
        var handlers: [String: () -> Bool]
    }

    private var registrations: [UUID: Registration] = [:]
    private var nextOrder = 0
    private var monitor: Any?
    private var activation: NSObjectProtocol?

    /// Starts the one key monitor; the first view that offers a command calls it.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
        // An edit in the file counts the next time Nook comes to the front, or straight away from Settings › Shortcuts.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Called while a view updates: publish the file's rules right after it.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// Reads `~/.nook/keybindings.json` again.
    func reload() {
        let read = Keybindings.read(Keybindings.userFileURL)
        guard read != file else { return }
        file = read
        rules = Keybindings.effective(user: read.rules)
    }

    /// The commands some view of Nook handles (see the `keyCommands` call sites); Settings marks the others as not
    /// available yet, so a rule for them is not mistaken for a broken key.
    static let wiredCommands: Set<String> = [
        "composer.send", "composer.sendAlternate", "composer.newline", "composer.stash", "composer.historyPrevious",
        "composer.historyNext", "queue.steerFirst", "chat.find", "commandPalette.toggle", "session.new", "session.undo", "diff.toggle",
    ]

    func update(_ id: UUID, window: NSWindow?, enabled: Bool, priority: Int, context: [String: Bool],
                handlers: [String: () -> Bool]) {
        start()
        var order = registrations[id]?.order ?? 0
        if order == 0 {
            nextOrder += 1
            order = nextOrder
        }
        registrations[id] = Registration(order: order, priority: priority, window: window, enabled: enabled, context: context,
                                         handlers: handlers)
    }

    func remove(_ id: UUID) {
        registrations[id] = nil
    }

    /// True when a handler took the key.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let responder = window.firstResponder
        // Keys being composed (an input method) and views that pass every key on (a mirrored app) stay theirs.
        if let text = responder as? NSTextView, text.hasMarkedText() { return false }
        if responder is ForwardsKeys { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chord = KeyChord.pressed(characters: event.characters(byApplyingModifiers: []), keyCode: event.keyCode,
                                           command: flags.contains(.command), control: flags.contains(.control),
                                           option: flags.contains(.option), shift: flags.contains(.shift)) else { return false }
        let live = registrations.values
            .filter { $0.enabled && $0.window === window }
            .sorted { ($0.priority, $0.order) < ($1.priority, $1.order) }
        var context = Self.focusContext(responder)
        for registration in live {
            for (key, value) in registration.context where value { context[key] = true }
        }
        guard let command = Keybindings.match(chord, context: context, rules: rules),
              let handler = live.last(where: { $0.handlers[command] != nil })?.handlers[command] else { return false }
        return handler()
    }

    /// What the first responder says: a text being edited, or a terminal.
    private static func focusContext(_ responder: NSResponder?) -> [String: Bool] {
        var context: [String: Bool] = [:]
        if let text = responder as? NSTextView, text.isEditable { context["editableFocus"] = true }
        var view = responder as? NSView
        while let current = view {
            if current is TerminalView { context["terminalFocus"] = true; break }
            view = current.superview
        }
        return context
    }
}

/// A view that passes every key on to something else (a mirrored Mac app): the panel's keybindings leave
/// its keys alone while it has the keyboard.
protocol ForwardsKeys: AnyObject {}

extension View {
    /// Offers keybinding commands (see `Keybindings.commandIDs`) while this view is in a window and `enabled`. A handler
    /// returns true when it used the key; false lets the key go on to the focused view. `context` adds what this view
    /// knows to the `when` context (`paletteOpen`, `turnRunning`…). When several views offer a command, the newest one
    /// wins; `priority: -1` makes a window-wide fallback that yields to any other.
    func keyCommands(_ handlers: [String: () -> Bool], context: [String: Bool] = [:], enabled: Bool = true,
                     priority: Int = 0) -> some View {
        background(KeyCommandProbe(handlers: handlers, flags: context, enabled: enabled, priority: priority))
    }

    /// One command that always uses the key.
    func keyCommand(_ command: String, enabled: Bool = true, priority: Int = 0, perform action: @escaping () -> Void) -> some View {
        keyCommands([command: { action(); return true }], enabled: enabled, priority: priority)
    }
}

/// Registers its view's commands with `KeyCommandCenter`, with the window it is in, and takes them back when it goes.
private struct KeyCommandProbe: NSViewRepresentable {
    let handlers: [String: () -> Bool]
    let flags: [String: Bool]
    let enabled: Bool
    let priority: Int

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.handlers = handlers
        view.flags = flags
        view.enabled = enabled
        view.priority = priority
        view.publish()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        KeyCommandCenter.shared.remove(view.id)
    }

    final class ProbeView: NSView {
        let id = UUID()
        var handlers: [String: () -> Bool] = [:]
        var flags: [String: Bool] = [:]
        var enabled = true
        var priority = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func publish() {
            KeyCommandCenter.shared.update(id, window: window, enabled: enabled, priority: priority, context: flags,
                                           handlers: handlers)
        }
    }
}
