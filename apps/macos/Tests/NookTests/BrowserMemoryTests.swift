import XCTest

/// What Nook's browser remembers: visited pages for the address bar, saved passwords, and Chrome Web Store packages.
final class BrowserMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: History

    func testTypingFindsVisitedPagesBySiteFirst() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "https://github.com/")!, title: "GitHub", at: now)
        history.record(url: URL(string: "https://github.com/apple/swift")!, title: "apple/swift", at: now)
        history.record(url: URL(string: "https://docs.example.com/git-guide")!, title: "A git guide", at: now)
        let found = history.suggestions(for: "git", now: now)
        XCTAssertEqual(found.first?.url, "https://github.com/")
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.last?.url, "https://docs.example.com/git-guide")
    }

    func testEveryWordMustMatchAddressOrTitle() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "https://news.example.com/a")!, title: "Weather in Utrecht", at: now)
        history.record(url: URL(string: "https://news.example.com/b")!, title: "Football results", at: now)
        XCTAssertEqual(history.suggestions(for: "news utrecht", now: now).map(\.url), ["https://news.example.com/a"])
        XCTAssertTrue(history.suggestions(for: "nothing here", now: now).isEmpty)
    }

    func testOftenAndRecentlyVisitedComeFirst() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "https://mail.example.com/old")!, title: "", at: now.addingTimeInterval(-90 * 86_400))
        for minute in 0..<5 {
            history.record(url: URL(string: "https://mail.example.com/new")!, title: "", at: now.addingTimeInterval(Double(minute) * 120))
        }
        XCTAssertEqual(history.suggestions(for: "mail", now: now).first?.url, "https://mail.example.com/new")
    }

    func testSamePageWithOrWithoutWwwIsOneEntry() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "https://www.example.com/")!, title: "Example", at: now)
        history.record(url: URL(string: "https://example.com")!, title: "Example", at: now.addingTimeInterval(3600))
        XCTAssertEqual(history.count, 1)
    }

    func testOnlyWebPagesAreRecorded() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "about:blank")!, title: "", at: now)
        history.record(url: URL(fileURLWithPath: "/tmp/page.html"), title: "", at: now)
        XCTAssertEqual(history.count, 0)
    }

    func testRemoveAndClear() {
        let history = BrowserHistory(file: nil)
        history.record(url: URL(string: "https://a.example.com")!, title: "", at: now)
        history.record(url: URL(string: "https://b.example.com")!, title: "", at: now)
        history.remove(url: "https://a.example.com")
        XCTAssertEqual(history.count, 1)
        history.clear()
        XCTAssertEqual(history.count, 0)
    }

    func testCompletionFinishesTheSiteYouStartedTyping() {
        let best = BrowserSuggestion(url: "https://github.com/apple/swift", title: "")
        XCTAssertEqual(BrowserHistory.completion(for: "git", best: best), "github.com")
        XCTAssertEqual(BrowserHistory.completion(for: "Git", best: best), "Github.com")
        XCTAssertNil(BrowserHistory.completion(for: "swift", best: best))
        XCTAssertNil(BrowserHistory.completion(for: "git hub", best: best))
    }

    func testHistoryIsSavedAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let first = BrowserHistory(file: file)
        first.record(url: URL(string: "https://example.com/page")!, title: "A page", at: now)
        first.save()
        let second = BrowserHistory(file: file)
        XCTAssertEqual(second.suggestions(for: "exa", now: now).map(\.title), ["A page"])
    }

    // MARK: Passwords

    func testPasswordsBelongToHttpsSitesWithoutWww() {
        XCTAssertEqual(BrowserPasswordBook.site(scheme: "https", host: "www.Example.com"), "example.com")
        XCTAssertNil(BrowserPasswordBook.site(scheme: "http", host: "example.com"))
        XCTAssertEqual(BrowserPasswordBook.site(scheme: "http", host: "localhost"), "localhost")
        XCTAssertNil(BrowserPasswordBook.site(scheme: "https", host: ""))
    }

    func testOfferSavesNewUpdatesChangedAndSkipsKnown() {
        var book = BrowserPasswordBook()
        XCTAssertEqual(book.offer(site: "example.com", username: "me", password: "one"), .save)
        book.save(BrowserCredential(site: "example.com", username: "me", password: "one", lastUsed: now))
        XCTAssertEqual(book.offer(site: "example.com", username: "me", password: "one"), .none)
        XCTAssertEqual(book.offer(site: "example.com", username: "me", password: "two"), .update)
        XCTAssertEqual(book.offer(site: "example.com", username: "", password: "one"), .none)
        XCTAssertEqual(book.offer(site: "example.com", username: "me", password: ""), .none)
        book.never("other.com")
        XCTAssertEqual(book.offer(site: "other.com", username: "me", password: "x"), .none)
    }

    func testCredentialsForASiteLastUsedFirst() {
        var book = BrowserPasswordBook()
        book.save(BrowserCredential(site: "example.com", username: "a", password: "1", lastUsed: now))
        book.save(BrowserCredential(site: "example.com", username: "b", password: "2", lastUsed: now.addingTimeInterval(-60)))
        book.save(BrowserCredential(site: "elsewhere.com", username: "c", password: "3", lastUsed: now))
        XCTAssertEqual(book.credentials(for: "example.com").map(\.username), ["a", "b"])
        book.used("example.com\u{1F}b", at: now.addingTimeInterval(60))
        XCTAssertEqual(book.credentials(for: "example.com").first?.username, "b")
        book.remove("example.com\u{1F}b")
        XCTAssertEqual(book.credentials(for: "example.com").map(\.username), ["a"])
    }

    func testSavingASiteAllowsItAgain() {
        var book = BrowserPasswordBook()
        book.never("example.com")
        book.save(BrowserCredential(site: "example.com", username: "me", password: "1", lastUsed: now))
        XCTAssertFalse(book.isNever("example.com"))
    }

    // MARK: Chrome Web Store

    func testExtensionIDFromStoreLinks() {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
        XCTAssertEqual(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin/\(id)"), id)
        XCTAssertEqual(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/\(id)?hl=nl"), id)
        XCTAssertEqual(ChromeWebStore.extensionID(from: "chrome.google.com/webstore/detail/ublock/\(id)"), id)
        XCTAssertEqual(ChromeWebStore.extensionID(from: id.uppercased()), id)
        XCTAssertNil(ChromeWebStore.extensionID(from: "https://example.com/detail/x/\(id)"))
        XCTAssertNil(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/category/extensions"))
    }

    func testDownloadAddressAsksForTheExtension() throws {
        let url = try XCTUnwrap(ChromeWebStore.downloadURL(id: "cjpalhdlnbpafiamejdnhcphjbkeiagm"))
        XCTAssertEqual(url.host, "clients2.google.com")
        XCTAssertTrue(url.absoluteString.contains("cjpalhdlnbpafiamejdnhcphjbkeiagm"))
    }

    func testZipComesOutOfCrx3AndCrx2() throws {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3]
        let magic: [UInt8] = Array("Cr24".utf8)
        // Spelled out piece by piece: one long chain of `+` takes older compilers too long to type-check.
        var crx3: [UInt8] = magic
        crx3 += Self.littleEndian(3)
        crx3 += Self.littleEndian(5)
        crx3 += [9, 9, 9, 9, 9]
        crx3 += zip
        XCTAssertEqual(try ChromeWebStore.zip(fromPackage: Data(crx3)), Data(zip))
        var crx2: [UInt8] = magic
        crx2 += Self.littleEndian(2)
        crx2 += Self.littleEndian(2)
        crx2 += Self.littleEndian(3)
        crx2 += [7, 7, 8, 8, 8]
        crx2 += zip
        XCTAssertEqual(try ChromeWebStore.zip(fromPackage: Data(crx2)), Data(zip))
        XCTAssertEqual(try ChromeWebStore.zip(fromPackage: Data(zip)), Data(zip))
        XCTAssertThrowsError(try ChromeWebStore.zip(fromPackage: Data("hello".utf8)))
        var truncated: [UInt8] = magic
        truncated += Self.littleEndian(3)
        truncated += Self.littleEndian(500)
        truncated += zip
        XCTAssertThrowsError(try ChromeWebStore.zip(fromPackage: Data(truncated)))
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
