import XCTest

/// The languages stay in step: every text exists in each, and the placeholders (%@, %ld) match, so a translated
/// text can never crash or show a wrong value. The tables are read from the source files (Core/I18n*.swift), so the test
/// needs nothing of the app itself.
final class I18nCoverageTests: XCTestCase {
    private static let files = ["I18n.swift", "I18n+Agents.swift", "I18n+Workspace.swift", "I18n+Redesign.swift", "I18n+Complete.swift", "I18n+Connect.swift", "I18n+Memory.swift", "I18n+Autocomplete.swift", "I18n+Languages.swift", "I18n+Music.swift", "I18n+AgentWork.swift", "I18n+Permissions.swift", "I18n+Home.swift", "I18n+Selection.swift", "I18n+SettingsLayout.swift", "I18n+Look.swift", "I18n+Control.swift"]

    /// language → key → text, merged over all table files.
    private static let tables: [String: [String: String]] = {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core")
        var result: [String: [String: String]] = [:]
        let entry = try! NSRegularExpression(pattern: #"^\s+"([^"]+)":\s*"((?:[^"\\]|\\.)*)""#, options: [.anchorsMatchLines])
        let header = try! NSRegularExpression(pattern: #"^\s*\.(nl|en|de|fr|es): \["#, options: [.anchorsMatchLines])
        for name in files {
            guard let text = try? String(contentsOf: core.appendingPathComponent(name), encoding: .utf8) else { continue }
            // Walk through the file: a `.nl: [` line starts a language block, entries belong to the block they follow.
            var language: String?
            for line in text.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = header.firstMatch(in: line, range: range), let lang = Range(match.range(at: 1), in: line) {
                    language = String(line[lang])
                } else if let language, let match = entry.firstMatch(in: line, range: range),
                          let key = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) {
                    result[language, default: [:]][String(line[key])] = String(line[value])
                }
            }
        }
        return result
    }()

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ld|@|d|f|\\.\\d+f)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testTheTablesWereFound() {
        for language in ["nl", "en", "de", "fr", "es"] {
            XCTAssertGreaterThan(Self.tables[language]?.count ?? 0, 1000, "tables for \(language) not read")
        }
    }

    func testEveryTextExistsInAllLanguages() {
        let nl = Self.tables["nl"] ?? [:], en = Self.tables["en"] ?? [:], de = Self.tables["de"] ?? [:]
        XCTAssertEqual(Set(nl.keys).subtracting(en.keys).sorted(), [], "missing in English")
        XCTAssertEqual(Set(nl.keys).subtracting(de.keys).sorted(), [], "missing in German")
        XCTAssertEqual(Set(en.keys).subtracting(nl.keys).sorted(), [], "missing in Dutch")
        XCTAssertEqual(Set(de.keys).subtracting(nl.keys).sorted(), [], "German text without Dutch original")
        for (name, other) in [("French", Self.tables["fr"] ?? [:]), ("Spanish", Self.tables["es"] ?? [:])] {
            XCTAssertEqual(Set(nl.keys).subtracting(other.keys).sorted(), [], "missing in \(name)")
            XCTAssertEqual(Set(other.keys).subtracting(nl.keys).sorted(), [], "\(name) text without Dutch original")
        }
    }

    func testPlaceholdersMatchAcrossLanguages() {
        let nl = Self.tables["nl"] ?? [:], en = Self.tables["en"] ?? [:], de = Self.tables["de"] ?? [:]
        var mismatches: [String] = []
        for (key, dutch) in nl {
            for (name, other) in [("en", en), ("de", de), ("fr", Self.tables["fr"] ?? [:]), ("es", Self.tables["es"] ?? [:])] {
                if let text = other[key], placeholders(text) != placeholders(dutch) { mismatches.append("\(key) (\(name))") }
            }
        }
        XCTAssertEqual(mismatches.sorted(), [])
    }
}
