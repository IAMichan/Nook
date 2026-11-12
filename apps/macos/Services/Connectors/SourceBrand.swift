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
        // The chat apps of the Chats tab (Telegram, Signal…).
        default: return MessagingApps.app(id: id)?.bundleIDs ?? []
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
        default: return MessagingApps.app(id: id)?.site
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

    /// Connectors an agent reports by name only (claude.ai connectors, plugin servers), whose name does not lead to their
    /// website by itself: the name, lowercased with dashes and underscores as spaces, to the website whose icon stands for it.
    private static let connectorNames: [String: String] = [
        "google calendar": "calendar.google.com", "gmail": "mail.google.com", "google drive": "drive.google.com",
        "google docs": "docs.google.com", "google sheets": "sheets.google.com", "google maps": "maps.google.com",
        "microsoft 365": "microsoft.com", "outlook": "outlook.com", "microsoft teams": "teams.microsoft.com",
        "onedrive": "onedrive.live.com", "sharepoint": "microsoft.com", "box": "box.com", "close": "close.com",
        "clay": "clay.com", "monday": "monday.com", "monday.com": "monday.com", "otter ai": "otter.ai", "otter": "otter.ai",
        "apollo": "apollo.io", "gong": "gong.io", "granola": "granola.ai", "intercom": "intercom.com",
        "datadog": "datadoghq.com", "pagerduty": "pagerduty.com", "ahrefs": "ahrefs.com", "amplitude": "amplitude.com",
        "amplitude eu": "amplitude.com", "canva": "canva.com", "klaviyo": "klaviyo.com", "similarweb": "similarweb.com",
        "supermetrics": "supermetrics.com", "calendly": "calendly.com", "crunchbase": "crunchbase.com",
        "fireflies": "fireflies.ai", "lusha": "lusha.com", "zoominfo": "zoominfo.com", "salesforce": "salesforce.com",
        "zendesk": "zendesk.com", "webflow": "webflow.com", "wix": "wix.com", "paypal": "paypal.com",
        "square": "squareup.com", "plaid": "plaid.com", "netlify": "netlify.com", "neon": "neon.tech",
        "prisma": "prisma.io", "mixpanel": "mixpanel.com", "posthog": "posthog.com", "miro": "miro.com",
        "clickup": "clickup.com", "egnyte": "egnyte.com", "harvey": "harvey.ai", "pitchbook": "pitchbook.com",
        "hex": "hex.tech", "snowflake": "snowflake.com", "databricks": "databricks.com", "bigquery": "cloud.google.com",
        "dropbox": "dropbox.com", "evernote": "evernote.com", "loom": "loom.com", "zoom": "zoom.us",
        "cloudinary": "cloudinary.com", "contentful": "contentful.com", "sanity": "sanity.io", "railway": "railway.app",
        "render": "render.com", "fly": "fly.io", "heroku": "heroku.com", "pinecone": "pinecone.io",
        "claude in chrome": "claude.ai"
    ]

    /// The website for a connector an agent reports by name only ("claude.ai Google Calendar", "plugin:design:linear",
    /// as `ConnectorSignIns.title` leaves it): a name Nook knows, a service it signs in to itself, or a known word in it.
    static func connectorDomain(name: String) -> String? {
        let key = name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let known = connectorNames[key] { return known }
        if let service = MCPRemoteService.all.first(where: { $0.id == key || $0.name.lowercased() == key }) { return service.domain }
        let dashed = key.replacingOccurrences(of: " ", with: "-")
        return mcpServices.first { dashed.contains($0.0) }?.1
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

    @MainActor private static var sizedIcons: [String: (source: NSImage, image: NSImage)] = [:]

    /// The app's icon drawn once into a bitmap of `side` points on this screen. The workspace icon holds every size up to
    /// 1024 pixels and is rendered again each time a view draws it: a list with an app icon on every row (Chats, all
    /// apps) paid for that on every row that scrolled into view.
    @MainActor
    static func appIcon(for id: String, side: CGFloat) -> NSImage? {
        guard let icon = appIcon(for: id) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((side * scale).rounded(.up))
        let key = "\(id)|\(pixels)"
        if let cached = sizedIcons[key], cached.source === icon { return cached.image }
        guard pixels > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return icon }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        context?.imageInterpolation = .high
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        sizedIcons[key] = (icon, image)
        return image
    }

    /// The icon as a small fixed-size image for menu items, or nil while there is none (yet). Made once per icon: a menu
    /// asks again on every redraw of the view that holds it, and a new image each time makes it update every item.
    @MainActor
    static func menuImage(for id: String, domain: String? = nil, size: CGFloat = 16) -> NSImage? {
        let source = appIcon(for: id) ?? (domain ?? self.domain(for: id)).flatMap { FaviconStore.shared.image(for: $0) }
        guard let source else { return nil }
        let key = "\(id)|\(domain ?? "")|\(size)"
        if let cached = menuImages[key], cached.source === source { return cached.image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        menuImages[key] = (source, image)
        return image
    }

    @MainActor private static var menuImages: [String: (source: NSImage, image: NSImage)] = [:]
}
