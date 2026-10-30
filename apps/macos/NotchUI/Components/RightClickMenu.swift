import AppKit
import SwiftUI

/// One item of a menu that shows both as a SwiftUI `Menu` (behind a button) and as an AppKit menu on a right-click
/// (`.onRightClickMenu`), so the two always offer the same: a title with its symbol, an action or a submenu, and a line
/// above it where it starts a new group.
struct NookMenuEntry {
    var title: String
    var symbol: String? = nil
    var destructive = false
    /// A line above this item.
    var separated = false
    var action: (() -> Void)? = nil
    var children: [NookMenuEntry] = []
}

/// The entries as SwiftUI menu content, for a `Menu { … }`.
struct NookMenuItems: View {
    let entries: [NookMenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            if entry.separated { Divider() }
            if entry.children.isEmpty {
                Button(role: entry.destructive ? .destructive : nil) { entry.action?() } label: { label(entry) }
            } else {
                Menu { NookMenuItems(entries: entry.children) } label: { label(entry) }
            }
        }
    }

    @ViewBuilder
    private func label(_ entry: NookMenuEntry) -> some View {
        if let symbol = entry.symbol {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }
}

extension NSMenu {
    /// The same entries as an AppKit menu, for a right-click.
    convenience init(entries: [NookMenuEntry]) {
        self.init()
        autoenablesItems = false
        for entry in entries {
            if entry.separated { addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if entry.children.isEmpty, let action = entry.action {
                let target = NookMenuAction(action)
                item.target = target
                item.action = #selector(NookMenuAction.run)
                // The item holds its target weakly: the represented object keeps it alive as long as the menu.
                item.representedObject = target
            } else if !entry.children.isEmpty {
                item.submenu = NSMenu(entries: entry.children)
            }
            addItem(item)
        }
    }
}

private final class NookMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension View {
    /// A right-click on this view opens `menu` instead of anything under it: selectable text answers a right-click with
    /// the system's own menu (Copy, Look Up, Services) before SwiftUI's `.contextMenu` hears it, so a chat message
    /// whose text can be selected never showed its own menu. Watches the mouse only while `enabled` (the pointer is on
    /// the view), so a long chat does not hold a watcher per message.
    func onRightClickMenu(enabled: Bool, _ menu: @escaping () -> [NookMenuEntry]) -> some View {
        background(RightClickReader(enabled: enabled, menu: menu))
    }
}

private struct RightClickReader: NSViewRepresentable {
    let enabled: Bool
    let menu: () -> [NookMenuEntry]

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.entries = menu
        nsView.enabled = enabled
    }

    static func dismantleNSView(_ nsView: RightClickView, coordinator: ()) {
        nsView.enabled = false
    }

    final class RightClickView: NSView {
        var entries: (() -> [NookMenuEntry])?
        private var monitor: Any?
        var enabled = false {
            didSet { if enabled != oldValue { watch() } }
        }

        // It sits behind the view only to know where it is: clicks go to what is on top.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch()
        }

        private func watch() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard enabled, window != nil else { return }
            // A right-click, or a click with Control held, as everywhere on the Mac.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, self.claims(event), let entries = self.entries?(), !entries.isEmpty else { return event }
                NSMenu.popUpContextMenu(NSMenu(entries: entries), with: event, for: self)
                return nil
            }
        }

        private func claims(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) { return false }
            return bounds.contains(convert(event.locationInWindow, from: nil))
        }
    }
}
