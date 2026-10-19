import XCTest

/// Evaluation set for source selection: everyday questions in Dutch and English, with the sources Nook must consult
/// (and, where it matters, must leave alone). New phrasings that users try belong here.
final class RoutingEvalTests: XCTestCase {
    private let active: Set<String> = ["calendar", "reminders", "loops", "mail", "notes", "files", "browser", "github", "notion",
                                       "stripe", "vercel", "customsources", "contacts", "clipboard"]

    private struct Case {
        let question: String
        let must: Set<String>
        var mustNot: Set<String> = []
    }

    private let cases: [Case] = [
        Case(question: "Zoek de laatste ontwikkelingen rond mijn project, vergelijk wat in mijn berichten en documenten staat en plan een overleg",
             must: ["mail", "files", "calendar", "customsources"]),
        Case(question: "Heb ik nog ongelezen mail van Lisa?", must: ["mail"], mustNot: ["stripe"]),
        Case(question: "Wat staat er in mijn notities over de offerte?", must: ["notes", "files"]),
        Case(question: "Welke pull requests wachten op mijn review?", must: ["github"], mustNot: ["stripe"]),
        Case(question: "Is de laatste deploy gelukt?", must: ["vercel"]),
        Case(question: "Hoeveel omzet hebben we deze maand?", must: ["stripe"]),
        Case(question: "Wat is het telefoonnummer van Jan?", must: ["contacts"]),
        Case(question: "Vat dit artikel in mijn browser samen", must: ["browser"]),
        Case(question: "Ben ik vrijdag beschikbaar voor een call?", must: ["calendar"]),
        Case(question: "Wat moet ik vandaag nog doen?", must: ["reminders", "loops", "calendar"]),
        Case(question: "Zoek in de wiki naar de onboarding-documentatie", must: ["notion"]),
        Case(question: "Wat zei het team in Slack over de release?", must: ["customsources", "github"]),
        Case(question: "Find the requirements document for the new dashboard", must: ["files", "notion"]),
        Case(question: "Did anyone reply to my email about the invoice?", must: ["mail"]),
        Case(question: "Which issues are open for the launch?", must: ["github"]),
        Case(question: "Summarize my week", must: ["mail", "github", "calendar", "notes"]),
        Case(question: "Wat heb ik net gekopieerd?", must: ["clipboard"]),
        Case(question: "Hoe laat is mijn volgende afspraak?", must: ["calendar"], mustNot: ["github", "stripe", "mail"])
    ]

    func testEverydayQuestionsReachTheRightSources() {
        var misses: [String] = []
        for item in cases {
            let routed = SourceRouter.relevant(to: item.question, scope: .automatic, active: active)
            let missing = item.must.subtracting(routed)
            let extra = item.mustNot.intersection(routed)
            if !missing.isEmpty || !extra.isEmpty {
                misses.append("\"\(item.question)\": missing \(missing.sorted()), unwanted \(extra.sorted())")
            }
        }
        XCTAssertTrue(misses.isEmpty, "Routing misses:\n" + misses.joined(separator: "\n"))
    }

    func testExclusionsInTheQuestionAlwaysWin() {
        let scope = SourceScope.automatic.merged(with: SourceScope.parse("vat mijn week samen, maar niet uit mijn mail"))
        let routed = SourceRouter.relevant(to: "vat mijn week samen, maar niet uit mijn mail", scope: scope, active: active)
        XCTAssertFalse(routed.contains("mail"))
        XCTAssertTrue(routed.contains("calendar"))
    }
}
