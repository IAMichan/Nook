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

    func testTheNewestFilesAreFetchedFirst() async {
        var asked: [String] = []
        _ = await ChatMedia.fetchingFiles((0..<4).map { message("m\($0)") }, limit: 1) { message in
            asked.append(message.id)
            return nil
        }
        XCTAssertEqual(asked, ["m3", "m2", "m1", "m0"], "a chat opens at its newest message")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testASavedFileNeedsNoWaitToSettle() throws {
        let target = try temporaryFolder().appendingPathComponent("nested/photo.jpg")
        XCTAssertTrue(ChatMedia.save(Data("whole".utf8), to: target))
        XCTAssertTrue(ChatMedia.isSettled(target), "written in one go: whole at once")

        let other = target.deletingLastPathComponent().appendingPathComponent("incoming.jpg")
        try Data("part".utf8).write(to: other)
        XCTAssertFalse(ChatMedia.isSettled(other), "a file someone else writes still waits")
    }

    func testAKeptFileIsFoundAgainAndWholeAtOnce() {
        let key = "wa-test-" + UUID().uuidString
        XCTAssertNil(ChatMedia.kept(key: key))
        let target = ChatMedia.destination(key: key, name: "photo.jpg")
        addTeardownBlock { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        XCTAssertTrue(ChatMedia.save(Data("whole".utf8), to: target))
        XCTAssertEqual(ChatMedia.kept(key: key)?.lastPathComponent, "photo.jpg")
        XCTAssertTrue(ChatMedia.isSettled(target))
    }

    func testKeptFilesAreTrimmedOldestFirstAndRemovedByPrefix() throws {
        let folder = try temporaryFolder()
        let now = Date()
        for (index, name) in ["wa-a-old", "wa-a-new", "other-file"].enumerated() {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            XCTAssertTrue(ChatMedia.save(Data(count: 100), to: dir.appendingPathComponent("file")))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) * 60)], ofItemAtPath: dir.path)
        }
        ChatMedia.trimKept(prefix: "wa-", limit: 150, in: folder)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        XCTAssertFalse(exists("wa-a-old"), "the oldest goes first")
        XCTAssertTrue(exists("wa-a-new"))
        XCTAssertTrue(exists("other-file"), "another prefix is left alone")

        ChatMedia.removeKept(prefix: "wa-a-", in: folder)
        XCTAssertFalse(exists("wa-a-new"))
        XCTAssertTrue(exists("other-file"))
    }
}
