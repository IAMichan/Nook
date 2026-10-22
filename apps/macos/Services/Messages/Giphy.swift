import Foundation

// GIFs to send from a chat without a file of your own, as WhatsApp offers them: GIPHY's trending ones when the panel opens,
// and a search. GIPHY needs an API key of your own (developers.giphy.com), kept in the Keychain; only the search words and
// that key go to api.giphy.com. Foundation only and without the network, so every request and answer can be tested
// anywhere; `ChatComposerModel` fetches them.

/// One GIF from GIPHY: a small moving preview for the grid, and the file that goes when you pick it.
struct GiphyGIF: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    /// A small animated GIF, about 100 points wide.
    var preview: URL
    var previewSize: CGSize?
    /// The file that is sent: an MP4 when GIPHY has one (what WhatsApp sends a GIF as), else the GIF itself.
    var file: URL
}

enum Giphy {
    /// The Keychain account of your GIPHY API key.
    static let keyAccount = "chats.giphy.key"
    static let host = "api.giphy.com"
    /// How many GIFs one page holds.
    static let pageSize = 30

    /// Trending GIFs when `query` is empty, else a search; `language` is a two-letter code for the search.
    static func request(query: String, key: String, language: String = "en", offset: Int = 0) -> URL? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = words.isEmpty ? "/v1/gifs/trending" : "/v1/gifs/search"
        var items = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "limit", value: String(pageSize)),
                     URLQueryItem(name: "offset", value: String(max(0, offset))), URLQueryItem(name: "rating", value: "pg-13")]
        if !words.isEmpty {
            items.append(URLQueryItem(name: "q", value: String(words.prefix(50))))
            items.append(URLQueryItem(name: "lang", value: language))
        }
        parts.queryItems = items
        return parts.url
    }

    /// The GIFs in an answer, in GIPHY's order; one without a usable preview or file is left out.
    static func gifs(_ data: Data) -> [GiphyGIF] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty, let images = item["images"] as? [String: Any] else { return nil }
            func rendition(_ name: String) -> [String: Any]? { images[name] as? [String: Any] }
            guard let small = rendition("fixed_width_small") ?? rendition("fixed_width"),
                  let preview = media(small["url"]) else { return nil }
            let mp4 = ["original", "fixed_height", "downsized_small"].lazy.compactMap { media(rendition($0)?["mp4"]) }.first
            guard let file = mp4 ?? media(rendition("original")?["url"]) else { return nil }
            var size: CGSize?
            if let width = number(small["width"]), let height = number(small["height"]), width > 0, height > 0 {
                size = CGSize(width: width, height: height)
            }
            return GiphyGIF(id: id, title: (item["title"] as? String) ?? "", preview: preview, previewSize: size, file: file)
        }
    }

    /// Why GIPHY refused (a wrong key, too many requests), in its own words.
    static func problem(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let meta = object["meta"] as? [String: Any]
        let text = (meta?["msg"] as? String) ?? (object["message"] as? String)
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// A file's address, only when it is GIPHY's own over HTTPS: an answer can never send Nook to fetch from elsewhere.
    static func media(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), host == "giphy.com" || host.hasSuffix(".giphy.com") else { return nil }
        return url
    }

    /// The name a GIF's file is kept under: its id, with the file's own extension.
    static func fileName(_ gif: GiphyGIF, preview: Bool = false) -> String {
        let url = preview ? gif.preview : gif.file
        let ext = url.pathExtension.isEmpty ? (preview ? "gif" : "mp4") : url.pathExtension.lowercased()
        return (preview ? "preview" : "GIF") + "." + ext
    }

    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }
}
