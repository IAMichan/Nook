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

    /// How often the database is looked at. Only a database that changed is read.
    private static let interval: TimeInterval = 4
    /// A first start shows what came in this long ago: macOS keeps the notifications it showed for a while, so the
    /// chats of the last weeks are there at once instead of only the ones that write after switching on.
    private static let firstLook: TimeInterval = 14 * 86_400
    /// What came in before this long ago, on a first start, counts as read: it was likely seen on the Mac already.
    private static let freshness: TimeInterval = 3600

    private static var file: URL { NookPaths.supportDirectory.appendingPathComponent("chat-inbox.json") }
    private var timer: Timer?
    private var polling = false
    private var lastChange: Date?

    private init() {
        var inbox = SafeStorage.load(ChatInbox.self, from: Self.file).value ?? ChatInbox()
        inbox.trim()
        self.inbox = inbox
        enabled = ConnectorToggle.isOn(ChatInboxConnector.sourceID, default: false)
    }

    private var databasePath: String { NotificationRecord.databasePath(home: AppDatabase.home) }

    func start() {
        guard enabled else { return }
        timer?.invalidate()
        lastChange = nil
        // Nothing collected yet (a start before Full Disk Access, or before any chat wrote): look back again.
        if inbox.threads.isEmpty { inbox.lastRecord = nil }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        timer?.tolerance = 1
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        status = .off
    }

    /// Reads what was added to the database since the last look. Does nothing while the database did not change.
    func poll() async {
        guard enabled, !polling else { return }
        let change = modified()
        if status == .running, change != nil, change == lastChange { return }
        polling = true
        defer { polling = false }
        do {
            let catchingUp = inbox.lastRecord == nil
            var lastRecord = inbox.lastRecord
            var changed = false
            // At most a few pages in one go; a backlog after a long sleep is read over the next looks.
            for _ in 0..<5 {
                let rows = try await AppDatabase.query(databasePath, NotificationRecord.query(
                    after: lastRecord, since: Date().addingTimeInterval(-Self.firstLook)), app: tr("chats.capture.source"))
                for row in rows {
                    guard let record = NotificationRecord.integer(row["id"]) else { continue }
                    lastRecord = max(lastRecord ?? record, record)
                    guard let notification = NotificationRecord.notification(row),
                          let notice = ChatCapture.notice(notification), !skips(notice) else { continue }
                    if inbox.add(notice, id: "n\(notification.record)") { changed = true }
                }
                if lastRecord == nil {
                    // Nothing in the last day: start after the newest notification there is.
                    let newest = try await AppDatabase.query(databasePath, NotificationRecord.newestQuery, app: tr("chats.capture.source"))
                    lastRecord = NotificationRecord.integer(newest.first?["id"]) ?? 0
                }
                if rows.count < 200 { break }
            }
            if catchingUp {
                let seen = Date().addingTimeInterval(-Self.freshness)
                for thread in inbox.threads.values where thread.unread > 0 && thread.last < seen { inbox.markRead(thread.id) }
            }
            if lastRecord != inbox.lastRecord {
                inbox.lastRecord = lastRecord
                changed = true
            }
            lastChange = change
            status = .running
            if changed { save() }
        } catch let error as NookError where error.kind == .auth {
            status = .needsAccess
        } catch {
            status = .failed(error.localizedDescription)
        }
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
        inbox = ChatInbox()
        inbox.lastRecord = last
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
