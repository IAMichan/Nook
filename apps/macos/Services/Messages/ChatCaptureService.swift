import Foundation
import Combine

/// Collects the chats of every chat app on this Mac into `ChatInbox`: macOS keeps each notification it showed in a
/// database of its own, and Nook reads the new ones from it every few seconds, read-only. Telegram, Instagram (in the
/// browser), Messenger, Signal, Messages and the others thereby land in the Chats tab without an account or an API.
/// It needs Full Disk Access, is off until you turn it on in Settings (Connections › On your Mac), and keeps what it
/// collected only on this Mac (`chat-inbox.json` in Nook's support folder, readable by you alone).
@MainActor
final class ChatCaptureService: ObservableObject {
    static let shared = ChatCaptureService()

    enum Status: Equatable {
        case off
        /// macOS does not let Nook read its notifications: Full Disk Access is missing.
        case needsAccess
        case running
        case failed(String)
    }

    @Published private(set) var inbox: ChatInbox
    @Published private(set) var status: Status = .off
    /// Which apps feed the inbox (Settings › Chats): the known ones you did not switch off, and the ones you added.
    @Published private(set) var sources = MessagingApps.sources
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            ConnectorToggle.set(ChatInboxConnector.sourceID, enabled)
            enabled ? start() : stop()
        }
    }

    /// A notification Nook already has another way (WhatsApp, while the phone is linked, arrives live).
    var skips: (ChatNotice) -> Bool = { _ in false }

    /// The apps Nook reads itself, with their history (`ChatBridge`): Messages from this Mac, Slack with a token,
    /// Telegram through TDLib once you logged in, Teams through Microsoft Graph once you signed in.
    let messagesBridge = MessagesBridge()
    let slackBridge = SlackBridge()
    let telegramBridge = TelegramBridge()
    let teamsBridge = TeamsBridge()
    /// WhatsApp from the WhatsApp app on this Mac while no phone is linked, and every network linked in Beeper.
    let whatsAppDesktopBridge = WhatsAppDesktopBridge()
    let beeperBridge = BeeperBridge()
    /// Beeper goes last: a network another bridge reads is left to that one.
    private var bridges: [ChatBridge] {
        [messagesBridge, whatsAppDesktopBridge, slackBridge, telegramBridge, teamsBridge, beeperBridge]
    }

    /// The bridge of an app, if Nook has one.
    func bridge(for app: String) -> ChatBridge? {
        bridges.first { $0.app == app }
    }

    /// A bridge's sign-in changed (Telegram logged in, Teams signed in): read it now instead of at its next turn.
    func bridgeChanged(_ app: String) {
        bridgeDue[app] = nil
        bridged.remove(app)
        bridgeProblems[app] = nil
        Task { await pollBridges() }
    }
    /// Why a bridge could not read, per app; empty while all of them work.
    @Published private(set) var bridgeProblems: [String: String] = [:]
    /// The apps whose bridge read at least once: their chats come in with history, not only from notifications.
    @Published private(set) var bridged: Set<String> = []
    private var bridgeDue: [String: Date] = [:]
    private var bridging = false

    /// How often the database is looked at. Only a database that changed is read, so looking is cheap; looking often
    /// matters because Slack and Teams take a notification back as soon as you read the message elsewhere.
    private static let interval: TimeInterval = 1
    /// A first start shows what came in this long ago: macOS keeps the notifications it showed for a while, so the
    /// chats of the last weeks are there at once instead of only the ones that write after switching on.
    private static let firstLook: TimeInterval = 14 * 86_400
    /// What came in before this long ago, on a first start, counts as read: it was likely seen on the Mac already.
    private static let freshness: TimeInterval = 3600

    private static var file: URL { NookPaths.supportDirectory.appendingPathComponent("chat-inbox.json") }
    private var timer: Timer?
    private var polling = false
    private var lastChange: Date?
    /// After a failed read (no Full Disk Access yet) the next try waits a little, instead of a read every second.
    private var retryAt: Date?
    /// The last look stopped at its page limit: the next one goes on even when the database did not change.
    private var backlog = false
    /// Looking back after a start: what comes in from before `freshness` counts as read, until the look-back is done.
    private var replaying = false
    /// Counts starts and stops, so a look still running from before one does not write over what came after.
    private var generation = 0

    private init() {
        var inbox = SafeStorage.load(ChatInbox.self, from: Self.file).value ?? ChatInbox()
        inbox.trim()
        self.inbox = inbox
        enabled = ConnectorToggle.isOn(ChatInboxConnector.sourceID, default: false)
        beeperBridge.skips = { [weak self] app in
            guard let self else { return false }
            return self.bridges.contains { $0.app == app && $0.isWorking && $0 !== self.beeperBridge }
        }
    }

    private var databasePath: String { NotificationRecord.databasePath(home: AppDatabase.home) }

    func start() {
        guard enabled else { return }
        timer?.invalidate()
        lastChange = nil
        retryAt = nil
        backlog = false
        generation += 1
        // Nothing collected yet (a start before Full Disk Access, or before any chat wrote), or an earlier version looked
        // back less far: look back again. What is already here is not added twice.
        if inbox.threads.isEmpty || (inbox.lookedBack ?? 0) < Self.firstLook {
            inbox.lastRecord = nil
            inbox.lookedBack = Self.firstLook
        }
        bridgeDue = [:]
        // A Telegram session from an earlier login starts by itself; a new login starts from Settings › Chats.
        if sources.isOn(telegramBridge.app) { telegramBridge.resume() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
                await self?.pollBridges()
            }
        }
        timer?.tolerance = 0.5
        Task {
            await poll()
            await pollBridges()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        telegramBridge.stop()
        status = .off
    }

    /// Reads what was added to the database since the last look. Does nothing while the database did not change.
    func poll() async {
        guard enabled, !polling else { return }
        let change = modified()
        if status == .running, !backlog, change != nil, change == lastChange { return }
        if let retryAt, retryAt > Date() { return }
        polling = true
        defer { polling = false }
        let started = generation
        do {
            if inbox.lastRecord == nil { replaying = true }
            let seen = Date().addingTimeInterval(-Self.freshness)
            var lastRecord = inbox.lastRecord
            var changed = false
            var full = false
            // At most a few pages in one go; the rest of a backlog (a look back, a long sleep) follows on the next looks.
            for _ in 0..<5 {
                let rows = try await AppDatabase.query(databasePath, NotificationRecord.query(
                    after: lastRecord, since: Date().addingTimeInterval(-Self.firstLook)), app: tr("chats.capture.source"))
                guard started == generation else { return }
                for row in rows {
                    guard let record = NotificationRecord.integer(row["id"]) else { continue }
                    lastRecord = max(lastRecord ?? record, record)
                    guard let notification = NotificationRecord.notification(row),
                          let notice = ChatCapture.notice(notification), !skips(notice), !isBridged(notice.app),
                          inbox.add(notice, id: "n\(notification.record)") else { continue }
                    changed = true
                    // Looking back: what came in before `freshness` was likely seen on the Mac already.
                    let key = ChatInbox.key(app: notice.app, chat: notice.chat)
                    if replaying, notice.date < seen, let unread = inbox.threads[key]?.unread, unread > 0 {
                        inbox.threads[key]?.unread = unread - 1
                    }
                }
                if lastRecord == nil {
                    // Nothing in the last day: start after the newest notification there is.
                    let newest = try await AppDatabase.query(databasePath, NotificationRecord.newestQuery, app: tr("chats.capture.source"))
                    guard started == generation else { return }
                    lastRecord = NotificationRecord.integer(newest.first?["id"]) ?? 0
                }
                full = rows.count >= 200
                if !full { break }
            }
            backlog = full
            if !full { replaying = false }
            if lastRecord != inbox.lastRecord {
                inbox.lastRecord = lastRecord
                changed = true
            }
            lastChange = change
            retryAt = nil
            status = .running
            if changed { save() }
        } catch let error as NookError where error.kind == .auth {
            guard started == generation else { return }
            status = .needsAccess
            retryAt = Date().addingTimeInterval(10)
        } catch {
            guard started == generation else { return }
            status = .failed(error.localizedDescription)
            retryAt = Date().addingTimeInterval(10)
        }
    }

    // MARK: Bridges

    /// A working bridge brings this app's messages itself: its notifications would only repeat them.
    private func isBridged(_ app: String) -> Bool {
        bridges.contains { $0.app == app && $0.isWorking } || (beeperBridge.isWorking && beeperBridge.covered.contains(app))
    }

    /// Reads every bridge that is due, of the apps that are on. Runs next to the notifications, also while those cannot
    /// be read: Slack needs no disk access.
    func pollBridges() async {
        guard enabled, !bridging else { return }
        bridging = true
        defer { bridging = false }
        var changed = false
        for bridge in bridges {
            guard sources.isOn(bridge.app), bridge.isReady else {
                bridgeProblems[bridge.app] = nil
                bridged.remove(bridge.app)
                continue
            }
            if let due = bridgeDue[bridge.app], due > Date() { continue }
            bridgeDue[bridge.app] = Date().addingTimeInterval(bridge.interval)
            do {
                for chat in try await bridge.read() where inbox.merge(chat) { changed = true }
                bridgeProblems[bridge.app] = nil
                bridged.insert(bridge.app)
            } catch {
                bridgeProblems[bridge.app] = error.localizedDescription
                // Try again in a minute, not every few seconds.
                bridgeDue[bridge.app] = Date().addingTimeInterval(max(bridge.interval, 60))
            }
        }
        if changed { save() }
    }

    /// The Slack token changed in Settings: read Slack again from the start.
    func slackTokenChanged() {
        slackBridge.reset()
        bridgeChanged(slackBridge.app)
    }

    // MARK: Sources

    func setSource(_ id: String, on: Bool) {
        changeSources { $0.set(id, on: on) }
    }

    /// Adds a website or a known app's name, as typed in Settings › Chats.
    @discardableResult
    func addSource(_ typed: String, name: String = "") -> ChatSources.Added {
        var result = ChatSources.Added.invalid
        changeSources { result = $0.add(typed, name: name) }
        return result
    }

    /// Adds a Mac app chosen in Settings › Chats.
    @discardableResult
    func addSource(bundleID: String, name: String) -> ChatSources.Added {
        var result = ChatSources.Added.invalid
        changeSources { result = $0.add(bundleID: bundleID, name: name) }
        return result
    }

    /// Forgets an app you added, and the chats collected from it.
    func removeSource(_ id: String) {
        changeSources { $0.remove(id) }
        let gone = inbox.threads.values.filter { $0.app == id }.map(\.id)
        guard !gone.isEmpty else { return }
        for thread in gone { inbox.remove(thread) }
        save()
    }

    private func changeSources(_ change: (inout ChatSources) -> Void) {
        var next = sources
        change(&next)
        guard next != sources else { return }
        MessagingApps.sources = next
        sources = next
    }

    func markRead(_ id: String) {
        guard inbox.threads[id]?.unread ?? 0 > 0 else { return }
        inbox.markRead(id)
        save()
    }

    func markAllRead() {
        inbox.markAllRead()
        save()
    }

    func remove(_ id: String) {
        inbox.remove(id)
        save()
    }

    /// Forgets every collected chat; the next look starts after the newest notification.
    func clear() {
        let last = inbox.lastRecord
        let lookedBack = inbox.lookedBack
        inbox = ChatInbox()
        inbox.lastRecord = last
        inbox.lookedBack = lookedBack
        save()
    }

    /// The database's last change: the file, or its write-ahead log where macOS writes first.
    private func modified() -> Date? {
        [databasePath, databasePath + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(inbox) else { return }
        try? SafeStorage.write(data, to: Self.file)
    }
}
