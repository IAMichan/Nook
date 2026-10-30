import XCTest

/// Forwarding a message to another chat: its text, its file with the text as caption, and chats that cannot take it.
final class ChatForwardTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testAnEmptyMessageHasNothingToForward() {
        XCTAssertNil(ChatForward(text: "  \n "))
        XCTAssertEqual(ChatForward(text: " Hi ")?.text, "Hi")
    }

    func testTextGoesToEveryChat() throws {
        let forward = try XCTUnwrap(ChatForward(text: "See you at eight"))
        let parts = try XCTUnwrap(forward.parts(sends: []))
        XCTAssertNil(parts.attachment)
        XCTAssertEqual(parts.text, "See you at eight")
    }

    func testAPhotoTakesTheTextAsItsCaption() throws {
        let forward = try XCTUnwrap(ChatForward(text: "Beach", file: try file("beach.jpg"), kind: .photo))
        let parts = try XCTUnwrap(forward.parts(sends: ChatOutgoing.Kind.everything))
        XCTAssertEqual(parts.attachment?.kind, .photo)
        XCTAssertEqual(parts.attachment?.caption, "Beach")
        XCTAssertEqual(parts.text, "")
    }

    func testAStickerSendsItsTextAfterIt() throws {
        let forward = try XCTUnwrap(ChatForward(text: "Ha", file: try file("s.webp"), kind: .sticker))
        let parts = try XCTUnwrap(forward.parts(sends: ChatOutgoing.Kind.everything))
        XCTAssertEqual(parts.attachment?.kind, .sticker)
        XCTAssertEqual(parts.attachment?.caption, "")
        XCTAssertEqual(parts.text, "Ha")
    }

    func testAChatThatTakesNoSuchFileCannotGetIt() throws {
        let forward = try XCTUnwrap(ChatForward(text: "Plan", file: try file("plan.pdf")))
        XCTAssertFalse(forward.fits([]), "a text-only chat gets no half message")
        XCTAssertFalse(forward.fits([.photo]))
        XCTAssertTrue(forward.fits([.file]))
    }

    func testAFileThatIsGoneCannotBeForwarded() throws {
        let forward = try XCTUnwrap(ChatForward(text: "", file: folder.appendingPathComponent("gone.jpg"), kind: .photo))
        XCTAssertFalse(forward.fits(ChatOutgoing.Kind.everything))
    }
}
