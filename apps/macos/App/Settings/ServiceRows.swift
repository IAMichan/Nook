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

/// How a service gets connected: the one word on every card of the catalogue, so a glance says what a click does.
enum ConnectMethod: String {
    /// One click opens the service's own sign-in page.
    case signIn
    /// A key or token, with the steps to get one.
    case key
    /// An MCP server that runs on this Mac or on the web.
    case mcp

    var label: String { tr("connect.method.badge.\(rawValue)") }
}

/// The small capsule on a catalogue card: filled for sign-in (the easiest way), tinted for the others. `text`
/// replaces the method's word (Retry, Cancel); `busy` shows a spinner instead.
struct ConnectMethodBadge: View {
    let method: ConnectMethod
    var text: String? = nil
    var busy = false

    var body: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Text(text ?? method.label)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(method == .signIn ? NookTheme.onIris : NookTheme.iris)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.xs)
                .background(Capsule().fill(method == .signIn ? NookTheme.iris : NookTheme.iris.opacity(0.14)))
                .lineLimit(1)
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
        case .notLinked, .off: return NookTheme.textSecondary
        }
    }
}

extension ConnectionHealth {
    /// The same state in the words every row of Settings › Accounts & connections uses.
    var status: ServiceStatus {
        switch self {
        case .working: return .connected
        case .busy: return .connecting
        case .off: return .off
        case .needsYou: return .expired
        case .broken: return .unreachable
        case .notLinked: return .notLinked
        }
    }
}

/// A dot (or a small spinner while connecting) and the state in words. `text` replaces the state's own word where a
/// row says more (an agent that is not installed, a sign-in in progress).
struct ServiceStatusLabel: View {
    let status: ServiceStatus
    var text: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if status == .connecting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 6, height: 6)
            }
            Text(text ?? status.label)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(status == .notLinked || status == .off ? NookTheme.textSecondary : status.color)
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
        ServiceRowShape(title: title, detail: detail, status: status, detailIsError: detailIsError) {
            ServiceTile(domain: domain, fallback: symbol, tint: tint, size: 28, source: source)
        } actions: {
            actions()
        }
    }
}

/// The shape behind `ServiceRowLayout`, for a row whose icon is not a service's site icon (a coding agent's logo): the
/// icon, the name with its state, one line, and the actions. Every linked thing in Settings is drawn with it, so a
/// service, a chat account and a coding agent read the same.
struct ServiceRowShape<Icon: View, Actions: View>: View {
    let title: String
    let detail: String
    let status: ServiceStatus
    /// Replaces the state's own word (see `ServiceStatusLabel`).
    var statusText: String? = nil
    var detailIsError = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var actions: () -> Actions

    /// Drawn as the closed `ConnectionRow`: the icon, the name, one line that starts with the state ("Connected · …"), a
    /// dot only when something is wrong, and the actions on the right. A row that only shows a linked thing (an account
    /// in a sheet) uses this; a row in a list you manage uses `ConnectionRow` itself.
    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            icon()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.strong).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                    if status.needsAttention || detailIsError {
                        Circle().fill(detailIsError ? NookTheme.coral : status.color).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    if status == .connecting {
                        ProgressView().controlSize(.mini)
                    }
                    Text([statusText ?? status.label, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(detailIsError ? NookTheme.coral : (status.needsAttention ? status.color : NookTheme.textSecondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            HStack(spacing: NookTheme.Spacing.sm) { actions() }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

/// A coding agent's logo on the same quiet tile as a service's icon, so agent rows line up with every other linked row.
struct AgentTile: View {
    let logo: AgentLogo
    var size: CGFloat = 30

    init(agent: String) { logo = AgentLogo(agent: agent, size: 20) }

    init(_ kind: AgentKind) { logo = AgentLogo(kind, size: 20) }

    var body: some View {
        NookTheme.shape(size * 0.27)
            .fill(NookTheme.smoke)
            .overlay(logo)
            .frame(width: size, height: size)
    }
}

/// One account of a chat app in its sheet, the same row for every app: the app's icon, the account, its state, one line,
/// and what can be done (sign in again, sign out, remove).
struct ChatAccountRow<Actions: View>: View {
    let app: String
    let title: String
    let detail: String
    var status: ServiceStatus = .connected
    var detailIsError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ServiceRowLayout(domain: MessagingApps.app(id: app)?.site, symbol: "person.crop.circle", tint: NookTheme.iris,
                         title: title, detail: detail, status: status, detailIsError: detailIsError, source: app,
                         actions: actions)
    }
}

/// A linked account of a chat app in its sheet, the same for every app (Telegram, Teams, Slack, Messages, Snapchat):
/// its state comes from one rule (`ChatAccountHealth`): reading, switched off in Nook, failing for a passing reason, or
/// signed out. Signed out offers "Sign in again" where the app has a way to (`signInAgain`), and every app that can be
/// signed out of offers it behind a confirmation (`signOut`). `problem` and `signedOut` are this account's own (an app
/// with several accounts, Teams); without them the app's last read decides.
struct ChatLinkedAccountRow<Actions: View>: View {
    let app: String
    let title: String
    /// The line while all is well.
    let detail: String
    var problem: String?
    var signedOut: Bool?
    var signInAgain: (() -> Void)?
    var signOut: (() -> Void)?
    @ViewBuilder var actions: () -> Actions
    @ObservedObject private var capture = ChatCaptureService.shared

    private var health: ChatAccountHealth {
        let own = problem
        return ChatAccountHealth.of(collecting: capture.enabled, shown: capture.sources.isOn(app),
                                    problem: own ?? capture.bridgeProblems[app],
                                    signedOut: own != nil ? signedOut == true : capture.bridgeSignedOut.contains(app))
    }

    private var status: ServiceStatus {
        switch health {
        case .working: return .connected
        case .off: return .off
        case .failing: return .unreachable
        case .signedOut: return .expired
        }
    }

    var body: some View {
        let health = self.health
        ChatAccountRow(app: app, title: title, detail: health.detail(working: detail, off: tr("chats.account.off")),
                       status: status, detailIsError: health.isProblem) {
            actions()
            if case .signedOut = health, let signInAgain {
                Button(tr("chats.teams.signInAgainButton"), action: signInAgain).controlSize(.small)
            }
            if let signOut {
                ConfirmedButton(tr("chats.teams.signOut"), question: tr("confirm.logout", title), action: signOut)
                    .controlSize(.small)
            }
        }
    }
}

extension ChatLinkedAccountRow where Actions == EmptyView {
    init(app: String, title: String, detail: String, problem: String? = nil, signedOut: Bool? = nil,
         signInAgain: (() -> Void)? = nil, signOut: (() -> Void)? = nil) {
        self.init(app: app, title: title, detail: detail, problem: problem, signedOut: signedOut, signInAgain: signInAgain,
                  signOut: signOut) { EmptyView() }
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

    /// The one connection row: the switch (off keeps the sign-in), Sign in again and Check again in the "…" menu with
    /// Disconnect last, and once opened the same parts as its sheet (signing in, what Nook can do with it).
    var body: some View {
        ConnectionRow(title: service.name, status: status, detail: detail,
                      isOn: Binding(get: { config.enabled && ConnectorToggle.isOn(config.sourceID) },
                                    set: { MCPServerStore.shared.setEnabled(config.id, $0) }),
                      removal: ConnectionRemoval(title: tr("connect.disconnect"), question: tr("connect.disconnectTitle", service.name),
                                                 detail: tr("connect.disconnectDetail", service.name)) {
                          let target = config
                          Task {
                              await MCPSignIn.shared.signOut(target)
                              MCPServerStore.shared.remove(target.id)
                          }
                      }) {
            ServiceTile(domain: service.domain, fallback: "link", tint: NookTheme.iris, size: 28)
        } menu: {
            if status == .connecting, signIn.isConnecting(config.id) {
                Button(tr("button.cancel")) { signIn.cancel() }
            }
            Button(tr("connect.reauthorize")) { signIn.signIn(config, app: app) }
            Button(tr("connector.retry")) { app.connectors.refresh(connector) }
        } expanded: {
            ServiceSignInSheet(service: service, capabilities: SourceCapabilities.line(service.id,
                tools: app.knownTools.map { (name: $0.name, isAction: $0.kind == .action) }))
        }
    }
}
