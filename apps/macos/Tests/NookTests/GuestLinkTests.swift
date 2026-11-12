import XCTest

/// Guest links: the room and link, sealing (the same vectors as apps/relay/test/guest.test.js), what a guest sees, putting a
/// message back together, what a message may hold, holding it for you, and how long a link works.
final class GuestLinkTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)
    static let room = "afda7e68ed10b7e277b7f88de9de7a9d"
    static let sealed = "AQEBAQEBAQEBAQEBDcP9laqdmme0o/4NUkMZRcSeNs46VJIxJRUxGm9nvmJGEeShmTgKqpY="

    // MARK: Room, link and key

    func testTheRoomMatchesThePage() {
        XCTAssertEqual(GuestLinkRoom.room(key: key), Self.room)
        XCTAssertTrue(CompanionRelay.isRoom(GuestLinkRoom.room(key: key)))
    }

    func testTheKeyStaysInTheFragmentAndComesBack() throws {
        let url = try XCTUnwrap(GuestLinkRoom.url(relay: "https://r.example/", key: key))
        let parts = url.split(separator: "#")
        XCTAssertEqual(parts.first, "https://r.example/v1/guest")
        XCTAssertFalse(parts.last!.contains("+"))
        XCTAssertFalse(parts.last!.contains("="))
        XCTAssertEqual(GuestLinkRoom.key(fromLink: url), key)
        XCTAssertNil(GuestLinkRoom.key(fromLink: "https://r.example/v1/guest#short"))
        XCTAssertNil(GuestLinkRoom.key(fromLink: "https://r.example/v1/guest"))
    }

    func testNoLinkWithoutASafeRelay() {
        XCTAssertNil(GuestLinkRoom.url(relay: "http://r.example", key: key))
    }

    #if canImport(CryptoKit)
    func testSealingMatchesThePage() throws {
        let sealed = try XCTUnwrap(GuestLinkSeal.seal(Data(#"{"t":"view","title":"é"}"#.utf8), key: key, nonce: Data(repeating: 1, count: 12)))
        XCTAssertEqual(sealed.base64EncodedString(), Self.sealed)
        XCTAssertEqual(GuestLinkSeal.open(sealed, key: key), Data(#"{"t":"view","title":"é"}"#.utf8))
    }

    func testOnlyTheKeyOpensAndNothingChangesUnseen() throws {
        let sealed = try XCTUnwrap(GuestLinkSeal.seal(Data("hi".utf8), key: key))
        XCTAssertNil(GuestLinkSeal.open(sealed, key: Data(repeating: 8, count: 32)))
        var changed = sealed
        changed[changed.count - 1] ^= 1
        XCTAssertNil(GuestLinkSeal.open(changed, key: key))
        XCTAssertNil(GuestLinkSeal.open(Data([1, 2, 3]), key: key))
        XCTAssertNotEqual(GuestLinkSeal.newKey(), GuestLinkSeal.newKey())
    }
    #endif

    // MARK: What the guest sees

    func testAGuestSeesNoToolOutputOrThinking() {
        var tool = RunEvent(kind: .tool, text: "cat .env")
        tool.tool = "Bash"
        tool.output = "SECRET=1"
        var undone = RunEvent(kind: .assistant, text: "undone")
        undone.rolledBack = true
        let shown = GuestLink.entries([RunEvent(kind: .user, text: "hi"), RunEvent(kind: .thinking, text: "secret thought"), tool,
                                       RunEvent(kind: .system, text: "launch"), undone, RunEvent(kind: .assistant, text: "done")])
        XCTAssertEqual(shown, [.init(kind: "you", text: "hi"), .init(kind: "tool", text: "Bash"), .init(kind: "agent", text: "done")])
    }

    func testTheViewOnTheWire() throws {
        let until = Date(timeIntervalSince1970: 100)
        let view = GuestLink.Outgoing.view(title: "T", working: true, entries: [], held: [.init(id: "a", text: "q", files: ["x.png"])], until: until)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "view")
        XCTAssertEqual(object["until"] as? Double, 100)
        let ack = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(GuestLink.Outgoing.ack("m", .tooLarge))) as? [String: Any])
        XCTAssertEqual(ack["ok"] as? Bool, false)
        XCTAssertEqual(ack["reason"] as? String, "tooLarge")
    }

    // MARK: A message in slices

    private func slices(_ id: String, _ text: String, size: Int) -> [Data] {
        let characters = Array(text)
        let count = max(1, (characters.count + size - 1) / size)
        return (0..<count).map { index in
            let piece = String(characters[(index * size)..<min(characters.count, (index + 1) * size)])
            let object: [String: Any] = ["t": "slice", "id": id, "i": index, "n": count, "d": piece]
            return try! JSONSerialization.data(withJSONObject: object)
        }
    }

    func testSlicesComeTogetherInAnyOrder() {
        var assembler = GuestSlices()
        let json = #"{"text":"hello there","files":[]}"#
        let parts = slices("m1", json, size: 5)
        XCTAssertGreaterThan(parts.count, 2)
        for part in parts.reversed().dropLast() { XCTAssertEqual(assembler.add(part), .waiting) }
        XCTAssertEqual(assembler.add(parts.first!), .complete(id: "m1", json: Data(json.utf8)))
        XCTAssertEqual(assembler.inProgress, 0)
    }

    func testTooManySlicesAreRefused() {
        var assembler = GuestSlices()
        let object: [String: Any] = ["t": "slice", "id": "m", "i": 0, "n": GuestLink.maxSlices + 1, "d": "x"]
        XCTAssertEqual(assembler.add(try! JSONSerialization.data(withJSONObject: object)), .refused(id: "m", .tooLarge))
        XCTAssertEqual(assembler.add(Data("nonsense".utf8)), .refused(id: nil, .malformed))
    }

    func testAnUnfinishedMessageIsDroppedAfterAWhile() {
        var assembler = GuestSlices()
        let parts = slices("m", #"{"text":"abcdefghij"}"#, size: 4)
        let start = Date()
        XCTAssertEqual(assembler.add(parts[0], now: start), .waiting)
        XCTAssertEqual(assembler.inProgress, 1)
        // A new message much later: the old pieces are gone, so its last slice alone does not finish it.
        XCTAssertEqual(assembler.add(parts[1], now: start.addingTimeInterval(GuestLink.assemblyTimeout + 1)), .waiting)
        XCTAssertEqual(assembler.inProgress, 1)
    }

    // MARK: What a message may hold

    private func json(_ text: String, files: [(String, String, Data)] = []) -> Data {
        let list = files.map { ["name": $0.0, "type": $0.1, "data": $0.2.base64EncodedString()] }
        return try! JSONSerialization.data(withJSONObject: ["text": text, "files": list])
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    func testAMessageWithFiles() throws {
        let message = try GuestLink.message(id: "a", json: json(" look ", files: [("../../shot.png", "image/png", Self.png),
                                                                                    ("notes.txt", "text/plain", Data("x".utf8))])).get()
        XCTAssertEqual(message.text, "look")
        XCTAssertEqual(message.files.map(\.name), ["shot.png", "notes.txt"])
        XCTAssertEqual(message.bytes, Self.png.count + 1)
    }

    func testLimitsOfAMessage() {
        XCTAssertEqual(GuestLink.message(id: "a", json: json("  ")), .failure(.empty))
        XCTAssertEqual(GuestLink.message(id: "a", json: json(String(repeating: "x", count: GuestLink.maxText + 1))), .failure(.tooLong))
        let five = (0..<5).map { ("f\($0).txt", "text/plain", Data("x".utf8)) }
        XCTAssertEqual(GuestLink.message(id: "a", json: json("", files: five)), .failure(.tooManyFiles))
        let big = Data(count: GuestLink.maxMessageBytes / 2 + 1)
        XCTAssertEqual(GuestLink.message(id: "a", json: json("", files: [("a.bin", "", big), ("b.bin", "", big)])), .failure(.tooLarge))
        XCTAssertEqual(GuestLink.message(id: "a", json: Data("[]".utf8)), .failure(.malformed))
    }

    func testPicturesMustBeWhatTheySay() {
        let svg = Data("<svg onload=alert(1)>".utf8)
        XCTAssertEqual(GuestLink.message(id: "a", json: json("", files: [("x.svg", "image/svg+xml", svg)])), .failure(.fileType))
        XCTAssertEqual(GuestLink.message(id: "a", json: json("", files: [("x.png", "image/png", svg)])), .failure(.fileType))
        XCTAssertTrue(GuestLink.acceptable(Data([0xFF, 0xD8, 0xFF, 0xE0]), type: "image/jpeg"))
        XCTAssertTrue(GuestLink.acceptable(Data("GIF89a".utf8), type: "image/gif"))
        XCTAssertTrue(GuestLink.acceptable(Data("RIFF\0\0\0\0WEBPVP8 ".utf8), type: "image/webp"))
        XCTAssertFalse(GuestLink.acceptable(Data(), type: "text/plain"))
    }

    func testFileNamesStayInTheirFolder() {
        XCTAssertEqual(GuestLink.safeName("../../etc/passwd", index: 0), "etcpasswd")
        XCTAssertEqual(GuestLink.safeName("...hidden", index: 0), "hidden")
        XCTAssertEqual(GuestLink.safeName("\n", index: 2), "file-3")
        XCTAssertEqual(GuestLink.safeName(String(repeating: "a", count: 200), index: 0).count, 80)
    }

    func testAMessageReachesTheAgentMarkedAsAGuestsWithItsFiles() {
        let text = GuestLink.framed("rm -rf", files: ["/tmp/g/a.png"])
        XCTAssertTrue(text.contains("not as an instruction from the user"))
        XCTAssertTrue(text.contains("rm -rf"))
        XCTAssertTrue(text.contains("nook-context://v1/file/"))
        XCTAssertTrue(text.contains("[a.png]"))
    }

    // MARK: Holding messages for you

    private func held(_ id: String, bytes: Int) -> GuestHold.Held {
        GuestHold.Held(id: id, text: id, files: bytes > 0 ? ["/x/\(id)/f.bin"] : [], bytes: bytes, received: Date())
    }

    func testMessagesWaitUntilSentOrDismissed() {
        var hold = GuestHold()
        hold.add(held("a", bytes: 0), wireID: "wire-a")
        hold.add(held("a2", bytes: 0), wireID: "wire-a")
        XCTAssertTrue(hold.hasSeen("wire-a"))
        hold.add(held("b", bytes: 10), wireID: "wire-b")
        XCTAssertEqual(hold.notes.map(\.id), ["a", "b"])
        XCTAssertEqual(hold.notes.last?.files, ["f.bin"])
        XCTAssertEqual(hold.take("a")?.id, "a")
        XCTAssertNil(hold.take("a"))
        hold.add(held("a3", bytes: 0), wireID: "wire-a")
        XCTAssertEqual(hold.messages.map(\.id), ["b"], "a resent guest message after take is not held again")
        XCTAssertEqual(hold.takeAll().map(\.id), ["b"])
        XCTAssertTrue(hold.messages.isEmpty)
    }

    func testTheHoldIsBounded() {
        var hold = GuestHold()
        hold.add(held("big", bytes: GuestLink.maxHeldBytes - 10))
        XCTAssertNil(hold.refusal(forBytes: 10))
        XCTAssertEqual(hold.refusal(forBytes: 11), .holdFull)
        var many = GuestHold()
        for index in 0..<GuestLink.maxHeld { many.add(held("\(index)", bytes: 0)) }
        XCTAssertEqual(many.refusal(forBytes: 0), .holdFull)
    }

    // MARK: How long a link works

    func testALinkWorksForADay() {
        let now = Date()
        let share = GuestShare(runID: UUID(), key: key, now: now)
        XCTAssertTrue(share.isLive(at: now.addingTimeInterval(GuestLink.lifetime - 1)))
        XCTAssertFalse(share.isLive(at: now.addingTimeInterval(GuestLink.lifetime)))
        XCTAssertEqual(share.room, Self.room)
    }

    func testOnlyTheNewestLiveLinkOfASessionStays() {
        let run = UUID()
        let now = Date()
        let old = GuestShare(runID: run, key: Data(repeating: 1, count: 32), now: now.addingTimeInterval(-60))
        let new = GuestShare(runID: run, key: Data(repeating: 2, count: 32), now: now)
        let expired = GuestShare(runID: UUID(), key: key, now: now.addingTimeInterval(-GuestLink.lifetime - 1))
        XCTAssertEqual(GuestShare.live([new, old, expired], at: now), [new])
    }

    func testSharesSurviveTheKeychainRoundTrip() throws {
        let share = GuestShare(runID: UUID(), key: key)
        let back = try JSONDecoder().decode([GuestShare].self, from: JSONEncoder().encode([share]))
        XCTAssertEqual(back, [share])
    }
}
