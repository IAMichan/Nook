import AppKit

/// The Agents list grouped by project (Settings › General): a folder per project, a project you
/// added pinned on top even with no sessions, and the sessions without a project together under one folder instead of one
/// each.
final class SidebarProjectFolders: Scenario {
    func testSidebarProjectFolders() throws {
        try scenario("Sessions sit in project folders; chats without a project share one folder") { nook, screen, app in
            InboxStore.shared.groupByProject = true
            let shop = try nook.project("shop")
            let blog = try nook.project("blog")
            let added = try nook.project("docs-site")
            WorkspaceSettings.shared.addProject(added.path)
            let convert = NookFixture.Project(name: "convert", path: try ScratchProjects.create(prompt: "Convert these pngs"))
            let trip = NookFixture.Project(name: "trip", path: try ScratchProjects.create(prompt: "Plan a trip"))
            _ = try nook.session(project: shop, title: "Fix the checkout", messages: ["Fix the checkout"])
            _ = try nook.session(project: blog, title: "Write a post", messages: ["Write a post"])
            _ = try nook.session(project: convert, title: "Convert the PNGs", messages: ["Convert these pngs"])
            let last = try nook.session(project: trip, title: "Plan the trip", messages: ["Plan a trip"])
            try nook.open(last)

            // The list is there: the sessions show by name.
            try expect(screen.text("Fix the checkout").first).toBeVisible()
            try expect(screen.labelled("docs-site")).toBeVisible()
            try expect(screen.labelled("shop")).toBeVisible()
            try expect(screen.labelled("No project")).toBeVisible()
            // A folder Nook made for a chat without a project never gets a folder of its own. (The open chat's own title
            // bar still names its folder, so this checks the other one.)
            try expect(screen.text("convert-these-pngs")).toBeHidden()
            try expect(screen.labelled("Add project")).toBeVisible()
            try app.screenshot("folders")
        }
    }
}
