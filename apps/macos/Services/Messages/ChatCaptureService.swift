import Foundation
import AppKit
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
    /// Chats someone just wrote in (their keys in `inbox`), newest last: Nook may tell you (Settings › Notifications).
    var onFresh: ([String]) -> Void = { _ in }
    /// Only a message this recent is news; older ones that come in (a first look, a long sleep) are for the Chats tab.
    static let newsWindow: TimeInterval = 600

    /// The apps Nook reads itself, with their history (`ChatBridge`): Messages from this Mac, Slack with a token,
    /// Telegram through TDLib once you logged in, Teams through Microsoft Graph once you signed in, Instagram through its
    /// own web API once you logged in on it inside Nook.
    let messagesBridge = MessagesBridge()
    let slackBridge = SlackBridge()
    let telegramBridge = TelegramBridge()
    let teamsBridge = TeamsBridge()
    /// WhatsApp from the WhatsApp app on this Mac while no phone is linked, and every app linked through Nook's own chat
    /// helper.
    let whatsAppDesktopBridge = WhatsAppDesktopBridge()
    let serviceBridge = ChatServiceBridge()
    /// The chat helper goes last: an app another bridge reads is left to that one.
    private var bridges: [ChatBridge] {
        [messagesBridge, whatsAppDesktopBridge, slackBridge, telegramBridge, teamsBridge, serviceBridge]
    }

    /// You logged in to an app from its row in Settings › Chats: it is switched on, collecting with it, and read now.
    func loggedIn(_ app: String) {
        setSource(app, on: true)
        if !enabled { enabled = true }
        bridgeChanged(app)
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
    /// Chats the helper has nothing older of (scrolled back to their start).
    private var noOlder: Set<String> = []
    private var bridgeDue: [String: Date] = [:]
    /// Quick reads still owed to a bridge after one of its app's notifications: the app's own server can list the
    /// message a few seconds after it notified, so one read right away may still miss it.
    private var bridgeNudges: [String: Int] = [:]
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
        serviceBridge.skips = { [weak self] app in
            guard let self else { return false }
            return self.bridges.contains { $0.app == app && $0.isWorking && $0 !== self.serviceBridge }
        }
        // A chat changed there this moment (its live line said so): read it at the next tick, not at its next turn.
        serviceBridge.onChange = { [weak self] in
            guard let self else { return }
            self.bridgeDue[self.serviceBridge.app] = nil
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
        bridgeNudges = [:]
        // A Telegram session from an earlier login starts by itself; a new login starts from Settings › Chats.
        if sources.isOn(telegramBridge.app) { telegramBridge.resume() }
        timer = Timer.scheduledCoalesced(withTimeInterval: Self.interval) { [weak self] _ in
            Task { @MainActor in
                await self?.pollTick()
            }
        }
        Task {
            await poll()
            await pollBridges()
        }
    }

    private var lastPollTime: Date = .distantPast

    /// Evaluates energy policy and display sleep state before polling databases.
    private func pollTick() async {
        let plan = EnergyMonitor.shared.plan
        if plan.reasons.contains(.displayAsleep) {
            guard Date().timeIntervalSince(lastPollTime) >= 15 else { return }
        } else {
            let interval = Self.interval * plan.slowdown
            guard Date().timeIntervalSince(lastPollTime) >= interval - 0.25 else { return }
        }
        lastPollTime = Date()
        await poll()
        await pollBridges()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        telegramBridge.stop()
        serviceBridge.stop()
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
        let before = inbox
        do {
            if inbox.lastRecord == nil { replaying = true }
            let wasReplaying = replaying
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
                          let notice = ChatCapture.notice(notification, webAppName: webAppName), !skips(notice) else { continue }
                    // A bridged app's notification says its bridge has something new: read it now, not at its next turn.
                    if isBridged(notice.app) {
                        if !replaying { nudge(notice.app) }
                        continue
                    }
                    guard inbox.add(notice, id: "n\(notification.record)") else { continue }
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
            if status != .running { status = .running }
            if changed {
                save()
                if !wasReplaying { announce(since: before) }
            }
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

    /// The names of the web apps in the Dock by bundle id, looked up once each (nil when it is not on this Mac).
    private var webAppNames: [String: String?] = [:]

    /// The name a web app in the Dock was given ("Instagram"), from its app bundle.
    private func webAppName(_ bundleID: String) -> String? {
        if let known = webAppNames[bundleID] { return known }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            let bundle = Bundle(url: url)
            return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        webAppNames.updateValue(name, forKey: bundleID)
        return name
    }

    // MARK: Bridges

    /// A working bridge brings this app's messages itself: its notifications would only repeat them.
    private func isBridged(_ app: String) -> Bool {
        bridges.contains { $0.app == app && $0.isWorking } || (serviceBridge.isWorking && serviceBridge.covered.contains(app))
    }

    /// Time between the quick reads after a bridged app's notification.
    private static let nudgeGap: TimeInterval = 5

    /// A notification of a bridged app came in: its bridge reads now, and twice more shortly after.
    private func nudge(_ app: String) {
        bridgeDue[app] = nil
        bridgeNudges[app] = 3
    }

    /// Reads every bridge that is due, of the apps that are on. Runs next to the notifications, also while those cannot
    /// be read: Slack needs no disk access.
    func pollBridges() async {
        guard enabled, !bridging else { return }
        bridging = true
        defer { bridging = false }
        var changed = false
        let before = inbox
        for bridge in bridges {
            // Each write to these fires `objectWillChange`, which redraws every chat view: write only what changed, so a
            // quiet tick every second costs no redraw.
            guard sources.isOn(bridge.app), bridge.isReady else {
                // This runs every second for every bridge that is off: write only on a change, since each write to a
                // published property redraws every view that watches the inbox.
                if bridgeProblems[bridge.app] != nil { bridgeProblems[bridge.app] = nil }
                if bridged.contains(bridge.app) { bridged.remove(bridge.app) }
                if bridge === serviceBridge, !bridged.isDisjoint(with: serviceBridge.covered) { bridged.subtract(serviceBridge.covered) }
                continue
            }
            if let due = bridgeDue[bridge.app], due > Date() { continue }
            let nudges = bridgeNudges[bridge.app] ?? 0
            bridgeNudges[bridge.app] = nudges > 1 ? nudges - 1 : nil
            bridgeDue[bridge.app] = Date().addingTimeInterval(nudges > 1 ? min(bridge.interval, Self.nudgeGap) : bridge.interval)
            do {
                let chats = try await bridge.read()
                // Merged into a copy: a read that brings nothing new (most of them) then leaves the published inbox alone.
                var merged = inbox
                var mergedAny = false
                for chat in chats where merged.merge(chat) { mergedAny = true }
                if mergedAny {
                    inbox = merged
                    changed = true
                }
                if bridgeProblems[bridge.app] != nil { bridgeProblems[bridge.app] = nil }
                // The chat helper reads several apps: each one it brought in is bridged.
                let apps: Set<String> = bridge === serviceBridge ? serviceBridge.covered.union([bridge.app]) : [bridge.app]
                if !apps.isSubset(of: bridged) { bridged.formUnion(apps) }
            } catch {
                let problem = error.localizedDescription
                if bridgeProblems[bridge.app] != problem { bridgeProblems[bridge.app] = problem }
                // Try again in a minute, not every few seconds.
                bridgeDue[bridge.app] = Date().addingTimeInterval(max(bridge.interval, 60))
            }
        }
        if changed {
            save()
            announce(since: before)
        }
    }

    /// Tells about the chats someone wrote in since `before`, in the apps that are on.
    private func announce(since before: ChatInbox) {
        let fresh = ChatInbox.fresh(before: before, after: inbox, since: Date().addingTimeInterval(-Self.newsWindow))
            .filter { inbox.threads[$0].map { sources.isOn($0.app) } ?? false }
        if !fresh.isEmpty { onFresh(fresh) }
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

    /// Read in Nook: kept in `chat-inbox.json`, so a restart does not bring the badge back. The app itself is not told.
    func markRead(_ id: String) {
        guard inbox.threads[id]?.unread ?? 0 > 0 else { return }
        inbox.markRead(id)
        save()
    }

    /// Read in the app too: after Nook told the app, or opened the chat there.
    func markReadInApp(_ id: String) {
        guard inbox.threads[id] != nil else { return }
        inbox.markReadInApp(id)
        save()
    }

    func markUnread(_ id: String) {
        guard inbox.threads[id]?.unread == 0 else { return }
        inbox.markUnread(id)
        save()
    }

    func markAllRead() {
        guard inbox.totalUnread > 0 else { return }
        inbox.markAllRead()
        save()
    }

    func remove(_ id: String) {
        inbox.remove(id)
        save()
    }

    /// A chat the chat helper brings in, with older messages there that Nook does not show yet.
    func canLoadOlder(_ id: String) -> Bool {
        guard let thread = inbox.threads[id], !noOlder.contains(id) else { return false }
        return serviceBridge.chatID(app: thread.app, name: thread.name) != nil
    }

    /// Scrolls back in a chat the helper brings in: its next batch of older messages, kept from now on. False when no
    /// older one came in.
    func loadOlder(_ id: String) async -> Bool {
        guard let thread = inbox.threads[id] else { return false }
        let before = thread.messages.count
        do {
            let (chat, hasMore) = try await serviceBridge.older(app: thread.app, name: thread.name, have: before)
            if !hasMore { noOlder.insert(id) }
            guard let chat else { return false }
            var merged = inbox
            merged.grow(id, by: ChatServiceBridge.olderStep)
            merged.merge(chat)
            let after = merged.threads[id]?.messages.count ?? before
            guard after > before else { return false }
            inbox = merged
            save()
            return true
        } catch {
            return false
        }
    }

    /// Chats brought over from another app (`BeeperImporter`), merged like a bridge's; how many changed.
    func importChats(_ chats: [BridgedChat]) -> Int {
        var changed = 0
        for chat in chats where inbox.merge(chat) { changed += 1 }
        if changed > 0 { save() }
        return changed
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
