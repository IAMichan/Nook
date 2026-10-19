import AppKit
import NaturalLanguage

/// Draws suggestions over whatever app has the focus, in a panel that takes no clicks and never becomes key, so typing goes
/// on in the app underneath.
///
/// The ghost text is drawn, not put in a label: in the app's own font and size (read through Accessibility), centred on the
/// cursor's line, starting exactly where the typed text ends, so it reads as the rest of the line instead of a box on top of
/// it. It only shows what fits in the field. After Typist's overlay (MIT, © 2026 Brody Salvucci).
@MainActor
final class GhostOverlay {
    private let panel: NSPanel
    private let ghost = GhostTextView()
    private let cardBackground = NSView()
    private let cardLabel = NSTextField(labelWithString: "")
    private let inset = CGSize(width: 7, height: 4)

    /// Where the ghost is now, to move it along as letters are typed or words taken.
    private var ghostState: (caret: CGRect, font: NSFont, verticalOffset: Double, limit: CGFloat)?

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
        cardBackground.wantsLayer = true
        cardBackground.layer?.cornerRadius = 6
        cardBackground.layer?.borderWidth = 0.5
        cardLabel.lineBreakMode = .byClipping
        cardBackground.addSubview(cardLabel)
    }

    var isVisible: Bool { panel.isVisible }

    /// The font the suggestion is drawn in: the app's when it says, otherwise the system font sized from the line height.
    static func font(name: String?, size: CGFloat?, caretHeight: CGFloat, scale: Double) -> NSFont {
        let base = size ?? (caretHeight * 0.78).rounded()
        let points = min(max(base * scale, 8), 72)
        return name.flatMap { NSFont(name: $0, size: points) } ?? .systemFont(ofSize: points)
    }

    /// The part of `text` that fits between the cursor and `limit` (the field's right edge), in whole words. Empty when not even
    /// the first word fits.
    static func fitting(_ text: String, font: NSFont, from x: CGFloat, to limit: CGFloat) -> String {
        let room = limit - x
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > room else { return text }
        var fitted = ""
        for chunk in CompletionSuggestion.chunks(of: Substring(text)) {
            let next = fitted + chunk
            if (next as NSString).size(withAttributes: attributes).width > room { break }
            fitted = next
        }
        return fitted
    }

    /// Grey text going on from the cursor, in the line itself. Returns what is shown (the words that fit), or "" when nothing fits.
    @discardableResult
    func showGhost(_ text: String, at caret: CGRect, font: NSFont, limit: CGFloat?, verticalOffset: Double = 0) -> String {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: caret.minX, y: caret.midY)) } ?? NSScreen.main
        let right = min(limit ?? .greatestFiniteMagnitude, (screen?.visibleFrame.maxX ?? caret.maxX + 2_000) - 2)
        let shown = Self.fitting(text, font: font, from: caret.minX, to: right)
        guard !shown.trimmingCharacters(in: .whitespaces).isEmpty else { hide(); return "" }
        ghostState = (caret, font, verticalOffset, right)
        draw(shown)
        return shown
    }

    /// Moves the ghost right by the width of `typed` (letters typed through, or a word just taken) and shows `remaining`, without
    /// waiting for the app: so the suggestion never sits on top of the new letters. False when there is no ghost to move.
    @discardableResult
    func advance(over typed: String, remaining: String) -> Bool {
        guard var state = ghostState, panel.isVisible, panel.contentView === ghost else { return false }
        let width = (typed as NSString).size(withAttributes: [.font: state.font]).width
        state.caret.origin.x += width
        ghostState = state
        let shown = Self.fitting(remaining, font: state.font, from: state.caret.minX, to: state.limit)
        guard !shown.trimmingCharacters(in: .whitespaces).isEmpty else { hide(); return false }
        draw(shown)
        return true
    }

    private func draw(_ text: String) {
        guard let state = ghostState else { return }
        ghost.text = NSAttributedString(string: text, attributes: [.font: state.font, .foregroundColor: NSColor.placeholderTextColor])
        let size = ghost.text.size()
        let height = max(state.caret.height, ceil(size.height))
        ghost.frame = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: height)
        ghost.needsDisplay = true
        panel.hasShadow = false
        panel.contentView = ghost
        // Centred on the cursor's line, like the text it continues.
        let origin = CGPoint(x: state.caret.minX, y: state.caret.midY - height / 2 + state.verticalOffset)
        present(CGRect(origin: origin, size: ghost.frame.size))
    }

    /// A small card just below `anchor` (the cursor, a selection or the field): emoji, typo fixes, other words.
    func showCard(_ text: NSAttributedString, below anchor: CGRect) {
        ghostState = nil
        cardLabel.maximumNumberOfLines = 0
        cardLabel.attributedStringValue = text
        cardBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        cardBackground.layer?.borderColor = NSColor.separatorColor.cgColor
        let fitting = cardLabel.fittingSize
        let size = CGSize(width: fitting.width + inset.width * 2, height: fitting.height + inset.height * 2)
        cardLabel.frame = CGRect(x: inset.width, y: inset.height, width: fitting.width, height: fitting.height)
        cardBackground.frame = CGRect(origin: .zero, size: size)
        panel.hasShadow = true
        panel.contentView = cardBackground
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 3)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) {
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 3 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width)
        }
        present(CGRect(origin: origin, size: size))
    }

    func hide() {
        ghostState = nil
        panel.orderOut(nil)
    }

    private func present(_ frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

/// Draws one line of text, vertically centred, with nothing behind it.
private final class GhostTextView: NSView {
    var text = NSAttributedString()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        text.draw(at: CGPoint(x: 0, y: (bounds.height - size.height) / 2))
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
        guard let (word, separator) = CompletionTextAnalysis.justCompletedWord(in: before),
              let language = language(of: before) else { return nil }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location != NSNotFound,
              let corrected = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0),
              corrected != word else { return nil }
        return Fix(deleteCount: word.count + 1, replacement: corrected + String(separator), original: word, corrected: corrected)
    }

    /// The language the text is written in, as one of the spell checker's languages; nil when unsure or not available.
    /// Checking Dutch with an English dictionary would mark every word, and a marked word holds back every suggestion.
    @MainActor static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(400)))
        guard let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.6 else { return nil }
        let available = NSSpellChecker.shared.availableLanguages
        return available.first { $0 == code.rawValue } ?? available.first { $0.hasPrefix(code.rawValue + "_") || $0.hasPrefix(code.rawValue + "-") }
    }
}
