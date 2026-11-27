import AppKit
import Foundation

/// Reading back through a long session while its agent keeps working, as a hand does on a trackpad: strokes up with a
/// reader's pause after each, then back down to the end. What you read moves only by your own steps: never while your
/// hands are off, and never by more or less than a step while you scroll. It used to bounce up and down under the reader
/// (rows above measured anew, folds, the end being put back), so the conversation could not be read nor scrolled through.
///
/// What moves on screen is measured on the text you read itself: every text view of the conversation in view, frame by
/// frame, compared with where the same view (with the same text) stood the frame before.
final class ReadingBackWhileWorking: Scenario {
    /// How far what you read may move in a frame without a step of yours (a rounding step).
    static let restMargin = 3.0
    /// How far a step may move what you read off the step itself.
    static let stepMargin = 6.0
    static let strokes = 14
    static let stepsPerStroke = 8
    static let step = 30.0
    /// Seconds hands off after each stroke up.
    static let pause = 1.2

    func testReadingBackWhileWorking() throws {
        try scenario("Reading back through a working session moves only with your own steps") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math { static func sum(a: Int) -> Int { a + 1 } }\n"])
            let prompts = (1...8).map { "Check and fix part \($0) of the reader" }
            let session = try nook.session(project: project, title: "Reading while working", messages: prompts, recording: "reading-work")
            try nook.open(session)
            try expect(screen.text(prompts[7])).toBeVisible()
            screen.settle(1.0)
            try nook.send(session, "Now go through the whole reader", wait: false)
            screen.settle(5.0)

            guard let scrollView = Self.conversation(in: screen.window?.contentView), let root = screen.window?.contentView else {
                throw ScenarioFailure.couldNotRun("the conversation's scroll view was not found")
            }
            let workspace = nook.app.workspace
            let wheel = Wheel(window: screen.window, scrollView: scrollView)
            let trace = ClipMoveTrace(scrollView)
            defer { wheel.finish(); trace.stop() }

            var restMoves: [String] = []
            var stepMisses: [String] = []
            var worstRest = 0.0
            var worstStep = 0.0
            var frames = 0
            var last = Self.texts(in: scrollView, root: root)
            /// Compares where what you read stands now with the frame before; `expected` is how far your step moved it
            /// (window coordinates: up is positive), nil when your hands were off.
            @MainActor func frame(_ label: @autoclosure () -> String, expected: Double?) {
                screen.refresh()
                frames += 1
                let now = Self.texts(in: scrollView, root: root)
                defer { last = now }
                guard let moved = Self.move(from: last, to: now) else { return }
                if let expected {
                    let off = abs(moved - expected)
                    if off > worstStep { worstStep = off }
                    if off > Self.stepMargin { stepMisses.append(String(format: "%@: moved %.0f for a step of %.0f", label(), moved, expected)) }
                } else {
                    if abs(moved) > worstRest { worstRest = abs(moved) }
                    if abs(moved) > Self.restMargin { restMoves.append(String(format: "%@: %@ %.0f pt", label(), moved > 0 ? "up" : "down", abs(moved))) }
                }
            }
            @MainActor func step(_ deltaY: Double, _ label: String) {
                let top = -Double(scrollView.contentView.contentInsets.top)
                let room = deltaY > 0 ? Double(scrollView.contentView.bounds.origin.y) - top : Self.fromEnd(scrollView)
                wheel.step(deltaY: deltaY)
                // What you read moves with your step (a step up moves the text down the screen), as far as the view
                // had room to go; the scroll view may move its clip view further by itself along with rows above that
                // it measured anew, which you do not see.
                let expected = -(deltaY > 0 ? min(deltaY, room) : max(deltaY, -room))
                frame(label, expected: expected)
            }
            @MainActor func handsOff(_ seconds: Double, _ label: String) {
                trace.armed = true
                defer { trace.armed = false }
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                    frame(label, expected: nil)
                }
            }

            let contentBefore = Double(scrollView.documentView?.frame.height ?? 0)
            // Up in strokes, a reader's pause after each.
            for stroke in 1...Self.strokes {
                let center = NotificationCenter.default
                center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
                for index in 1...Self.stepsPerStroke {
                    step(Self.step, "stroke \(stroke) up, step \(index)")
                    center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
                }
                center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
                handsOff(Self.pause, "reading after stroke \(stroke) up")
            }
            guard workspace.run(session.id)?.status.isActive == true else {
                throw ScenarioFailure.couldNotRun("the agent stopped working before the reading was done")
            }
            try app.screenshot("reading")
            self.log(String(format: "content %.0f pt before reading back, %.0f pt after (earlier rows drawn above as you went up)",
                            contentBefore, Double(scrollView.documentView?.frame.height ?? 0)))
            // Back down, slower strokes with pauses, until the end.
            for stroke in 1...Self.strokes {
                let center = NotificationCenter.default
                center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
                for index in 1...Self.stepsPerStroke {
                    step(-Self.step, "stroke \(stroke) down, step \(index)")
                    center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
                }
                center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
                if Self.fromEnd(scrollView) <= 1 { break }
                handsOff(Self.pause, "reading after stroke \(stroke) down")
            }

            self.log("\(frames) frames, worst move at rest \(Int(worstRest)) pt, worst step off by \(Int(worstStep)) pt")
            self.log("moves at rest: \(restMoves.count)" + (restMoves.isEmpty ? "" : ": " + restMoves.prefix(12).joined(separator: "; ")))
            self.log("steps off: \(stepMisses.count)" + (stepMisses.isEmpty ? "" : ": " + stepMisses.prefix(12).joined(separator: "; ")))
            // Who moved the view while your hands were off: on 2026-11-27 the reading anchor, holding a row by the
            // place a lazy stack guessed for it.
            for line in trace.report().prefix(15) { self.log(line) }
            if !restMoves.isEmpty || !stepMisses.isEmpty {
                throw ScenarioFailure.assertion("what you read moved by itself \(restMoves.count) time(s) (worst \(Int(worstRest)) pt) and "
                                                + "\(stepMisses.count) step(s) moved it off the step (worst \(Int(worstStep)) pt); first: "
                                                + (restMoves.first ?? stepMisses.first ?? ""))
            }
        }
    }

    /// Where each text view of the conversation in view stands (its top in window coordinates), by the view and its text.
    @MainActor
    private static func texts(in scrollView: NSScrollView, root: NSView) -> [TextKey: Double] {
        let clip = scrollView.contentView
        let visible = clip.convert(clip.bounds, to: nil)
        var found: [TextKey: Double] = [:]
        func visit(_ view: NSView) {
            if let text = view as? NSTextView, !text.isEditable {
                let frame = text.convert(text.bounds, to: nil)
                if frame.height > 4, frame.intersects(visible.insetBy(dx: 0, dy: 40)) {
                    found[TextKey(view: ObjectIdentifier(text), text: text.string.hashValue, height: Int(frame.height))] = Double(frame.maxY)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        scrollView.documentView.map(visit)
        return found
    }

    /// How far what you read moved between two frames (up is positive): the move most of the text views in both agree
    /// on; nil when none is in both.
    private static func move(from old: [TextKey: Double], to new: [TextKey: Double]) -> Double? {
        let moves = new.compactMap { key, y in old[key].map { y - $0 } }.sorted()
        guard !moves.isEmpty else { return nil }
        return moves[moves.count / 2]
    }

    private struct TextKey: Hashable {
        let view: ObjectIdentifier
        let text: Int
        let height: Int
    }

    private static func fromEnd(_ scrollView: NSScrollView) -> Double {
        let clip = scrollView.contentView
        let end = Double(scrollView.documentView?.frame.height ?? 0) + Double(clip.contentInsets.bottom) - Double(clip.bounds.height)
        return max(0, end - Double(clip.bounds.origin.y))
    }

    /// The scroll view with the tallest content: the conversation.
    private static func conversation(in root: NSView?) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        root.map(visit)
        return best
    }
}
