import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

/// Mail changes and app menu commands that the chat proposes: parsing the request, guarding it, and the AppleScript.
final class AppActionsTests: XCTestCase {
    // MARK: Mail

    func testMessageIDsAreCleanedFromEveryForm() {
        let ids = MailActions.ids(["message:%3Cabc@example.com%3E", "<def@example.com>", "id: ghi@example.com", " abc@example.com ", ""])
        XCTAssertEqual(ids, ["abc@example.com", "def@example.com", "ghi@example.com"])
    }

    func testSelectionReadsIdsFiltersAndDays() {
        let selection = MailActions.selection(["ids": ["<a@x>"], "from": " LinkedIn ", "unread_only": true, "days": "500"])
        XCTAssertEqual(selection.ids, ["a@x"])
        XCTAssertEqual(selection.from, "LinkedIn")
        XCTAssertNil(selection.subject)
        XCTAssertTrue(selection.unreadOnly)
        XCTAssertEqual(selection.days, 365)
    }

    func testTrashNeedsANarrowSelection() {
        XCTAssertFalse(MailActions.problems(.trash, .init(unreadOnly: true, days: 7)).isEmpty)
        XCTAssertTrue(MailActions.problems(.trash, .init(from: "linkedin")).isEmpty)
        XCTAssertTrue(MailActions.problems(.trash, .init(ids: ["a@x"])).isEmpty)
        // Marking everything unread of this week as read is a normal request.
        XCTAssertTrue(MailActions.problems(.read, .init(unreadOnly: true, days: 7)).isEmpty)
        XCTAssertFalse(MailActions.problems(.read, .init()).isEmpty)
    }

    func testScriptFiltersAndAppliesTheChange() {
        let script = MailActions.script(.trash, .init(from: "news\"letter", unreadOnly: true, days: 30))
        XCTAssertTrue(script.contains("sender contains \"news\\\"letter\""))
        XCTAssertTrue(script.contains("read status is false"))
        XCTAssertTrue(script.contains("set cutoff to (current date) - (30 * days)"))
        XCTAssertTrue(script.contains("date received > cutoff"))
        XCTAssertTrue(script.contains("delete m"))
        XCTAssertTrue(script.contains(">= \(MailActions.limit)"))

        let ids = MailActions.script(.flagged, .init(ids: ["a@x", "b@x"]))
        XCTAssertTrue(ids.contains("(message id is \"a@x\" or message id is \"b@x\")"))
        XCTAssertTrue(ids.contains("set flagged status of m to true"))
    }

    func testSummaryAndResult() {
        XCTAssertEqual(MailActions.summary(.trash, .init(from: "LinkedIn", days: 30)), "Move mail from LinkedIn (last 30 days) to Trash")
        XCTAssertEqual(MailActions.summary(.read, .init(ids: ["a", "b"])), "Mark 2 messages as read")
        let result = MailActions.describe(.trash, raw: "2\nWeekly digest|||LinkedIn <news@linkedin.com>\nJobs|||LinkedIn <jobs@linkedin.com>\n")
        XCTAssertTrue(result.hasPrefix("Moved to Trash: 2 messages."))
        XCTAssertTrue(result.contains("- Weekly digest (from LinkedIn)"))
        XCTAssertEqual(MailActions.describe(.read, raw: "0\n"), "No matching mail found in the inbox; nothing changed.")
    }

    func testActionGateRejectsTrashingAllMail() {
        let schema: [String: Any] = ["type": "object", "properties": [
            "unread_only": ["type": "boolean"], "from": ["type": "string"]
        ]]
        let broad = ActionGate.problems(tool: "trash_mail", input: ["unread_only": true], schema: schema, parseDate: { _ in nil })
        XCTAssertFalse(broad.isEmpty)
        let narrow = ActionGate.problems(tool: "trash_mail", input: ["from": "linkedin"], schema: schema, parseDate: { _ in nil })
        XCTAssertTrue(narrow.isEmpty)
    }

    // MARK: App menus

    func testMenuPathFromArrayOrText() {
        XCTAssertEqual(AppMenu.path(["File", " New Folder "]), ["File", "New Folder"])
        XCTAssertEqual(AppMenu.path("Message > Move to > Archive"), ["Message", "Move to", "Archive"])
        XCTAssertEqual(AppMenu.path("Bestand › Nieuwe map"), ["Bestand", "Nieuwe map"])
        XCTAssertEqual(AppMenu.path(nil), [])
    }

    func testMenuCommandNeedsAFullPath() {
        XCTAssertFalse(AppMenu.problems(app: "Finder", path: ["File"]).isEmpty)
        XCTAssertFalse(AppMenu.problems(app: "", path: ["File", "New Folder"]).isEmpty)
        XCTAssertFalse(AppMenu.problems(app: "Finder", path: ["A", "B", "C", "D"]).isEmpty)
        XCTAssertTrue(AppMenu.problems(app: "Finder", path: ["File", "New Folder"]).isEmpty)
    }

    func testClickScriptWalksDownTheMenus() {
        let script = AppMenu.clickScript(process: "Mail", path: ["Message", "Move to", "Archive"])
        XCTAssertTrue(script.contains("tell process \"Mail\""))
        XCTAssertTrue(script.contains("menu item \"Archive\" of menu 1 of menu item \"Move to\" of menu 1 of menu bar item \"Message\" of menu bar 1"))
    }

    func testMenuListingFiltersAndDeduplicates() {
        let raw = "File > New Folder\nFile > New Folder\nEdit > Move to Trash\nView > as List\n"
        let all = AppMenu.describe(raw, app: "Finder", filter: nil)
        XCTAssertEqual(all.components(separatedBy: "File > New Folder").count, 2)
        let trash = AppMenu.describe(raw, app: "Finder", filter: "trash")
        XCTAssertTrue(trash.contains("- Edit > Move to Trash"))
        XCTAssertFalse(trash.contains("New Folder"))
        XCTAssertEqual(AppMenu.describe("", app: "Finder", filter: nil), "Finder shows no menu commands right now.")
    }
}
