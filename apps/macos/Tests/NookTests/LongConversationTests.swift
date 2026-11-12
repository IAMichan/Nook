import XCTest

/// A long conversation end to end, from the turns Nook keeps to what the newest question carries: the window
/// (`ConversationWindow`) keeps the topic it started with, and that old request is not taken for the newest one
/// (`ChatIntent`, `Research`). The window of a small model is used, where the recap lands among the newest turns.
final class LongConversationTests: XCTestCase {
    private let filler = Array(repeating: "word", count: 200).joined(separator: " ")

    private var window: [ChatTurn] {
        var turns = [ChatTurn(fromUser: true, text: "Stuur Anna een WhatsApp: ik kom later"),
                     ChatTurn(fromUser: false, text: "Hier is het bericht aan Anna.")]
        for index in 2..<12 { turns.append(ChatTurn(fromUser: index % 2 == 0, text: filler)) }
        return ConversationWindow.fit(turns, limits: .fitting(.apple))
    }

    func testTheTopicTheConversationStartedWithIsKept() {
        let window = self.window
        XCTAssertLessThanOrEqual(window.reduce(0) { $0 + $1.text.count }, ConversationWindow.Limits.fitting(.apple).budget)
        XCTAssertTrue(window.first?.text.contains("Stuur Anna een WhatsApp") == true, "the recap names the first request")
    }

    func testARetryDoesNotResendAnOldMessageFromTheRecap() {
        let intent = ChatIntent.detect("Probeer het opnieuw", history: window)
        XCTAssertNotEqual(intent.primaryAction, "whatsapp_send", "the recap's old request is not the request to retry")
    }
}
