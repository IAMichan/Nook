import Foundation
import Combine
import Security

/// The CLIProxyAPI hubs the user added in Settings and what each one reports about its accounts (`CLIProxyHub`).
///
/// A hub is read with one `GET /v0/management/auth-files`; the management key stays in the Keychain (`SecretStore`) and
/// goes only to the hub's own address, which `CLIProxyHub.base` limits to https or the local network. Nothing here asks
/// the hub to call a provider for an account, so no sign-in is used outside its own app. It reads when a usage view opens
/// (and every two minutes while one stays open, `AppModel.watchQuotas`) and when the user presses refresh, at most once
/// every ten seconds per hub; nothing runs on a timer while no usage view is open.
@MainActor
final class CLIProxyUsage: ObservableObject {
    /// What one hub answered last.
    struct Snapshot: Equatable {
        var accounts: [CLIProxyAccount] = []
        var readAt: Date?
        /// Why the last read failed; the accounts of the read before stay.
        var problem: Problem?
    }

    enum Problem: Error, Equatable {
        case noKey, badAddress, insecureAddress, rejectedKey, unreachable, notAHub
    }

    @Published private(set) var hubs: [CLIProxyHub]
    @Published private(set) var snapshots: [String: Snapshot] = [:]

    private static let hubsKey = "cliproxy.hubs"
    private static let minimumInterval: TimeInterval = 10
    private var busy = Set<String>()
    private var lastRead: [String: Date] = [:]
    private let session: URLSession

    init(session: URLSession = CLIProxyUsage.makeSession()) {
        self.session = session
        if let data = UserDefaults.standard.data(forKey: Self.hubsKey),
           let saved = try? JSONDecoder().decode([CLIProxyHub].self, from: data) {
            hubs = saved
        } else {
            hubs = []
        }
    }

    /// No cookies, no cache, no redirects to another host: the management key must not leave the address it was given for.
    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: Hubs

    /// Whether the address can be used, before the hub is added.
    static func check(address: String) -> Problem? {
        switch CLIProxyHub.base(address) {
        case .success: return nil
        case .failure(.invalid): return .badAddress
        case .failure(.insecure): return .insecureAddress
        }
    }

    /// Adds a hub and reads it. The key goes to the Keychain; when that fails the hub is not added.
    @discardableResult
    func add(label: String, address: String, key: String) -> Problem? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .noKey }
        if let problem = Self.check(address: address) { return problem }
        let hub = CLIProxyHub(id: UUID().uuidString.lowercased(), label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                              url: address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard SecretStore.write(trimmedKey, account: hub.secretAccount) == errSecSuccess else { return .noKey }
        hubs.append(hub)
        save()
        read(hub, force: true)
        return nil
    }

    func remove(_ hub: CLIProxyHub) {
        _ = SecretStore.remove(hub.secretAccount)
        hubs.removeAll { $0.id == hub.id }
        snapshots[hub.id] = nil
        lastRead[hub.id] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hubs) { UserDefaults.standard.set(data, forKey: Self.hubsKey) }
    }

    // MARK: Reading

    /// Reads every hub that was not read in the last ten seconds.
    func refreshNow() {
        for hub in hubs { read(hub, force: false) }
    }

    /// The refresh button: reads every hub now (unless it was read seconds ago) and returns once the answers are in.
    func refreshManually() async {
        refreshNow()
        while !busy.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    private func read(_ hub: CLIProxyHub, force: Bool) {
        if !force, let last = lastRead[hub.id], Date().timeIntervalSince(last) < Self.minimumInterval { return }
        guard busy.insert(hub.id).inserted else { return }
        lastRead[hub.id] = Date()
        let session = session
        let url = hub.url
        let account = hub.secretAccount
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.fetch(address: url, secretAccount: account, session: session)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(hub.id)
                guard self.hubs.contains(where: { $0.id == hub.id }) else { return }
                var snapshot = self.snapshots[hub.id] ?? Snapshot()
                switch result {
                case .success(let accounts):
                    snapshot = Snapshot(accounts: accounts, readAt: Date(), problem: nil)
                case .failure(let problem):
                    snapshot.problem = problem
                }
                if self.snapshots[hub.id] != snapshot { self.snapshots[hub.id] = snapshot }
            }
        }
    }

    private nonisolated static func fetch(address: String, secretAccount: String, session: URLSession) async -> Result<[CLIProxyAccount], Problem> {
        guard let key = SecretStore.read(secretAccount) else { return .failure(.noKey) }
        let base: URL
        switch CLIProxyHub.base(address) {
        case .success(let url): base = url
        case .failure(.invalid): return .failure(.badAddress)
        case .failure(.insecure): return .failure(.insecureAddress)
        }
        guard let url = CLIProxyHub.managementURL(base, path: "auth-files") else { return .failure(.badAddress) }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failure(.unreachable) }
            if status == 401 || status == 403 { return .failure(.rejectedKey) }
            guard (200..<300).contains(status), let accounts = CLIProxyReply.accounts(data) else { return .failure(.notAHub) }
            return .success(accounts)
        } catch {
            return .failure(.unreachable)
        }
    }

    // MARK: What the views show

    /// The accounts of one hub as the usage views show them: one entry per account with its windows.
    func accounts(of hub: CLIProxyHub) -> [CLIProxyAccount] { snapshots[hub.id]?.accounts ?? [] }
}
