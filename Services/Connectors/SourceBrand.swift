import AppKit

/// Where the real icon of a source comes from: the Mac app it reads (Calendar, Mail, WhatsApp…), or else the website
/// of the service (GitHub, Stripe…). Views fall back to the source's SF Symbol only when neither is there.
enum SourceBrand {
    /// The apps a source reads from, first match wins.
    static func bundleIDs(for id: String) -> [String] {
        switch id {
        case "calendar", "icalfeeds": return ["com.apple.iCal"]
        case "reminders": return ["com.apple.reminders"]
        case "notes": return ["com.apple.Notes"]
        case "mail": return ["com.apple.mail"]
        case "messages": return ["com.apple.MobileSMS"]
        case "whatsapp": return ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]
        case "bear": return ["net.shinyfrog.bear"]
        case "things": return ["com.culturedcode.ThingsMac"]
        case "files": return ["com.apple.finder"]
        case "terminal": return ["com.apple.Terminal"]
        case "contacts": return ["com.apple.AddressBook"]
        default: return []
        }
    }

    /// The website whose icon stands for a cloud service.
    static func domain(for id: String) -> String? {
        switch id {
        case "github": return "github.com"
        case "vercel": return "vercel.com"
        case "stripe": return "stripe.com"
        case "notion": return "notion.so"
        case "calcom": return "cal.com"
        case "n8n": return "n8n.io"
        case "resend": return "resend.com"
        case "whatsapp": return "whatsapp.com"
        case "bear": return "bear.app"
        case "things": return "culturedcode.com"
        default: return nil
        }
    }

    @MainActor private static var appIcons: [String: NSImage?] = [:]

    /// The icon of the app behind a source, if that app is on this Mac. The browser source shows your default browser.
    @MainActor
    static func appIcon(for id: String) -> NSImage? {
        if let cached = appIcons[id] { return cached }
        let workspace = NSWorkspace.shared
        var url = bundleIDs(for: id).lazy.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        if id == "browser", let web = URL(string: "https://example.com") {
            url = workspace.urlForApplication(toOpen: web)
        }
        let icon = url.map { workspace.icon(forFile: $0.path) }
        appIcons[id] = icon
        return icon
    }

    /// The icon as a small fixed-size image for menu items, or nil while there is none (yet).
    @MainActor
    static func menuImage(for id: String, domain: String? = nil, size: CGFloat = 16) -> NSImage? {
        let source = appIcon(for: id) ?? (domain ?? self.domain(for: id)).flatMap { FaviconStore.shared.image(for: $0) }
        guard let source else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
