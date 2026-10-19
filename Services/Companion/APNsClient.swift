import Foundation
import CryptoKit

/// Sends a push to Apple's service with the user's own APNs key (token-based authentication): the Mac signs an ES256 token
/// and posts the payload over HTTP/2. No server of ours sees the notification; Apple does, which is why the text is short.
@MainActor
final class APNsClient {
    static let shared = APNsClient()

    struct Result {
        var outcome: APNsJWT.Outcome
        var status: Int
        var reason: String?
    }

    private var cached: (token: String, issued: Date)?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// A signed token, reused for fifty minutes (Apple refuses a new one more often than every twenty).
    private func token(now: Date = Date()) -> String? {
        if let cached, now.timeIntervalSince(cached.issued) < APNsJWT.lifetime { return cached.token }
        let store = CompanionStore.shared
        guard let pem = store.apnsKeyPEM(), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem),
              let input = APNsJWT.signingInput(keyID: store.apnsKeyID, teamID: store.apnsTeamID, issuedAt: now),
              let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        let jwt = input + "." + Base64URL.encode(signature.rawRepresentation)
        cached = (jwt, now)
        return jwt
    }

    func forgetToken() { cached = nil }

    func send(payload: [String: Any], to deviceToken: String, production: Bool, collapseID: String, priority: Int = 10) async -> Result {
        let topic = "nl.imdigital.nook.companion"
        guard let url = APNsJWT.endpoint(production: production, deviceToken: deviceToken), let jwt = token(),
              let body = try? JSONSerialization.data(withJSONObject: payload), body.count <= 4_096 else {
            return Result(outcome: .configuration, status: 0, reason: "not configured")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            // A rejected key must not stay cached: the next try signs again.
            if status == 403 { cached = nil }
            return Result(outcome: APNsJWT.outcome(status: status, reason: reason), status: status, reason: reason)
        } catch {
            return Result(outcome: .retryLater, status: 0, reason: error.localizedDescription)
        }
    }
}
