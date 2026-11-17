import Foundation

// The Nook tab on the phone does what the Mac's Nook tab does (`CompanionFeature.nookChats`): the home with the Mac's
// "For you" rows, agenda, limits, player and starters; the list of conversations with what asks for you on top, the
// pinned ones, then Today, Yesterday, Previous 7 days and Older, a search and the archive; renaming, pinning,
// archiving, deleting, marking unread and retrying a conversation (`CompanionOp.chatAct`); a question asked while Nook
// still answers waits in line as on the Mac instead of stopping the answer; and pictures with a question.
// Foundation only, so the rules are tested on Linux.

/// One thing the phone does to one of Nook's conversations (`CompanionOp.chatAct`, `conversation` the conversation),
/// after your own tap, through the same functions as the Mac's list and conversation menu (`NookChat`).
struct NookChatAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// The conversation gets the name `text`.
        case rename
        /// Pinned on top of the list (`value`); a pinned conversation leaves the archive.
        case pin
        /// Into the archive or back out of it (`value`).
        case archive
        /// Gone for good, as "Delete" on the Mac.
        case delete
        /// Marked unread (`value` true) or read again (`value` false).
        case markUnread
        /// Nook answers the last question again, as "Retry" under a failed answer on the Mac.
        case retry
    }

    var kind: Kind
    var text: String? = nil
    var value: Bool? = nil

    /// The longest name the Mac keeps (`NookChat.rename`).
    static let titleLimit = 80

    /// Whether the action carries what it needs; the Mac checks again.
    var isComplete: Bool {
        switch kind {
        case .rename:
            let name = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name.count <= 200
        case .pin, .archive, .markUnread: return value != nil
        case .delete, .retry: return true
        }
    }

    /// What waits until Nook finished its answer, as on the Mac: a conversation Nook still writes in is not archived,
    /// deleted or asked again.
    var needsIdle: Bool {
        switch kind {
        case .archive, .delete, .retry: return true
        case .rename, .pin, .markUnread: return false
        }
    }
}

/// The list of conversations as the Mac's Nook tab shows it (`NookList`): what asks something of you on top, then the
/// pinned ones, then the rest by age (`DayBucket`). A scheduled task's run that asks nothing is left out without a
/// search, as on the Mac (its task's row opens it there).
enum NookChatSections {
    enum Group: String, CaseIterable, Sendable {
        case pinned, today, yesterday, previousWeek, older
    }

    /// One part of the list under its header.
    struct Section: Identifiable {
        var group: Group
        var chats: [ChatDigest]
        var id: Group { group }
    }

    /// Nook is writing, a plan or draft waits for you, or an answer came that you did not read.
    static func asksAttention(_ chat: ChatDigest) -> Bool {
        chat.busy || chat.waiting || chat.unread == true
    }

    /// The age group of `date`, as the Mac's `DayBucket`: a date in the future is today.
    static func group(for date: Date, now: Date, calendar: Calendar = .current) -> Group {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -8, to: today), date >= week { return .previousWeek }
        return .older
    }

    /// `chats` (newest first, as the Mac sends them) in the list's parts; empty groups are left out.
    static func sections(_ chats: [ChatDigest], searching: Bool, now: Date, calendar: Calendar = .current)
        -> (attention: [ChatDigest], groups: [Section]) {
        let attention = chats.filter(asksAttention)
        let settled = chats.filter { !asksAttention($0) && ($0.pinned == true || searching || $0.scheduled != true) }
        var byGroup: [Group: [ChatDigest]] = [:]
        for chat in settled {
            let group = chat.pinned == true ? Group.pinned : group(for: Date(timeIntervalSince1970: chat.updated), now: now, calendar: calendar)
            byGroup[group, default: []].append(chat)
        }
        let groups = Group.allCases.compactMap { group in byGroup[group].map { Section(group: group, chats: $0) } }
        return (attention, groups)
    }

    /// The words of a search, matched as the Mac matches them: every word in the title or the preview, ignoring case and
    /// accents. For a phone that filters what it already has while the Mac's answer is on its way.
    static func matches(_ chat: ChatDigest, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard !words.isEmpty else { return true }
        let haystack = (chat.title + " " + chat.preview).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy(haystack.contains)
    }

    /// The most questions in line one digest lists (`ChatDigest.queued`).
    static let maxQueued = 5
}

/// "Copy conversation" on the phone: the conversation as Markdown, as the Mac's `ChatExport` writes it, from the
/// messages the phone has.
enum NookChatExport {
    static func markdown(title: String, lines: [ChatLine], you: String) -> String {
        var parts = ["# " + title]
        for line in lines where !line.text.isEmpty {
            parts.append("**\(line.fromNook ? "Nook" : you)**\n\n" + line.text)
        }
        return parts.joined(separator: "\n\n")
    }
}
