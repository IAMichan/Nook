import Foundation

final class ReplayTurnStreams: Scenario {
    func testReplayTurnStreams() throws {
        try scenario("A replayed turn streams a reply, shows its tool calls, and finishes") { nook, screen, app in
            let project = try nook.project("demo", files: [
                "Sources/Math.swift": "enum Math {\n    static func sum(_ a: Int, _ b: Int) -> Int {\n        a + b\n    }\n}\n",
            ])
            let session = try nook.session(project: project, title: "Short tour", messages: ["Give me a short tour"],
                                                 wait: false)
            try nook.open(session)

            let stop = screen.button("Stop")
            try expect(screen.text("The project has a single math module")).toBeVisible()
            try expect(stop).toBeVisible()
            try app.screenshot("streaming")

            try expect(screen.text("This turn is a replay")).toBeVisible(timeout: 30)
            try expect(stop).toBeHidden()
            try expect(screen.text("Give me a short tour").first).toBeVisible()
            // The finished turn folds its work away; opening it shows the tool calls.
            try screen.button("Worked for", exact: false).tap()
            try expect(screen.text("Read 1 file and searched once")).toBeVisible()
            try app.screenshot("finished")
        }
    }
}
