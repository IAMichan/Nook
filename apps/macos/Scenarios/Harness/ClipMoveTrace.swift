import AppKit
import Foundation

/// Who moved a conversation's clip view: while `armed` (your hands are off), every move of more than `threshold` points
/// is kept with the call stack that made it, so a scenario that sees the view jump can say which code did it.
@MainActor
final class ClipMoveTrace {
    struct Move {
        let from: Double
        let to: Double
        let content: Double
        let stack: [String]
    }

    var armed = false
    var threshold = 20.0
    private(set) var moves: [Move] = []
    private var last: Double
    private var observer: NSObjectProtocol?
    private let scrollView: NSScrollView

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        last = Double(scrollView.contentView.bounds.origin.y)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func moved() {
        let now = Double(scrollView.contentView.bounds.origin.y)
        defer { last = now }
        guard armed, abs(now - last) > threshold, moves.count < 40 else { return }
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(40).map { line in
            // "12 Module 0x… symbol + 123": keep the symbol, demangled.
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4 else { return line }
            let symbol = String(parts[3]).components(separatedBy: " + ").first ?? String(parts[3])
            return "\(parts[1]) " + Self.demangle(symbol)
        }
        moves.append(Move(from: last, to: now, content: Double(scrollView.documentView?.frame.height ?? 0), stack: Array(stack)))
    }

    /// The moves kept, for the scenario's notes: each with the frames of Nook's own code in its stack.
    func report() -> [String] {
        moves.map { move in
            let own = move.stack.filter { $0.contains("NookScenarios") && !$0.contains("ClipMoveTrace") }.prefix(8)
            let swiftUI = move.stack.first { $0.hasPrefix("SwiftUI") || $0.hasPrefix("AppKit") } ?? ""
            return String(format: "clip %.0f → %.0f (content %.0f) by: ", move.from, move.to, move.content)
                + (own.isEmpty ? "[no Nook frame] " + swiftUI : own.joined(separator: " ← "))
        }
    }

    @_silgen_name("swift_demangle")
    private static func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                                      _ outputLength: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    private static func demangle(_ symbol: String) -> String {
        guard let result = symbol.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else { return symbol }
        defer { free(result) }
        let text = String(cString: result)
        return text.count > 160 ? String(text.prefix(160)) : text
    }
}
