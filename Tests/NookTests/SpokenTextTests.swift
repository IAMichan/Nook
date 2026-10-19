import XCTest

/// An answer read aloud: plain words, sentence by sentence while it is written.
final class SpokenTextTests: XCTestCase {
    func testMarkdownBecomesPlainSpeech() {
        let spoken = SpokenText.plain("""
        ## Je dag
        - **Om 10:00** overleg met [Lisa](https://example.com) [1]
        - Lunch
        ```swift
        let x = 1
        ```
        Zie https://nook.example voor meer.
        """)
        XCTAssertEqual(spoken, "Je dag. Om 10:00 overleg met Lisa. Lunch. Zie voor meer.")
    }

    func testTablesAreReadAsCells() {
        XCTAssertEqual(SpokenText.plain("| Dag | Afspraken |\n|---|---|\n| Ma | 3 |"), "Dag, Afspraken. Ma, 3.")
    }

    func testSentencesComeOutWhileTheAnswerGrows() {
        var queue = SpokenText.Queue()
        XCTAssertEqual(queue.feed("Je hebt vandaag"), [])
        XCTAssertEqual(queue.feed("Je hebt vandaag 3 afspraken. De eerste"), ["Je hebt vandaag 3 afspraken."])
        XCTAssertEqual(queue.feed("Je hebt vandaag 3 afspraken. De eerste is om 9.30 uur"), [], "9.30 is not a sentence end")
        XCTAssertEqual(queue.finish("Je hebt vandaag 3 afspraken. De eerste is om 9.30 uur met Jan."), ["De eerste is om 9.30 uur met Jan."])
        XCTAssertEqual(queue.finish("Je hebt vandaag 3 afspraken. De eerste is om 9.30 uur met Jan."), [])
    }
}
