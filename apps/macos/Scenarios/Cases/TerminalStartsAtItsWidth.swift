import AppKit

/// A program in a terminal reads the width the terminal has on screen. A terminal used to start its shell at a made-up
/// 800 points (about 110 columns) and only got its real width once shown, so a program that draws to the width it reads
/// at launch (devenv's task tree, progress bars) drew lines too long for the terminal, and every redraw stacked under
/// the last one.
final class TerminalStartsAtItsWidth: Scenario {
    func testTerminalStartsAtItsWidth() throws {
        try scenario("A command in a terminal reads the width the terminal shows") { nook, screen, app in
            let project = try nook.project("demo")
            // The smallest window, so the terminal is clearly narrower than 800 points.
            try nook.openNook(nil, size: CGSize(width: 900, height: 600))
            let model = nook.app
            model.viewModel.windowTab = .agents
            model.viewModel.selectedAgentID = AgentsPage.terminals
            let session = TerminalStore.shared.open(in: project.path, command: "stty size", title: "Width")
            screen.settle(1.0)

            // What `stty size` printed: "rows columns".
            var printed: Int?
            try screen.scenario.step("terminal", "wait for stty size") {
                let end = Date().addingTimeInterval(15)
                while printed == nil {
                    printed = session.output(lines: 200).split(separator: "\n").lazy.compactMap { line -> Int? in
                        let parts = line.split(separator: " ")
                        guard parts.count == 2, Int(parts[0]) != nil else { return nil }
                        return Int(parts[1])
                    }.first
                    if printed != nil { break }
                    if Date() > end { throw ScenarioFailure.couldNotRun("the terminal printed no size after 15 s") }
                    ScenarioClock.spin(nanoseconds: 100_000_000)
                }
            }
            try app.screenshot("terminal")

            let shown = session.view.getTerminal().cols
            try screen.scenario.step("expect", "the command read \(shown) columns") {
                guard printed == shown else {
                    throw ScenarioFailure.assertion("the command read \(printed ?? 0) columns; the terminal shows \(shown)")
                }
            }
            TerminalStore.shared.close(session.id)
        }
    }
}
