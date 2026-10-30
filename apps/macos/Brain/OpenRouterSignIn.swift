import Foundation
import AppKit
import AuthenticationServices

/// Signing in to OpenRouter instead of making a key: OpenRouter's own page asks you to log in and allow Nook (with a
/// spending limit if you like), sends a one-time code back to `nook://`, and Nook trades that code, with the PKCE
/// verifier only it knows, for a key of your own. The key goes straight into the Keychain like a pasted one.
@MainActor
final class OpenRouterSignIn: NSObject, ObservableObject {
    static let shared = OpenRouterSignIn()

    enum Phase: Equatable {
        case idle
        /// Waiting for the person to sign in on OpenRouter's page.
        case waiting
        case failed(String)
        case done
    }

    @Published private(set) var phase: Phase = .idle
    private var session: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?

    private static let callback = "nook://oauth/openrouter"

    func signIn(settings: AppSettings) {
        cancel()
        phase = .waiting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try await self.run()
                if let error = settings.saveProviderKey(key, for: .openrouter) {
                    self.phase = .failed(error)
                } else {
                    self.phase = .done
                }
            } catch {
                // A newer sign-in cancelled this one: it owns the phase now.
                guard !Task.isCancelled else { return }
                if (error as? MCPOAuthError) == .cancelled {
                    self.phase = .idle
                } else {
                    // Never the code, verifier or key: only what went wrong.
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        task?.cancel()
        task = nil
        if phase == .waiting { phase = .idle }
    }

    private func run() async throws -> String {
        let pkce = MCPOAuth.PKCE.make()
        var page = URLComponents(string: "https://openrouter.ai/auth")!
        page.queryItems = [
            URLQueryItem(name: "callback_url", value: Self.callback),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = page.url else { throw MCPOAuthError.callbackFailed("no sign-in page") }
        let answer = try await present(url)
        guard let code = URLComponents(url: answer, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPOAuthError.declined
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": pkce.verifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty else {
            throw MCPOAuthError.tokenFailed("OpenRouter")
        }
        return key
    }

    /// OpenRouter's page in a system window that shares the browser's login; it catches the way back to `nook://`.
    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MCPOAuth.callbackScheme) { answer, error in
                if let answer {
                    continuation.resume(returning: answer)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MCPOAuthError.cancelled)
                } else {
                    continuation.resume(throwing: MCPOAuthError.callbackFailed(error?.localizedDescription ?? "no answer"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: MCPOAuthError.callbackFailed("the sign-in window did not open"))
            }
        }
    }
}

extension OpenRouterSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
