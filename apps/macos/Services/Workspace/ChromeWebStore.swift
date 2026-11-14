import Foundation

/// The Chrome Web Store as a place to get extensions for Nook's browser (`BrowserExtensions`): which extension a store
/// page is about, where its package downloads from, and the package's zip inside the CRX wrapper. Foundation only, so
/// tests can use it.
enum ChromeWebStore {
    /// The Chrome version Nook asks the store for: new enough that current extensions are offered.
    static let chromeVersion = "131.0.0.0"

    /// An extension's id: 32 letters from a to p.
    static func isExtensionID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The extension a store page is about, from its address (`chromewebstore.google.com/detail/name/<id>`, the old
    /// `chrome.google.com/webstore/detail/...`), or a bare id you pasted. Nil for anything else.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(text.lowercased()) { return text.lowercased() }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              let host = url.host?.lowercased(), isStoreHost(host, path: url.path) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].map { $0.lowercased() }.first(where: isExtensionID)
    }

    /// Whether a page is an extension's page in the store, where Nook's browser offers to add it.
    static func isStorePage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return extensionID(from: url.absoluteString) != nil
    }

    private static func isStoreHost(_ host: String, path: String) -> Bool {
        host == "chromewebstore.google.com" || (host == "chrome.google.com" && path.hasPrefix("/webstore"))
    }

    /// Where the store sends an extension's package from (it answers with a redirect to the file).
    static func downloadURL(id: String) -> URL? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")
        ]
        return components?.url
    }

    enum PackageError: Error, Equatable {
        case notAPackage
        case unsupportedVersion(UInt32)
        case truncated
    }

    /// The zip inside a CRX package (version 2 or 3): the extension's files, which WebKit loads. A plain zip comes back
    /// as it is.
    static func zip(fromPackage data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data }
        guard bytes.count >= 12, bytes.starts(with: Array("Cr24".utf8)) else { throw PackageError.notAPackage }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let version = uint32(4)
        let start: Int
        switch version {
        case 2:
            guard bytes.count >= 16 else { throw PackageError.truncated }
            start = 16 + Int(uint32(8)) + Int(uint32(12))
        case 3:
            start = 12 + Int(uint32(8))
        default:
            throw PackageError.unsupportedVersion(version)
        }
        guard start + 4 <= bytes.count, bytes[start..<(start + 4)].elementsEqual([0x50, 0x4B, 0x03, 0x04]) else {
            throw PackageError.truncated
        }
        return data.subdata(in: (data.startIndex + start)..<data.endIndex)
    }
}
