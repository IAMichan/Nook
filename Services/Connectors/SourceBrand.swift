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

    /// Well-known MCP servers by a word in their name or command (specific enough not to match by accident), with the website whose icon stands for them.
    private static let mcpServices: [(String, String)] = [
        ("github", "github.com"), ("gitlab", "gitlab.com"), ("slack", "slack.com"), ("notion", "notion.so"),
        ("linear", "linear.app"), ("atlassian", "atlassian.com"), ("jira", "atlassian.com"), ("confluence", "atlassian.com"),
        ("brave", "brave.com"), ("postgres", "postgresql.org"), ("sqlite", "sqlite.org"), ("mysql", "mysql.com"),
        ("mongo", "mongodb.com"), ("redis", "redis.io"), ("supabase", "supabase.com"), ("puppeteer", "pptr.dev"),
        ("playwright", "playwright.dev"), ("stripe", "stripe.com"), ("sentry", "sentry.io"), ("figma", "figma.com"),
        ("vercel", "vercel.com"), ("cloudflare", "cloudflare.com"), ("todoist", "todoist.com"), ("discord", "discord.com"),
        ("telegram", "telegram.org"), ("airtable", "airtable.com"), ("hubspot", "hubspot.com"), ("shopify", "shopify.com"),
        ("obsidian", "obsidian.md"), ("spotify", "spotify.com"), ("gdrive", "drive.google.com"), ("google-drive", "drive.google.com"),
        ("gmail", "mail.google.com"), ("google-maps", "maps.google.com"), ("asana", "asana.com"), ("trello", "trello.com"),
        ("zapier", "zapier.com"), ("docker", "docker.com"), ("kubernetes", "kubernetes.io"), ("aws", "aws.amazon.com"),
        ("azure", "azure.microsoft.com"), ("dropbox", "dropbox.com"), ("box-mcp", "box.com"), ("hugging", "huggingface.co"),
        ("exa-mcp", "exa.ai"), ("tavily", "tavily.com"), ("perplexity", "perplexity.ai"), ("firecrawl", "firecrawl.dev"),
        ("context7", "context7.com"), ("n8n", "n8n.io"), ("resend", "resend.com"), ("calcom", "cal.com"),
        ("memory", "modelcontextprotocol.io"), ("sequential-thinking", "modelcontextprotocol.io"),
        ("everything", "modelcontextprotocol.io"), ("fetch", "modelcontextprotocol.io")
    ]

    /// The website for an MCP server: its own host for a remote server (mcp.notion.com → notion.com), otherwise a
    /// known service named in its command or name ("npx -y @modelcontextprotocol/server-github" → github.com).
    static func mcpDomain(name: String, transport: MCPServerConfig.Transport) -> String? {
        var text = name.lowercased()
        switch transport {
        case .http(let address):
            if let url = URL(string: address), url.host != nil { return KnownService.iconDomain(for: url) }
        case .stdio(let command, let arguments):
            text += " " + ([command] + arguments).joined(separator: " ").lowercased()
        }
        return mcpServices.first { text.contains($0.0) }?.1
    }

    /// A local MCP server that works with the Mac's own files or apps shows that app ("server-filesystem" → Finder).
    static func mcpAppSource(name: String, transport: MCPServerConfig.Transport) -> String? {
        guard case .stdio(let command, let arguments) = transport else { return nil }
        let text = (name + " " + ([command] + arguments).joined(separator: " ")).lowercased()
        let apps: [(String, String)] = [("filesystem", "files"), ("apple-notes", "notes"), ("apple-mail", "mail"),
                                        ("imessage", "messages"), ("apple-calendar", "calendar"), ("reminders", "reminders"),
                                        ("whatsapp", "whatsapp"), ("things", "things"), ("bear-", "bear"), ("contacts", "contacts")]
        return apps.first { text.contains($0.0) }?.1
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
