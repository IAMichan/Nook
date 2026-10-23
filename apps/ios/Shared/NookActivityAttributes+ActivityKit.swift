import ActivityKit
import SwiftUI

// What the app and its widget extension share about a Live Activity: ActivityKit's view of the shared types
// (packages/protocol/Sources/CompanionLiveActivity.swift) and how a phase looks.

extension NookActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityContent
}

extension LiveActivityPhase {
    /// Colors keep their meaning: iris = working, amber = waiting on you, mint = done, coral = failed.
    var color: Color {
        switch self {
        case .working: return Theme.blue
        case .waiting: return Theme.amber
        case .done: return Theme.mint
        case .failed: return Theme.coral
        }
    }

    var word: String {
        switch self {
        case .working: return String(localized: "Working")
        case .waiting: return String(localized: "Waiting for you")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        }
    }

    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// Where a tap on an activity goes: the session in the app (`nook://session?id=…`).
enum ActivityLink {
    static let host = "session"

    static func url(session: String) -> URL? {
        var c = URLComponents()
        c.scheme = "nook"
        c.host = host
        c.queryItems = [URLQueryItem(name: "id", value: session)]
        return c.url
    }

    static func session(from url: URL) -> String? {
        guard url.scheme == "nook", url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
