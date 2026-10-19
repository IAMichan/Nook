import SwiftUI
import AppKit

/// The groups on Settings › Connected services, in the order people look for them.
enum ServiceCategory: String, CaseIterable, Identifiable {
    case development, work, business, automation, mac

    var id: String { rawValue }
    var title: String { tr("connect.category.\(rawValue)") }

    /// Where a built-in source belongs. Anything unknown is automation (custom APIs, webhooks, MCP).
    static func of(sourceID id: String) -> ServiceCategory {
        switch id {
        case "github", "vercel", "sentry": return .development
        case "notion", "linear", "calcom", "icalfeeds": return .work
        case "stripe", "portfolio": return .business
        case "calendar", "reminders", "notes", "mail", "browser", "files", "clipboard", "messages", "whatsapp", "bear", "things": return .mac
        default: return .automation
        }
    }

    static func of(_ service: MCPRemoteService) -> ServiceCategory {
        switch service.category {
        case .development: return .development
        case .work: return .work
        case .business: return .business
        case .automation: return .automation
        }
    }
}

/// One of a few plain states a connection is in, the same words everywhere.
enum ServiceStatus: Equatable {
    case notLinked, connecting, connected, expired, unreachable, off

    var label: String { tr("connect.state.\(self)") }

    var color: Color {
        switch self {
        case .connected: return NookTheme.mint
        case .expired: return NookTheme.amber
        case .unreachable: return NookTheme.coral
        case .connecting: return NookTheme.iris
        case .notLinked, .off: return .secondary
        }
    }
}

/// A dot (or a small spinner while connecting) and the state in words.
struct ServiceStatusLabel: View {
    let status: ServiceStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .connecting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 6, height: 6)
            }
            Text(status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(status == .notLinked || status == .off ? Color.secondary : status.color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one row shape for every service: icon, name with its state, one line about it, and the actions on the right.
struct ServiceRowLayout<Actions: View>: View {
    let domain: String?
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let status: ServiceStatus
    var detailIsError = false
    /// The source id, so a source backed by a Mac app shows that app's own icon.
    var source: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            ServiceTile(domain: domain, fallback: symbol, tint: tint, size: 30, source: source)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                    ServiceStatusLabel(status: status)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailIsError ? NookTheme.coral : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.vertical, 3)
    }
}

/// A service connected through its official MCP server and OAuth: Connect opens the service's own sign-in page and
/// brings you back here, with the state shown at once.
struct MCPServiceRow: View {
    let service: MCPRemoteService
    /// The same service with a key instead (Notion, Stripe, Vercel): offered as the alternative while not connected.
    var keyAlternative: ContextSource?
    var capabilities: String = ""
    var onChange: () -> Void = {}

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var signIn = MCPSignIn.shared
    @ObservedObject private var store = MCPServerStore.shared
    @State private var showKeySetup = false
    @State private var confirmDisconnect = false

    private var config: MCPServerConfig? { store.servers.first { $0.serviceID == service.id } }

    var body: some View {
        Group {
            if let config, let connector = app.connectors.source(id: config.sourceID) as? MCPConnector {
                LinkedMCPServiceRow(service: service, config: config, connector: connector, confirmDisconnect: $confirmDisconnect)
            } else {
                notLinked
            }
        }
        .sheet(isPresented: $showKeySetup, onDismiss: onChange) {
            if let keyAlternative {
                CloudConnectorViews.setupSheet(keyAlternative, capabilities: capabilities, onChange: onChange)
            }
        }
    }

    private var notLinked: some View {
        let connecting = config.map { signIn.isConnecting($0.id) } ?? false
        let failure = signIn.failure(for: service.id) ?? config.flatMap { signIn.failure(for: $0.id) }
        return ServiceRowLayout(
            domain: service.domain, symbol: "link", tint: NookTheme.iris, title: service.name,
            detail: failure ?? (connecting ? tr("connect.waiting", service.name) : service.tagline + " · " + tr("connect.method.oauth", service.name)),
            status: connecting ? .connecting : .notLinked,
            detailIsError: failure != nil
        ) {
            if connecting {
                Button(tr("button.cancel")) { signIn.cancel() }.controlSize(.small)
            } else {
                if keyAlternative != nil {
                    Button(tr("connect.useKey")) { showKeySetup = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help(tr("connect.useKeyHelp"))
                }
                Button(failure == nil ? tr("connect.connect") : tr("connector.retry")) { signIn.connect(service, app: app) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// A service you connect by signing in on its own page: one click opens its sign-in, you log in there, and Nook takes
/// it from there. A service that also takes a key offers that on right-click.
struct OneClickServiceCard: View {
    let service: MCPRemoteService
    var keyAlternative: ContextSource?
    var capabilities: String = ""
    var onChange: () -> Void = {}

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var signIn = MCPSignIn.shared
    @ObservedObject private var store = MCPServerStore.shared
    @State private var showKeySetup = false

    private var config: MCPServerConfig? { store.servers.first { $0.serviceID == service.id } }

    var body: some View {
        let connecting = config.map { signIn.isConnecting($0.id) } ?? false
        let failure = signIn.failure(for: service.id) ?? config.flatMap { signIn.failure(for: $0.id) }
        GalleryCard(title: service.name,
                    detail: failure ?? (connecting ? tr("connect.waiting", service.name) : service.tagline)) {
            ServiceTile(domain: service.domain, fallback: "link", tint: NookTheme.iris, size: 32)
        } accessory: {
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                Text(failure == nil ? tr("settings.connections.signIn") : tr("connector.retry"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NookTheme.onIris)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(NookTheme.iris))
            }
        } action: {
            if connecting { signIn.cancel() } else { signIn.connect(service, app: app) }
        }
        .help(connecting ? tr("button.cancel") : tr("settings.connections.signInHelp", service.name))
        .contextMenu {
            if keyAlternative != nil {
                Button(tr("connect.useKey")) { showKeySetup = true }
            }
        }
        .sheet(isPresented: $showKeySetup, onDismiss: onChange) {
            if let keyAlternative {
                CloudConnectorViews.setupSheet(keyAlternative, capabilities: capabilities, onChange: onChange)
            }
        }
    }
}

/// A connected (or expired) MCP service: observes its connector so the state changes without reopening Settings.
private struct LinkedMCPServiceRow: View {
    let service: MCPRemoteService
    let config: MCPServerConfig
    @ObservedObject var connector: MCPConnector
    @Binding var confirmDisconnect: Bool

    @EnvironmentObject private var app: AppModel
    @ObservedObject private var signIn = MCPSignIn.shared

    private var status: ServiceStatus {
        if signIn.isConnecting(config.id) { return .connecting }
        if !ConnectorToggle.isOn(config.sourceID) || !config.enabled { return .off }
        switch connector.status.state {
        case .ok: return .connected
        case .loading, .off: return .connecting
        case .error: return (connector.status.errorKind ?? .other).needsReconnect ? .expired : .unreachable
        }
    }

    private var detail: String {
        if let failure = signIn.failure(for: config.id) { return failure }
        switch status {
        case .connecting: return signIn.isConnecting(config.id) ? tr("connect.waiting", service.name) : tr("settings2.service.busyDetail")
        case .expired: return tr("connect.expiredDetail", service.name)
        case .unreachable:
            if case .error(let message) = connector.status.state { return message }
            return tr("connect.state.unreachable")
        case .off: return tr("settings2.service.offDetail")
        default:
            if signIn.phase == .done(config.id) { return tr("connect.justConnected", service.name) }
            let headline = connector.status.headline.isEmpty ? service.tagline : connector.status.headline
            return headline + (connector.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? "")
        }
    }

    var body: some View {
        ServiceRowLayout(domain: service.domain, symbol: "link", tint: NookTheme.iris, title: service.name, detail: detail,
                         status: status, detailIsError: signIn.failure(for: config.id) != nil) {
            switch status {
            case .connecting where signIn.isConnecting(config.id):
                Button(tr("button.cancel")) { signIn.cancel() }.controlSize(.small)
            case .expired:
                Button(tr("connect.reauthorize")) { signIn.signIn(config, app: app) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .unreachable:
                Button(tr("connector.retry")) { app.connectors.refresh(connector) }.controlSize(.small)
            default:
                EmptyView()
            }
            Menu {
                Button(tr("connect.reauthorize")) { signIn.signIn(config, app: app) }
                Button(tr("connector.retry")) { app.connectors.refresh(connector) }
                Divider()
                Button(tr("connect.disconnect"), role: .destructive) { confirmDisconnect = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("connect.manage", service.name))
        }
        .confirmationDialog(tr("connect.disconnectTitle", service.name), isPresented: $confirmDisconnect) {
            Button(tr("connect.disconnect"), role: .destructive) {
                let target = config
                Task {
                    await MCPSignIn.shared.signOut(target)
                    MCPServerStore.shared.remove(target.id)
                }
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("connect.disconnectDetail", service.name))
        }
    }
}
