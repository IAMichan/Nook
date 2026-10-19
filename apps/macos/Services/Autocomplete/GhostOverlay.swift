import AppKit

/// Draws suggestions over whatever app has the focus, in a panel that takes no clicks and never becomes key, so typing goes
/// on in the app underneath. After Typist's overlay (MIT, © 2026 Brody Salvucci).
@MainActor
final class GhostOverlay {
    private let panel: NSPanel
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private let inset = CGSize(width: 7, height: 4)

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        label.lineBreakMode = .byClipping
        background.addSubview(label)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Grey text going on from the cursor, in the line itself. The app's font is unknown; the cursor's height stands in for
    /// its line height.
    func showGhost(_ text: String, at caret: CGRect, fontScale: Double = 1, verticalOffset: Double = 0) {
        let size = min(max((caret.height * 0.78 * fontScale).rounded(), 9), 48)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.stringValue = text
        style(card: false)
        var fitting = label.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) {
            fitting.width = min(fitting.width, max(screen.frame.maxX - caret.minX, 0))
        }
        label.frame = CGRect(origin: .zero, size: fitting)
        present(CGRect(x: caret.minX, y: caret.midY - fitting.height / 2 + verticalOffset, width: fitting.width, height: fitting.height))
    }

    /// A small card just below `anchor` (the cursor, a selection or the field).
    func showCard(_ text: NSAttributedString, below anchor: CGRect) {
        label.maximumNumberOfLines = 0
        label.attributedStringValue = text
        style(card: true)
        let fitting = label.fittingSize
        let size = CGSize(width: fitting.width + inset.width * 2, height: fitting.height + inset.height * 2)
        label.frame = CGRect(x: inset.width, y: inset.height, width: fitting.width, height: fitting.height)
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 3)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) {
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 3 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width)
        }
        present(CGRect(origin: origin, size: size))
    }

    func hide() { panel.orderOut(nil) }

    private func style(card: Bool) {
        panel.hasShadow = card
        background.layer?.backgroundColor = card ? NSColor.windowBackgroundColor.cgColor : nil
        background.layer?.borderColor = card ? NSColor.separatorColor.cgColor : nil
        background.layer?.borderWidth = card ? 0.5 : 0
    }

    private func present(_ frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

/// Catches a typo in the word just finished, with the system spell checker (the languages set in macOS, Dutch included).
enum AutocompleteTypos {
    struct Fix {
        /// Characters to delete before the cursor: the word and the separator after it.
        var deleteCount: Int
        var replacement: String
        var original: String
        var corrected: String
    }

    @MainActor static func fix(for before: String) -> Fix? {
        guard let (word, separator) = CompletionTextAnalysis.justCompletedWord(in: before) else { return nil }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        guard checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound,
              let corrected = checker.correction(forWordRange: range, in: word, language: checker.language(), inSpellDocumentWithTag: 0),
              corrected != word else { return nil }
        return Fix(deleteCount: word.count + 1, replacement: corrected + String(separator), original: word, corrected: corrected)
    }
}
