import Foundation

// Which website stands for a connector, by name only. Foundation-only so the core tests (Linux) can use it; the icons
// themselves are drawn by `SourceBrand`.

/// Services whose official MCP server lets an app sign in without a client id or secret of its own.
struct MCPRemoteService: Identifiable, Equatable {
    enum Category: String, CaseIterable {
        case development, work, business, automation
    }

    let id: String
    let name: String
    let url: String
    let domain: String
    let category: Category

    static let all: [MCPRemoteService] = [
        MCPRemoteService(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", domain: "notion.so", category: .work),
        MCPRemoteService(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", domain: "linear.app", category: .work),
        MCPRemoteService(id: "stripe", name: "Stripe", url: "https://mcp.stripe.com", domain: "stripe.com", category: .business),
        MCPRemoteService(id: "vercel", name: "Vercel", url: "https://mcp.vercel.com", domain: "vercel.com", category: .development),
        MCPRemoteService(id: "sentry", name: "Sentry", url: "https://mcp.sentry.dev/mcp", domain: "sentry.io", category: .development),
        MCPRemoteService(id: "atlassian", name: "Jira & Confluence", url: "https://mcp.atlassian.com/v1/mcp", domain: "atlassian.com", category: .work),
        MCPRemoteService(id: "canva", name: "Canva", url: "https://mcp.canva.com/mcp", domain: "canva.com", category: .work),
        MCPRemoteService(id: "supabase", name: "Supabase", url: "https://mcp.supabase.com/mcp", domain: "supabase.com", category: .development),
        MCPRemoteService(id: "neon", name: "Neon", url: "https://mcp.neon.tech/mcp", domain: "neon.tech", category: .development),
        MCPRemoteService(id: "huggingface", name: "Hugging Face", url: "https://huggingface.co/mcp", domain: "huggingface.co", category: .development),
        // Sign in instead of a key: Cal.com and Resend host their own MCP server with OAuth, as does GitLab.com (the
        // token stays the way for a self-hosted GitLab and for merge requests in the notch).
        MCPRemoteService(id: "calcom", name: "Cal.com", url: "https://mcp.cal.com/mcp", domain: "cal.com", category: .work),
        MCPRemoteService(id: "resend", name: "Resend", url: "https://mcp.resend.com/mcp", domain: "resend.com", category: .business),
        MCPRemoteService(id: "gitlab", name: "GitLab", url: "https://gitlab.com/api/v4/mcp", domain: "gitlab.com", category: .development)
    ]
}

enum ConnectorDomains {
    /// Well-known MCP servers by a word in their name or command (specific enough not to match by accident), with the website whose icon stands for them.
    static let mcpServices: [(String, String)] = [
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

}
