import XCTest

final class TerminalTitleTests: XCTestCase {
    func testShellTitleKeepsOnlyTheFolderName() {
        XCTAssertEqual(TerminalTitle.display("michan@macbook-pro-3:~/IMDigital/Code/Applicaties/Nook"), "Nook")
        XCTAssertEqual(TerminalTitle.display("me@host: /usr/local/bin/"), "bin")
        XCTAssertEqual(TerminalTitle.display("~/Code/Nook"), "Nook")
    }

    func testHomeAndRootStay() {
        XCTAssertEqual(TerminalTitle.display("me@host:~"), "~")
        XCTAssertEqual(TerminalTitle.display("me@host:/"), "/")
    }

    func testOtherTitlesAreLeftAlone() {
        XCTAssertEqual(TerminalTitle.display("npm run dev"), "npm run dev")
        XCTAssertEqual(TerminalTitle.display("vim notes.md"), "vim notes.md")
        XCTAssertEqual(TerminalTitle.display("ssh deploy@server"), "ssh deploy@server")
    }
}
