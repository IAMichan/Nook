import Foundation

/// Links chat apps (Instagram, WhatsApp, Telegram, Teams…) from Settings › Chats › Linked chats, one login at a time,
/// through the local chat service on this Mac that `BeeperBridge` reads: it lists what can be linked, walks a login
/// through its steps (fields to fill in, a QR code to scan, signing in on the app's website) and unlinks an account.
/// Once a login is complete the app's chats come in through `BeeperBridge` like every linked chat.
@MainActor
final class ChatLinker: ObservableObject {
    static let shared = ChatLinker()

    @Published private(set) var networks: [ChatLinkData.Network] = []
    @Published private(set) var isLoading = false
    /// Why the apps could not be listed; nil while it works.
    @Published private(set) var problem: String?
    /// The login under way, with the app it links; nil while none is.
    @Published private(set) var session: ChatLinkData.Session?
    @Published private(set) var linking: ChatLinkData.Network?
    /// A step is on its way: the row shows it is busy.
    @Published private(set) var isSending = false
    /// Why the last step did not go, in the app's own words.
    @Published private(set) var stepProblem: String?

    private var waiting: Task<Void, Never>?
    private var bridge: BeeperBridge { ChatCaptureService.shared.beeperBridge }

    private static func path(_ network: String) -> String {
        "/v1/bridges/" + (network.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? network)
    }

    private static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
    }

    /// The apps that can be linked, and their linked accounts.
    func refresh() async {
        guard let token = BeeperBridge.token else {
            networks = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            networks = ChatLinkData.networks(try await bridge.get("/v1/bridges", [:], token: token))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Logging in

    /// Starts linking an account in `network`, after your own click.
    func link(_ network: ChatLinkData.Network) async {
        await cancel()
        linking = network
        stepProblem = nil
        await send { token in
            try await self.bridge.call("POST", Self.path(network.id) + "/login-sessions", [:], token: token, timeout: 60,
                                       failure: tr("chats.link.failed"), plain: true)
        }
    }

    /// What you filled in for the current step.
    func submit(_ values: [String: String]) async {
        guard let step = session?.step else { return }
        await answer(step, body: ChatLinkData.answer(step, values: values))
    }

    /// What the sign-in window collected on the app's website.
    func submitBrowser(_ values: [String: String], lastURL: String?) async {
        guard let step = session?.step, case .browser = step else { return }
        await answer(step, body: ChatLinkData.answer(step, values: values, lastURL: lastURL))
    }

    /// Stops the login under way, after your own click (or when another one starts).
    func cancel() async {
        waiting?.cancel()
        waiting = nil
        defer {
            session = nil
            linking = nil
            isSending = false
        }
        guard let session, !session.isOver, let token = BeeperBridge.token else { return }
        _ = try? await bridge.call("DELETE", Self.path(session.network) + "/login-sessions/" + Self.segment(session.id), nil,
                                   token: token, timeout: 15, failure: tr("chats.link.failed"), plain: true)
    }

    /// Unlinks an account from this Mac, after you confirmed it.
    func unlink(_ account: ChatLinkData.Account, in network: ChatLinkData.Network) async {
        guard let login = account.login, let token = BeeperBridge.token else { return }
        do {
            _ = try await bridge.call("POST", Self.path(network.id) + "/logins/" + Self.segment(login) + "/remove",
                                      ["scope": "current-device"], token: token, timeout: 30, failure: tr("chats.link.failed"), plain: true)
            ToastCenter.shared.success(tr("chats.link.unlinked", network.name))
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
        await refresh()
    }

    private func answer(_ step: ChatLinkData.Step, body: [String: any Sendable]) async {
        guard let session, let id = step.id else { return }
        stepProblem = nil
        await send { token in
            try await self.bridge.call("POST", Self.path(session.network) + "/login-sessions/" + Self.segment(session.id)
                                       + "/steps/" + Self.segment(id), body, token: token, timeout: 120,
                                       failure: tr("chats.link.failed"), plain: true)
        }
    }

    /// Sends one request of the login and takes the session it answers with.
    private func send(_ request: @escaping (String) async throws -> Data) async {
        guard let token = BeeperBridge.token else {
            stepProblem = tr("chats.link.noToken")
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let data = try await request(token)
            guard let next = BeeperData.object(data).flatMap(ChatLinkData.session) else { throw NookError(tr("chats.link.failed")) }
            await took(next)
        } catch {
            stepProblem = error.localizedDescription
        }
    }

    /// A new state of the login: done, failed, or the next step to show.
    private func took(_ next: ChatLinkData.Session) async {
        session = next
        switch next.state {
        case .complete:
            let name = linking?.name ?? ""
            waiting?.cancel()
            session = nil
            linking = nil
            ToastCenter.shared.success(tr("chats.link.done", name))
            // The new account's chats come in right away, through the linked chats.
            let capture = ChatCaptureService.shared
            capture.setSource(capture.beeperBridge.app, on: true)
            capture.beeperBridge.reset()
            capture.bridgeChanged(capture.beeperBridge.app)
            await refresh()
        case .failed:
            stepProblem = next.problem ?? tr("chats.link.failed")
        case .cancelled:
            session = nil
            linking = nil
        case .waitingForDisplay:
            wait(next)
        case .waitingForInput, .waitingForCookies:
            break
        }
    }

    /// A QR code or code is shown: the login goes on by itself once you scanned or typed it on your phone. The step is
    /// answered (it returns once something happened) and, when that times out, the session is looked at again.
    private func wait(_ shown: ChatLinkData.Session) {
        waiting?.cancel()
        guard let step = shown.step, let stepID = step.id else { return }
        waiting = Task { [weak self] in
            guard let self, let token = BeeperBridge.token else { return }
            let base = Self.path(shown.network) + "/login-sessions/" + Self.segment(shown.id)
            // A service that does not wait on the step answers at once with an error: from then on it is only looked at.
            var answers = true
            while !Task.isCancelled, self.session?.id == shown.id, self.session?.step == step {
                if answers {
                    let answered = try? await self.bridge.call("POST", base + "/steps/" + Self.segment(stepID),
                                                               ChatLinkData.answer(step), token: token, timeout: 120,
                                                               failure: tr("chats.link.failed"), plain: true)
                    guard !Task.isCancelled, self.session?.id == shown.id else { return }
                    if let answered, let next = BeeperData.object(answered).flatMap(ChatLinkData.session), next != shown {
                        self.waiting = nil
                        await self.took(next)
                        return
                    }
                    if answered == nil { answers = false }
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if let json = try? await self.bridge.get(base, [:], token: token), let next = ChatLinkData.session(json), next != shown {
                    self.waiting = nil
                    await self.took(next)
                    return
                }
            }
        }
    }
}
