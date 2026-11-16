import Foundation

/// A session with more conversation than fits opens at its end: its newest prompt is on screen and its first is not,
/// when it opens and again when you come back to it from another session. The first prompt stays as one mark on the
/// conversation's rail; its message is not drawn (the lazy list keeps rows near the screen in the accessibility tree,
/// so the session is several screens long).
final class SessionOpensAtEnd: Scenario {
    func testSessionOpensAtEnd() throws {
        try scenario("A long session opens at its end, also when you come back to it") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let prompts = (1...12).map { "Prompt number \($0) of the long session" }
            let long = try nook.session(project: project, title: "Long session", messages: prompts)
            let other = try nook.session(project: project, title: "Other session", messages: ["Give me a short tour"])

            try nook.open(long)
            try expect(screen.text(prompts[11])).toBeVisible()
            try expect(screen.text(prompts[0])).toHaveCount(1)
            try app.screenshot("opened")

            try nook.open(other)
            try expect(screen.text("Give me a short tour").first).toBeVisible()

            try nook.open(long)
            try expect(screen.text(prompts[11])).toBeVisible()
            try expect(screen.text(prompts[0])).toHaveCount(1)
            try app.screenshot("back")
        }
    }
}
