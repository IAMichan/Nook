import XCTest

/// A change to one chat app is a change to all of them (`docs/INTEGRATIONS.md`): what sets an app apart is said once,
/// in its `MessagingApp` (its notice layout, its own link, its calls) or in its bridge, never by comparing its id
/// somewhere in the shared code. The sources are read as text (like `AgentParityTests`), so this also runs through
/// `scripts/core-tests.sh`.
final class ChatParityTests: XCTestCase {
    /// `apps/macos`: from the environment when the tests run as a throwaway package, else relative to this file.
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// Every chat app Nook knows. "x" and "line" are left out: as text they are mostly something else (a key, a chart).
    private static let appIDs = MessagingApps.builtIn.map(\.id).filter { !["x", "line"].contains($0) }

    /// A check for one app by its id: `app.id == "slack"`, `"whatsapp" != app`, `["whatsapp", …].contains(app)`,
    /// `id.hasPrefix("teams")`. A line that starts with `case` is a switch and does not count.
    private static var patterns: [String] {
        let ids = "(" + appIDs.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
        return [#"(==|!=)\s*""# + ids + #"""#,
                #"""# + ids + #""\s*(==|!=)"#,
                #"\[[^\[\]]*""# + ids + #""[^\[\]]*\]\s*\.contains\("#,
                #"(hasPrefix|hasSuffix)\(""# + ids + #""\)"#]
    }

    /// Where an app may be named: its bridge and its own data (they translate that one app), WhatsApp's own folder, and
    /// the texts.
    private static func isMemberFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasPrefix("Services/WhatsApp/") || name.contains("Bridge") || name.hasSuffix("Data.swift")
            || name.hasPrefix("I18n")
    }

    /// The checks that stay, per file, and why. The number may only go down.
    private static let allowed: [String: (count: Int, reason: String)] = [
        "App/Settings/ChatAppSheet.swift": (1, "which apps Nook writes in itself: WhatsApp's link and the Slack and Telegram bridges"),
        "UI/Chat/EmbeddedAppView.swift": (1, "a URL scheme (whatsapp:), not an app id"),
        "Services/AgentTranscript.swift": (2, "the JSON key \"messages\" of a transcript, not an app"),
    ]

    private static let found: [String: [String]] = {
        let regexes = patterns.map { try! NSRegularExpression(pattern: $0) }
        var result: [String: [String]] = [:]
        for folder in ["App", "UI", "Services", "Brain", "Core"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = folder + "/" + String(url.path.dropFirst(base.path.count + 1))
                guard !isMemberFile(path), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("case ") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                        result[path, default: []].append("\(path):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        return result
    }()

    func testTheSourcesWereFound() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Services/Messages/ChatInbox.swift").path),
                      "sources not read from \(Self.root.path)")
        XCTAssertTrue(Self.appIDs.contains("whatsapp"))
    }

    /// A feature for one chat app fails here: say it in `MessagingApp` (or its bridge) and give it to every app that can.
    func testNoNewSingleAppChecks() {
        var added: [String] = []
        var removed: [String] = []
        for path in Set(Self.found.keys).union(Self.allowed.keys).sorted() {
            let lines = Self.found[path] ?? []
            let allowed = Self.allowed[path]?.count ?? 0
            if lines.count > allowed { added.append(contentsOf: lines) }
            if lines.count < allowed { removed.append("\(path): \(lines.count) (was \(allowed))") }
        }
        XCTAssertEqual(added, [], """
            a feature for one chat app must reach every chat app (docs/INTEGRATIONS.md): describe it in MessagingApp \
            (ChatInbox.swift) or in the app's bridge. Only for something the other apps do not offer, raise the number in \
            ChatParityTests.allowed with the reason, and write the gap in the chat feature matrix.
            """)
        XCTAssertEqual(removed, [], "fewer single-app checks: lower these in ChatParityTests.allowed")
    }

    func testThePatternsCatchEveryForm() {
        let regexes = Self.patterns.map { try! NSRegularExpression(pattern: $0) }
        func caught(_ line: String) -> Bool {
            regexes.contains { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        }
        XCTAssertTrue(caught(#"if app.id == "slack" {"#))
        XCTAssertTrue(caught(#"guard entry.app != "messages" else"#))
        XCTAssertTrue(caught(#"if ["whatsapp", "telegram"].contains(app) {"#))
        XCTAssertTrue(caught(#"if "teams" == app.id {"#))
        XCTAssertFalse(caught(#"if layout.senderInTitle {"#))
        XCTAssertFalse(caught(#"if kind == "PreToolUse" {"#))
    }

    /// The layouts the shared notice parsing reads: what each app said by its id before.
    func testTheAppsSayWhatSetsThemApart() {
        XCTAssertEqual(MessagingApps.known("slack")?.noticeLayout, NoticeLayout(slackMarkup: true, speakerInText: .inChannels))
        XCTAssertEqual(MessagingApps.known("teams")?.noticeLayout, NoticeLayout(speakerInText: .always))
        XCTAssertEqual(MessagingApps.known("whatsapp")?.noticeLayout, NoticeLayout(senderInTitle: true))
        XCTAssertEqual(MessagingApps.known("telegram")?.noticeLayout, NoticeLayout())
        XCTAssertEqual(MessagingApps.builtIn.filter(\.notifiesByDefault).map(\.id), ["whatsapp"])
        XCTAssertEqual(MessagingApps.builtIn.filter(\.callsAreFaceTime).map(\.id), ["messages"])
        XCTAssertEqual(MessagingApps.builtIn.filter { $0.ownLink != nil }.map(\.id), ["whatsapp"])
        // An app you added keeps none of it through saving.
        let added = MessagingApp(id: "custom", name: "Custom", bundleIDs: ["a.b"], notifiesByDefault: true)
        let decoded = try? JSONDecoder().decode(MessagingApp.self, from: JSONEncoder().encode(added))
        XCTAssertEqual(decoded?.id, "custom")
        XCTAssertEqual(decoded?.notifiesByDefault, false)
    }
}
