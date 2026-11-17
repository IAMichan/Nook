import Foundation

/// The Nook tab as on the Mac (`CompanionFeature.nookChats`, `CompanionNookChats.swift`): the home, the player's
/// buttons, the search and the archive, and what the conversation menu does.
extension CompanionClient {
    /// The Mac's home: For you, the agenda, the limits, what plays and where to start.
    func loadHome() async {
        guard can(CompanionFeature.home), allows(.read), !Self.isDemo else { return }
        await perform(CompanionRequest(op: .home), quiet: true)
    }

    /// Whether the player's buttons work from this phone.
    var controlsMusic: Bool { can(CompanionFeature.music) && allows(.music) }

    /// Play/pause, next or previous on the Mac (`command`: "playpause", "next", "previous"); answered with the home.
    func music(_ command: String) async {
        guard controlsMusic, !Self.isDemo else { return }
        await perform(CompanionRequest(op: .music, text: command))
    }

    /// The conversations whose title or last answer hold `words`, or the archive (`archive`), as the Mac's search
    /// finds them. No words outside the archive ends the search.
    func searchNookChats(_ words: String, archive: Bool) async {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard can(CompanionFeature.nookChats), archive || !words.isEmpty else {
            if nookFound != nil { nookFound = nil }
            return
        }
        if Self.isDemo {
            nookFound = (archive ? Self.demoArchive : conversations).filter { NookChatSections.matches($0, query: words) }
            return
        }
        await perform(CompanionRequest(op: .chatSearch, text: words, allow: archive), quiet: true)
    }

    /// The model, access and sources of Nook's composer, for `conversation` (nil for a new chat).
    func loadNookComposer(conversation: String?) async {
        guard can(CompanionFeature.nookComposer), allows(.nookChat), !Self.isDemo else { return }
        var request = CompanionRequest(op: .nookComposer)
        request.conversation = conversation
        if let digest = await perform(request, quiet: true)?.nookComposer { nookComposer = digest }
    }

    /// One choice of Nook's composer changed on the Mac, after your tap (`NookComposerChange`); the Mac answers with all
    /// of them as they are now.
    func setNookComposer(_ change: NookComposerChange, item: String = "", on: Bool = true, conversation: String?) async {
        guard can(CompanionFeature.nookComposer), allows(.operate) else { return }
        var request = CompanionRequest(op: .nookComposerSet, text: change.rawValue, allow: on)
        request.item = item
        request.conversation = conversation
        if let digest = await perform(request)?.nookComposer { nookComposer = digest }
    }

    /// *Do it* or the cross on what Nook could do next (`CompanionFeature.actionSuggestions`), after your tap. The cross
    /// hides it here at once; the Mac's lists bring the new state either way.
    func actOnSuggestion(_ suggestion: ActionSuggestionDigest, _ act: SuggestionAct) async {
        if act == .dismiss { dismissedSuggestions.insert(suggestion.conversation + "|" + (suggestion.steps.first?.text ?? "")) }
        guard can(CompanionFeature.actionSuggestions), !Self.isDemo else { return }
        await perform(CompanionRequest(op: .suggestionAct, item: suggestion.conversation, text: act.rawValue))
    }

    /// A suggestion to show: one the Mac offers that was not put away here.
    func shownSuggestion(_ suggestion: ActionSuggestionDigest?) -> ActionSuggestionDigest? {
        guard let suggestion, can(CompanionFeature.actionSuggestions) || Self.isDemo,
              !dismissedSuggestions.contains(suggestion.conversation + "|" + (suggestion.steps.first?.text ?? "")) else { return nil }
        return suggestion
    }

    /// Something done to one of Nook's conversations as on the Mac, after your own tap: true when the Mac did it. The Mac
    /// answers with the list as it is after it; a refusal says why in `notice`.
    @discardableResult
    func actOnNookChat(_ conversationID: String, _ action: NookChatAction) async -> Bool {
        guard can(CompanionFeature.nookChats), action.isComplete else { return false }
        var request = CompanionRequest(op: .chatAct, conversation: conversationID)
        request.nookAction = action
        guard await perform(request) != nil else { return false }
        // What the search or the archive shows changes with it.
        if nookFound != nil { nookFound = nookFound?.filter { $0.id != conversationID || action.kind != .delete } }
        return true
    }

    /// The conversation as Markdown, as "Copy conversation" on the Mac writes it, from the messages this phone has.
    func nookMarkdown(_ conversationID: String) -> String {
        let title = conversations.first { $0.id == conversationID }?.title
            ?? nookFound?.first { $0.id == conversationID }?.title ?? String(localized: "New chat")
        return NookChatExport.markdown(title: title, lines: chatLines[conversationID] ?? [], you: String(localized: "You"))
    }

    /// The conversation's digest, in the open list or in what the search or archive found.
    func nookDigest(_ conversationID: String) -> ChatDigest? {
        conversations.first { $0.id == conversationID } ?? nookFound?.first { $0.id == conversationID }
    }

    /// The archive of the demo (`-NookDemo`).
    static var demoArchive: [ChatDigest] {
        let now = Date().timeIntervalSince1970
        return [ChatDigest(id: "c9", title: "Holiday in Rome", updated: now - 86400 * 40, busy: false, waiting: false,
                           preview: "The flights on Friday are the cheapest.", archived: true)]
    }
}
