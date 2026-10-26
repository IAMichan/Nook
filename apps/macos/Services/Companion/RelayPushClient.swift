import Foundation
import Combine

/// Push through the relay (`RelayPush`, apps/relay/worker/push.js): for everyone without an Apple developer account. Each
/// notification is sealed with the phone's pairing key (a push key derived from it) and posted with its device token to
/// the relay, which forwards it to Apple with Nook's own APNs key. Only the phone can read it. The other way, the user's
/// own .p8 key (`APNsClient`), stays as it was and is still what Live Activities need.
@MainActor
final class RelayPushClient: ObservableObject {
    static let shared = RelayPushClient()

    enum Route: String {
        /// Through the relay in use (Nook's, or the user's own with the APNS_* secrets).
        case relay
        /// Straight to Apple with the user's own APNs key.
        case own
    }

    @Published var route: Route {
        didSet { UserDefaults.standard.set(route.rawValue, forKey: Self.routeKey) }
    }

    private static let routeKey = "companion.push.route"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.routeKey).flatMap(Route.init(rawValue:))
        // Someone who already set up their own key keeps it; everyone else starts on the relay when the build has one.
        route = stored ?? (CompanionStore.shared.canPush || CompanionRelayClient.nookRelay == nil ? .own : .relay)
    }

    /// The relay pushes go through.
    var relay: String? { CompanionRelayClient.shared.current }

    /// Notifications go through the relay now.
    var active: Bool { route == .relay && relay.flatMap(RelayPush.endpoint(relay:)) != nil }

    /// Seals `content` for `device` and posts it to the relay.
    func send(_ content: RelayPushContent, to device: PairedDevice, collapseKey: String, urgent: Bool) async -> APNsClient.Result {
        guard let token = device.pushToken, let key = CompanionStore.key(for: device.id),
              let url = relay.flatMap(RelayPush.endpoint(relay:)) else {
            return APNsClient.Result(outcome: .configuration, status: 0, reason: "not configured")
        }
        let collapse = RelayPush.collapseID(collapseKey, pushKey: RelayPush.pushKey(pairingKey: key))
        guard let envelope = try? RelayPush.seal(content, pairingKey: key, deviceID: device.id),
              let request = RelayPush.request(envelope: envelope, room: CompanionRelay.room(forKey: key), token: token,
                                              production: device.pushProduction ?? true, collapse: collapse, urgent: urgent),
              let body = try? JSONEncoder().encode(request) else {
            return APNsClient.Result(outcome: .configuration, status: 0, reason: "could not seal")
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.httpBody = body
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            let (data, response) = try await session.data(for: http)
            let answer = RelayPush.outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
            return APNsClient.Result(outcome: answer.outcome, status: answer.apns, reason: answer.reason)
        } catch {
            return APNsClient.Result(outcome: .retryLater, status: 0, reason: error.localizedDescription)
        }
    }
}
