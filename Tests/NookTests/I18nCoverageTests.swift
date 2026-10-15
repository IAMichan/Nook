import XCTest

/// The three languages stay in step: every text exists in each, and the placeholders (%@, %ld) match, so a translated
/// text can never crash or show a wrong value.
final class I18nCoverageTests: XCTestCase {
    private func merged(_ lang: AppLanguage) -> [String: String] {
        var result: [String: String] = [:]
        // Later tables win, as in I18n.lookup (the first table in `tables` is searched first).
        for table in I18n.tables.reversed() {
            for (key, value) in table[lang] ?? [:] { result[key] = value }
        }
        return result
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ld|@|d|f|\\.\\d+f)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testEveryTextExistsInAllLanguages() {
        let nl = merged(.nl), en = merged(.en), de = merged(.de)
        XCTAssertEqual(Set(nl.keys).subtracting(en.keys).sorted(), [], "missing in English")
        XCTAssertEqual(Set(nl.keys).subtracting(de.keys).sorted(), [], "missing in German")
        XCTAssertEqual(Set(en.keys).subtracting(nl.keys).sorted(), [], "missing in Dutch")
    }

    func testPlaceholdersMatchAcrossLanguages() {
        let nl = merged(.nl), en = merged(.en), de = merged(.de)
        var mismatches: [String] = []
        for (key, dutch) in nl {
            for (name, other) in [("en", en), ("de", de)] {
                if let text = other[key], placeholders(text) != placeholders(dutch) { mismatches.append("\(key) (\(name))") }
            }
        }
        XCTAssertEqual(mismatches.sorted(), [])
    }
}
