import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The fetcher against canned answers: which addresses it asks, that the token only goes to the API, and that a file
/// that differs from the tree is refused.
final class SkillFetcherTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ r: URLRequest) { lock.lock(); requests.append(r); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    private let sha = String(repeating: "d", count: 40)

    private func fetcher(_ log: Log, token: String? = "secret", answers: @escaping @Sendable (URL) -> (Int, Data)) -> SkillFetcher {
        SkillFetcher(transport: { request in
            log.add(request)
            let (status, data) = answers(request.url!)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
        }, token: { token })
    }

    private func answers(skillBody: String = "---\nname: pdf\ndescription: PDFs\n---", scriptBody: String = "print(1)") -> @Sendable (URL) -> (Int, Data) {
        let sha = self.sha
        let tree = SkillCatalogTests.tree([
            ("skills/pdf/SKILL.md", "blob", "100644", "---\nname: pdf\ndescription: PDFs\n---".utf8.count),
            ("skills/pdf/fill.py", "blob", "100644", 8),
            ("skills/design-v2/SKILL.md", "blob", "100644", 30),
        ])
        return { url in
            let s = url.absoluteString
            if s.hasPrefix("https://skills.sh/api/search") {
                return (200, Data(#"{"skills":[{"id":"acme/skills/taste","source":"acme/skills","skillId":"taste","name":"taste","installs":3}]}"#.utf8))
            }
            if s == "https://api.github.com/repos/acme/skills/commits/HEAD" { return (200, Data(#"{"sha":"\#(sha)"}"#.utf8)) }
            if s == "https://api.github.com/repos/acme/skills/git/trees/\(sha)?recursive=1" { return (200, tree) }
            if s == "https://raw.githubusercontent.com/acme/skills/\(sha)/skills/pdf/SKILL.md" { return (200, Data(skillBody.utf8)) }
            if s == "https://raw.githubusercontent.com/acme/skills/\(sha)/skills/pdf/fill.py" { return (200, Data(scriptBody.utf8)) }
            if s == "https://raw.githubusercontent.com/acme/skills/\(sha)/skills/design-v2/SKILL.md" {
                return (200, Data("---\nname: taste\ndescription: Looks\n---".utf8))
            }
            return (404, Data())
        }
    }

    func testSearchResolveDownloadAndInstall() async throws {
        let log = Log()
        let f = fetcher(log, answers: answers())
        let hits = try await f.search("  taste ")
        XCTAssertEqual(hits.map(\.skillID), ["taste"])
        let search = try XCTUnwrap(URLComponents(url: log.all[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(search.queryItems?.first { $0.name == "q" }?.value, "taste")

        let taste = try await f.resolve(hits[0])
        XCTAssertEqual(taste.folder, "skills/design-v2", "found by the front matter's name when no folder is called so")
        XCTAssertEqual(taste.description, "Looks")
        XCTAssertEqual(taste.commit, sha)

        let pdf = try await f.resolve(SkillSearchHit(id: "x", repository: hits[0].repository, skillID: "pdf", name: "pdf", installs: 0))
        XCTAssertEqual(pdf.description, "PDFs")
        let files = try await f.download(pdf)
        XCTAssertEqual(Set(files.keys), ["SKILL.md", "fill.py"])
        let root = URL(fileURLWithPath: try TestData.tempFolder())
        try SkillInstaller.install(pdf, files: files, into: root)
        XCTAssertEqual(SkillIndex.scan(roots: [root]).map(\.name), ["pdf"])

        for request in log.all {
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if request.url?.host == "api.github.com" { XCTAssertEqual(auth, "Bearer secret") } else { XCTAssertNil(auth, "\(request.url!)") }
            XCTAssertTrue(request.url?.absoluteString.contains("/main/") == false, "files are read at the pinned commit")
        }
        XCTAssertEqual(log.all.filter { $0.url?.host == "api.github.com" }.count, 4, "two API calls per resolved skill")
    }

    func testChangedFileIsRefusedAndErrorsAreTyped() async throws {
        let f = fetcher(Log(), token: nil, answers: answers(scriptBody: "print(12345)"))
        let pdf = try await f.resolve(SkillSearchHit(id: "x", repository: SkillRepository(owner: "acme", name: "skills"), skillID: "pdf", name: "pdf", installs: 0))
        do {
            _ = try await f.download(pdf)
            XCTFail("a file larger than the tree said must be refused")
        } catch { XCTAssertEqual(error as? SkillFetcher.FetchError, .sizeMismatch("fill.py")) }

        do {
            _ = try await f.commit(of: SkillRepository(owner: "acme", name: "missing"))
            XCTFail()
        } catch { XCTAssertEqual(error as? SkillFetcher.FetchError, .notFound) }

        let empty = try await f.search("   ")
        XCTAssertEqual(empty, [], "an empty query does not go out")
    }
}
