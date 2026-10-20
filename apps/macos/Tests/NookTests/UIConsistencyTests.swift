import XCTest

/// The notch, the main window, and Settings stay one design: every view takes its colors, type, and corner radii from
/// `NookTheme` instead of inventing its own. The sources under `NotchUI` and `App` are read as text (like
/// `I18nCoverageTests`), so the test needs nothing of the app and also runs through `scripts/core-tests.sh`.
///
/// `scripts/ui-lint.sh` checks the same rules without a Swift toolchain; keep the two in step.
final class UIConsistencyTests: XCTestCase {
    /// `apps/macos`: from the environment when the tests run as a throwaway package, else relative to this file.
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// Files whose literal colors are part of what they draw: the theme itself, Nook's face and accessories, brand marks,
    /// chart series, and palettes that are named once and used through their name.
    private static let ownColors: Set<String> = [
        "NotchUI/Theme/NookTheme.swift",
        "NotchUI/Components/BrandLogo.swift",
        "NotchUI/Components/AgentLogo.swift",
        "NotchUI/Components/StatusStyleView.swift",
        "NotchUI/Components/ComposerDropdown.swift",
        "NotchUI/Chat/ChatChartView.swift",
        "NotchUI/Workspace/WorkspaceComponents.swift",
        "NotchUI/Pills/Music/MusicControls.swift",
        "App/MCPSettingsSection.swift",
        "App/Settings/SettingsStyle.swift",
        "App/Settings/SettingsView+Appearance.swift",
    ]

    /// All Swift sources of the user interface, as (path relative to `apps/macos`, text).
    private static let sources: [(path: String, text: String)] = {
        var result: [(String, String)] = []
        for folder in ["NotchUI", "App"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = folder + "/" + String(url.path.dropFirst(base.path.count + 1))
                result.append((relative, text))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }()

    private func isCharacter(_ path: String) -> Bool { path.hasPrefix("NotchUI/Character/") }

    /// "path:line: text" for every line of every source that matches `pattern`, skipping `excluded` files.
    private func offenders(_ pattern: String, excluding excluded: (String) -> Bool = { _ in false }) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (path, text) in Self.sources where !excluded(path) {
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(path):\(index + 1): \(trimmed)")
                }
            }
        }
        return found
    }

    func testTheSourcesWereFound() {
        XCTAssertGreaterThan(Self.sources.count, 100, "UI sources not read from \(Self.root.path)")
        XCTAssertTrue(Self.sources.contains { $0.path == "NotchUI/Theme/NookTheme.swift" })
    }

    /// Type comes from the scale: `NookTheme.font`, `mono`, `rounded`, or a `TextStyle`, never `Font.system(size:)` inline.
    func testFontsComeFromTheTheme() {
        let found = offenders(#"\.font\(\s*\.system\(\s*size:"#) { $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.font / mono / rounded instead of Font.system(size:)")
    }

    /// Colors come from the theme: a literal hex, RGB, or gray belongs in `NookTheme` (or in a file that draws something
    /// of its own, listed in `ownColors`) and is used everywhere else by name.
    func testColorsComeFromTheTheme() {
        let literal = #"\b(NS)?Color\(\s*(hex|red|white|\.sRGB)\b"#
        let found = offenders(literal) { Self.ownColors.contains($0) || self.isCharacter($0) }
        XCTAssertEqual(found, [], "use a NookTheme color, or add the file to UIConsistencyTests.ownColors when it draws its own")
    }

    /// Corners sit on the radius scale: `NookTheme.Radius.chip … pill`, not a number that happens to look right.
    func testCornerRadiiComeFromTheScale() {
        let found = offenders(#"cornerRadius:\s*(6|7|8|9|10|12|13|14|16|20)(?![.0-9])"#) { self.isCharacter($0) || $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.Radius (chip 6, control 8, card 10, panel 12, sheet 14, pill 20)")
    }

    /// Every token the scale promises exists, so the names in the docs and in the lint script stay true.
    func testThemeDefinesTheScales() {
        guard let theme = Self.sources.first(where: { $0.path == "NotchUI/Theme/NookTheme.swift" })?.text else {
            return XCTFail("NookTheme.swift not found")
        }
        for name in ["enum Radius", "enum Spacing", "enum TextStyle", "static let canvas", "static let well", "static let surface",
                     "static let hairline", "static let fieldStroke", "static func rounded("] {
            XCTAssertTrue(theme.contains(name), "NookTheme lost \(name)")
        }
    }
}
