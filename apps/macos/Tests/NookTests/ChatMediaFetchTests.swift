import XCTest

/// Fetching a read's files: a few at a time instead of one after another, every message in its own place, and only
/// the messages whose file is not on this Mac yet.
@MainActor
final class ChatMediaFetchTests: XCTestCase {
    private func message(_ id: String, path: String? = nil, media: Bool = true) -> InboxMessage {
        var message = InboxMessage(id: id, sender: "", text: "", date: Date(timeIntervalSince1970: 0), fromMe: false)
        if media { message.media = ChatMedia(kind: .photo, name: id + ".jpg", path: path, source: "https://x/" + id) }
        return message
    }

    func testFilesAreFetchedAFewAtATimeInTheirPlaces() async {
        let messages = (0..<10).map { message("m\($0)") } + [message("text", media: false), message("here", path: "/kept.jpg")]
        var running = 0
        var most = 0
        var asked: [String] = []
        let fetched = await ChatMedia.fetchingFiles(messages, limit: 3) { message in
            asked.append(message.id)
            running += 1
            most = max(most, running)
            try? await Task.sleep(for: .milliseconds(20))
            running -= 1
            return message.id == "m4" ? nil : "/saved/" + message.id
        }
        XCTAssertEqual(most, 3, "at most three at a time, and more than one")
        XCTAssertEqual(Set(asked), Set((0..<10).map { "m\($0)" }), "not a message without a file, nor one whose file is here")
        XCTAssertEqual(fetched.map(\.id), messages.map(\.id), "every message keeps its place")
        XCTAssertEqual(fetched[0].media?.path, "/saved/m0")
        XCTAssertNil(fetched[4].media?.path, "one that could not be fetched stays without a file")
        XCTAssertEqual(fetched[11].media?.path, "/kept.jpg")
    }
}
