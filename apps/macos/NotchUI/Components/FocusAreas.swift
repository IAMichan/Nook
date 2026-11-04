import AppKit
import SwiftUI
import SwiftTerm
import WebKit

/// The parts of a window the keyboard can be in, for F6 / ⇧F6 (`focus.next` / `focus.previous`): the session list, the
/// conversation, its composer, and the side and bottom panels that are open. F6 goes to the next one that is on screen
/// (after the last back to the first) and puts the keyboard where it was when you left that part, else on the first thing
/// there that takes typing (a field, a terminal, a page). It also tells the key monitor whether a panel has the keyboard
/// (`panelFocus`, for ⌘W). Views mark their part with `.focusArea(_:focus:)`; nothing runs until a key asks.
@MainActor
final class FocusAreas {
    static let shared = FocusAreas()

    enum Area: Int, CaseIterable, Sendable {
        case sidebar, conversation, composer, sidePanel, bottomPanel

        var isPanel: Bool { self == .sidePanel || self == .bottomPanel }
    }

    private struct Entry {
        weak var view: NSView?
        let area: Area
        /// Puts the keyboard in a part that is SwiftUI's to focus (the session list); true when it did.
        var focus: (() -> Bool)?
        var order: Int
    }

    private final class WeakResponder {
        weak var value: NSResponder?
        init(_ value: NSResponder?) { self.value = value }
    }

    private var entries: [UUID: Entry] = [:]
    private var nextOrder = 0
    /// Where F6 went last in each window: a part SwiftUI focuses leaves AppKit's first responder on the window's host.
    private var current: [ObjectIdentifier: Area] = [:]
    /// What had the keyboard when you left each part, per window.
    private var remembered: [ObjectIdentifier: [Area: WeakResponder]] = [:]

    func update(_ id: UUID, view: NSView, area: Area, focus: (() -> Bool)?) {
        var order = entries[id]?.order ?? 0
        if order == 0 {
            nextOrder += 1
            order = nextOrder
        }
        entries[id] = Entry(view: view, area: area, focus: focus, order: order)
    }

    func remove(_ id: UUID) {
        entries[id] = nil
    }

    /// The parts on screen in `window`, one per area (the newest when a part shows twice), in F6 order.
    private func present(in window: NSWindow) -> [(area: Area, frame: NSRect, entry: Entry)] {
        var byArea: [Area: (frame: NSRect, entry: Entry)] = [:]
        for entry in entries.values {
            guard let view = entry.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.width > 1, frame.height > 1 else { continue }
            if let known = byArea[entry.area], known.entry.order > entry.order { continue }
            byArea[entry.area] = (frame, entry)
        }
        return Area.allCases.compactMap { area in byArea[area].map { (area, $0.frame, $0.entry) } }
    }

    /// The part a view lies in: the smallest marked part that holds all of what shows of it (the composer inside the
    /// conversation is the composer). Nil for a view outside every part, such as the window's own host.
    func area(of responder: NSResponder?, in window: NSWindow) -> Area? {
        guard let view = responder as? NSView, view.window === window else { return nil }
        let rect = view.convert(view.visibleRect, to: nil)
        guard !rect.isEmpty else { return nil }
        return smallest(containing: rect, in: present(in: window))
    }

    private func smallest(containing rect: NSRect, in parts: [(area: Area, frame: NSRect, entry: Entry)]) -> Area? {
        parts.filter { $0.frame.insetBy(dx: -1, dy: -1).contains(rect) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.area
    }

    /// Moves the keyboard `step` parts on (1 for F6, -1 for ⇧F6), round the end. False when the window has no parts.
    func cycle(_ step: Int, in window: NSWindow) -> Bool {
        let parts = present(in: window)
        guard !parts.isEmpty else { return false }
        let key = ObjectIdentifier(window)
        let now = area(of: window.firstResponder, in: window) ?? current[key]
        if let now, let responder = window.firstResponder, area(of: responder, in: window) == now {
            remembered[key, default: [:]][now] = WeakResponder(responder)
        }
        let start: Int
        if let now, let index = parts.firstIndex(where: { $0.area == now }) {
            start = index + step
        } else {
            start = step > 0 ? 0 : parts.count - 1
        }
        for offset in 0..<parts.count {
            let index = ((start + offset * step) % parts.count + parts.count) % parts.count
            let part = parts[index]
            if focus(part, in: window, parts: parts) {
                current[key] = part.area
                return true
            }
        }
        return false
    }

    private func focus(_ part: (area: Area, frame: NSRect, entry: Entry), in window: NSWindow,
                       parts: [(area: Area, frame: NSRect, entry: Entry)]) -> Bool {
        let key = ObjectIdentifier(window)
        // Back where you were in it.
        if let view = remembered[key]?[part.area]?.value as? NSView, view.window === window,
           area(of: view, in: window) == part.area, window.makeFirstResponder(view) {
            return true
        }
        if let focus = part.entry.focus, focus() { return true }
        if let view = firstTaker(in: part.area, frame: part.frame, window: window, parts: parts),
           window.makeFirstResponder(view) {
            return true
        }
        // A part with nothing that takes typing (the conversation): the keyboard leaves where it was and F6 goes on from here.
        if part.area == .conversation {
            window.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// The first view in the part that takes the keyboard: a text that can be edited, a terminal or a web page first.
    private func firstTaker(in area: Area, frame: NSRect, window: NSWindow,
                            parts: [(area: Area, frame: NSRect, entry: Entry)]) -> NSView? {
        guard let root = window.contentView else { return nil }
        var preferred: NSView?
        var other: NSView?
        var stack: [NSView] = [root]
        while let view = stack.popLast(), preferred == nil {
            if view.isHidden { continue }
            let rect = view.convert(view.visibleRect, to: nil)
            if !rect.isEmpty, frame.insetBy(dx: -1, dy: -1).contains(rect), view.acceptsFirstResponder,
               smallest(containing: rect, in: parts) == area {
                let editable = (view as? NSTextView)?.isEditable == true
                if editable || view is TerminalView || view is WKWebView {
                    preferred = view
                } else if other == nil, !(view is NSScrollView), !(view is NSClipView) {
                    other = view
                }
            }
            // Children in reverse, so the first subview is looked at first.
            stack.append(contentsOf: view.subviews.reversed())
        }
        return preferred ?? other
    }
}

extension View {
    /// Marks this view as a part of the window F6 / ⇧F6 steps through (see `FocusAreas`). `focus` puts the keyboard in it
    /// when that is SwiftUI's to do (a list with a `@FocusState`); return true when it did.
    func focusArea(_ area: FocusAreas.Area, focus: (() -> Bool)? = nil) -> some View {
        background(FocusAreaProbe(area: area, focus: focus))
    }
}

private struct FocusAreaProbe: NSViewRepresentable {
    let area: FocusAreas.Area
    let focus: (() -> Bool)?

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.area = area
        view.focus = focus
        view.publish()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        FocusAreas.shared.remove(view.id)
    }

    final class ProbeView: NSView {
        let id = UUID()
        var area: FocusAreas.Area = .conversation
        var focus: (() -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func publish() {
            if window == nil { FocusAreas.shared.remove(id) } else { FocusAreas.shared.update(id, view: self, area: area, focus: focus) }
        }
    }
}
