import AppKit
import NaturalLanguage

/// Draws suggestions over whatever app has the focus, in a panel that takes no clicks and never becomes key, so typing goes
/// on in the app underneath.
///
/// The ghost text is drawn, not put in a label: in the app's own font and size (read through Accessibility), centred on the
/// cursor's line, starting exactly where the typed text ends, so it reads as the rest of the line instead of a box on top of
/// it. It only shows what fits in the field.
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

    /// The value of `key` in the card's text under `point` (AppKit screen coordinates), when the card is shown there: which
    /// emoji in the picker was clicked. The panel itself takes no clicks; the key tap asks this on a mouse down.
    func cardValue(at point: CGPoint, key: NSAttributedString.Key) -> Int? {
        guard panel.isVisible, panel.contentView === cardBackground, panel.frame.contains(point) else { return nil }
        let text = cardLabel.attributedStringValue
        let size = cardLabel.frame.size
        // The label draws from the bottom up; text layout counts from the top.
        let local = CGPoint(x: point.x - panel.frame.minX - cardLabel.frame.minX,
                            y: size.height - (point.y - panel.frame.minY - cardLabel.frame.minY))
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < text.length else { return nil }
        return text.attribute(key, at: index, effectiveRange: nil) as? Int
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
        /// Characters to delete before the cursor: the word and everything typed after it.
        var deleteCount: Int
        var replacement: String
        var original: String
        var corrected: String
        /// The next word is already being typed: the fix also retypes its start.
        var typedOn: Bool
    }

    /// The last word checked, in which languages, and its fix: the same word is checked again with every letter of the next.
    @MainActor private static var lastCheck: (word: String, languages: [String], corrected: String?)?

    /// - Parameter known: words (lowercased) that are never a typo: the user's own vocabulary and fixes they turned down.
    @MainActor static func fix(for before: String, known: Set<String> = []) -> Fix? {
        guard let (word, tail) = CompletionTextAnalysis.recentlyFinishedWord(in: before), !known.contains(word.lowercased()) else { return nil }
        let languages = languages(of: before)
        let corrected: String?
        if let last = lastCheck, last.word == word, last.languages == languages {
            corrected = last.corrected
        } else {
            corrected = correction(of: word, languages: languages)
            lastCheck = (word, languages, corrected)
        }
        guard let corrected else { return nil }
        return Fix(deleteCount: word.count + tail.count, replacement: corrected + tail, original: word, corrected: corrected,
                   typedOn: tail.last?.isLetter == true)
    }

    @MainActor private static func correction(of word: String, languages: [String]) -> String? {
        let checker = NSSpellChecker.shared
        guard let primary = languages.first, !checker.hasLearnedWord(word) else { return nil }
        // Only a typo when none of the user's languages knows the word: an English word in a Dutch message is not one.
        for language in languages {
            let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location == NSNotFound { return nil }
        }
        // The autocorrect choice first, then the guesses: `correction` alone often has nothing for a word that is clearly off.
        let range = NSRange(location: 0, length: (word as NSString).length)
        var candidates: [String] = []
        for language in languages.prefix(2) {
            if let corrected = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0) {
                candidates.append(corrected)
            }
        }
        candidates += checker.guesses(forWordRange: range, in: word, language: primary, inSpellDocumentWithTag: 0) ?? []
        guard var corrected = candidates.first(where: { CompletionTextAnalysis.isLikelyFix($0, for: word) }) else { return nil }
        if word.first?.isUppercase == true, corrected.first?.isLowercase == true { corrected = corrected.prefix(1).uppercased() + corrected.dropFirst() }
        return corrected
    }

    /// The spell checker's languages to check `text` in. When the recognizer is sure, only the text's own language: checking
    /// Dutch with an English dictionary would mark every word. Otherwise (short texts, mixed languages) its likely languages and
    /// the ones set in macOS, so a short message is checked too instead of not at all.
    @MainActor static func languages(of text: String) -> [String] {
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        func match(_ code: String) -> String? {
            available.first { $0 == code } ?? available.first { $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-") }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(400)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        if let (code, confidence) = hypotheses.first, confidence > 0.75, let language = match(code.rawValue) { return [language] }
        var result: [String] = []
        for (code, confidence) in hypotheses where confidence > 0.2 {
            if let language = match(code.rawValue), !result.contains(language) { result.append(language) }
        }
        for language in checker.userPreferredLanguages.prefix(3) where !result.contains(language) && available.contains(language) {
            result.append(language)
        }
        return result
    }
}
