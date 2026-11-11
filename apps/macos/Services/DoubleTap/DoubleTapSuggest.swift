import Foundation

// Double Tap suggestions: what Nook could do with what is in front of you right now, as one-click chips under the
// field the double tap opens. Text selected in a document gets "Improve this", "Shorten this" and a translation into
// the language it is not in; an empty reply box gets "Write a reply"; a form with empty fields gets "Fill in the form";
// a window full of dates gets "Put this in my calendar"; and the last things you asked come back as chips too. Every
// suggestion is an ordinary request in the user's language, so it takes the same path as one typed by hand
// (`AppModel.askFromQuickField`): writing at the cursor, filling the form, or the chat with the window attached.

/// What is in front of the user at the moment of the double tap, as far as suggestions need it.
struct DoubleTapScene: Equatable {
    enum Focus: Equatable {
        /// No text that takes typing has the keyboard (a page, a list, the desktop).
        case none
        /// A one-line field (a search box, a subject, a chat's message box in some apps).
        case field
        /// A text area or a document (a mail body, Word's page, a note).
        case text
    }

    var app = ""
    var bundleID = ""
    var focus: Focus = .none
    /// The selected text in the focused field, if any.
    var selection = ""
    /// The focused field holds no text yet.
    var focusEmpty = true
    /// The field's placeholder ("Write a message…"), which tells a reply box from a document.
    var placeholder = ""
    /// Empty fields Nook may fill in the window in front (`DoubleTapLogic.candidates`).
    var emptyFields = 0
    /// The text of the window in front, as the active brain may see it (for dates and for "summarize").
    var windowText = ""
}

/// One chip under the Double Tap field: the request it sends, and its symbol.
struct DoubleTapSuggestion: Equatable {
    var text: String
    var symbol: String
}

extension DoubleTapLogic {
    /// At most this many chips: the field stays a field, not a menu.
    static let maxSuggestions = 4
    /// The requests remembered for the chips, newest first.
    static let maxRecents = 8

    /// Apps whose text box is where you answer someone: an empty box there asks for a reply.
    static let replyApps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.microsoft.teams", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.hnc.Discord", "com.apple.mail", "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac", "com.facebook.archon", "com.beeper.beeper-desktop", "com.automattic.beeper.desktop"
    ]
    /// Placeholder words of a reply box, in every language Nook speaks ("Write a message", "Typ een bericht").
    static let replyPlaceholderWords: [String] = [
        "message", "reply", "answer", "respond", "comment",
        "bericht", "antwoord", "reageer", "reactie",
        "nachricht", "antwort", "antworten", "kommentar",
        "réponse", "répondre", "repondre", "commentaire",
        "mensaje", "respuesta", "responder", "comentario"
    ]

    /// The chips for what is in front, then the most recent requests that are not among them, at most `maxSuggestions`.
    /// `language`: the app's language, which the suggestions are written in and a translation goes to.
    static func suggestions(for scene: DoubleTapScene?, recents: [String], language: AppLanguage,
                            selectionLanguage: String? = nil, now: Date = Date()) -> [DoubleTapSuggestion] {
        var chips: [DoubleTapSuggestion] = []
        let text = { (key: String, args: [CVarArg]) in I18n.text(key, args, for: language) }
        if let scene {
            let selected = scene.selection.trimmingCharacters(in: .whitespacesAndNewlines)
            if scene.focus != .none, !selected.isEmpty {
                // Text selected where Nook can type: rewrite it in place.
                chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.improve", []), symbol: "sparkles"))
                if let target = translationTarget(selectionLanguage: selectionLanguage, app: language) {
                    let name = Locale(identifier: language.rawValue).localizedString(forLanguageCode: target) ?? target
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.translate", [name]), symbol: "globe"))
                }
                if selected.count > 120 {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.shorten", []), symbol: "text.word.spacing"))
                }
                chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.explain", []), symbol: "questionmark.bubble"))
            } else {
                if scene.emptyFields >= 2 || (scene.emptyFields >= 1 && scene.focus == .field && scene.focusEmpty
                                              && !isReplyBox(scene)) {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.fill", []), symbol: "list.bullet.rectangle"))
                }
                if scene.focus != .none, isReplyBox(scene), scene.focusEmpty {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.reply", []), symbol: "arrowshape.turn.up.left"))
                } else if scene.focus == .text, !scene.focusEmpty {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.continue", []), symbol: "text.append"))
                }
                if hasDates(scene.windowText, now: now) {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.calendar", []), symbol: "calendar.badge.plus"))
                }
                if scene.windowText.count >= 600 {
                    chips.append(DoubleTapSuggestion(text: text("doubletap.suggest.summarize", []), symbol: "text.alignleft"))
                }
            }
        }
        chips = Array(chips.prefix(maxSuggestions))
        // What you asked lately, so a request you repeat is one click; at least one when there is room.
        let shown = Set(chips.map { $0.text.lowercased() })
        for recent in recents where chips.count < maxSuggestions && !shown.contains(recent.lowercased()) {
            chips.append(DoubleTapSuggestion(text: recent, symbol: "clock.arrow.circlepath"))
        }
        return chips
    }

    /// An empty box in a chat or mail app, or one whose placeholder asks for a message: where you answer someone.
    static func isReplyBox(_ scene: DoubleTapScene) -> Bool {
        if replyApps.contains(scene.bundleID) { return true }
        let placeholder = scene.placeholder.lowercased()
        guard !placeholder.isEmpty else { return false }
        return replyPlaceholderWords.contains { placeholder.contains($0) }
    }

    /// The language a selection should be translated into: the app's language when the selection is in another one,
    /// else English (or nothing when the app's language is English too). Nil when the language was not recognized.
    static func translationTarget(selectionLanguage: String?, app: AppLanguage) -> String? {
        guard let source = selectionLanguage?.prefix(2).lowercased(), !source.isEmpty else { return nil }
        if source != app.rawValue { return app.rawValue }
        return app == .en ? nil : "en"
    }

    /// Whether the window names a day: a date from yesterday to a year from now, written with a day in it (not only a
    /// clock time, which nearly every window shows).
    static func hasDates(_ text: String, now: Date = Date()) -> Bool {
        let sample = String(text.prefix(4_000))
        guard !sample.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return false
        }
        let from = now.addingTimeInterval(-24 * 3_600)
        let until = now.addingTimeInterval(366 * 24 * 3_600)
        let ns = sample as NSString
        for match in detector.matches(in: sample, range: NSRange(location: 0, length: ns.length)) {
            guard let date = match.date, date >= from, date <= until else { continue }
            let written = ns.substring(with: match.range)
            // "14:30" alone is a clock; "12 november", "di 14 nov 14:30", "11-12" name a day.
            let clockOnly = written.range(of: #"^\s*\d{1,2}[:.]\d{2}\s*(am|pm|uur|h)?\s*$"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
            if !clockOnly { return true }
        }
        return false
    }

    /// Remembers a request typed in the Double Tap field, newest first, without repeats.
    static func remembering(_ request: String, in recents: [String]) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return recents }
        let rest = recents.filter { $0.lowercased() != trimmed.lowercased() }
        return Array(([trimmed] + rest).prefix(maxRecents))
    }
}
