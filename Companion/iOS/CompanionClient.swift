import Foundation
import Network
import UIKit

/// The phone's side: one short connection per request (connect, send a sealed request, read the sealed answer, close).
/// While the app is in front it asks for the list every few seconds; nothing runs in the background.
@MainActor
final class CompanionClient: ObservableObject {
    enum Phase: Equatable {
        case unpaired
        case pairing
        case connected
        case offline(String)
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sessions: [SessionDigest] = []
    @Published private(set) var macName = ""
    @Published var notice: String?

    private var link: PairingLink?
    private var poll: Task<Void, Never>?

    init() {
        link = PairingStore.load()
        macName = link?.macName ?? ""
        phase = link == nil ? .unpaired : .offline("")
    }

    // MARK: Pairing

    /// Pairs with the code the Mac shows. The first request, `hello`, proves the phone holds the key; the Mac then keeps the device.
    func pair(link text: String) {
        guard let parsed = PairingLink.parse(text) else { notice = "Dat is geen geldige koppelcode."; return }
        phase = .pairing
        notice = nil
        Task {
            do {
                let response = try await request(CompanionRequest(op: .hello, text: UIDevice.current.name), using: parsed)
                guard response.ok else { throw CompanionClientError.refused(response.error) }
                guard PairingStore.save(parsed) else { throw CompanionClientError.storage }
                link = parsed
                macName = response.macName ?? parsed.macName
                sessions = response.sessions ?? []
                phase = .connected
                startPolling()
            } catch {
                phase = link == nil ? .unpaired : .offline(error.localizedDescription)
                notice = "Koppelen mislukt: \(error.localizedDescription) De code werkt vijf minuten en één keer; maak op de Mac een nieuwe."
            }
        }
    }

    func unpair() {
        poll?.cancel()
        PairingStore.clear()
        link = nil
        sessions = []
        phase = .unpaired
    }

    // MARK: Polling and actions

    func startPolling() {
        poll?.cancel()
        guard link != nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPolling() { poll?.cancel() }

    func refresh() async {
        guard link != nil else { return }
        await perform(CompanionRequest(op: .list))
    }

    func decide(_ session: SessionDigest, item: SessionDigest.Item, allow: Bool) async {
        await perform(CompanionRequest(op: .decide, session: session.id, item: item.id, allow: allow))
    }

    func answer(_ session: SessionDigest, item: SessionDigest.Item, text: String) async {
        await perform(CompanionRequest(op: .answer, session: session.id, item: item.id, text: text))
    }

    func send(_ session: SessionDigest, text: String) async {
        await perform(CompanionRequest(op: .send, session: session.id, text: text))
    }

    func stop(_ session: SessionDigest) async {
        await perform(CompanionRequest(op: .stop, session: session.id))
    }

    private func perform(_ req: CompanionRequest) async {
        guard let link else { return }
        do {
            let response = try await request(req, using: link)
            if response.ok {
                if let list = response.sessions { sessions = list }
                if let name = response.macName { macName = name }
                phase = .connected
                if let message = response.message { notice = message == "queued" ? "In de wachtrij: de sessie is nog bezig." : nil }
            } else {
                switch response.error {
                case .notAllowedFromPhone: notice = "Dat kan niet vanaf de telefoon: open het op je Mac."
                case .unknownItem, .unknownSession: notice = "Dat is al afgehandeld."; await refresh()
                case .stale: notice = "De klok van je telefoon en Mac loopt te ver uit elkaar."
                case .rateLimited: notice = "Even rustig aan."
                default: notice = "De Mac weigerde dit."
                }
            }
        } catch {
            phase = .offline(error.localizedDescription)
        }
    }

    // MARK: Transport

    private func request(_ req: CompanionRequest, using link: PairingLink) async throws -> CompanionResponse {
        let deviceID = PairedDevice.identifier(forKey: link.key)
        let plain = try JSONEncoder().encode(req)
        let sealed = try CompanionSeal.seal(plain, pairingKey: link.key, deviceID: deviceID, direction: .request)
        guard let framed = CompanionFrameReader.frame(sealed), let port = NWEndpoint.Port(rawValue: link.port) else {
            throw CompanionClientError.badRequest
        }
        let reply = try await Exchange.run(host: link.host, port: port, payload: framed)
        let opened = try CompanionSeal.open(reply, pairingKey: link.key, direction: .response)
        let response = try JSONDecoder().decode(CompanionResponse.self, from: opened)
        guard response.id == req.id else { throw CompanionClientError.badRequest }
        return response
    }
}

enum CompanionClientError: LocalizedError {
    case refused(CompanionError?)
    case storage, badRequest, timeout, closed

    var errorDescription: String? {
        switch self {
        case .refused: return "De Mac weigerde de code."
        case .storage: return "De sleutel kon niet worden bewaard."
        case .badRequest: return "Onbegrijpelijk antwoord van de Mac."
        case .timeout: return "De Mac antwoordt niet. Staat de companion aan en zit je op hetzelfde wifi?"
        case .closed: return "De verbinding werd verbroken."
        }
    }
}

/// One connection: send the frame, read until one whole frame came back, with a timeout.
private enum Exchange {
    static func run(host: String, port: NWEndpoint.Port, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let queue = DispatchQueue(label: "nook.companion.client")
            let box = Once(continuation)
            var reader = CompanionFrameReader()

            func finish(_ result: Result<Data, Error>) {
                connection.cancel()
                box.resume(result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        let frames = reader.feed(data)
                        if let first = frames.first { return finish(.success(first)) }
                        if reader.overflowed { return finish(.failure(CompanionClientError.badRequest)) }
                    }
                    if error != nil || complete { return finish(.failure(CompanionClientError.closed)) }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { finish(.failure(CompanionClientError.closed)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { finish(.failure(CompanionClientError.timeout)) }
        }
    }

    /// Resumes a continuation once, however many callbacks race.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?

        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        func resume(_ result: Result<Data, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
