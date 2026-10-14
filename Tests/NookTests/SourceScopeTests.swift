import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

/// Bronkeuze: wat de gebruiker in de vraag zegt, hoe dat samengaat met de bronkiezer en welke bronnen volledig meegaan.
final class SourceScopeTests: XCTestCase {
    func testOnlyCalendarAndMailInDutch() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Gebruik alleen mijn agenda en mail en bereid me voor op morgen"))
        XCTAssertEqual(scope.mode, .only)
        XCTAssertTrue(scope.allows("calendar"))
        XCTAssertTrue(scope.allows("mail"))
        XCTAssertTrue(scope.allows("icalfeeds"), "‘agenda’ dekt alle agenda's")
        XCTAssertFalse(scope.allows("github"))
        XCTAssertFalse(scope.allows(SourceCatalog.screen))
    }

    func testOnlyInEnglish() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Only use my calendar and email."))
        XCTAssertEqual(scope.mode, .only)
        XCTAssertEqual(scope.included, ["calendar", "icalfeeds", "calcom", "mail"])
    }

    func testFocusWithExclusion() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Search Slack and GitHub, but do not use my screen context."))
        XCTAssertEqual(scope.mode, .automatic)
        XCTAssertTrue(scope.focus.contains("github"))
        XCTAssertTrue(scope.focus.contains("customsources"))
        XCTAssertEqual(scope.excluded, [SourceCatalog.screen])
        XCTAssertFalse(scope.allowsTool("read_screen"))
        XCTAssertTrue(scope.allowsTool("github_search"))
    }

    func testDutchNegationAfterMention() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Vat mijn week samen, maar gebruik mijn scherm niet"))
        XCTAssertEqual(scope.excluded, [SourceCatalog.screen])
    }

    func testWithoutInGerman() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Fasse alles zusammen ohne Bildschirm"))
        XCTAssertTrue(scope.excluded.contains(SourceCatalog.screen))
    }

    func testAllSourcesIsAutomatic() throws {
        let scope = try XCTUnwrap(SourceScope.parse("Use all relevant sources available to me."))
        XCTAssertEqual(scope.mode, .automatic)
        XCTAssertFalse(scope.isRestricted)
    }

    func testNoMentionGivesNil() {
        XCTAssertNil(SourceScope.parse("Hoe laat is het?"))
    }

    func testIncidentalNegationDoesNotExclude() throws {
        // "niet" hoort bij dubbel geboekt, niet bij de agenda.
        let scope = SourceScope.parse("Check of ik vrijdag niet dubbel geboekt sta in mijn agenda")
        XCTAssertFalse(scope?.excluded.contains("calendar") ?? false)
    }

    func testToolsWithoutSourceAlwaysAllowed() {
        let scope = SourceScope(mode: .only, included: ["mail"])
        XCTAssertTrue(scope.allowsTool("show_chart"))
        XCTAssertTrue(scope.allowsTool("compose_mail"))
        XCTAssertFalse(scope.allowsTool("list_events"))
        XCTAssertFalse(scope.allowsTool("search_web"))
    }

    func testMergeKeepsPickerExclusions() {
        let picker = SourceScope(mode: .automatic, excluded: [SourceCatalog.screen])
        let request = SourceScope(mode: .only, included: ["mail", SourceCatalog.screen])
        let merged = picker.merged(with: request)
        XCTAssertEqual(merged.mode, .only)
        XCTAssertTrue(merged.allows("mail"))
        XCTAssertFalse(merged.allows(SourceCatalog.screen), "Wat in de bronkiezer uit staat, blijft uit")
    }

    func testMergeIntersectsWithPickerOnly() {
        let picker = SourceScope(mode: .only, included: ["mail", "calendar"])
        let request = SourceScope(mode: .only, included: ["mail"])
        XCTAssertEqual(picker.merged(with: request).included, ["mail"])
    }

    func testLabel() {
        XCTAssertEqual(SourceScope.automatic.label(), "Automatisch")
        XCTAssertEqual(SourceScope(mode: .only, included: ["calendar", "mail"]).label(), "Alleen Agenda en Mail")
        XCTAssertEqual(SourceScope(excluded: [SourceCatalog.screen]).label(), "Zonder Scherm")
    }

    func testToolSourceMapping() {
        XCTAssertEqual(SourceCatalog.source(forTool: "github_pr_details"), "github")
        XCTAssertEqual(SourceCatalog.source(forTool: "search_mail"), "mail")
        XCTAssertEqual(SourceCatalog.source(forTool: "check_availability"), "calendar")
        XCTAssertEqual(SourceCatalog.source(forTool: "notion_read_page"), "notion")
        XCTAssertNil(SourceCatalog.source(forTool: "show_chart"))
        XCTAssertNil(SourceCatalog.source(forTool: "compose_mail"), "Een concept schrijven is geen bron lezen")
    }

    // MARK: Routering

    func testRouterTargetsRelevantSources() {
        let active: Set<String> = ["calendar", "mail", "github", "stripe", "browser", "files"]
        let relevant = SourceRouter.relevant(to: "Wat heeft Lisa gemaild over de offerte?", scope: .automatic, active: active)
        XCTAssertTrue(relevant.contains("mail"))
        XCTAssertTrue(relevant.contains("calendar"), "agenda gaat altijd mee")
        XCTAssertFalse(relevant.contains("stripe"))
        XCTAssertFalse(relevant.contains("github"))
    }

    func testRouterBroadQuestionUsesAllAllowed() {
        let active: Set<String> = ["calendar", "mail", "github", "stripe"]
        let relevant = SourceRouter.relevant(to: "Vat samen wat er deze week gebeurde", scope: SourceScope(excluded: ["stripe"]), active: active)
        XCTAssertEqual(relevant, ["calendar", "mail", "github"])
    }

    func testRouterUnderstandsUnreadMailWithoutTheWordMail() {
        let active: Set<String> = ["calendar", "mail", "github"]
        for question in ["hoeveel heb ik nog niet gelezen?", "maak een grafiek van mijn ongelezen berichten", "how many unread do I have"] {
            let relevant = SourceRouter.relevant(to: question, scope: .automatic, active: active)
            XCTAssertTrue(relevant.contains("mail"), question)
            XCTAssertFalse(relevant.contains("github"), question)
        }
        XCTAssertEqual(SourceCatalog.source(forTool: "mail_unread"), "mail")
        XCTAssertEqual(SourceCatalog.source(forTool: "inbox_mail"), "mail")
        XCTAssertEqual(SourceCatalog.source(forTool: "read_app"), SourceCatalog.screen, "zonder scherm = ook geen apps lezen")
    }

    func testRouterRespectsOnlyScope() {
        let active: Set<String> = ["calendar", "mail", "github"]
        let relevant = SourceRouter.relevant(to: "summarize everything", scope: SourceScope(mode: .only, included: ["github"]), active: active)
        XCTAssertEqual(relevant, ["github"])
    }
}

final class SourceCapabilitiesTests: XCTestCase {
    func testDescribeSeparatesReadAndWrite() {
        let tools: [(name: String, isAction: Bool)] = [
            ("github_search", false), ("github_create_issue", true), ("search_mail", false), ("show_chart", false)
        ]
        let github = SourceCapabilities.describe("github", tools: tools)
        XCTAssertEqual(github.reads, ["issues en PR's zoeken"])
        XCTAssertEqual(github.writes, ["issue maken"])
        XCTAssertEqual(SourceCapabilities.line("stripe", tools: [("stripe_payments", false)]),
                       "API-sleutel · lezen: betalingen lezen · schrijven: niets")
    }
}
