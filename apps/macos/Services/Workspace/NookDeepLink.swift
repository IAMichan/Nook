import Foundation

/// `nook://` links to things inside Nook: a conversation, a settings page, the memory page, the shortcut sheet.
/// (A session or a prompt keeps its own links, `SessionLink` and `PromptLink`.) A link only ever names something; it never
/// carries a command, and the app decides what opening it does.
enum NookDeepLink: Equatable, Sendable {
    case conversation(UUID)
    case settings(String)
    case memory
    case shortcuts

    static let scheme = "nook"
    static func parse(_ url: URL) -> NookDeepLink? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let segments = parts.path.split(separator: "/").map(String.init)
        switch host {
        case "conversation", "chat":
            guard segments.count == 1, let id = UUID(uuidString: segments[0]) else { return nil }
            return .conversation(id)
        case "settings":
            let page = segments.first?.lowercased() ?? ""
            guard segments.count <= 1, page.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return .settings(page)
        case "memory": return .memory
        case "shortcuts": return .shortcuts
        default: return nil
        }
    }

    var url: URL? {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .conversation(let id): parts.host = "conversation"; parts.path = "/" + id.uuidString.lowercased()
        case .settings(let page): parts.host = "settings"; parts.path = page.isEmpty ? "" : "/" + page
        case .memory: parts.host = "memory"
        case .shortcuts: parts.host = "shortcuts"
        }
        return parts.url
    }
}
