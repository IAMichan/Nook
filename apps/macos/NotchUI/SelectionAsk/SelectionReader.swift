import AppKit
import SwiftTerm
import WebKit

/// Words selected in one of Nook's windows, where they are on screen, and what else can be done with them there.
struct FoundSelection {
    let text: String
    /// Where the selection is, in screen points: its first line where the view can say, else around the pointer.
    let anchor: NSRect
    /// Quotes the words into the reply box of the session they were selected in; nil where there is none.
    let quote: ((String) -> Void)?
}

/// Reads the selection of the view that has the keyboard in a window, for every kind of text Nook shows: its own text
/// views (an answer, a file), SwiftUI's selectable text (messages, cards, settings), the terminal, and web pages (the
/// browser, an app beside the chat). Text you are writing (a composer, a field, a form on a page) is left alone.
@MainActor
enum SelectionReader {
    /// `press` and `release`: where a drag started and ended (screen points); nil for a selection made with the keys.
    static func read(in window: NSWindow, press: NSPoint?, release: NSPoint?) async -> FoundSelection? {
        guard let view = window.firstResponder as? NSView, view.window === window else { return nil }
        // A drag elsewhere (a slider, a split, the window's edge) leaves another view's selection as it was.
        if let press, !contains(view, press) { return nil }
        let pointer = pointerAnchor(press: press, release: release) ?? topLine(of: view)

        if let text = view as? NSTextView {
            guard !text.isEditable, !text.isFieldEditor else { return nil }
            let range = text.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (text.string as NSString).length,
                  let words = SelectionAsk.offered((text.string as NSString).substring(with: range)) else { return nil }
            let line = text.firstRect(forCharacterRange: range, actualRange: nil)
            let quote = (text.delegate as? SelectableProse.Coordinator)?.quote
            return FoundSelection(text: words, anchor: line.isEmpty ? pointer : line, quote: quote)
        }
        if let terminal = ancestor(of: view, as: TerminalView.self) {
            guard terminal.selectionActive, let words = terminal.getSelection().flatMap(SelectionAsk.offered) else { return nil }
            return FoundSelection(text: words, anchor: pointer, quote: nil)
        }
        if let web = ancestor(of: view, as: WKWebView.self) {
            return await page(web, pointer: pointer)
        }
        // SwiftUI's selectable `Text` says what is selected through Accessibility, in this process: no permission needed.
        guard let words = view.accessibilitySelectedText().flatMap(SelectionAsk.offered) else { return nil }
        return FoundSelection(text: words, anchor: pointer, quote: nil)
    }

    // MARK: Web pages

    /// Read in the page's own frame, in a world of Nook's (`.defaultClient`), so the page cannot answer for it. Nothing
    /// while the keyboard is in a field of the page: selecting there is editing.
    private static let pageScript = """
        (() => {
          const active = document.activeElement;
          if (active && (active.isContentEditable || active.tagName === 'INPUT' || active.tagName === 'TEXTAREA')) return null;
          const selection = window.getSelection();
          if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
          const range = selection.getRangeAt(0);
          const box = range.getClientRects()[0] || range.getBoundingClientRect();
          return { text: selection.toString(), x: box.left, y: box.top, width: box.width, height: box.height };
        })()
        """

    private static func page(_ web: WKWebView, pointer: NSRect) async -> FoundSelection? {
        guard let found = try? await web.evaluateJavaScript(pageScript, contentWorld: .defaultClient) as? [String: Any],
              let words = (found["text"] as? String).flatMap(SelectionAsk.offered) else { return nil }
        let number = { (key: String) in CGFloat((found[key] as? NSNumber)?.doubleValue ?? 0) }
        let zoom = web.pageZoom * web.magnification
        var box = NSRect(x: number("x") * zoom, y: number("y") * zoom, width: number("width") * zoom, height: number("height") * zoom)
        if !web.isFlipped { box.origin.y = web.bounds.height - box.maxY }
        guard let window = web.window, box.width > 0, web.visibleRect.intersects(box) else {
            return FoundSelection(text: words, anchor: pointer, quote: nil)
        }
        return FoundSelection(text: words, anchor: window.convertToScreen(web.convert(box, to: nil)), quote: nil)
    }

    // MARK: Geometry

    /// The stretch between where a drag started and ended, a line high, so the bar sits above its top line.
    private static func pointerAnchor(press: NSPoint?, release: NSPoint?) -> NSRect? {
        guard let release else { return nil }
        let start = press ?? release
        let half: CGFloat = 10
        return NSRect(x: min(start.x, release.x), y: min(start.y, release.y) - half,
                      width: abs(release.x - start.x), height: abs(release.y - start.y) + 2 * half)
    }

    /// For a selection made with the keys: the top line of the part of the view in sight.
    private static func topLine(of view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        let visible = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        return NSRect(x: visible.minX, y: visible.maxY - 20, width: visible.width, height: 20)
    }

    private static func contains(_ view: NSView, _ point: NSPoint) -> Bool {
        guard let window = view.window else { return false }
        let frame = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        return frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private static func ancestor<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }
}
