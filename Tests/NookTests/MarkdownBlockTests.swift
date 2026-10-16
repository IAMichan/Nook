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
