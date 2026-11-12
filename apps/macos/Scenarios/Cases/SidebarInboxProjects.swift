import AppKit

/// The Agents list: one inbox, not a folder per project. Every row names its project with a badge, a
/// session at work sits on the Working shelf at the foot of the list, and a finished one comes up on top.
final class SidebarInboxProjects: Scenario {
    func testSidebarInboxProjects() throws {
        try scenario("One list with the project on every row, Working at the foot, a finished session on top") { nook, screen, app in
            // "shop" has a favicon of its own, which its rows show; "blog" has none and shows its initials.
            let favicon = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#f2b25c"/><path d="M9 12h14l-2 10H11z" fill="#1a1a1a"/></svg>"##
            let shop = try nook.project("shop", files: ["public/favicon.svg": favicon])
            let blog = try nook.project("blog")
            _ = try nook.session(project: shop, title: "Fix the checkout", messages: ["Fix the checkout"])
            let post = try nook.session(project: blog, title: "Write a post", messages: ["Write a post"])
            let busy = try nook.session(project: shop, title: "Speed up search", messages: ["Speed up search"], wait: false)
            try nook.open(post)

            // No folders: the rows say which project they are from.
            try expect(screen.text("Fix the checkout").first).toBeVisible()
            try expect(screen.text("Write a post").first).toBeVisible()
            try expect(screen.text("shop").first).toBeVisible()
            try expect(screen.text("blog").first).toBeVisible()
            try expect(screen.labelled("No project")).toBeHidden()
            // The session at work sits on its own shelf at the foot of the list.
            try expect(screen.text("Working").first).toBeVisible()
            try expect(screen.labelled("Add project")).toBeVisible()
            try app.screenshot("working")

            // Once it finishes it leaves the shelf and comes up on top of the list.
            _ = busy
            try expect(screen.text("Working now")).toBeHidden(timeout: 30)
            try expect(screen.text("Speed up search").first).toBeVisible()
            try app.screenshot("finished")
        }
    }
}
