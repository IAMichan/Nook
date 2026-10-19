import Foundation

/// The search engine of the workspace browser: what you type there that is not an address
/// becomes a search with it. Foundation only, so tests can use it.
enum BrowserSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo = "duckduckgo"
    case google
    case bing
    case brave
    case kagi
    case startpage
    case ecosia

    static let defaultsKey = "ws.browserSearch"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
        case .ecosia: return "Ecosia"
        }
    }

    private var base: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .kagi: return "https://kagi.com/search"
        case .startpage: return "https://www.startpage.com/do/search"
        case .ecosia: return "https://www.ecosia.org/search"
        }
    }

    func url(for query: String) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    static func current(defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        defaults.string(forKey: defaultsKey).flatMap(BrowserSearchEngine.init(rawValue:)) ?? .duckDuckGo
    }

    /// What you typed in the address bar: an address (with or without https://), or otherwise a search. Only web pages.
    static func address(_ input: String, engine: BrowserSearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let url: URL?
        let lowered = text.lowercased()
        if (lowered.hasPrefix("http://") || lowered.hasPrefix("https://")), !text.contains(" "), let parsed = URL(string: text),
           parsed.host?.isEmpty == false {
            // An explicit address, such as http://localhost:3000 from a dev server chip: open it as is.
            url = parsed
        } else if text.contains("."), !text.contains(" "), let parsed = URL(string: lowered.hasPrefix("http") ? text : "https://" + text) {
            url = parsed
        } else if lowered.hasPrefix("localhost"), !text.contains(" ") {
            url = URL(string: "http://" + text)
        } else {
            url = engine.url(for: text)
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
