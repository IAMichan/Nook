import AppKit
import Foundation

/// Watching an agent type a long answer, at the end of the conversation, without touching anything: what you read
/// never moves down (a bounce), and when the agent finishes the answer stays where it is instead of jumping. Each frame
/// of the screen is laid out and drawn as the window would draw it, so a frame that takes long is a stutter you see.
final class AnswerStreamsSmoothly: Scenario {
    /// The answer's first paragraph, unique to the turn that streams.
    static let marker = "The reader now stops at the first bad value."
    /// How far the answer may move down in one frame (a rounding step) before it counts as a jump.
    static let jumpMargin = 3.0
    /// How far the answer may move up in one frame once the agent is done: a glide's step, not the whole way at once
    /// (it jumped about 100 pt in one frame when its footer and card came in under it).
    static let finishStep = 48.0

    func testAnswerStreamsSmoothly() throws {
        try scenario("A streamed answer moves only up while it types and stays put when it is done") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math { static func sum(a: Int) -> Int { a + 1 } }\n"])
            let prompts = (1...4).map { "Look at part \($0) of the project" }
            let session = try nook.session(project: project, title: "Streaming answer", messages: prompts, recording: "streaming-answer")
            try nook.open(session)
            try expect(screen.text(prompts[3])).toBeVisible()
            screen.settle(1.0)
            guard let window = screen.window, let root = window.contentView else {
                throw ScenarioFailure.couldNotRun("no window")
            }

            try nook.send(session, "Now write it all up", wait: false)
            let workspace = nook.app.workspace
            var frames: [Double] = []
            var downs: [String] = []
            var ups: [String] = []
            var finishJump = 0.0
            var last: Double?
            var finishedAt: Date?
            var phase = "typing"
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                let start = Date()
                screen.refresh()
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                // The frame's whole time: the wait of a 60 Hz frame and whatever ran on the main thread meanwhile.
                frames.append(Date().timeIntervalSince(start) - 1.0 / 60)
                let active = workspace.run(session.id)?.status.isActive ?? false
                if !active, finishedAt == nil {
                    finishedAt = Date()
                    phase = "finishing"
                }
                // Where the answer's first paragraph stands on screen (window coordinates: higher is up).
                if let y = Self.markerTop(in: root) {
                    if let last, y < last - Self.jumpMargin {
                        downs.append(String(format: "%@: down %.0f pt", phase, last - y))
                    }
                    if let last, y > last + 24 {
                        ups.append(String(format: "%@: up %.0f pt", phase, y - last))
                    }
                    if let last, finishedAt != nil, y - last > finishJump { finishJump = y - last }
                    last = y
                }
                if let finishedAt, Date().timeIntervalSince(finishedAt) > 3 { break }
            }
            guard finishedAt != nil else { throw ScenarioFailure.couldNotRun("the turn did not finish") }
            guard last != nil else { throw ScenarioFailure.couldNotRun("the answer never showed") }
            try app.screenshot("finished")

            let sorted = frames.sorted()
            let p50 = sorted[sorted.count / 2] * 1000
            let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
            let slow = frames.filter { $0 > 1.0 / 30 }.count
            log(String(format: "%d frames: p50 %.1f ms, p95 %.1f ms, worst %.0f ms, %d over 33 ms",
                       frames.count, p50, p95, (sorted.last ?? 0) * 1000, slow))
            log("moves down: \(downs.isEmpty ? "none" : downs.joined(separator: ", "))")
            log("big moves up: \(ups.isEmpty ? "none" : ups.joined(separator: ", "))")
            if finishJump > Self.finishStep {
                throw ScenarioFailure.assertion(String(format: "when the agent was done the answer jumped %.0f pt up in one frame", finishJump))
            }
            if !downs.isEmpty {
                throw ScenarioFailure.assertion("the answer moved down while you watched: \(downs.prefix(6).joined(separator: ", "))")
            }
        }
    }

    /// The top of the text view that shows the marker, in window coordinates; nil while it is not drawn.
    private static func markerTop(in root: NSView) -> Double? {
        var found: Double?
        func visit(_ view: NSView) {
            guard found == nil else { return }
            if let text = view as? NSTextView, text.string.contains(marker) {
                let frame = text.convert(text.bounds, to: nil)
                let range = (text.string as NSString).range(of: marker)
                if let layout = text.layoutManager, let container = text.textContainer {
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    found = Double(text.convert(rect, to: nil).maxY)
                } else {
                    found = Double(frame.maxY)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }
}
