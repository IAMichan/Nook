import AppKit
import SwiftUI

/// Scrolling back through a long chat (any chat app: they all show `ChatTranscript`): what you read moves with your
/// fingers and nothing else, also when a page of older messages is drawn above it and when the chat's app sends older
/// ones. It used to jump: each page was drawn first and the view put back on the old top message a frame later (a
/// `scrollTo`), so the chat flashed down and up again, and the view snapped to that message's top.
///
/// It hosts the real transcript in a window that is never on screen, scrolls it up 30 pt a step with `Wheel` and, after
/// each step, checks how far a message in view moved on screen: as far as the step, give or take a rounding step.
final class ChatHistoryScrollsSmoothly: Scenario {
    /// How far a message may stray from the step in one step before it counts as a jump.
    static let margin = 3.0
    static let step = 30.0

    func testChatHistoryScrollsSmoothly() throws {
        try scenario("Scrolling back through a long chat moves only with your fingers") { _, screen, app in
            let model = ChatHistoryModel(count: 150, older: 90)
            let host = NSHostingView(rootView: ChatHistoryHost(model: model))
            host.sizingOptions = []
            // Far outside every screen and never ordered in: nothing shows, nothing takes focus.
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 520, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            defer { window.close() }
            Self.allowAutomation(host)
            screen.window = window
            screen.settle(1.0)

            guard let scrollView = Self.scrollView(in: host) else {
                throw ScenarioFailure.couldNotRun("the chat's scroll view was not found")
            }
            let wheel = Wheel(window: window, scrollView: scrollView)
            defer { wheel.finish() }

            var jumps: [String] = []
            var steps = 0
            var stuck = 0
            // Up through every page drawn here and every one the app sends, until the chat's start.
            while steps < 1500, stuck < 40 {
                screen.refresh()
                if ProcessInfo.processInfo.environment["CHAT_SCROLL_TRACE"] != nil {
                    log(String(format: "step %d: offset %.0f, content %.0f, clip %.0f, first %@", steps,
                               scrollView.contentView.bounds.origin.y, scrollView.documentView?.frame.height ?? 0,
                               scrollView.contentView.bounds.height, Self.messageInView(screen)?.id ?? "-"))
                }
                guard let before = Self.messageInView(screen) else {
                    throw ScenarioFailure.couldNotRun("no message in view after \(steps) steps")
                }
                let offset = scrollView.contentView.bounds.origin.y
                wheel.step(deltaY: Self.step)
                steps += 1
                screen.refresh()
                guard let after = Self.position(of: before.id, screen) else {
                    jumps.append("step \(steps): \(before.id) left the view in one step")
                    continue
                }
                // Screen coordinates: higher is up. Scrolling up moves what you read down by the step, or less where the
                // view reached the top.
                let moved = before.y - after
                let moves = abs(scrollView.contentView.bounds.origin.y - offset) > 0.5 || abs(moved) > 0.5
                stuck = moves ? 0 : stuck + 1
                if !moves { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                // Where the view stood above its top less than a step, it could move only that far.
                let room = Double(offset) + Double(scrollView.contentView.contentInsets.top)
                let expected = min(Self.step, max(room, 0))
                if abs(moved - expected) > Self.margin {
                    jumps.append(String(format: "step %d: %@ moved %.0f pt for a step of %.0f", steps, before.id, moved, Self.step))
                }
            }
            try app.screenshot("start of the chat")
            log("\(steps) steps, \(model.fetches) fetch(es) from the app, \(model.bubbles.count) messages")
            log("jumps: \(jumps.isEmpty ? "none" : jumps.prefix(12).joined(separator: "; "))")
            guard model.fetches > 0 else { throw ScenarioFailure.couldNotRun("never reached the messages the app sends") }
            guard Self.position(of: model.bubbles[0].id, screen) != nil else {
                throw ScenarioFailure.couldNotRun("never reached the start of the chat")
            }
            if !jumps.isEmpty {
                throw ScenarioFailure.assertion("\(jumps.count) jump(s) while scrolling back: \(jumps.prefix(6).joined(separator: "; "))")
            }
        }
    }

    /// The first message whose text is in view, and its top on screen.
    private static func messageInView(_ screen: Screen) -> (id: String, y: Double)? {
        let frame = screen.window.map { $0.convertToScreen($0.contentLayoutRect) } ?? .zero
        return screen.elements()
            .compactMap { element -> (id: String, y: Double)? in
                guard let id = element.texts.lazy.compactMap(ChatHistoryModel.id(in:)).first,
                      element.frame.minY > frame.minY + 60, element.frame.maxY < frame.maxY - 60 else { return nil }
                return (id, Double(element.frame.maxY))
            }
            .max { $0.y < $1.y }
    }

    private static func position(of id: String, _ screen: Screen) -> Double? {
        screen.elements().first { $0.texts.contains { ChatHistoryModel.id(in: $0) == id } }.map { Double($0.frame.maxY) }
    }

    private static func scrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        for view in root.subviews { if let found = scrollView(in: view) { return found } }
        return nil
    }

    /// SwiftUI builds its accessibility elements only once something asks for them as an assistive app does.
    private static func allowAutomation(_ host: NSView) {
        let selector = NSSelectorFromString("set_accessibilityAllowsAutomationElements:")
        guard host.responds(to: selector), let method = class_getInstanceMethod(type(of: host), selector) else { return }
        typealias Setter = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(host, selector, true)
    }
}

/// A chat with `count` messages on this Mac and `older` more its app sends when asked, 30 at a time.
@MainActor
final class ChatHistoryModel: ObservableObject {
    @Published var bubbles: [ChatBubble]
    private var waiting: [ChatBubble]
    private(set) var fetches = 0

    init(count: Int, older: Int) {
        let all = (0..<(older + count)).map(Self.bubble)
        waiting = Array(all.prefix(older))
        bubbles = Array(all.suffix(count))
    }

    /// Messages of one to six lines, from both sides, a day line now and then.
    private static func bubble(_ index: Int) -> ChatBubble {
        let filler = String(repeating: "and a few more words to wrap the line ", count: (index * 7) % 6)
        return ChatBubble(id: "m\(index)", text: String(format: "Message %04d %@", index, filler), time: "12:00",
                          date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 2_400),
                          fromMe: index % 3 == 0)
    }

    static func id(in text: String) -> String? {
        guard let range = text.range(of: #"Message \d{4}"#, options: .regularExpression) else { return nil }
        return "m" + String(Int(text[range].dropFirst(8)) ?? -1)
    }

    func loadOlder() async -> Bool {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !waiting.isEmpty else { return false }
        fetches += 1
        let page = waiting.suffix(30)
        waiting.removeLast(page.count)
        bubbles.insert(contentsOf: page, at: 0)
        return true
    }
}

private struct ChatHistoryHost: View {
    @ObservedObject var model: ChatHistoryModel

    var body: some View {
        ChatTranscript(bubbles: model.bubbles, contact: "Sam", fills: true, onLoadOlder: { await model.loadOlder() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
