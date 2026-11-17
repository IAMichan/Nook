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
