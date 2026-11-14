import AppKit

/// Readies the pictures of a chat's newest messages before its bubbles are drawn, the same for every chat app: the
/// photos decoded at a bubble's size and the videos' stills made, a few at a time, newest first. Started when the
/// pointer rests on a chat in the list and again as it opens, so the chat appears with its pictures in place instead
/// of with placeholders that fill one by one. The bubbles share these decodes (`ChatMediaImages.load`,
/// `ChatVideoStills.still`): nothing is decoded twice.
@MainActor
enum ChatMediaWarmup {
    /// How many of the newest messages: the page a chat opens with.
    static let count = ChatTranscript.page
    /// How many pictures are made at the same time: enough to fill a chat quickly, few enough to leave the opening
    /// chat's own work room.
    static let parallel = 4

    /// The warm-up going on per chat: hovering a chat and then opening it does not start a second one.
    private static var running: [String: Task<Void, Never>] = [:]

    static func warm(_ thread: InboxThread?) {
        guard let thread, running[thread.id] == nil else { return }
        let files = pictures(thread.messages.suffix(count))
        guard !files.isEmpty else { return }
        let id = thread.id
        running[id] = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = files.makeIterator()
                for _ in 0..<parallel {
                    guard let file = next.next() else { break }
                    group.addTask { await make(file) }
                }
                while await group.next() != nil {
                    guard let file = next.next() else { continue }
                    group.addTask { await make(file) }
                }
            }
            running[id] = nil
        }
    }

    private enum Picture: Sendable {
        case photo(URL), video(URL)
    }

    /// The photos and videos among `messages` that are on this Mac and not made yet, newest first.
    private static func pictures(_ messages: ArraySlice<InboxMessage>) -> [Picture] {
        messages.reversed().compactMap { message in
            guard let media = message.media, let url = media.url else { return nil }
            switch media.shownKind {
            case .photo:
                // A file still being written is left to its bubble, which waits for it.
                guard ChatMediaImages.cached(url) == nil, ChatMedia.isSettled(url) else { return nil }
                return .photo(url)
            case .video:
                return ChatVideoStills.cached(url) == nil ? .video(url) : nil
            default:
                return nil
            }
        }
    }

    private static func make(_ picture: Picture) async {
        switch picture {
        case .photo(let url): _ = await ChatMediaImages.load(url)
        case .video(let url): _ = await ChatVideoStills.still(url)
        }
    }
}
