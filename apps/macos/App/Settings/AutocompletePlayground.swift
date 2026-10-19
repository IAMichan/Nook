import AppKit
import SwiftUI

/// Settings › Autocomplete › Playground: a text box to try autocomplete in, with the same model, keys and settings as in other
/// apps, and what the model read and answered. Nothing typed here is saved or counted in the statistics.
struct AutocompletePlaygroundSection: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared
    @StateObject private var playground = CompletionPlayground()
    @State private var editor = PlaygroundEditorHandle()

    var body: some View {
        Group {
            Section {
                if !store.prefs.enabled || autocomplete.activeModel == nil {
                    StatusRow(title: tr("autocomplete.playground.unavailable"), detail: tr("autocomplete.playground.unavailableDetail"), state: .warning) {
                        Button(tr("autocomplete.tab.general")) { store.settingsTab = .general }
                    }
                }
                PlaygroundEditor(playground: playground, handle: editor)
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if playground.isEmpty {
                            Text(tr("autocomplete.playground.placeholder"))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 9)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                HStack(spacing: 10) {
                    if playground.thinking {
                        ProgressView().controlSize(.small)
                        Text(tr("autocomplete.playground.thinking")).foregroundStyle(.secondary)
                    } else if playground.suggestion != nil {
                        Text(tr("autocomplete.playground.keys", store.prefs.acceptWord.label, store.prefs.acceptAll.label))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("autocomplete.playground.clear")) { editor.clear() }.disabled(playground.isEmpty)
                }
                .font(.caption)
            } footer: {
                Text(tr("autocomplete.playground.footer"))
            }

            if let last = playground.last {
                Section(tr("autocomplete.playground.lastTitle")) {
                    if let model = autocomplete.activeModel {
                        LabeledContent(tr("autocomplete.playground.model")) { Text(model.title).lineLimit(1) }
                    }
                    LabeledContent(tr("autocomplete.playground.time")) { Text(tr("autocomplete.playground.ms", last.milliseconds)).monospacedDigit() }
                    LabeledContent(tr("autocomplete.playground.answer")) {
                        Text(last.raw.isEmpty ? tr("autocomplete.playground.noAnswer") : "“\(last.raw)”")
                            .foregroundStyle(last.raw.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                    }
                    LabeledContent(tr("autocomplete.playground.shown")) {
                        Text(last.suggestion.map { "“\($0.remaining)”" } ?? tr("autocomplete.playground.nothingShown"))
                            .foregroundStyle(last.suggestion == nil ? Color.secondary : Color.primary)
                    }
                    LabeledContent(tr("autocomplete.playground.taken")) { Text(tr("autocomplete.stats.words", playground.wordsTaken)).monospacedDigit() }
                    DisclosureGroup(tr("autocomplete.playground.prompt")) {
                        Text(last.prompt.document)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .onDisappear { playground.dismiss() }
    }
}

/// The Playground's state: the suggestion on screen and the text it continues. Mirrors how `AutocompleteController` treats a
/// field: a short pause after a key, typing through a suggestion keeps it, taking the last word asks for the next one at once.
@MainActor
final class CompletionPlayground: ObservableObject {
    @Published private(set) var suggestion: CompletionSuggestion?
    @Published private(set) var thinking = false
    @Published private(set) var last: CompletionPlaygroundResult?
    @Published private(set) var wordsTaken = 0
    @Published private(set) var isEmpty = true

    /// The text before the cursor that the suggestion continues.
    private var anchor = ""
    /// The text before the cursor the model was last asked about, so moving the cursor without typing does not ask again.
    private var requested: String?
    private var task: Task<Void, Never>?
    /// Goes up with everything typed; answers for older text are dropped.
    private var token = 0

    private var prefs: CompletionPreferences { AutocompleteStore.shared.prefs }

    /// The text or the cursor changed.
    func changed(before: String, after: String, hasSelection: Bool, isEmpty: Bool) {
        self.isEmpty = isEmpty
        if before == anchor, !hasSelection {
            // A word was just taken (or the cursor did not move): ask for more once the whole suggestion is in.
            if suggestion == nil, requested != before { request(before: before, after: after, continuing: true) }
            return
        }
        // Typing what the suggestion says keeps the rest of it.
        if var shown = suggestion, !hasSelection, before.hasPrefix(anchor), shown.consume(typed: String(before.dropFirst(anchor.count))) {
            anchor = before
            if shown.isEmpty {
                suggestion = nil
                request(before: before, after: after, continuing: true)
            } else {
                suggestion = shown
            }
            return
        }
        suggestion = nil
        anchor = before
        guard !hasSelection else {
            requested = nil
            return cancel()
        }
        request(before: before, after: after, continuing: false)
    }

    /// The next word to type, or nil when there is no suggestion.
    func takeWord() -> String? {
        guard var shown = suggestion else { return nil }
        let word = shown.acceptNextChunk(CompletionSuggestion.AcceptOptions(trailingSpace: prefs.trailingSpace, attachedPunctuation: prefs.attachedPunctuation))
        return take(word, leaving: shown)
    }

    /// The whole suggestion, or nil when there is none.
    func takeAll() -> String? {
        guard var shown = suggestion else { return nil }
        let text = shown.acceptAll()
        return take(text, leaving: shown)
    }

    func dismiss() {
        suggestion = nil
        cancel()
    }

    private func take(_ text: String, leaving rest: CompletionSuggestion) -> String? {
        guard !text.isEmpty else { return nil }
        wordsTaken += text.completionWordCount
        anchor += text
        suggestion = rest.isEmpty ? nil : rest
        return text
    }

    private func cancel() {
        token += 1
        task?.cancel()
        task = nil
        thinking = false
    }

    private func request(before: String, after: String, continuing: Bool) {
        cancel()
        let policy = CompletionPolicy(midLine: false)
        guard prefs.enabled, policy.shouldComplete(before: before, after: after, hasSelection: false), before.last?.isNewline != true else { return }
        requested = before
        let token = self.token
        let delay = continuing ? 0 : UInt64(max(prefs.delayMilliseconds, 120)) * 1_000_000
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled, token == self.token else { return }
            self.thinking = true
            let result = await AutocompleteController.shared.playgroundCompletion(before: before, continuing: continuing)
            guard token == self.token else { return }
            self.thinking = false
            self.task = nil
            self.last = result
            self.anchor = before
            self.suggestion = result?.suggestion
        }
    }
}

/// Lets the Playground's buttons reach the text view.
final class PlaygroundEditorHandle {
    fileprivate weak var textView: PlaygroundTextView?

    @MainActor func clear() {
        guard let textView else { return }
        textView.selectAll(nil)
        textView.insertText("", replacementRange: textView.selectedRange())
        textView.window?.makeFirstResponder(textView)
    }
}

/// A plain text view that shows the suggestion as grey text at the cursor and takes it with the autocomplete keys.
private struct PlaygroundEditor: NSViewRepresentable {
    @ObservedObject var playground: CompletionPlayground
    let handle: PlaygroundEditorHandle

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        // TextKit 1: the ghost is placed with the layout manager.
        let textView = PlaygroundTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        textView.delegate = context.coordinator
        textView.playground = playground
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // The model's own words, as it wrote them: no corrections or replacements in between.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        handle.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlaygroundTextView else { return }
        textView.playground = playground
        textView.ghost = playground.suggestion?.remaining ?? ""
    }

    func makeCoordinator() -> Coordinator { Coordinator(playground: playground) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let playground: CompletionPlayground

        init(playground: CompletionPlayground) { self.playground = playground }

        func textDidChange(_ notification: Notification) { report(notification) }
        func textViewDidChangeSelection(_ notification: Notification) { report(notification) }

        private func report(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.string as NSString
            let range = textView.selectedRange()
            guard range.location != NSNotFound, range.location + range.length <= text.length else { return }
            playground.changed(before: text.substring(to: range.location), after: text.substring(from: range.location + range.length),
                               hasSelection: range.length > 0, isEmpty: text.length == 0)
        }
    }
}

private final class PlaygroundTextView: NSTextView {
    weak var playground: CompletionPlayground?
    /// The suggestion drawn at the cursor.
    var ghost = "" {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }

    override func keyDown(with event: NSEvent) {
        if let playground, playground.suggestion != nil {
            let prefs = AutocompleteStore.shared.prefs
            let code = Int(event.keyCode)
            let modifiers = Self.modifiers(event.modifierFlags)
            if prefs.acceptWord.matches(keyCode: code, modifiers: modifiers), let word = playground.takeWord() {
                insertText(word, replacementRange: selectedRange())
                return
            }
            if prefs.acceptAll.matches(keyCode: code, modifiers: modifiers), let text = playground.takeAll() {
                insertText(text, replacementRange: selectedRange())
                return
            }
            if code == 53 {
                playground.dismiss()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Escape is for the suggestion here, not for the system's word list.
    override func complete(_ sender: Any?) {}

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= CompletionShortcut.command }
        if flags.contains(.option) { result |= CompletionShortcut.option }
        if flags.contains(.control) { result |= CompletionShortcut.control }
        if flags.contains(.shift) { result |= CompletionShortcut.shift }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ghost.isEmpty, selectedRange().length == 0, let origin = caretOrigin() else { return }
        let font = self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: style]
        let width = bounds.width - textContainerInset.width - origin.x
        guard width > 8 else { return }
        (ghost as NSString).draw(in: NSRect(x: origin.x, y: origin.y, width: width, height: font.boundingRectForFont.height + 2),
                                 withAttributes: attributes)
    }

    /// The top left of where the next letter goes: the right edge of the character before the cursor.
    private func caretOrigin() -> NSPoint? {
        guard let layoutManager, let textContainer else { return nil }
        let location = selectedRange().location
        guard location > 0, location <= (string as NSString).length else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location - 1, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSPoint(x: box.maxX + origin.x, y: line.minY + origin.y)
    }
}
