import Foundation

/// The sessions shared through a guest link (see `GuestLink`). Each link has one outgoing WebSocket to the relay, in a room
/// of its own, as the companion's rooms are. Nothing runs per frame: the view goes to a guest only while one is connected,
/// at most twice a second, and only when the session's timeline changed; the socket's keep-alive is answered by the relay
/// without waking it.
@MainActor
final class GuestShares: ObservableObject {
    static let shared = GuestShares()

    /// Shared sessions and until when their link works.
    @Published private(set) var shared: [UUID: Date] = [:]
    /// What guests wrote, waiting for you, per session.
    @Published private(set) var held: [UUID: [GuestHold.Held]] = [:]
    /// How many guests follow each shared session now.
    @Published private(set) var watching: [UUID: Int] = [:]

    weak var workspace: WorkspaceManager?

    private final class Link {
        let share: GuestShare
        var loop: Task<Void, Never>?
        var expiry: Task<Void, Never>?
        var socket: URLSessionWebSocketTask?
        var peers: Set<UInt32> = []
        var slices = GuestSlices()
        var hold = GuestHold()
        var lastSent = Data()
        var pushScheduled = false
        var shownTimeline = false
        var observer: Task<Void, Never>?
        init(share: GuestShare) { self.share = share }
    }

    private var links: [UUID: Link] = [:]
    private static let account = "guest.shares"
    private static let keepAlive: UInt64 = 30

    /// Where guests' files wait: one folder per message, removed when it is dismissed or the link ends.
    static var filesDirectory: URL { NookPaths.supportDirectory.appendingPathComponent("guest-files", isDirectory: true) }

    // MARK: Lifecycle

    /// At launch: takes up the links that still work. Files of messages that waited when Nook quit are gone with them.
    func start(workspace: WorkspaceManager) {
        self.workspace = workspace
        try? FileManager.default.removeItem(at: Self.filesDirectory)
        let saved = SecretStore.read(Self.account).flatMap { try? JSONDecoder().decode([GuestShare].self, from: Data($0.utf8)) } ?? []
        let live = GuestShare.live(saved)
        if live != saved { persist(live) }
        for share in live where workspace.run(share.runID) != nil { open(share) }
    }

    /// Whether a link can be made: it needs a relay (Settings › Devices › Away from home, or Nook's own).
    var canShare: Bool { CompanionRelayClient.shared.current != nil }

    /// The link of a shared session.
    func link(_ id: UUID) -> String? {
        guard let link = links[id], let relay = CompanionRelayClient.shared.current else { return nil }
        return GuestLinkRoom.url(relay: relay, key: link.share.key)
    }

    /// Starts sharing (or answers the link that works already); nil without a relay.
    @discardableResult
    func share(_ id: UUID) -> String? {
        if let existing = link(id) { return existing }
        guard canShare, workspace?.run(id) != nil else { return nil }
        let share = GuestShare(runID: id, key: GuestLinkSeal.newKey())
        open(share)
        persist(links.values.map(\.share))
        return link(id)
    }

    /// Ends the link now: the page hears it, waiting messages and their files go, and a new link gets a new key.
    func stop(_ id: UUID) {
        guard let link = links.removeValue(forKey: id) else { return }
        send(.ended, link, to: link.peers)
        link.loop?.cancel()
        link.expiry?.cancel()
        link.observer?.cancel()
        if link.shownTimeline { workspace?.timelineHidden(id) }
        for message in link.hold.takeAll() { removeFiles(message) }
        let socket = link.socket
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            socket?.cancel(with: .goingAway, reason: nil)
        }
        shared[id] = nil
        held[id] = nil
        watching[id] = nil
        persist(links.values.map(\.share))
    }

    /// Nook quits: the sockets close; the links work again at the next launch, within their 24 hours.
    func suspend() {
        for link in links.values {
            link.loop?.cancel()
            link.socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: Messages that wait

    /// Sends a guest's message to the agent as your next message, with its files.
    func sendHeld(_ id: UUID, message: String) {
        guard let link = links[id], let taken = link.hold.take(message) else { return }
        held[id] = link.hold.messages
        workspace?.submit(id, text: GuestLink.framed(taken.text, files: taken.files))
        schedulePush(id)
    }

    func dismissHeld(_ id: UUID, message: String) {
        guard let link = links[id], let taken = link.hold.take(message) else { return }
        held[id] = link.hold.messages
        removeFiles(taken)
        schedulePush(id)
    }

    // MARK: The socket

    private func open(_ share: GuestShare) {
        guard let relay = CompanionRelayClient.shared.current,
              let url = CompanionRelay.socketURL(relay: relay, room: share.room, role: .mac) else { return }
        let link = Link(share: share)
        links[share.runID] = link
        shared[share.runID] = share.until
        link.loop = Task { [weak self] in await self?.run(share.runID, link, url) }
        let wait = max(0, share.until.timeIntervalSinceNow)
        link.expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(share.runID)
        }
    }

    private func run(_ id: UUID, _ link: Link, _ url: URL) async {
        var delay: UInt64 = 2
        while !Task.isCancelled, link.share.isLive() {
            let socket = URLSession.shared.webSocketTask(with: url)
            link.socket = socket
            link.peers = []
            socket.resume()
            socket.send(.string("ping")) { _ in }
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.keepAlive * 1_000_000_000)
                    socket.send(.string("ping")) { _ in }
                }
            }
            while !Task.isCancelled, let message = try? await socket.receive() {
                delay = 2
                guard case .data(let data) = message, let frame = RelayMux.decode(data) else { continue }
                received(frame, id, link)
            }
            keepAlive.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            peersChanged(id, link, to: [])
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 60)
        }
    }

    private func received(_ frame: RelayMux.Message, _ id: UUID, _ link: Link) {
        guard links[id] === link else { return }
        switch frame.kind {
        case .open:
            peersChanged(id, link, to: link.peers.union([frame.connection]))
            link.lastSent = Data()
            push(id, link, to: [frame.connection])
        case .close:
            peersChanged(id, link, to: link.peers.subtracting([frame.connection]))
        case .data:
            guard link.share.isLive(), let plain = GuestLinkSeal.open(frame.payload, key: link.share.key) else { return }
            switch link.slices.add(plain) {
            case .waiting: break
            case .refused(let messageID, let refusal):
                if let messageID { send(.ack(messageID, refusal), link, to: [frame.connection]) }
            case .complete(let messageID, let json):
                take(messageID, json, id, link, from: frame.connection)
            }
        }
    }

    private func take(_ messageID: String, _ json: Data, _ id: UUID, _ link: Link, from connection: UInt32) {
        switch GuestLink.message(id: messageID, json: json) {
        case .failure(let refusal):
            send(.ack(messageID, refusal), link, to: [connection])
        case .success(let message):
            if let refusal = link.hold.refusal(forBytes: message.bytes) {
                send(.ack(messageID, refusal), link, to: [connection])
                return
            }
            guard let files = save(message, id) else {
                send(.ack(messageID, .malformed), link, to: [connection])
                return
            }
            link.hold.add(GuestHold.Held(id: UUID().uuidString, text: message.text, files: files, bytes: message.bytes,
                                         received: Date()))
            held[id] = link.hold.messages
            send(.ack(messageID, nil), link, to: [connection])
            schedulePush(id)
        }
    }

    private func peersChanged(_ id: UUID, _ link: Link, to peers: Set<UInt32>) {
        link.peers = peers
        let count = peers.count
        if watching[id] != (count == 0 ? nil : count) { watching[id] = count == 0 ? nil : count }
        // While someone follows, the timeline stays in memory, and its changes reach them.
        if count > 0, !link.shownTimeline {
            link.shownTimeline = true
            workspace?.timelineShown(id)
            link.observer = observe(id)
        } else if count == 0, link.shownTimeline {
            link.shownTimeline = false
            link.observer?.cancel()
            link.observer = nil
            workspace?.timelineHidden(id)
        }
    }

    private func observe(_ id: UUID) -> Task<Void, Never>? {
        guard let workspace else { return nil }
        let changes = workspace.timelineChanges(for: id).objectWillChange.values
        return Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                self.schedulePush(id)
            }
        }
    }

    /// At most twice a second, after the change has landed.
    private func schedulePush(_ id: UUID) {
        guard let link = links[id], !link.peers.isEmpty, !link.pushScheduled else { return }
        link.pushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, let link = self.links[id] else { return }
            link.pushScheduled = false
            self.push(id, link, to: link.peers)
        }
    }

    private func push(_ id: UUID, _ link: Link, to peers: Set<UInt32>) {
        guard !peers.isEmpty, let workspace else { return }
        guard let run = workspace.run(id), !run.archived else {
            stop(id)
            return
        }
        let view = GuestLink.Outgoing.view(title: run.title, working: run.status.isActive,
                                           entries: GuestLink.entries(workspace.timeline(id)), held: link.hold.notes,
                                           until: link.share.until)
        guard let plain = try? JSONEncoder().encode(view) else { return }
        // Everyone already has this; a new guest (one peer) always gets it.
        if peers == link.peers, plain == link.lastSent { return }
        if peers == link.peers { link.lastSent = plain }
        send(plain, link, to: peers)
    }

    private func send(_ message: GuestLink.Outgoing, _ link: Link, to peers: Set<UInt32>) {
        guard let plain = try? JSONEncoder().encode(message) else { return }
        send(plain, link, to: peers)
    }

    private func send(_ plain: Data, _ link: Link, to peers: Set<UInt32>) {
        guard let socket = link.socket, let sealed = GuestLinkSeal.seal(plain, key: link.share.key) else { return }
        for peer in peers {
            socket.send(.data(RelayMux.encode(.data, connection: peer, payload: sealed))) { _ in }
        }
    }

    // MARK: Files and the keychain

    /// Saves a message's files, readable only by you; nil when that fails.
    private func save(_ message: GuestLink.Message, _ id: UUID) -> [String]? {
        guard !message.files.isEmpty else { return [] }
        let folder = Self.filesDirectory.appendingPathComponent(id.uuidString.prefix(8).lowercased())
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var paths: [String] = []
            var used = Set<String>()
            for file in message.files {
                var name = file.name
                if !used.insert(name).inserted { name = "\(paths.count + 1)-" + name }
                let url = folder.appendingPathComponent(name)
                try file.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                paths.append(url.path)
            }
            return paths
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    private func removeFiles(_ message: GuestHold.Held) {
        guard let first = message.files.first else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: first).deletingLastPathComponent())
    }

    private func persist(_ shares: [GuestShare]) {
        if shares.isEmpty {
            _ = SecretStore.remove(Self.account)
        } else if let data = try? JSONEncoder().encode(shares) {
            _ = SecretStore.write(String(decoding: data, as: UTF8.self), account: Self.account)
        }
    }
}
