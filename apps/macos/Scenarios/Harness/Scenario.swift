import AppKit
import XCTest

/// A scenario: one behavior shown in the real app code, with the replay agent instead of a model (docs/SCENARIOS.md).
/// Write one test per file, with its body in `scenario(_:)`:
///
///     final class ReplayTurnStreams: Scenario {
///         func testReplayTurnStreams() throws {
///             try scenario("A replayed turn streams a reply") { nook, screen, app in
///                 let project = try nook.project("demo", files: ["Sources/Math.swift": "…"])
///                 let session = try nook.session(project: project, title: "Tour", messages: ["Hi"])
///                 try nook.open(session)
///                 try expect(screen.text("This turn is a replay")).toBeVisible()
///                 try app.screenshot("finished")
///             }
///         }
///     }
@MainActor
class Scenario: XCTestCase {
    private(set) var steps: [ScenarioReport.Step] = []
    private(set) var captures: [String] = []
    private(set) var notes: [String] = []
    private var resultDirectory: URL?
    private var screen: Screen?
    private var fixture: NookFixture?

    /// The test's name without the `test` prefix: its folder in the output.
    var scenarioName: String {
        let method = name.split(separator: " ").last.map { String($0.dropLast()) } ?? name
        let className = String(describing: type(of: self))
        let short = method.hasPrefix("test") ? String(method.dropFirst(4)) : method
        return short == className ? className : className + "-" + short
    }

    func log(_ line: String) { notes.append(line) }

    /// SwiftUI builds its accessibility elements only for an app an assistive client asked about; the process asks
    /// for them itself, once and before any scenario runs (it holds for this process only).
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            let selector = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
            if NSApplication.shared.responds(to: selector) { NSApplication.shared.perform(selector, with: NSNumber(value: true)) }
        }
    }

    /// Runs the scenario body and writes its result: passed, failed (an `expect` did not hold), or error (could not run).
    func scenario(_ title: String, _ body: (NookFixture, Screen, ScenarioApp) throws -> Void) throws {
        let started = Date()
        var failure: ScenarioFailure?
        do {
            let paths = try ScenarioHome.prepare()
            let directory = paths.output.appendingPathComponent("results", isDirectory: true)
                .appendingPathComponent(scenarioName, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resultDirectory = directory
            let screen = Screen(scenario: self)
            self.screen = screen
            let fixture = NookFixture(scenario: self, paths: paths, screen: screen)
            self.fixture = fixture
            _ = ScenarioRuntimeGuards.drain()
            _ = ScenarioHome.drainSpawnRefusals()
            try body(fixture, screen, ScenarioApp(scenario: self, screen: screen))
            // What the guards refused counts against the run: the scenario cannot vouch for a run that tried.
            let refused = ScenarioRuntimeGuards.drain() + ScenarioHome.drainSpawnRefusals()
            if !refused.isEmpty {
                notes += refused.map { "guard: " + $0 }
                if let agent = refused.first(where: { $0.hasPrefix("spawn refused") || $0.hasPrefix("process") }),
                   fixture.agentRefusalsFail {
                    throw ScenarioFailure.couldNotRun("a guard refused to start a real agent: \(agent)")
                }
            }
        } catch let error as ScenarioFailure {
            failure = error
        } catch {
            failure = .couldNotRun("\(error)")
        }
        if let failure {
            // The screen where it went wrong, and what the tree held then.
            if screen?.window != nil {
                try? ScenarioApp(scenario: self, screen: screen!).capture("failure", recordStep: false)
                notes.append("screen at failure:\n" + (screen?.dump() ?? ""))
            }
        }
        fixture?.tearDown()
        notes += (ScenarioRuntimeGuards.drain() + ScenarioHome.drainSpawnRefusals()).map { "guard: " + $0 }
        let status: ScenarioReport.Status
        switch failure {
        case nil: status = .passed
        case .assertion?: status = .failed
        case .couldNotRun?: status = .error
        }
        let result = ScenarioReport.Result(name: scenarioName, title: title, status: status,
                                           error: failure.map { .init(code: $0.code, message: $0.message) },
                                           steps: steps, captures: captures, notes: notes,
                                           durationSeconds: Date().timeIntervalSince(started))
        ScenarioReport.write(result, in: resultDirectory)
        if let failure { XCTFail(failure.description) }
    }

    /// Records one step of the scenario for the report.
    func step<T>(_ api: String, _ label: String, _ work: () throws -> T) throws -> T {
        let index = steps.count
        steps.append(.init(api: api, label: label, status: "running"))
        NSLog("NookScenarios step: %@ %@", api, label)
        do {
            let value = try work()
            steps[index].status = "passed"
            return value
        } catch {
            steps[index].status = "failed"
            throw error
        }
    }

    func addCapture(_ data: Data, label: String) throws {
        guard let resultDirectory else { return }
        let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let file = String(format: "%02d-%@.png", captures.count + 1, slug)
        try data.write(to: resultDirectory.appendingPathComponent(file))
        captures.append(file)
    }
}

/// The app as a whole: screenshots of the hosted window.
@MainActor
struct ScenarioApp {
    let scenario: Scenario
    let screen: Screen

    /// Writes the window as it is now to the scenario's output as `NN-label.png`. A proof pairs base and head captures
    /// by label.
    func screenshot(_ label: String) throws {
        try capture(label, recordStep: true)
    }

    func capture(_ label: String, recordStep: Bool) throws {
        let work = {
            screen.settle(0.2)
            guard let host = screen.host else { throw ScenarioFailure.couldNotRun("no window to capture: call nook.open first") }
            guard let data = ScenarioCapture.png(of: host) else { throw ScenarioFailure.couldNotRun("the window could not be drawn") }
            try scenario.addCapture(data, label: label)
        }
        if recordStep { try scenario.step("screenshot", label, work) } else { try work() }
    }
}

enum ScenarioCapture {
    /// Draws the view's layer tree into a bitmap. The window is never on screen, so the window server has no picture of
    /// it; `cacheDisplay` can be stale there, the layer tree is what the view shows.
    @MainActor static func png(of view: NSView, scale: CGFloat = 2) -> Data? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped || layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        CATransaction.flush()
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = size
        return bitmap.representation(using: .png, properties: [:])
    }
}
