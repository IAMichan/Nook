import Foundation

/// One conversation can span several transcript files. Resuming a Claude Code chat (`--resume`, `/resume`, or Nook
/// continuing a chat that began in the home folder inside the project it moved to) starts a new file with a new session
/// id, so without this the Agents list shows one row per file for what you see as a single chat.
///
/// Files belong together when they share a link: a session id (copied lines keep the id they were written under), the
/// first message (a resumed file starts with the copied history), the message a continuation picks up from (the last
/// message of the file before), or the time and text of the first prompt.
enum ResumedConversations {
    struct Transcript {
        /// From `links(...)`, which must include the transcript's own session id.
        var links: Set<String>
    }

    /// The links for a transcript, from what it says about itself.
    static func links(sessionIDs: Set<String>, firstMessage: String, firstParent: String, lastMessage: String,
                      firstPrompt: String, firstPromptAt: String) -> Set<String> {
        var links = Set(sessionIDs.filter { !$0.isEmpty }.map { "session:" + $0 })
        for message in [firstMessage, firstParent, lastMessage] where !message.isEmpty { links.insert("message:" + message) }
        if !firstPrompt.isEmpty, !firstPromptAt.isEmpty { links.insert("prompt:\(firstPromptAt)|\(firstPrompt)") }
        return links
    }

    /// Groups transcripts that are one conversation, as indices into `transcripts`, each group in the order given.
    static func groups(_ transcripts: [Transcript]) -> [[Int]] {
        var parent = Array(transcripts.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var owner: [String: Int] = [:]
        for (index, transcript) in transcripts.enumerated() {
            for link in transcript.links {
                if let other = owner[link] {
                    let (a, b) = (root(other), root(index))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    owner[link] = index
                }
            }
        }
        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for index in transcripts.indices {
            let group = root(index)
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(index)
        }
        return order.compactMap { members[$0] }
    }
}
