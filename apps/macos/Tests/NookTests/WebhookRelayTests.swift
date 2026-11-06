import XCTest

final class WebhookRelayTests: XCTestCase {
    private let token = String(repeating: "x", count: 40)
    private static let workerRoom = "014f590460ba2fadde9e395e5a74b772"

    func testTheRoomMatchesTheWorker() {
        // roomOf("x" × 40) in apps/relay/worker/hooks.js: both sides must make the same room.
        XCTAssertEqual(WebhookRelay.room(token: token), Self.workerRoom)
        XCTAssertFalse(WebhookRelay.room(token: token).contains(token))
    }

    func testAddresses() {
        let task = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let room = WebhookRelay.room(token: token)
        XCTAssertEqual(WebhookRelay.publicURL(relay: "https://r.example", token: token, task: task),
                       "https://r.example/v1/hooks/\(room)/00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(WebhookRelay.listenURL(relay: "https://r.example", token: token)?.absoluteString,
                       "wss://r.example/v1/hooks/\(room)/listen")
    }

    func testARequestReachesTheChecksAsAPost() {
        let text = #"{"id":"a","path":"/hooks/x","headers":{"X-Hub-Signature-256":"sha256=1"},"body":"aGk="}"#
        let incoming = WebhookRelay.incoming(text)
        XCTAssertEqual(incoming?.request.method, "POST")
        XCTAssertEqual(incoming?.request.headers["x-hub-signature-256"], "sha256=1")
        XCTAssertEqual(incoming?.request.body, Data("hi".utf8))
    }

    func testBadOrHugeRequestsAreDropped() {
        XCTAssertNil(WebhookRelay.incoming("ping"))
        XCTAssertNil(WebhookRelay.incoming(#"{"id":"a","path":"/x","body":"***"}"#))
        let huge = Data(count: WebhookHTTP.maxBodyBytes + 1).base64EncodedString()
        XCTAssertNil(WebhookRelay.incoming(#"{"id":"a","path":"/x","body":"\#(huge)"}"#))
    }

    func testAnswer() {
        XCTAssertEqual(WebhookRelay.answer(id: "a", status: 202, message: "ok"), #"{"id":"a","message":"ok","status":202}"#)
    }
}
