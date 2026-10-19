import XCTest

final class MarkdownBlockTests: XCTestCase {
    func testChartBlockBecomesAChart() {
        let text = "```chart\n{\"type\":\"bar\",\"data\":[{\"label\":\"a\",\"value\":1},{\"label\":\"b\",\"value\":2}]}\n```"
        guard case .chart(let chart) = MarkdownBlock.parse(text).first else { return XCTFail("no chart") }
        XCTAssertEqual(chart.series.first?.points.count, 2)
    }

    func testPlainCodeKeepsItsLanguage() {
        guard case .code(let language, let code) = MarkdownBlock.parse("```swift\nlet a = 1\n```").first else { return XCTFail("no code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1")
    }

    func testQuestionBlock() {
        let text = "```question\n{\"question\":\"Welke?\",\"options\":[\"A\",{\"label\":\"B\"}]}\n```"
        guard case .question(let ask, let options) = MarkdownBlock.parse(text).first else { return XCTFail("no question") }
        XCTAssertEqual(ask, "Welke?")
        XCTAssertEqual(options, ["A", "B"])
    }

    func testTrailingChoicesNeedAQuestion() {
        let asked = MarkdownBlock.parse("Wat wil je?\n\n- Optie een\n- Optie twee")
        XCTAssertEqual(MarkdownBlock.trailingChoices(asked)?.options, ["Optie een", "Optie twee"])
        let statement = MarkdownBlock.parse("Dit is gedaan.\n\n- Een\n- Twee")
        XCTAssertNil(MarkdownBlock.trailingChoices(statement))
        let nested = MarkdownBlock.parse("Welke wil je?\n\n- Een\n  - detail\n- Twee")
        XCTAssertNil(MarkdownBlock.trailingChoices(nested))
    }

    func testNestedListKeepsItsDepth() {
        let text = "- **Update:** main is bijgewerkt:\n  - Sessies tonen voortgang\n  - • Nieuwe tests\n    1. Diep\n- **Build:** geslaagd"
        guard case .list(let items) = MarkdownBlock.parse(text).first else { return XCTFail("no list") }
        XCTAssertEqual(items, [
            MarkdownListItem(level: 0, number: nil, text: "**Update:** main is bijgewerkt:"),
            MarkdownListItem(level: 1, number: nil, text: "Sessies tonen voortgang"),
            MarkdownListItem(level: 1, number: nil, text: "Nieuwe tests"),
            MarkdownListItem(level: 2, number: "1.", text: "Diep"),
            MarkdownListItem(level: 0, number: nil, text: "**Build:** geslaagd")
        ])
    }

    func testNumberedListWithBulletsAndBlankLinesStaysOneList() {
        let text = "1. Eerst\n   - detail\n\n2. Daarna\n   vervolg van de regel\n\nKlaar."
        let blocks = MarkdownBlock.parse(text)
        guard case .list(let items) = blocks.first else { return XCTFail("no list") }
        XCTAssertEqual(items.map(\.level), [0, 1, 0])
        XCTAssertEqual(items.last?.text, "Daarna vervolg van de regel")
        guard case .paragraph("Klaar.") = blocks.last else { return XCTFail("no closing paragraph") }
    }

    func testCalloutAndTask() {
        XCTAssertEqual(Callout.detect("[!WARNING]\nPas op")?.body, "Pas op")
        XCTAssertEqual(Callout.detect("**Tip:** probeer dit")?.body, "probeer dit")
        XCTAssertNil(Callout.detect("gewone quote"))
        XCTAssertEqual(MarkdownBlock.task("[x] klaar")?.done, true)
    }

    func testTableTurnsIntoAChart() {
        let chart = ChartRescue.chart(fromTable: ["Maand", "Omzet"], rows: [["jan", "10"], ["feb", "20"]], title: "")
        XCTAssertEqual(chart?.series.first?.name, "Omzet")
    }
}
