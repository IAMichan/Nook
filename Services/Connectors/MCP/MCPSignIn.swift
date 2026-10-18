import AppKit
import AuthenticationServices
import SwiftUI

// One click to connect a service: Nook adds its official MCP server, opens the service's own sign-in page in a system
// sign-in window, and comes back to Settings by itself. See MCPOAuth.swift for the protocol.

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

    var tagline: String { tr("connect.service.\(id)") }

    static let all: [MCPRemoteService] = [
        MCPRemoteService(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", domain: "notion.so", category: .work),
        MCPRemoteService(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", domain: "linear.app", category: .work),
        MCPRemoteService(id: "stripe", name: "Stripe", url: "https://mcp.stripe.com", domain: "stripe.com", category: .business),
        MCPRemoteService(id: "vercel", name: "Vercel", url: "https://mcp.vercel.com", domain: "vercel.com", category: .development),
        MCPRemoteService(id: "sentry", name: "Sentry", url: "https://mcp.sentry.dev/mcp", domain: "sentry.io", category: .development)
    ]
}

/// The OAuth tokens of signed-in MCP servers, one Keychain item per server, never on disk or in a log.
enum MCPOAuthStore {
    static func account(_ serverID: String) -> String { "connector.mcp.\(serverID).oauth" }

    static func load(_ serverID: String) -> MCPOAuth.Credentials? {
        guard let text = Keychain.read(account(serverID)) else { return nil }
        return try? JSONDecoder().decode(MCPOAuth.Credentials.self, from: Data(text.utf8))
    }

    @discardableResult
    static func save(_ credentials: MCPOAuth.Credentials, for serverID: String) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials), let text = String(data: data, encoding: .utf8) else { return false }
        return Keychain.write(text, account: account(serverID)) == errSecSuccess
    }

    static func remove(_ serverID: String) {
        Keychain.remove(account(serverID))
    }
}

/// Hands the transport a valid token. One refresh at a time per server: an actor, so two requests that both find the
/// token expired do not each spend the (single-use) refresh token.
actor MCPOAuthAuthorizer: MCPAuthorizer {
    private let serverID: String
    private var refreshing: Task<MCPOAuth.Credentials, Error>?

    init(serverID: String) {
        self.serverID = serverID
    }

    func bearerToken(forceRefresh: Bool) async throws -> String {
        guard let credentials = MCPOAuthStore.load(serverID) else { throw MCPOAuthError.notSignedIn }
        guard forceRefresh || credentials.tokens.needsRefresh() else { return credentials.tokens.accessToken }
        if let refreshing { return try await refreshing.value.tokens.accessToken }
        let id = serverID
        let task = Task { () throws -> MCPOAuth.Credentials in
            var updated = credentials
            updated.tokens = try await MCPOAuth.refresh(credentials)
            MCPOAuthStore.save(updated, for: id)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.tokens.accessToken
    }
}

extension MCPOAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .insecure: return tr("connect.error.insecure")
        case .noAuthorizationServer: return tr("connect.error.noServer")
        case .noPKCE: return tr("connect.error.noPKCE")
        case .noRegistration: return tr("connect.error.noRegistration")
        case .registrationFailed(let detail): return tr("connect.error.registration", detail)
        case .declined: return tr("connect.error.declined")
        case .cancelled: return tr("connect.error.cancelled")
        case .stateMismatch: return tr("connect.error.state")
        case .callbackFailed(let detail): return tr("connect.error.callback", detail)
        case .tokenFailed(let detail): return tr("connect.error.token", detail)
        case .expired: return tr("connect.error.expired")
        case .notSignedIn: return tr("connect.error.notSignedIn")
        }
    }
}

/// Runs the sign-in for one server at a time and tells Settings how it is going.
@MainActor
final class MCPSignIn: NSObject, ObservableObject {
    static let shared = MCPSignIn()

    enum Phase: Equatable {
        case idle
        /// Waiting for the person to sign in on the service's page.
        case connecting(String)
        case failed(String, String)
        case done(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var session: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?

    func isConnecting(_ serverID: String) -> Bool { phase == .connecting(serverID) }

    func failure(for serverID: String) -> String? {
        if case .failed(let id, let message) = phase, id == serverID { return message }
        return nil
    }

    /// Connects a built-in service: adds its server when needed and signs in. A first attempt that does not finish
    /// leaves nothing behind.
    func connect(_ service: MCPRemoteService, app: AppModel) {
        let store = MCPServerStore.shared
        let existing = store.servers.first { $0.serviceID == service.id }
        let config = existing ?? store.add(name: service.name, transport: .http(url: service.url), secrets: [:],
                                           usesOAuth: true, serviceID: service.id)
        signIn(config, app: app, removeOnFailure: existing == nil)
    }

    /// Signs in to a server (again). Also used for "Reconnect" when the sign-in expired.
    func signIn(_ config: MCPServerConfig, app: AppModel, removeOnFailure: Bool = false) {
        cancel()
        phase = .connecting(config.id)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(config)
                self.phase = .done(config.id)
                ConnectorToggle.set(config.sourceID, true)
                if let source = app.connectors.source(id: config.sourceID) { app.connectors.refresh(source) }
            } catch {
                if removeOnFailure { MCPServerStore.shared.remove(config.id) }
                if (error as? MCPOAuthError) == .cancelled {
                    self.phase = .idle
                } else {
                    // The message names what went wrong; never the token, code or verifier.
                    self.phase = .failed(config.id, error.localizedDescription)
                    Log.connectors.notice("MCP sign-in failed for \(config.id, privacy: .public)")
                }
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        task?.cancel()
        task = nil
        if case .connecting = phase { phase = .idle }
    }

    /// Signs out: asks the service to forget the token, then removes it from the Keychain.
    func signOut(_ config: MCPServerConfig) async {
        if let credentials = MCPOAuthStore.load(config.id) { await MCPOAuth.revoke(credentials) }
        MCPOAuthStore.remove(config.id)
        if phase == .done(config.id) { phase = .idle }
    }

    private func run(_ config: MCPServerConfig) async throws {
        guard case .http(let address) = config.transport, let url = URL(string: address) else { throw MCPOAuthError.insecure }
        guard let discovery = try await MCPOAuth.discover(server: url) else {
            // The server needs no sign-in: nothing to store, it simply works.
            return
        }
        // Keep the registration from an earlier sign-in at the same authorization server.
        let previous = MCPOAuthStore.load(config.id)
        let client: MCPOAuth.Client
        if let previous, previous.server.issuer == discovery.server.issuer {
            client = previous.client
        } else {
            client = try await MCPOAuth.register(discovery.server)
        }
        let pkce = MCPOAuth.PKCE.make()
        let state = MCPOAuth.randomToken()
        guard let authorize = MCPOAuth.authorizationURL(server: discovery.server, client: client, pkce: pkce, state: state,
                                                        resource: discovery.resource, scope: discovery.scope) else {
            throw MCPOAuthError.noAuthorizationServer
        }
        let callback = try await present(authorize)
        switch MCPOAuth.parseCallback(callback, expectedState: state, issuer: discovery.server.issuer) {
        case .failed(let error):
            throw error
        case .code(let code):
            let tokens = try await MCPOAuth.exchange(code: code, verifier: pkce.verifier, server: discovery.server,
                                                     client: client, resource: discovery.resource)
            let credentials = MCPOAuth.Credentials(server: discovery.server, client: client, tokens: tokens,
                                                   resource: discovery.resource, scope: discovery.scope)
            guard MCPOAuthStore.save(credentials, for: config.id) else {
                throw NookError(tr("connect.error.keychain"), kind: .config)
            }
        }
    }

    /// The service's sign-in page in a system window that shares the browser's logins and password manager.
    /// The window itself catches the redirect back to `nook://`, so no other app can.
    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MCPOAuth.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MCPOAuthError.cancelled)
                } else {
                    continuation.resume(throwing: MCPOAuthError.callbackFailed(error?.localizedDescription ?? "no answer"))
                }
            }
            session.presentationContextProvider = self
            // Use the browser's existing login, so most people only have to click "Allow".
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: MCPOAuthError.callbackFailed("the sign-in window did not open"))
            }
        }
    }
}

extension MCPSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
